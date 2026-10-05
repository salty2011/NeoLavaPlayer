extends Node
## AppleMusicStream: plays one `applemusic:<ID>` playlist entry through the
## Music app for AudioService (child node; AudioService calls poll() from its
## own _process so PCM and state arrive in a fixed order each frame).
##
## - play(id) sends `control play-id`, then keeps `watch --interval 0.25`
##   (now-playing) and `tap --app com.apple.Music` (the Music app's audio as
##   f32le stereo at `tap_rate`) running while the entry is current.
## - Transport truth: after `play-id` the state is "starting" (shown as
##   loading) until `watch` reports Music playing *our* id; only then
##   "playing". Pause/resume/seek map to `control`, with a short hold after
##   each command so a stale watch line does not undo it; after the hold,
##   watch wins (a pause from Music itself, a headset button or another app
##   shows as paused, with a status line).
## - End of track: Music reports a different track (its own auto-advance) or
##   `stopped` after our track was within END_WINDOW of its end -> `ended`.
##   Any other change of track in Music (the user picked something there, or
##   Music quit) -> `lost`; we stop following until Play is pressed again.
## - Volume: only when `volume_link` is on (setting "Oozic volume controls the
##   Music app", default off) does Oozic send `control volume`, and only for
##   explicit volume/mute changes or a non-zero volume at start. Music's
##   volume persists in Music, so Oozic never leaves it at 0 (unmuting,
##   unlinking, leaving the entry or quitting restores it).
## - Tap health: exit 3 (permission), no data (stalled) or digital silence
##   while playing -> tap_health(false, reason); the tap is then restarted
##   with backoff (2 s, 5 s, 10 s, then every 30 s) until real sound returns
##   -> tap_health(true, "").
## See docs/APPLE_MUSIC.md.

signal state_changed(state: String)
signal ended()
signal lost(reason: String)
signal tap_health(ok: bool, reason: String)
signal status(text: String)

const MUSIC_APP := "com.apple.Music"
const WATCH_INTERVAL := "0.25"
## Seconds before the end that count as "our track is ending".
const END_WINDOW := 3.0
const CONFIRM_TIMEOUT_MS := 15000
const HOLD_MS := 900
const STALL_MS := 3000
const SILENT_MS := 8000
const RESTART_MS := 2000
## Tap restart delays after a stall/silence/crash; the last one repeats.
const RETRY_DELAYS_MS := [2000, 5000, 10000, 30000]
const RETRYABLE := ["stalled", "silent", "exited"]
## Diagnostics log interval for the level line.
const LEVEL_LOG_MS := 5000
## Frames kept for analysis when nobody consumes them (about 1 s at 48 kHz).
const MAX_PENDING_FRAMES := 48000
## Sample magnitude treated as sound (tap delivers exact zeros when paused).
const SOUND_LEVEL := 1e-4

var bridge
## Requested tap rate; AudioService sets it to its analysis rate (no resampling).
var tap_rate := 48000
## "tap" avoids the Screen Recording fallback prompt; on exit 1 (no process
## taps, macOS < 14.2) the stream retries once with "auto".
var tap_backend := "tap"
## Current persistent ID ("" when no applemusic entry is current).
var id := ""
## "starting" (play-id sent, Music not yet confirmed) | "playing" | "paused" | "stopped"
var state := "stopped"
var position := 0.0
var duration := 0.0
var volume := 1.0
var muted := false
## Setting "Oozic volume controls the Music app" (default off).
var volume_link := false
var tap_ok := true
var tap_reason := ""
## Tap restarts since the last real sound.
var retry_count := 0
## Last tap header ({rate, channels, format, source, backend}) and event.
var tap_info := {}
## Helper `output` events: whether Music's process is producing audio (null: unknown).
var music_output = null
## Peak level (dBFS) of the most recent tap block.
var level_db := -120.0
## Helper `rebuilt` events (device/process/health rebuilds inside the helper).
var tap_rebuilds := 0
## Tap PCM bytes received while the current entry is active.
var bytes_total := 0
var last_watch := {}
var watch_proc = null
var tap_proc = null
## Tests: >= 0 replaces Time.get_ticks_msec().
var fake_now := -1

var _confirmed := false
var _near_end := false
var _ended := false
var _lost := false
var _switching := false
var _issued_ms := 0
var _stamp_ms := 0
var _hold_state_until := 0
var _hold_pos_until := 0
var _playing_since := 0
var _last_bytes_ms := 0
var _last_sound_ms := 0
var _last_watch_ms := 0
var _carry := PackedByteArray()
var _frames := PackedVector2Array()
var _tap_denied := false
var _tap_auto := false
var _tap_restart_at := 0
var _watch_denied := false
var _watch_restart_at := 0
var _music_zeroed := false
var _volume_hint_shown := false
var _no_output_shown := false
var _zero_volume_shown := false
var _watch_key := ""
var _level_logged_ms := 0
var _peak := 0.0

func _init() -> void:
	name = "AppleMusicStream"

func now() -> int:
	return fake_now if fake_now >= 0 else Time.get_ticks_msec()

func active() -> bool: return not id.is_empty()

func is_playing() -> bool: return active() and state == "playing"

func diag(event: String, data := {}) -> void:
	if bridge != null and bridge.has_method("diag"): bridge.diag(event, data)

# --- Transport ----------------------------------------------------------------

## Starts `track_id` in Music. Await: the control result {ok, code, ...}.
## `length` (seconds, from the library) is used until watch reports one.
## The state is "starting" until watch confirms Music plays this id.
func play(track_id: String, length := 0.0) -> Dictionary:
	_switching = true
	var result: Dictionary = await bridge.control(PackedStringArray(["play-id", track_id]))
	_switching = false
	diag("play", {"id": track_id, "ok": result.get("ok", false), "code": result.get("code", -1)})
	if not result.get("ok", false): return result
	id = track_id
	duration = length
	position = 0.0
	_stamp_ms = now()
	_issued_ms = now()
	_last_watch_ms = 0
	_confirmed = false
	_near_end = false
	_ended = false
	_lost = false
	# Permissions may have been granted since the last refusal: try again.
	_tap_denied = false
	_watch_denied = false
	_no_output_shown = false
	_zero_volume_shown = false
	_frames.clear()
	_carry.clear()
	_hold(true, true)
	_set_state("starting", true)
	_ensure_watch()
	_ensure_tap()
	# Never send 0 implicitly (a mute or 0 volume saved from an earlier session).
	if volume_link and not muted and volume > 0.0: _send_volume()
	return result

func resume() -> void:
	if not active(): return
	if state == "stopped" or _lost or _ended:
		_lost = false
		_ended = false
		_confirmed = false
		_issued_ms = now()
		_last_watch_ms = 0
		_send(["play-id", id])
		position = 0.0 if state == "stopped" else position
		_stamp_ms = now()
		_hold(true, false)
		_set_state("starting", true)
		return
	_send(["play"])
	_stamp_ms = now()
	_hold(true, false)
	_set_state("playing", true)

func pause() -> void:
	if not active() or not state in ["playing", "starting"]: return
	position = playback_time()
	_stamp_ms = now()
	_send(["pause"])
	_hold(true, false)
	_set_state("paused")

func stop() -> void:
	if not active(): return
	if state != "stopped" and not _lost: _send(["stop"])
	position = 0.0
	_stamp_ms = now()
	_frames.clear()
	_set_state("stopped")

func seek(seconds: float) -> void:
	if not active(): return
	position = clampf(seconds, 0.0, duration if duration > 0.0 else seconds)
	_stamp_ms = now()
	_near_end = false
	_send(["seek", "%.3f" % position], "seek")
	_hold(false, true)

## Oozic's volume/mute changed (an explicit user action).
func set_volume(value: float, is_muted: bool) -> void:
	var changed := not is_equal_approx(value, volume) or is_muted != muted
	volume = value
	muted = is_muted
	if not active() or not changed: return
	if volume_link: _send_volume()
	elif not _volume_hint_shown:
		_volume_hint_shown = true
		status.emit("Oozic's volume doesn't change the Music app. Use Music's or the system volume, or turn on Settings › Playlist › “Oozic volume controls the Music app”.")

## Turns the volume link on (sends the current volume) or off (restores
## Music's volume if Oozic had muted it).
func set_volume_link(on: bool) -> void:
	if on == volume_link: return
	volume_link = on
	diag("volume_link", {"on": on})
	if not active(): return
	if on: _send_volume()
	else: restore_music_volume()

## If Oozic muted Music (sent volume 0 for a mute), put Music's volume back
## to Oozic's unmuted level. `sync`: blocking (quit path). Returns the control
## args sent (empty when nothing was needed).
func restore_music_volume(sync := false) -> PackedStringArray:
	if not _music_zeroed or bridge == null: return PackedStringArray()
	_music_zeroed = false
	var level := int(round(clampf(volume, 0.0, 1.0) * 100.0))
	if level <= 0: return PackedStringArray()
	var args := PackedStringArray(["volume", str(level)])
	diag("volume_restore", {"level": level, "sync": sync})
	if sync: bridge.control_sync(args)
	else: _send(Array(args), "volume")
	return args

## True while Music's volume is 0 because of a mute in Oozic.
func music_muted_by_oozic() -> bool: return _music_zeroed

## Leaves the Music app (switching to a file entry, clearing, quitting):
## optionally pauses Music, stops watch and tap.
func deactivate(pause_music := true) -> void:
	if not active(): return
	if pause_music and (state in ["playing", "starting"] or _ended): _send(["pause"])
	restore_music_volume()
	if watch_proc != null: bridge.release(watch_proc)
	if tap_proc != null: bridge.release(tap_proc)
	watch_proc = null
	tap_proc = null
	diag("deactivate", {"id": id})
	id = ""
	_frames.clear()
	_carry.clear()
	_set_state("stopped")

## Audible position (s): last watch position extrapolated while playing.
func playback_time() -> float:
	if state != "playing": return position
	var t := position + float(now() - _stamp_ms) / 1000.0
	return clampf(t, 0.0, duration) if duration > 0.0 else t

## PCM frames captured since the last call (only while playing).
func take_frames() -> PackedVector2Array:
	var out := _frames
	_frames = PackedVector2Array()
	return out

func _send_volume() -> void:
	var level := 0 if muted else int(round(clampf(volume, 0.0, 1.0) * 100.0))
	_music_zeroed = muted
	_send(["volume", str(level)], "volume")

func _send(args: Array, key := "") -> void:
	if bridge == null: return
	var job = bridge.queue_control(PackedStringArray(args), key)
	if job.done: _on_control(job.result)
	else: job.finished.connect(_on_control)

func _on_control(result: Dictionary) -> void:
	if result.get("ok", false) or result.get("coalesced", false) or str(result.get("error", "")) == "cancelled": return
	var code := int(result.get("code", -1))
	var command := str(result.get("command", ""))
	if code == 4:
		# Music quit: nothing to pause or seek; Play starts the track again.
		if command in ["pause", "stop", "volume"]: return
		_lost = true
		_set_state("stopped")
	_status(bridge.status_for("control", code, str(result.get("message", ""))))

func _hold(state_too: bool, position_too: bool) -> void:
	if state_too: _hold_state_until = now() + HOLD_MS
	if position_too: _hold_pos_until = now() + HOLD_MS

func _set_state(value: String, force_emit := false) -> void:
	if value == "playing" and (value != state or force_emit): _playing_since = now()
	if value == state and not force_emit: return
	if value != state: diag("state", {"id": id, "from": state, "to": value})
	state = value
	state_changed.emit(value)

func _status(text: String) -> void:
	diag("status", {"text": text})
	status.emit(text)

# --- Watch ------------------------------------------------------------------------

## Applies one `watch`/`now` line (a parsed dictionary) to the stream state.
func apply_watch(d: Dictionary) -> void:
	last_watch = d
	var t := now()
	_log_watch(d)
	if d.has("error") or not active() or _switching: return
	_last_watch_ms = t
	var running := bool(d.get("running", false))
	var wid := str(d.get("id", ""))
	var wstate := str(d.get("state", "stopped"))
	if running and wid == id:
		if _lost or (state == "stopped" and t >= _hold_state_until): return
		_confirmed = true
		var length := float(d.get("duration", 0.0))
		if length > 0.0: duration = length
		if t >= _hold_pos_until:
			position = float(d.get("position", 0.0))
			_stamp_ms = t
		if wstate == "stopped" and _near_end and not _ended:
			_finish()
			return
		_near_end = duration > 0.0 and position >= duration - END_WINDOW
		if state == "starting":
			# Only Music playing our id makes us "playing".
			if wstate == "playing": _set_state("playing")
			elif t - _issued_ms > CONFIRM_TIMEOUT_MS:
				_set_state("paused")
				_status("Music has the track but hasn't started playing it (network or account?). Press Play to try again.")
			return
		if t >= _hold_state_until and wstate in ["playing", "paused"]:
			if wstate == "paused" and state == "playing":
				_status("Music paused playback (not from Oozic: Music itself, a headset button or another app). Press Play to continue.")
			_set_state(wstate)
		if state == "playing": _check_music_volume(d)
		return
	# Music is not on our track.
	if state == "stopped" or _ended or _lost: return
	if not _confirmed:
		if t - _issued_ms > CONFIRM_TIMEOUT_MS: _lose("timeout")
		return
	if not running: _lose("quit")
	elif _near_end: _finish()
	else: _lose("switched")

## Music's own volume at 0 while playing: the speakers are silent and so is
## the tap. Say so once per track (Oozic never sets 0 unless the user muted
## with the volume link on).
func _check_music_volume(d: Dictionary) -> void:
	if _zero_volume_shown or not d.has("volume") or int(d.volume) > 0: return
	if volume_link and muted: return
	_zero_volume_shown = true
	_status("The Music app's own volume is at 0, so nothing is audible. Turn it up in Music.")

func _log_watch(d: Dictionary) -> void:
	var key := "%s|%s|%s|%s|%s" % [d.get("running", false), d.get("id", ""), d.get("state", ""), d.get("volume", ""), d.get("error", "")]
	if key == _watch_key: return
	_watch_key = key
	diag("watch", {"running": d.get("running", false), "id": d.get("id", ""), "state": d.get("state", ""), "position": d.get("position", 0.0),
		"duration": d.get("duration", 0.0), "volume": d.get("volume", -1), "error": d.get("error", ""), "ours": str(d.get("id", "")) == id and active(), "our_state": state})

func _finish() -> void:
	_ended = true
	diag("ended", {"id": id})
	ended.emit()

func _lose(reason: String) -> void:
	_lost = true
	_frames.clear()
	_set_state("stopped")
	diag("lost", {"id": id, "reason": reason})
	match reason:
		"quit": _status("The Music app quit. Press Play to continue.")
		"timeout": _status("Music didn't start the track. Press Play to try again.")
		_: _status("Music switched to another track. Press Play to return to your playlist.")
	lost.emit(reason)

func _ensure_watch() -> void:
	if watch_proc != null or _watch_denied or bridge == null: return
	watch_proc = bridge.spawn(PackedStringArray(["watch", "--interval", WATCH_INTERVAL]))

func _poll_watch(t: int) -> void:
	if watch_proc == null:
		if active() and not _watch_denied and t >= _watch_restart_at: _ensure_watch()
		return
	var r: Dictionary = watch_proc.poll()
	for line in r.out:
		var parsed = JSON.parse_string(line)
		if parsed is Dictionary: apply_watch(parsed)
	if r.exited:
		var code: int = watch_proc.exit_code
		diag("watch_exit", {"code": code})
		bridge.release(watch_proc)
		watch_proc = null
		_watch_restart_at = t + RESTART_MS
		if code == 3:
			_watch_denied = true
			_status(bridge.status_for("watch", 3))
			# Nothing can confirm the track now: trust play-id.
			if state == "starting": _set_state("playing")

# --- Tap ----------------------------------------------------------------------------

func _ensure_tap() -> void:
	if tap_proc != null or _tap_denied or bridge == null: return
	var backend := "auto" if _tap_auto else tap_backend
	tap_proc = bridge.spawn(PackedStringArray(["tap", "--app", MUSIC_APP, "--rate", str(tap_rate), "--backend", backend]), true)
	_last_bytes_ms = now()

func _poll_tap(t: int) -> void:
	if tap_proc == null:
		if active() and not _tap_denied and t >= _tap_restart_at: _ensure_tap()
		return
	var r: Dictionary = tap_proc.poll()
	if not r.out.is_empty(): push_pcm_bytes(r.out)
	for line in r.err:
		var parsed = JSON.parse_string(line)
		if parsed is Dictionary: apply_tap_event(parsed)
	if r.exited:
		var code: int = tap_proc.exit_code
		diag("tap_exit", {"code": code})
		bridge.release(tap_proc)
		tap_proc = null
		_tap_restart_at = t + RESTART_MS
		if code == 3:
			_tap_denied = true
			_set_tap(false, "permission")
		elif code == 1 and not _tap_auto and tap_backend != "auto":
			_tap_auto = true
			_tap_restart_at = t
		elif code != 0:
			_set_tap(false, "exited")
			_tap_restart_at = t + _retry_delay()
			retry_count += 1

## One tap stderr JSON line: the header or an event.
func apply_tap_event(parsed: Dictionary) -> void:
	if parsed.has("rate"):
		tap_info = parsed
		diag("tap_header", parsed)
		return
	tap_info.last_event = parsed
	var event := str(parsed.get("event", ""))
	if event == "rebuilt": tap_rebuilds += 1
	elif event == "output": music_output = bool(parsed.get("running", false))
	elif event == "level" and parsed.has("output"): music_output = bool(parsed.output)
	diag("tap_" + event if not event.is_empty() else "tap_event", parsed)

## Converts tap stdout bytes (f32le stereo, any split) to frames.
func push_pcm_bytes(bytes: PackedByteArray) -> void:
	var t := now()
	_last_bytes_ms = t
	bytes_total += bytes.size()
	var data := _carry + bytes if not _carry.is_empty() else bytes
	var whole := data.size() - data.size() % 8
	_carry = data.slice(whole)
	if whole == 0: return
	var frames := pcm_to_frames(data.slice(0, whole))
	var peak := 0.0
	for i in range(0, frames.size(), 8):
		var f := frames[i]
		peak = maxf(peak, maxf(absf(f.x), absf(f.y)))
	level_db = linear_to_db(peak) if peak > 1e-6 else -120.0
	_peak = maxf(_peak, peak)
	if peak > SOUND_LEVEL:
		_last_sound_ms = t
		if not tap_ok and tap_reason != "permission": _set_tap(true, "")
	if state != "playing": return
	_frames.append_array(frames)
	if _frames.size() > MAX_PENDING_FRAMES: _frames = _frames.slice(_frames.size() - MAX_PENDING_FRAMES)

## f32le interleaved stereo -> Godot stereo frames (same -1..1 scale as
## AudioEffectCapture.get_buffer()).
static func pcm_to_frames(bytes: PackedByteArray) -> PackedVector2Array:
	var floats := bytes.to_float32_array()
	var count := floats.size() / 2
	var frames := PackedVector2Array()
	frames.resize(count)
	for i in count:
		frames[i] = Vector2(floats[2 * i], floats[2 * i + 1])
	return frames

func _check_tap_health(t: int) -> void:
	if state != "playing" or not _confirmed: return
	# Music says playing but its process outputs nothing: the speakers are
	# silent too (buffering, AirPlay/other route). Not a capture problem.
	if music_output == false and t - _playing_since > SILENT_MS and not _no_output_shown:
		_no_output_shown = true
		_status("Music says it's playing, but it isn't producing any audio on this Mac (still buffering, or playing to AirPlay or another output?).")
	if not tap_ok: return
	if t - maxi(_playing_since, _last_bytes_ms) > STALL_MS: _set_tap(false, "stalled")
	elif int(last_watch.get("volume", 100)) > 0 and t - maxi(_playing_since, _last_sound_ms) > SILENT_MS: _set_tap(false, "silent")

func _retry_delay() -> int:
	return RETRY_DELAYS_MS[mini(retry_count, RETRY_DELAYS_MS.size() - 1)]

## While the tap is unhealthy (not a permission refusal) and Music plays:
## restart it on the backoff schedule.
func _maybe_retry(t: int) -> void:
	if tap_ok or not tap_reason in RETRYABLE or state != "playing" or _tap_denied: return
	if tap_proc == null or t < _tap_restart_at: return
	diag("tap_retry", {"attempt": retry_count + 1, "reason": tap_reason})
	bridge.release(tap_proc)
	tap_proc = null
	_tap_restart_at = t
	_ensure_tap()
	retry_count += 1
	_tap_restart_at = t + _retry_delay()

func _set_tap(ok: bool, reason: String) -> void:
	if ok == tap_ok and reason == tap_reason: return
	tap_ok = ok
	tap_reason = reason
	diag("tap_health", {"ok": ok, "reason": reason, "retries": retry_count, "music_output": music_output, "level_db": snappedf(level_db, 0.1)})
	if ok:
		retry_count = 0
		tap_health.emit(ok, reason)
		return
	if reason in RETRYABLE: _tap_restart_at = now() + _retry_delay()
	tap_health.emit(ok, reason)
	match reason:
		"permission": _status(bridge.status_for("tap", 3))
		"stalled": _status("Apple Music audio isn't reaching the visualiser (capture stalled). Retrying; using the synthetic beat meanwhile.")
		"silent":
			if music_output == false: _status("Music isn't producing any audio, so the visualiser uses the synthetic beat for now.")
			else: _status("No audio from Music reaches the visualiser. If the track is audible, allow Oozic under System Settings › Privacy & Security › Screen & System Audio Recording. Retrying; using the synthetic beat meanwhile.")
		_: _status("Apple Music audio capture stopped. Retrying; using the synthetic beat meanwhile.")

# --- Diagnostics --------------------------------------------------------------------

## One line for the F3 overlay:
## "music: <state> · tap <backend> pid <n> · level <dB> · <ok|silent|stalled|retrying>".
func debug_line() -> String:
	if not active(): return "music: idle"
	var music_state := state
	if not last_watch.is_empty() and str(last_watch.get("id", "")) == id and str(last_watch.get("state", "")) != state:
		music_state += " (Music: %s)" % str(last_watch.get("state", ""))
	var backend := str(tap_info.get("backend", "-"))
	var pid := str(tap_proc.pid) if tap_proc != null else "-"
	var health := "ok" if tap_ok else tap_reason
	if not tap_ok and tap_reason in RETRYABLE and retry_count > 0: health = "retrying %d (%s)" % [retry_count, tap_reason]
	if music_output == false and state == "playing": health += ", Music not outputting"
	if tap_rebuilds > 0: health += ", %d helper rebuild%s" % [tap_rebuilds, "" if tap_rebuilds == 1 else "s"]
	return "music: %s · tap %s pid %s · level %d dB · %s" % [music_state, backend, pid, int(round(level_db)), health]

func _log_level(t: int) -> void:
	if t - _level_logged_ms < LEVEL_LOG_MS: return
	_level_logged_ms = t
	diag("level", {"peak_db": snappedf(linear_to_db(_peak) if _peak > 1e-6 else -120.0, 0.1), "state": state, "tap_ok": tap_ok, "reason": tap_reason, "retries": retry_count, "music_output": music_output})
	_peak = 0.0

# --- Per frame ------------------------------------------------------------------------

## Called by AudioService._process.
func poll() -> void:
	if not active(): return
	var t := now()
	_poll_watch(t)
	_poll_tap(t)
	_check_tap_health(t)
	_maybe_retry(t)
	if state == "starting" and _last_watch_ms == 0 and t - _issued_ms > CONFIRM_TIMEOUT_MS and watch_proc == null:
		# No watch at all: nothing can confirm the track; trust play-id.
		_set_state("playing")
	if bridge != null and bridge.diagnostics != null and bridge.diagnostics.enabled(): _log_level(t)

func _exit_tree() -> void:
	if bridge == null: return
	if watch_proc != null: bridge.release(watch_proc)
	if tap_proc != null: bridge.release(tap_proc)
	watch_proc = null
	tap_proc = null
