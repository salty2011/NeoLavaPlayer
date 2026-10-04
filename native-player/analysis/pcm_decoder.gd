extends RefCounted
## Offline audio decode for analysis: any Core Audio readable file (MP3, FLAC,
## WAV, AAC...) -> mono float32 PCM at ANALYSIS_RATE, via macOS /usr/bin/afconvert.
## Nothing is played; the file is converted to a temporary WAV, read, deleted.
## The process gets an argument array (no shell), as in flac_decoder.gd.

const ANALYSIS_RATE := 22050

## Directory for temporary WAV files. Override (e.g. in tests) if user:// is
## not writable.
static var temp_dir: String = "user://"

static func decode_mono(path: String, rate: int = ANALYSIS_RATE) -> Dictionary:
	if OS.get_name() != "macOS":
		return {"error": "Offline analysis decoding currently requires macOS afconvert."}
	if not FileAccess.file_exists(path):
		return {"error": "File not found: %s" % path}
	var src: String = ProjectSettings.globalize_path(path)
	var dir: String = ProjectSettings.globalize_path(temp_dir)
	var temp_path: String = dir.path_join("analysis-%d-%d.wav" % [OS.get_process_id(), Time.get_ticks_usec()])
	var output: Array = []
	var code: int = OS.execute("/usr/bin/afconvert", PackedStringArray([src, temp_path, "-f", "WAVE", "-d", "LEF32@%d" % rate, "-c", "1"]), output, true)
	var result: Dictionary = {"error": "afconvert failed (%d): %s" % [code, " ".join(output)]}
	if code == 0:
		result = read_float_wave(temp_path)
	if FileAccess.file_exists(temp_path):
		DirAccess.remove_absolute(temp_path)
	return result

## Reads a mono/stereo 32-bit float (or 16-bit PCM) WAV, including
## WAVE_FORMAT_EXTENSIBLE. Returns {samples: PackedFloat32Array mono, rate}.
static func read_float_wave(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_buffer(4).get_string_from_ascii() != "RIFF":
		return {"error": "Not a RIFF file"}
	file.get_32()
	if file.get_buffer(4).get_string_from_ascii() != "WAVE":
		return {"error": "Not a WAVE file"}
	var rate: int = 0
	var channels: int = 0
	var bits: int = 0
	var tag: int = 0
	var data := PackedByteArray()
	while file.get_position() + 8 <= file.get_length():
		var chunk: String = file.get_buffer(4).get_string_from_ascii()
		var size: int = file.get_32()
		var start: int = file.get_position()
		if size > file.get_length() - start:
			size = file.get_length() - start
		if chunk == "fmt " and size >= 16:
			tag = file.get_16()
			channels = file.get_16()
			rate = file.get_32()
			file.get_32()
			file.get_16()
			bits = file.get_16()
			if tag == 65534 and size >= 40:
				file.seek(start + 24)
				tag = file.get_32() & 0xffff
		elif chunk == "data":
			data = file.get_buffer(size)
		file.seek(start + size + (size & 1))
	if rate <= 0 or channels < 1 or data.is_empty():
		return {"error": "Unsupported or empty WAV"}
	var interleaved := PackedFloat32Array()
	if tag == 3 and bits == 32:
		interleaved = data.to_float32_array()
	elif tag == 1 and bits == 16:
		var n: int = data.size() / 2
		interleaved.resize(n)
		for i in n:
			interleaved[i] = float(data.decode_s16(i * 2)) / 32768.0
	else:
		return {"error": "Unsupported WAV format tag %d / %d bits" % [tag, bits]}
	if channels == 1:
		return {"samples": interleaved, "rate": rate}
	var frames: int = interleaved.size() / channels
	var mono := PackedFloat32Array()
	mono.resize(frames)
	for i in frames:
		var acc: float = 0.0
		for c in channels:
			acc += interleaved[i * channels + c]
		mono[i] = acc / float(channels)
	return {"samples": mono, "rate": rate}

## Linear-interpolation resampler with a 3-tap pre-filter when downsampling.
## Adequate for analysis features (not for listening).
static func resample(pcm: PackedFloat32Array, from_rate: float, to_rate: float) -> PackedFloat32Array:
	if absf(from_rate - to_rate) < 0.5:
		return pcm
	var src := pcm
	if from_rate > to_rate * 1.4:
		src = PackedFloat32Array()
		src.resize(pcm.size())
		for i in pcm.size():
			var a: float = pcm[maxi(0, i - 1)]
			var c: float = pcm[mini(pcm.size() - 1, i + 1)]
			src[i] = 0.25 * a + 0.5 * pcm[i] + 0.25 * c
	var ratio: float = from_rate / to_rate
	var n: int = int(float(src.size()) / ratio)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var x: float = float(i) * ratio
		var j: int = int(x)
		var f: float = x - float(j)
		var b: float = src[j + 1] if j + 1 < src.size() else src[j]
		out[i] = src[j] * (1.0 - f) + b * f
	return out
