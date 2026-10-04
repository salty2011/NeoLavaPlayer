extends RefCounted
## macOS Core Audio decoding (afconvert to a temporary 16-bit stereo WAV, run
## off the main thread by AudioService) for every local format Godot can't
## load natively: FLAC, AAC/M4A (incl. ALAC, which uses .m4a), AIFF, WAV, CAF.
## MP3 keeps Godot's own loader. Protected .m4p files are refused (FairPlay).
## No external codec installation. Decoded PCM is held fully in memory
## (stereo 16-bit), so very long files are refused.
const EXTENSIONS := ["flac", "m4a", "aac", "aiff", "aif", "wav", "caf", "alac"]
const MAX_DECODED_BYTES := 1536 * 1024 * 1024
const TEMP_PREFIX := "flac-"

## Estimated decoded stereo 16-bit size from afinfo's duration and rate; -1 if unknown.
static func estimate_decoded_bytes(path: String) -> int:
	var output := []
	if OS.execute("/usr/bin/afinfo", PackedStringArray([path]), output, true) != 0 or output.is_empty(): return -1
	var text := str(output[0])
	var duration := -1.0
	var rate := -1.0
	for line in text.split("\n"):
		line = line.strip_edges()
		if line.begins_with("estimated duration:"): duration = line.trim_prefix("estimated duration:").strip_edges().split(" ")[0].to_float()
		elif line.begins_with("Data format:") and " Hz" in line:
			for part in line.split(","):
				if part.strip_edges().ends_with(" Hz"): rate = part.strip_edges().trim_suffix(" Hz").to_float()
	if duration <= 0 or rate <= 0: return -1
	return int(duration * rate) * 4

static func size_error(bytes: int) -> String:
	return "That file is too long to load (about %.1f GB decoded; limit %.1f GB). Choose a shorter file." % [bytes / 1073741824.0, MAX_DECODED_BYTES / 1073741824.0]

## Remove temporary WAVs left behind by a crash or forced quit.
## Files younger than min_age_seconds may belong to another running instance.
static func clean_stale_temp_files(min_age_seconds := 600) -> int:
	var removed := 0
	var directory := DirAccess.open("user://")
	if directory == null: return 0
	for file in directory.get_files():
		if not file.begins_with(TEMP_PREFIX) or file.get_extension().to_lower() != "wav": continue
		if Time.get_unix_time_from_system() - FileAccess.get_modified_time("user://" + file) < min_age_seconds: continue
		if directory.remove(file) == OK: removed += 1
	return removed

static func decode(path: String) -> Dictionary:
	var kind := path.get_extension().to_upper()
	if kind == "M4P": return {"error":"Protected (.m4p) files can't be decoded. Add the track from the Music library instead; the Music app plays it."}
	if OS.get_name() != "macOS": return {"error":"%s playback currently requires macOS." % kind}
	if not FileAccess.file_exists(path): return {"error":"Couldn't open that %s file." % kind}
	var estimate := estimate_decoded_bytes(path)
	if estimate > MAX_DECODED_BYTES: return {"error":size_error(estimate)}
	var temp_path := ProjectSettings.globalize_path("user://flac-%d-%d.wav" % [OS.get_process_id(), Time.get_ticks_usec()])
	var output := []
	# Arguments go directly to the process; filenames never pass through a shell.
	var code := OS.execute("/usr/bin/afconvert", PackedStringArray([path, temp_path, "-f", "WAVE", "-d", "LEI16", "-c", "2"]), output, true)
	var stream: AudioStreamWAV
	if code == 0:
		# Second guard when afinfo could not estimate: check the converted size.
		var file := FileAccess.open(temp_path, FileAccess.READ)
		var size := file.get_length() if file != null else 0
		file = null
		if size > MAX_DECODED_BYTES:
			DirAccess.remove_absolute(temp_path)
			return {"error":size_error(size)}
		stream = _read_pcm_wave(temp_path)
	if FileAccess.file_exists(temp_path): DirAccess.remove_absolute(temp_path)
	if stream == null or stream.get_length() <= 0: return {"error":"Couldn't decode that %s file." % kind}
	return {"stream":stream}

static func _read_pcm_wave(path: String) -> AudioStreamWAV:
	# Core Audio emits WAVE_FORMAT_EXTENSIBLE; Godot's WAV loader rejects it.
	# Read its declared PCM payload directly, retaining the original sample rate.
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_buffer(4).get_string_from_ascii() != "RIFF": return null
	file.get_32()
	if file.get_buffer(4).get_string_from_ascii() != "WAVE": return null
	var rate := 0
	var valid_format := false
	var pcm := PackedByteArray()
	while file.get_position() + 8 <= file.get_length():
		var chunk := file.get_buffer(4).get_string_from_ascii()
		var size := file.get_32()
		var start := file.get_position()
		if size > file.get_length() - start: return null
		if chunk == "fmt " and size >= 16:
			var tag := file.get_16()
			var channels := file.get_16()
			rate = file.get_32()
			file.get_32()
			var align := file.get_16()
			var bits := file.get_16()
			if tag == 65534 and size >= 40:
				file.seek(start + 24)
				tag = file.get_32() # PCM subtype in extensible GUID.
			valid_format = tag == 1 and channels == 2 and bits == 16 and align == 4 and rate > 0
		elif chunk == "data": pcm = file.get_buffer(size)
		file.seek(start + size + (size & 1))
	if not valid_format or pcm.is_empty() or pcm.size() % 4 != 0: return null
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.stereo = true
	stream.mix_rate = rate
	stream.data = pcm
	return stream
