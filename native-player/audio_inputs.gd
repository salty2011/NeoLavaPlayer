extends RefCounted
## Recovered Lava3Aud signal generation; see audio-input-recovery.md.
## Input is Godot normalized stereo PCM. Band A and global S are distinct signals.

const PCM_SCALE := 32768.0
const LOG10 := 2.302585092994046
const LN2 := 0.6931471824645996
const DEFAULT_EDGES := [0.0, 300.0, 1000.0, 2000.0, 4000.0, 6000.0]

var sample_rate: float = 48000.0
var fft_size: int = 1024
var hop_size: int = 512
var band_a := PackedFloat32Array()
var global_s: float = 0.0
var _reference := PackedFloat64Array()
var _pending := PackedFloat64Array()
var _window := PackedFloat64Array()
var _bins: Array[Vector2i] = []
var _peak_band := PackedFloat64Array()
var _peak_whole: float = 0.0
var _peak_windows: int = 0
var _peak_elapsed: float = 0.0

func _init(rate: float = 48000.0, edges: Array = DEFAULT_EDGES) -> void:
	configure(rate, edges)

func configure(rate: float, edges: Array = DEFAULT_EDGES) -> void:
	sample_rate = rate if rate > 0.0 and rate <= 48000.0 else 44100.0
	fft_size = 1024 if sample_rate >= 32000.0 else (512 if sample_rate >= 16000.0 else 256)
	hop_size = fft_size / 2
	_window.resize(fft_size)
	for i in fft_size:
		_window[i] = 0.5 - 0.5 * cos(TAU * float(i) / float(fft_size - 1))
	_bins.clear()
	var ranges: Array = edges if not edges.is_empty() and edges[0] is Dictionary else []
	if ranges.is_empty():
		for i in edges.size() - 1: ranges.append({"min": edges[i], "max": edges[i + 1]})
	for interval in ranges:
		var low: float = clampf(float(interval.min), 0.0, sample_rate * 0.49)
		var high: float = clampf(float(interval.max), 0.0, sample_rate * 0.49)
		if low >= high:
			low = high * 0.5
		_bins.append(Vector2i(int(float(fft_size) * low / sample_rate + 0.5), int(float(fft_size) * high / sample_rate + 0.5)))
	reset()

func reset() -> void:
	_pending.clear()
	_reference.resize(_bins.size())
	_reference.fill(1.0)
	band_a.resize(_bins.size())
	band_a.fill(0.0)
	global_s = 0.0
	_clear_window_peaks()

func _clear_window_peaks() -> void:
	_peak_band.resize(_bins.size())
	_peak_band.fill(0.0)
	_peak_whole = 0.0
	_peak_windows = 0
	_peak_elapsed = 0.0

## Single-call form: analyse this buffer and normalise immediately.
func update(buffer: PackedVector2Array, delta: float) -> Dictionary:
	push(buffer, delta)
	return consume()

## Frame-rate independent form: push captured PCM every render frame, then
## consume once per simulation tick. FFT windows completed since the last
## consume are max-pooled, as the original pooled one frame's windows at 25 FPS.
## A consume with no completed window holds the previous A/S instead of
## reporting silence (at >94 FPS a 48 kHz frame holds fewer than 512 samples).
func push(buffer: PackedVector2Array, delta: float = 0.0) -> void:
	# Original smoothing time is captured sample count / sample rate.
	_peak_elapsed += float(buffer.size()) / sample_rate if not buffer.is_empty() else maxf(delta, 0.0)
	for frame in buffer:
		_pending.append((float(frame.x) + float(frame.y)) * PCM_SCALE)
	var start: int = 0
	if _peak_band.size() != _bins.size(): _clear_window_peaks()
	while _pending.size() - start >= fft_size:
		var power: PackedFloat64Array = _fft_power(start)
		var total: float = 0.0
		for value in power:
			total += value
		_peak_whole = maxf(_peak_whole, total / float(fft_size))
		for b in _bins.size():
			var sum_power: float = 0.0
			for k in range(_bins[b].x, _bins[b].y + 1):
				sum_power += power[k]
			_peak_band[b] = maxf(_peak_band[b], sum_power)
		_peak_windows += 1
		start += hop_size
	if start > 0:
		_pending = _pending.slice(start)

func consume() -> Dictionary:
	if _peak_windows > 0 or _peak_elapsed > 0.0 and _pending.is_empty():
		_normalize(_peak_band, _peak_whole, _peak_elapsed)
		_clear_window_peaks()
	return {"band_a": band_a, "global_s": global_s}

func _normalize(power: PackedFloat64Array, whole_power: float, elapsed: float) -> void:
	for b in power.size():
		var ratio: float = power[b] / _reference[b]
		var db: float = 10.0 * log(ratio) / LOG10 if ratio > 0.0 else -3.0
		band_a[b] = (clampf(db, -3.0, 0.0) + 3.0) / 3.0
		# Full-scale band response instantly adopts current power; otherwise reference half-life 1.3s.
		var retention: float = 0.0 if band_a[b] == 1.0 else exp(-LN2 * elapsed / 1.3)
		_reference[b] = maxf((1.0 - retention) * power[b] + retention * _reference[b], 2000.0)
	var level_db: float = 10.0 * log(whole_power) / LOG10 if whole_power > 0.0 else 70.0
	var level: float = (clampf(level_db, 70.0, 105.0) - 70.0) / 35.0
	var retention: float = 0.0 if level >= 0.5 and level > global_s else exp(-LN2 * elapsed / 1.7)
	global_s = (1.0 - retention) * level + retention * global_s

func _fft_power(start: int) -> PackedFloat64Array:
	var real := PackedFloat64Array()
	var imaginary := PackedFloat64Array()
	real.resize(fft_size)
	imaginary.resize(fft_size)
	imaginary.fill(0.0)
	for i in fft_size:
		real[i] = _pending[start + i] * _window[i]
	# Iterative radix-2 FFT, unnormalized, matching the recovered butterfly scale.
	var reverse: int = 0
	for i in range(1, fft_size):
		var bit: int = fft_size >> 1
		while reverse & bit:
			reverse ^= bit
			bit >>= 1
		reverse ^= bit
		if i < reverse:
			var temporary: float = real[i]
			real[i] = real[reverse]
			real[reverse] = temporary
	var length: int = 2
	while length <= fft_size:
		var angle: float = -TAU / float(length)
		var step_real: float = cos(angle)
		var step_imaginary: float = sin(angle)
		var half: int = length >> 1
		for block in range(0, fft_size, length):
			var twiddle_real: float = 1.0
			var twiddle_imaginary: float = 0.0
			for k in half:
				var first: int = block + k
				var second: int = first + half
				var r: float = real[second] * twiddle_real - imaginary[second] * twiddle_imaginary
				var im: float = real[second] * twiddle_imaginary + imaginary[second] * twiddle_real
				real[second] = real[first] - r
				imaginary[second] = imaginary[first] - im
				real[first] += r
				imaginary[first] += im
				var next_real: float = twiddle_real * step_real - twiddle_imaginary * step_imaginary
				twiddle_imaginary = twiddle_real * step_imaginary + twiddle_imaginary * step_real
				twiddle_real = next_real
		length <<= 1
	var power := PackedFloat64Array()
	power.resize(fft_size >> 1)
	power[0] = real[0] * real[0]
	for k in range(1, power.size()):
		# Original two-real-window extraction doubles real and imaginary components.
		power[k] = 4.0 * (real[k] * real[k] + imaginary[k] * imaginary[k])
	return power
