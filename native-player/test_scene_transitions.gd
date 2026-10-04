extends SceneTree
## Scene transitions, cycle modes, musical scheduling and per-track pins (Phase 4e). Silent:
##   Godot --headless --audio-driver Dummy --path native-player --script res://test_scene_transitions.gd
## 1. A crossfade completes, hands the incoming runtime to the window, frees the old runtime
##    and the stage, and leaks no nodes across repeated transitions (every style).
## 2. Rapid repeated changes settle on the last request with one runtime and no stage.
## 3. Cut (original) switches synchronously; resize mid-blend resizes the stage.
## 4. "By track" cycling switches exactly once per track and not on a timer.
## 5. Musical timing: mock 128 BPM hub; automatic changes land on downbeats / phrase starts,
##    not mid-drop, manual picks wait for a beat only when one is < 0.5 s away.
## 6. Section mode is rate limited; pins persist with the playlist and win over the cycle mode.
const PlayerBusScript = preload("res://player_bus.gd")
const SceneDirector = preload("res://scene_director.gd")
const SceneTransition = preload("res://scene_transition.gd")
const Visualiser = preload("res://visualiser.gd")
const AudioService = preload("res://audio_service.gd")
const Reactivity = preload("res://analysis/reactivity.gd")
const SyntheticSource = preload("res://analysis/synthetic_source.gd")

var failures := PackedStringArray()

func _initialize(): call_deferred("run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error("FAIL: " + message)

func frames(count: int) -> void:
	for i in count: await process_frame

func wait_until(condition: Callable, max_frames := 900) -> bool:
	for i in max_frames:
		if condition.call(): return true
		await process_frame
	return condition.call()

func scene_index(bus, title: String) -> int:
	for i in bus.scenes.size():
		if str(bus.scenes[i].get("title", bus.scenes[i].name)).begins_with(title): return i
	return -1

func runtime_count() -> int:
	var count := 0
	var pending: Array = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node.get_script() != null and str(node.get_script().resource_path).ends_with("scene_runtime.gd"): count += 1
		pending.append_array(node.get_children())
	return count

func run():
	var bus = PlayerBusScript.instance()
	var director = SceneDirector.new(false)
	root.add_child(director)
	await process_frame
	var visualiser = Visualiser.new()
	root.add_child(visualiser)
	await process_frame
	bus.controller_present = false
	visualiser.set_analysis_source("mock", false)
	var triple := scene_index(bus, "Triple Trance")
	var dancing := scene_index(bus, "Dancing Well")
	check(triple >= 0 and dancing >= 0, "catalog has Triple Trance and Dancing Well")
	var third := 0
	for i in bus.scenes.size():
		if i != triple and i != dancing:
			third = i
			break
	# Non-persistent directors default to Cut and no musical timing; the transition tests set what they need.
	director.select(triple)
	check(visualiser.scene_loaded == triple, "first scene loads without a transition")

	# 1. Every style completes, adopts the incoming runtime, frees old runtime and stage, leaks nothing.
	var settled_nodes := {}
	for style in ["crossfade", "dip", "iris"]:
		director.set_cycling({"transition": style, "transition_seconds": 0.5})
		for round in 2:
			var target: int = dancing if visualiser.scene_loaded == triple else triple
			var old_runtime = visualiser.runtime
			director.select(target)
			check(visualiser.transition.blending and visualiser.scene_loaded != target, "%s: blend running, window scene still the old one (blending %s loaded %d target %d active %s)" % [style, visualiser.transition.blending, visualiser.scene_loaded, target, visualiser.transition.is_active()])
			check(visualiser.transition.runtime != null and visualiser.transition.runtime != old_runtime, "%s: incoming runtime is separate" % style)
			check(runtime_count() == 2, "%s: exactly two runtimes while blending (%d)" % [style, runtime_count()])
			var old_ticks: int = old_runtime.metrics.ticks
			var incoming = visualiser.transition.runtime
			await wait_until(func(): return old_runtime.metrics.ticks > old_ticks + 2 and incoming.metrics.ticks > 2, 300)
			check(old_runtime.metrics.ticks > old_ticks and incoming.metrics.ticks > 0, "%s: both scenes keep simulating" % style)
			check(await wait_until(func(): return visualiser.scene_loaded == target and not visualiser.transition.is_active()), "%s: blend completes and the stage is freed" % style)
			check(not is_instance_valid(old_runtime), "%s: old runtime freed" % style)
			check(runtime_count() == 1 and visualiser.runtime.get_parent() == visualiser, "%s: one runtime, owned by the visualiser" % style)
			check(visualiser.runtime.camera.current and root.get_camera_3d() == visualiser.runtime.camera, "%s: adopted camera is the window's current camera" % style)
			check(not visualiser.transition.blending and visualiser.transition.stage == null, "%s: no stage left" % style)
			await frames(3)
			var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
			if not settled_nodes.has(target): settled_nodes[target] = nodes
			check(abs(nodes - int(settled_nodes[target])) <= 2, "%s round %d: node count for scene %d steady (%d vs %d)" % [style, round, target, nodes, settled_nodes[target]])
	print("prepare hitch (last load, ms): %.1f" % visualiser.transition.load_ms)

	# 2. Rapid changes: last request wins, one runtime, no stage.
	director.set_cycling({"transition": "crossfade", "transition_seconds": 1.0})
	var first: int = dancing if visualiser.scene_loaded == triple else triple
	director.select(first)
	await frames(4)
	director.select(third)
	await frames(2)
	director.select(triple)
	director.select(dancing)
	check(await wait_until(func(): return visualiser.scene_loaded == dancing and not visualiser.transition.is_active(), 1800), "rapid changes settle on the last request")
	check(runtime_count() == 1 and bus.scene_index == dancing, "rapid changes: one runtime, bus agrees")

	# 3. Cut is synchronous (the original behaviour); a resize mid-blend resizes the stage.
	director.set_cycling({"transition": "cut"})
	director.select(triple)
	check(visualiser.scene_loaded == triple and not visualiser.transition.is_active(), "Cut (original) switches at once")
	director.set_cycling({"transition": "crossfade", "transition_seconds": 2.0})
	director.select(dancing)
	var before_size: Vector2i = visualiser.transition.stage.size
	root.size = Vector2i(before_size.x + 200, before_size.y + 100)
	await frames(2)
	visualiser.transition._on_resize()
	check(visualiser.transition.stage.size == root.size, "stage follows the window size mid-blend (%s vs %s)" % [visualiser.transition.stage.size, root.size])
	root.size = before_size
	check(await wait_until(func(): return visualiser.scene_loaded == dancing and not visualiser.transition.is_active(), 1800), "blend finishes after a resize")

	# 4. By track: once per track, never on the timer.
	director.set_cycling({"transition": "cut", "enabled": true, "mode": "track", "interval": 30})
	var changes := [0]
	var count_changes := func(_i): changes[0] += 1
	bus.scene_changed.connect(count_changes)
	bus.publish_playlist(PackedStringArray(["/m/a.mp3", "/m/b.mp3", "/m/c.mp3"]), -1)
	bus.publish_transport("stopped")
	bus.publish_track(0, "a")
	check(changes[0] == 0, "a restored playlist announcing its track (nothing playing) does not cycle")
	bus.publish_transport("playing")
	director.tick(5000.0)
	check(changes[0] == 0, "track mode ignores the timer")
	bus.publish_track(1, "b")
	check(changes[0] == 1, "new track switches the scene once")
	bus.publish_track(2, "c")
	check(changes[0] == 2, "next track switches once more")
	bus.scene_changed.disconnect(count_changes)

	# 5. Musical timing against a mock 128 BPM hub.
	await _musical(bus, director)

	# 6. Section mode and pins.
	await _sections_and_pins(bus, director)

	visualiser.queue_free()
	director.queue_free()
	await frames(2)
	if failures.is_empty():
		print("PASS test_scene_transitions: styles complete and free everything, rapid changes settle, cut is synchronous, resize follows, by-track cycles once per track, musical scheduling lands on downbeats/phrases, section mode rate-limited, pins persist and win")
		quit(0)
	else:
		print("FAIL test_scene_transitions: ", "; ".join(failures))
		quit(1)

# --- musical timing ---------------------------------------------------------------

class FrameStub:
	extends RefCounted
	var frame
	var hub

func _hub(bpm: float, schedule := SyntheticSource.SCHEDULE):
	var hub = Reactivity.new()
	root.add_child(hub)
	hub.set_source(SyntheticSource.new(bpm, schedule))
	return hub

## Runs the hub and the director at 60 fps from `start`; returns what happened.
func _drive(director, hub, start: float, seconds: float, stub, until_commit := true) -> Dictionary:
	var result := {"commit_time": -1.0, "downbeat": false, "phrase": 0, "section": "", "prepared_before": false, "waited": 0.0, "committed": false}
	var bus = PlayerBusScript.instance()
	var seen := {"prepared": false}
	var on_prepare := func(i): if i >= 0: seen.prepared = true
	var on_scene := func(_i):
		result.committed = true
		result.downbeat = hub.frame.downbeat
		result.phrase = hub.frame.phrase
		result.section = hub.frame.section
		result.prepared_before = seen.prepared
	bus.scene_prepare.connect(on_prepare)
	bus.scene_changed.connect(on_scene)
	var t := start
	var dt := 1.0 / 60.0
	var steps := int(seconds / dt)
	for i in steps:
		hub.update_time(t, dt)
		stub.frame = hub.frame
		director.tick(dt)
		if result.committed:
			result.commit_time = t
			if until_commit: break
		t += dt
	bus.scene_prepare.disconnect(on_prepare)
	bus.scene_changed.disconnect(on_scene)
	return result

func _musical(bus, director) -> void:
	director.set_cycling({"transition": "cut", "enabled": true, "mode": "time", "interval": 30, "musical": true, "order": "alphabetical"})
	var stub := FrameStub.new()
	director.rx = stub
	# 5a. Quiet intro: due at t = 3.3 s, must wait for a downbeat (bar = 1.875 s at 128 BPM).
	var hub = _hub(128.0)
	stub.hub = hub
	stub.frame = hub.frame
	for warm in 300:
		hub.update_time(float(warm) / 60.0, 1.0 / 60.0)
	var t0 := 5.0
	for warm in 60:
		hub.update_time(t0 + float(warm) / 60.0, 1.0 / 60.0)
	director.elapsed = 29.95
	var downbeat_hits := 0
	for trial in 4:
		director.elapsed = 29.95
		var r := _drive(director, hub, t0 + 1.0 + float(trial) * 2.1, 6.0, stub)
		check(r.committed and r.downbeat, "5a trial %d: automatic change commits on a downbeat frame (committed %s downbeat %s section %s)" % [trial, r.committed, r.downbeat, r.section])
		check(r.prepared_before, "5a trial %d: next scene announced for pre-roll before the boundary" % trial)
		if r.downbeat: downbeat_hits += 1
	check(downbeat_hits == 4, "5a: all four runs landed on downbeats")
	# 5b. Inside the drop (bars 16..32 = 30..60 s): never on a plain downbeat, only a phrase start or the wait cap.
	var drop_results := []
	for start in [33.0, 38.0, 41.0]:
		director.elapsed = 29.95
		var r := _drive(director, hub, start, 14.0, stub)
		drop_results.append(r)
		check(r.committed, "5b start %.0f: still commits (cap)" % start)
		var waited: float = r.commit_time - start
		check(int(r.phrase) > 0 or waited >= SceneDirector.MAX_WAIT - 0.1 or r.section != "drop", "5b start %.0f: not on a plain mid-drop downbeat (phrase %d, waited %.2f, section %s)" % [start, r.phrase, waited, r.section])
	# 5c. A change due just before the drop starts lands with the drop.
	director.elapsed = 29.95
	var before_drop := _drive(director, hub, 27.4, 6.0, stub)
	check(before_drop.committed and (before_drop.commit_time >= 29.9 or before_drop.downbeat), "5c: change due before a drop waits for the drop or a downbeat (commit %.2f)" % before_drop.commit_time)
	# 5d. Manual picks: a beat < 0.5 s away is awaited (128 BPM: beat = 0.469 s); at 60 BPM the beat is a second away.
	director.elapsed = 0.0
	hub.update_time(20.3, 1.0 / 60.0)
	stub.frame = hub.frame
	director.cancel_pending()
	var committed_at := {"t": -1.0}
	var seen := [false]
	var on_scene := func(_i): seen[0] = true
	bus.scene_changed.connect(on_scene)
	director.select((director.current + 1) % director.scenes.size())
	var waited_for_beat: bool = not director.pending.is_empty()
	var t := 20.3
	if waited_for_beat:
		for i in 60:
			t += 1.0 / 60.0
			hub.update_time(t, 1.0 / 60.0)
			stub.frame = hub.frame
			director.tick(1.0 / 60.0)
			if seen[0]:
				committed_at.t = t
				check(hub.frame.beat or float(t) - 20.3 >= 0.69, "5d: manual pick lands on a beat (beat %s)" % hub.frame.beat)
				break
	check(waited_for_beat and seen[0] and committed_at.t - 20.3 < 0.7, "5d: manual pick waited for the beat < 0.5 s away and landed within it")
	bus.scene_changed.disconnect(on_scene)
	# Slow tempo: beat is 1 s away, so the pick is immediate.
	var slow = _hub(60.0)
	for i in 120: slow.update_time(10.0 + float(i) / 60.0, 1.0 / 60.0)
	# land just after a beat: 10.0 + 2/60 s past beat at integer seconds
	slow.update_time(12.0 + 2.0 / 60.0, 1.0 / 60.0)
	stub.hub = slow
	stub.frame = slow.frame
	var immediate := [false]
	var on_immediate := func(_i): immediate[0] = true
	bus.scene_changed.connect(on_immediate)
	director.select((director.current + 1) % director.scenes.size())
	check(immediate[0] and director.pending.is_empty(), "5d: pick with the next beat > 0.5 s away is immediate")
	bus.scene_changed.disconnect(on_immediate)
	# Musical off: immediate regardless.
	director.set_cycling({"musical": false})
	director.elapsed = 29.95
	stub.hub = hub
	stub.frame = hub.frame
	check(director.tick(0.1) and director.pending.is_empty(), "musical timing off: due change is immediate")
	director.rx = null
	hub.queue_free()
	slow.queue_free()
	director.set_cycling({"enabled": false, "musical": true})

# --- sections and pins --------------------------------------------------------------

func _sections_and_pins(bus, director) -> void:
	director.set_cycling({"transition": "cut", "enabled": true, "mode": "section", "interval": 30})
	var changes := [0]
	var count := func(_i): changes[0] += 1
	bus.scene_changed.connect(count)
	director.elapsed = 10.0
	director.on_section_changed("drop")
	check(changes[0] == 0, "section change under 60 s since the last switch is ignored")
	director.elapsed = 61.0
	director.on_section_changed("quiet")
	check(changes[0] == 0, "quiet is not a major section")
	director.on_section_changed("drop")
	check(changes[0] == 1 and director.elapsed == 0.0, "major section after 60 s switches the scene")
	director.on_section_changed("breakdown")
	check(changes[0] == 1, "rate limit: a second boundary right after is ignored")
	bus.scene_changed.disconnect(count)

	# Pins: stored in the playlist file, restored by a new AudioService, and win over cycling.
	var audio = AudioService.new(false)
	root.add_child(audio)
	await process_frame
	audio.persist = true
	audio.playlist_path = OS.get_temp_dir().path_join("oozic-test-pins.json")
	audio.settings_path = OS.get_temp_dir().path_join("oozic-test-pins.cfg")
	audio.playlist = PackedStringArray(["/m/a.mp3", "/m/b.mp3", "/m/c.mp3"])
	audio.track_index = 1
	bus.publish_playlist(audio.playlist, 1)
	bus.publish_scene_pins({})
	director.set_cycling({"enabled": false, "mode": "time"})
	director.commit(2, "user")
	bus.publish_transport("playing")
	bus.command(&"pin_scene")
	var path := "/m/b.mp3"
	check(bus.scene_pins.get(path, "") == director.scenes[2].path, "pin_scene stores the scene for the current track")
	var file := FileAccess.get_file_as_string(audio.playlist_path)
	var parsed = JSON.parse_string(file)
	check(parsed is Dictionary and parsed.get("scene_pins", {}).get(path, "") == director.scenes[2].path, "pins are written into the playlist file")
	bus.scene_pins = {} # forget in memory only (publishing would rewrite the file)
	check(audio.load_playlist_file() and bus.scene_pins.get(path, "") == director.scenes[2].path, "pins are restored with the playlist")
	director.commit(0, "user")
	bus.publish_track(1, "b")
	check(director.current == 2 and bus.scene_reason == "pin", "a pinned track switches to its scene even with cycling off")
	director.set_cycling({"enabled": true, "mode": "track", "transition": "cut"})
	bus.publish_track(0, "a")
	var after_a: int = director.current
	check(after_a != 2 or director.scenes.size() < 2, "unpinned track cycles by track")
	bus.publish_track(1, "b")
	check(director.current == 2, "the pin still beats the by-track cycle")
	bus.command(&"unpin_scene")
	check(not bus.scene_pins.has(path), "unpin_scene removes it")
	audio.persist = false
	DirAccess.remove_absolute(audio.playlist_path)
	DirAccess.remove_absolute(audio.settings_path)
	audio.queue_free()
