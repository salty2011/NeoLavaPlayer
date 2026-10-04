extends RefCounted
## Streaming STFT feature extractor shared by the offline (TrackAnalyzer) and
## realtime (LiveAnalyzer) paths, so both see identical per-frame features.
##
## Input: mono float PCM at `sample_rate` (22050 Hz recommended), pushed in
## arbitrary block sizes. Each hop produces one frame with:
##   band_db[6]   mean-square power per band in dBFS (sine at 0 dBFS = -3 dB)
##   flux         half-wave rectified, log-compressed spectral flux (sum over log bands)
##   band_flux[6] the same flux split by main band (for onset band attribution)
##   rms_db       windowed RMS in dBFS
##   kpow         K-weighting-like weighted mean-square (for LUFS-like loudness)
##   logspec[NLOG] log-compressed log-band spectrum (offline only, for downbeat novelty)
## Frame i is centred at sample i*hop + fft_size/2 (see `frame_time`).

const FFT := preload("res://analysis/fft.gd")

const BAND_NAMES := ["sub", "bass", "lowmid", "mid", "presence", "high"]
const BAND_EDGES := [20.0, 60.0, 250.0, 500.0, 2000.0, 6000.0, 20000.0]
const NUM_BANDS := 6
const NLOG := 36
const LOG_MIN_HZ := 30.0
## Crude K-weighting (BS.1770 high-pass + high-shelf) applied per band.
const K_WEIGHTS := [0.35, 0.85, 1.0, 1.0, 1.45, 1.55]
const DB_FLOOR := -120.0

var sample_rate: float = 22050.0
var fft_size: int = 1024
var hop: int = 256
var frame_rate: float = 0.0
var keep_logspec: bool = false
var keep_history: bool = true
var frames_done: int = 0

# Per-frame outputs (appended; cleared at every push() when keep_history is false).
var band_db := PackedFloat32Array()   # frames * NUM_BANDS
var band_flux := PackedFloat32Array() # frames * NUM_BANDS
var flux := PackedFloat32Array()
var rms_db := PackedFloat32Array()
var kpow := PackedFloat32Array()
var logspec := PackedFloat32Array()   # frames * NLOG when keep_logspec

var _fft
var _window := PackedFloat32Array()
var _win_norm: float = 1.0
var _pending := PackedFloat32Array()
var _band_lo := PackedInt32Array()
var _band_hi := PackedInt32Array()   # exclusive
var _log_lo := PackedInt32Array()
var _log_hi := PackedInt32Array()
var _log_band := PackedInt32Array()  # main band of each log band
var _prev_log := PackedFloat32Array()
var _gamma: float = 1.0

func _init(rate: float = 22050.0, size: int = 1024, hop_size: int = 256) -> void:
	sample_rate = rate
	fft_size = size
	hop = hop_size
	frame_rate = sample_rate / float(hop)
	_fft = FFT.new(fft_size)
	_window.resize(fft_size)
	var sumsq: float = 0.0
	for i in fft_size:
		var w: float = 0.5 - 0.5 * cos(TAU * float(i) / float(fft_size))
		_window[i] = w
		sumsq += w * w
	# One-sided power sum -> mean square: ms = 2 * sum(P) / (N * sum(w^2)).
	_win_norm = 2.0 / (float(fft_size) * sumsq)
	var nyq_bin: int = fft_size / 2
	var bin_hz: float = sample_rate / float(fft_size)
	for b in NUM_BANDS:
		var lo: int = clampi(int(round(BAND_EDGES[b] / bin_hz)), 1, nyq_bin)
		var hi: int = clampi(int(round(BAND_EDGES[b + 1] / bin_hz)), lo + 1, nyq_bin + 1)
		_band_lo.append(lo)
		_band_hi.append(hi)
	# Log-spaced bands for flux; each at least one bin wide, contiguous.
	var edges := PackedInt32Array()
	var max_hz: float = sample_rate * 0.5
	var prev_bin: int = -1
	for j in NLOG + 1:
		var hz: float = LOG_MIN_HZ * pow(max_hz / LOG_MIN_HZ, float(j) / float(NLOG))
		var bin: int = clampi(int(round(hz / bin_hz)), 1, nyq_bin + 1)
		if bin <= prev_bin:
			bin = prev_bin + 1
		edges.append(bin)
		prev_bin = bin
	for j in NLOG:
		var lo: int = mini(edges[j], nyq_bin)
		var hi: int = clampi(edges[j + 1], lo + 1, nyq_bin + 1)
		_log_lo.append(lo)
		_log_hi.append(hi)
		var centre_hz: float = 0.5 * float(lo + hi) * bin_hz
		var mb: int = NUM_BANDS - 1
		for b in NUM_BANDS:
			if centre_hz < BAND_EDGES[b + 1]:
				mb = b
				break
		_log_band.append(mb)
	_prev_log.resize(NLOG)
	_prev_log.fill(0.0)
	# Compression constant: log(1 + gamma * magnitude) with magnitude in FFT units.
	_gamma = 1000.0 / float(fft_size)

func frame_time(index: int) -> float:
	return (float(index * hop) + 0.5 * float(fft_size)) / sample_rate

func reset() -> void:
	_pending = PackedFloat32Array()
	_prev_log.fill(0.0)
	frames_done = 0
	clear_outputs()

func clear_outputs() -> void:
	band_db = PackedFloat32Array()
	band_flux = PackedFloat32Array()
	flux = PackedFloat32Array()
	rms_db = PackedFloat32Array()
	kpow = PackedFloat32Array()
	logspec = PackedFloat32Array()

## Push mono samples; returns the number of new frames produced.
func push(samples: PackedFloat32Array) -> int:
	if not keep_history:
		clear_outputs()
	_pending.append_array(samples)
	var produced: int = 0
	var start: int = 0
	var n: int = fft_size
	var frame := PackedFloat32Array()
	frame.resize(n)
	var win := _window
	var pending := _pending
	while pending.size() - start >= n:
		var sumsq: float = 0.0
		for i in n:
			var v: float = pending[start + i] * win[i]
			frame[i] = v
			sumsq += v * v
		_analyse_frame(frame, sumsq)
		produced += 1
		start += hop
	if start > 0:
		_pending = pending.slice(start)
	frames_done += produced
	return produced

## Offline fast path: analyse a whole buffer without copying it into _pending.
## Set from the main thread to stop every running process_all() early (app
## quit while a worker analyses). Callers check it and discard the result.
static var abort: bool = false

func process_all(samples: PackedFloat32Array) -> int:
	clear_outputs()
	var produced: int = 0
	var n: int = fft_size
	var frame := PackedFloat32Array()
	frame.resize(n)
	var win := _window
	var start: int = 0
	var total: int = samples.size()
	while start + n <= total:
		if (produced & 511) == 0 and abort:
			break
		var sumsq: float = 0.0
		for i in n:
			var v: float = samples[start + i] * win[i]
			frame[i] = v
			sumsq += v * v
		_analyse_frame(frame, sumsq)
		produced += 1
		start += hop
	frames_done += produced
	return produced

func _analyse_frame(frame: PackedFloat32Array, sumsq: float) -> void:
	var p: PackedFloat32Array = _fft.power_spectrum(frame)
	var m: int = p.size()
	# Prefix sum so every band is O(1).
	var cum := PackedFloat64Array()
	cum.resize(m + 1)
	var acc: float = 0.0
	cum[0] = 0.0
	for k in m:
		acc += p[k]
		cum[k + 1] = acc
	var norm: float = _win_norm
	var kp: float = 0.0
	for b in NUM_BANDS:
		var ms: float = (cum[_band_hi[b]] - cum[_band_lo[b]]) * norm
		kp += ms * K_WEIGHTS[b]
		band_db.append(maxf(DB_FLOOR, 10.0 * log(ms + 1e-14) / log(10.0)))
	kpow.append(kp)
	# Windowed RMS: mean square of the Hann-weighted frame, compensated for the window energy.
	rms_db.append(maxf(DB_FLOOR, 10.0 * log(sumsq / (float(fft_size) * 0.375) + 1e-14) / log(10.0)))
	var f: float = 0.0
	var bf := PackedFloat32Array()
	bf.resize(NUM_BANDS)
	bf.fill(0.0)
	var g: float = _gamma
	for j in NLOG:
		var mag: float = sqrt(cum[_log_hi[j]] - cum[_log_lo[j]])
		var lv: float = log(1.0 + g * mag)
		var d: float = lv - _prev_log[j]
		_prev_log[j] = lv
		if keep_logspec:
			logspec.append(lv)
		if d > 0.0:
			f += d
			bf[_log_band[j]] += d
	flux.append(f)
	band_flux.append_array(bf)
