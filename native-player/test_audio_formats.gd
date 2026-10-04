extends SceneTree
## Local formats beyond MP3/FLAC: fixtures are made from the bundled MP3 with
## macOS afconvert (AAC .m4a/.aac, ALAC .m4a, AIFF, WAV float, CAF 24-bit), then
## decoded through the generalised Core Audio path and played by AudioService.
## Protected .m4p files are refused with a clear message.
const Decoder = preload("res://flac_decoder.gd")
const AudioService = preload("res://audio_service.gd")

func _initialize(): call_deferred("run")

func run():
	var source := ProjectSettings.globalize_path("res://test-media/DemoBeat.mp3")
	var folder := OS.get_temp_dir().path_join("oozic-formats-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(folder)
	var cases := {
		"aac.m4a": ["-f", "m4af", "-d", "aac"],
		"alac.m4a": ["-f", "m4af", "-d", "alac"],
		"adts.aac": ["-f", "adts", "-d", "aac"],
		"big.aiff": ["-f", "AIFF", "-d", "BEI16"],
		"short.aif": ["-f", "AIFF", "-d", "BEI24"],
		"float.wav": ["-f", "WAVE", "-d", "LEF32"],
		"deep.caf": ["-f", "caff", "-d", "LEI24"],
	}
	var made := PackedStringArray()
	for name in cases:
		var target := folder.path_join(name)
		var args := PackedStringArray([source, target])
		args.append_array(PackedStringArray(cases[name]))
		assert(OS.execute("/usr/bin/afconvert", args) == 0 and FileAccess.file_exists(target))
		made.append(target)
		var decoded: Dictionary = Decoder.decode(target)
		assert(decoded.has("stream"), name)
		assert(decoded.stream.stereo and decoded.stream.mix_rate == 44100, name)
		# AAC adds encoder priming/padding; lengths stay within a fraction of a second.
		assert(absf(decoded.stream.get_length() - 30.04) < 0.2, name)
	var protected := folder.path_join("bought.m4p")
	var file := FileAccess.open(protected, FileAccess.WRITE)
	file.store_string("not really protected")
	file = null
	assert(Decoder.decode(protected).error.contains(".m4p"))
	assert(Decoder.decode(folder.path_join("missing.caf")).error == "Couldn't open that CAF file.")
	assert(Decoder.size_error(2 * 1024 * 1024 * 1024).contains("too long"))
	# AudioService: picker/drop filtering, decode on a thread, protected refusal.
	var audio = AudioService.new(false)
	root.add_child(audio)
	await process_frame
	assert(audio.add_tracks(made, false) == made.size())
	assert(await audio.play_track(0))
	assert(audio.player.stream is AudioStreamWAV and audio.player.playing and audio.bus.transport == "playing")
	assert(await audio.play_track(6))
	assert(audio.player.stream is AudioStreamWAV and audio.track_index == 6)
	audio.playlist.append(protected)
	assert(not await audio.play_track(audio.playlist.size() - 1))
	assert(audio.bus.status.contains(".m4p") and audio.track_index == 6)
	assert(audio.add_tracks(PackedStringArray([protected]), false) == 0 and audio.bus.status.contains(".m4p"))
	assert(audio.add_directory(folder) == made.size())
	var filters: Array = audio.bus.AUDIO_FILE_FILTERS
	for extension in ["flac", "mp3", "m4a", "aac", "aiff", "aif", "wav", "caf", "alac"]:
		assert(filters[0].contains("*." + extension) and extension in AudioService.AUDIO_EXTENSIONS)
	audio.stop_play()
	audio.queue_free()
	await process_frame
	for path in made: DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(protected)
	DirAccess.remove_absolute(folder)
	print("PASS: AAC .m4a/.aac, ALAC .m4a, AIFF 16/24, WAV float, CAF 24 decoded via Core Audio at 44.1k stereo; AudioService plays them, filters accept them, folder scan finds them; .m4p refused (decoder, add, play); missing-file message")
	quit()
