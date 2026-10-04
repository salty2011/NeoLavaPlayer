extends Node
## AppleMusicStream: plays one `applemusic:<ID>` playlist entry through the
## Music app for AudioService (child node; AudioService calls poll() from its
## own _process so PCM and state arrive in a fixed order each frame).
##
## - play(id) sends `control play-id`, then keeps `watch --interval 0.25`
##   (now-playing) and `tap --app com.apple.Music` (the Music app's audio as
##   f32le stereo at `tap_rate`) running while the entry is current.
## - Transport calls map to `control` (play/pause/stop/seek/volume); state,
##   position and duration follow `watch`, with a short hold after each command
##   so a stale watch line does not undo it.
## - End of track: Music reports a different track (its own auto-advance) or
##   `stopped` after our track was within END_WINDOW of its end -> `ended`.
##   Any other change of track in Music (the user picked something there, or
##   Music quit) -> `lost`; we stop following until Play is pressed again.
## - Tap health: exit 3 (permission), no data (stalled) or digital silence
##   while playing -> tap_health(false, reason); real sound again -> (true, "").
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
## "playing" | "paused" | "stopped"
var state := "stopped"
var position := 0.0
var duration := 0.0
var volume := 1.0
var muted := false
var tap_ok := true
var tap_reason := ""
## Last tap header ({rate, channels, format, source, backend}) and event.
var tap_info := {}
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
var _carry := PackedByteArray()
var _frames := PackedVector2Array()
var _tap_denied := false
var _tap_auto := false
var _tap_restart_at := 0
var _watch_denied := false
var _watch_restart_at := 0

func _init() -> void:
	name = "AppleMusicStream"

func now() -> int:
	return fake_now if fake_now >= 0 else Time.get_ticks_msec()

func active() -> bool: return not id.is_empty()

func is_playing() -> bool: return active() and state == "playing"

# --- Transport ----------------------------------------------------------------

## Starts `track_id` in Music. Await: the control result {ok, code, ...}.
## `length` (seconds, from the library) is used until watch reports one.
func play(track_id: String, length := 0.0) -> Dictionary:
	_switching = true
	var result: Dictionary = await bridge.control(PackedStringArray(["play-id", track_id]))
	_switching = false
	if not result.get("ok", false): return result
	id = track_id
	duration = length
	position = 0.0
	_stamp_ms = now()
	_issued_ms = now()
	_confirmed = false
	_near_end = false
	_ended = false
	_lost = false
	# Permissions may have been granted since the last refusal: try again.
	_tap_denied = false
	_watch_denied = false
	_frames.clear()
	_carry.clear()
	_hold(true, true)
	_set_state("playing", true)
	_ensure_watch()
	_ensure_tap()
	_send_volume()
	return result

func resume() -> void:
	if not active(): return
	if state == "stopped" or _lost or _ended:
		_lost = false
		_ended = false
		_confirmed = false
		_issued_ms = now()
		_send(["play-id", id])
		position = 0.0 if state == "stopped" else position
	else: _send(["play"])
	_stamp_ms = now()
	_hold(true, false)
	_set_state("playing", true)

func pause() -> void:
	if not active() or state != "playing": return
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

func set_volume(value: float, is_muted: bool) -> void:
	volume = value
	muted = is_muted
	if active(): _send_volume()

## Leaves the Music app (switching to a file entry, clearing, quitting):
## optionally pauses Music, stops watch and tap.
func deactivate(pause_music := true) -> void:
	if not active(): return
	if pause_music and (state == "playing" or _ended): _send(["pause"])
	if watch_proc != null: bridge.release(watch_proc)
	if tap_proc != null: bridge.release(tap_proc)
	watch_proc = null
	tap_proc = null
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
	_send(["volume", str(0 if muted else int(round(clampf(volume, 0.0, 1.0) * 100.0)))], "volume")

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
	status.emit(bridge.status_for("control", code, str(result.get("message", ""))))

func _hold(state_too: bool, position_too: bool) -> void:
	if state_too: _hold_state_until = now() + HOLD_MS
	if position_too: _hold_pos_until = now() + HOLD_MS

func _set_state(value: String, force_emit := false) -> void:
	if value == "playing" and (value != state or force_emit): _playing_since = now()
	if value == state and not force_emit: return
	state = value
	state_changed.emit(value)

# --- Watch ------------------------------------------------------------------------

## Applies one `watch`/`now` line (a parsed dictionary) to the stream state.
func apply_watch(d: Dictionary) -> void:
	last_watch = d
	if d.has("error") or not active() or _switching: return
	var t := now()
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
		if t >= _hold_state_until and wstate in ["playing", "paused"]: _set_state(wstate)
		return
	# Music is not on our track.
	if state == "stopped" or _ended or _lost: return
	if not _confirmed:
		if t - _issued_ms > CONFIRM_TIMEOUT_MS: _lose("timeout")
		return
	if not running: _lose("quit")
	elif _near_end: _finish()
	else: _lose("switched")

func _finish() -> void:
	_ended = true
	ended.emit()

func _lose(reason: String) -> void:
	_lost = true
	_frames.clear()
	_set_state("stopped")
	match reason:
		"quit": status.emit("The Music app quit. Press Play to continue.")
		"timeout": status.emit("Music didn't start the track. Press Play to try again.")
		_: status.emit("Music switched to another track. Press Play to return to your playlist.")
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
		bridge.release(watch_proc)
		watch_proc = null
		_watch_restart_at = t + RESTART_MS
		if code == 3:
			_watch_denied = true
			status.emit(bridge.status_for("watch", 3))

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
		if parsed is Dictionary:
			if parsed.has("rate"): tap_info = parsed
			else: tap_info.last_event = parsed
	if r.exited:
		var code: int = tap_proc.exit_code
		bridge.release(tap_proc)
		tap_proc = null
		_tap_restart_at = t + RESTART_MS
		if code == 3:
			_tap_denied = true
			_set_tap(false, "permission")
		elif code == 1 and not _tap_auto and tap_backend != "auto":
			_tap_auto = true
			_tap_restart_at = t
		elif code != 0: _set_tap(false, "exited")

## Converts tap stdout bytes (f32le stereo, any split) to frames.
func push_pcm_bytes(bytes: PackedByteArray) -> void:
	var t := now()
	_last_bytes_ms = t
	var data := _carry + bytes if not _carry.is_empty() else bytes
	var whole := data.size() - data.size() % 8
	_carry = data.slice(whole)
	if whole == 0: return
	var frames := pcm_to_frames(data.slice(0, whole))
	var loud := false
	for i in range(0, frames.size(), 8):
		var f := frames[i]
		if absf(f.x) > SOUND_LEVEL or absf(f.y) > SOUND_LEVEL:
			loud = true
			break
	if loud:
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
	if not tap_ok or state != "playing" or not _confirmed: return
	if t - maxi(_playing_since, _last_bytes_ms) > STALL_MS: _set_tap(false, "stalled")
	elif not muted and volume > 0.02 and t - maxi(_playing_since, _last_sound_ms) > SILENT_MS: _set_tap(false, "silent")

func _set_tap(ok: bool, reason: String) -> void:
	if ok == tap_ok and reason == tap_reason: return
	tap_ok = ok
	tap_reason = reason
	tap_health.emit(ok, reason)
	if ok: return
	match reason:
		"permission": status.emit(bridge.status_for("tap", 3))
		"stalled": status.emit("Apple Music audio isn't reaching the visualiser (capture stalled). Using the synthetic beat meanwhile.")
		"silent": status.emit("No audio from Music reaches the visualiser. If the track is audible, allow Oozic under System Settings › Privacy & Security › Screen & System Audio Recording. Using the synthetic beat meanwhile.")
		_: status.emit("Apple Music audio capture stopped. Using the synthetic beat meanwhile.")

# --- Per frame ------------------------------------------------------------------------

## Called by AudioService._process.
func poll() -> void:
	if not active(): return
	var t := now()
	_poll_watch(t)
	_poll_tap(t)
	_check_tap_health(t)

func _exit_tree() -> void:
	if bridge == null: return
	if watch_proc != null: bridge.release(watch_proc)
	if tap_proc != null: bridge.release(tap_proc)
	watch_proc = null
	tap_proc = null
