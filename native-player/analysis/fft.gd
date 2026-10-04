extends RefCounted
## Radix-2 FFT with precomputed twiddle and bit-reversal tables.
##
## `power_spectrum()` computes the power of a real frame of `real_size` samples
## through one complex FFT of half that size (the standard "two-for-one"
## packing), which halves the GDScript cost. `complex_transform()` is a plain
## in-place complex FFT used for FFT-based autocorrelation.
## Thread-safe after construction: no shared mutable state.

var real_size: int = 0
var half: int = 0
var _rev := PackedInt32Array()      # bit reversal for `half`
var _tw_cos := PackedFloat64Array() # cos(-2πk/half), k < half/2
var _tw_sin := PackedFloat64Array()
var _post_cos := PackedFloat64Array() # cos(-2πk/real_size), k <= half
var _post_sin := PackedFloat64Array()

func _init(n: int = 1024) -> void:
	assert(n >= 4 and (n & (n - 1)) == 0, "FFT size must be a power of two")
	real_size = n
	half = n >> 1
	_rev = bit_reversal(half)
	_tw_cos.resize(half >> 1)
	_tw_sin.resize(half >> 1)
	for k in half >> 1:
		_tw_cos[k] = cos(-TAU * float(k) / float(half))
		_tw_sin[k] = sin(-TAU * float(k) / float(half))
	_post_cos.resize(half + 1)
	_post_sin.resize(half + 1)
	for k in half + 1:
		_post_cos[k] = cos(-TAU * float(k) / float(n))
		_post_sin[k] = sin(-TAU * float(k) / float(n))

static func bit_reversal(n: int) -> PackedInt32Array:
	var rev := PackedInt32Array()
	rev.resize(n)
	var bits: int = 0
	while (1 << bits) < n:
		bits += 1
	for i in n:
		var r: int = 0
		var v: int = i
		for b in bits:
			r = (r << 1) | (v & 1)
			v >>= 1
		rev[i] = r
	return rev

## Power |X[k]|^2 for k = 0..real_size/2 of an already windowed real frame.
## `frame` must hold `real_size` samples starting at `offset`.
func power_spectrum(frame: PackedFloat32Array, offset: int = 0) -> PackedFloat32Array:
	var h: int = half
	var re := PackedFloat64Array()
	var im := PackedFloat64Array()
	re.resize(h)
	im.resize(h)
	var rev := _rev
	for i in h:
		var j: int = rev[i]
		re[j] = frame[offset + 2 * i]
		im[j] = frame[offset + 2 * i + 1]
	var tc := _tw_cos
	var ts := _tw_sin
	# First two stages fused as radix-4 (twiddles 1 and -i: no multiplies).
	var q: int = 0
	while q < h:
		var r0: float = re[q]
		var i0: float = im[q]
		var r1: float = re[q + 1]
		var i1: float = im[q + 1]
		var r2: float = re[q + 2]
		var i2: float = im[q + 2]
		var r3: float = re[q + 3]
		var i3: float = im[q + 3]
		var ar: float = r0 + r1
		var ai: float = i0 + i1
		var br_: float = r0 - r1
		var bi_: float = i0 - i1
		var cr: float = r2 + r3
		var ci: float = i2 + i3
		var dr: float = r2 - r3
		var di: float = i2 - i3
		re[q] = ar + cr
		im[q] = ai + ci
		re[q + 2] = ar - cr
		im[q + 2] = ai - ci
		# (dr, di) * -i = (di, -dr)
		re[q + 1] = br_ + di
		im[q + 1] = bi_ - dr
		re[q + 3] = br_ - di
		im[q + 3] = bi_ + dr
		q += 4
	var length: int = 8
	while length <= h:
		var hl: int = length >> 1
		var stride: int = h / length
		var block: int = 0
		while block < h:
			var t: int = 0
			for a in range(block, block + hl):
				var b: int = a + hl
				var wr: float = tc[t]
				var wi: float = ts[t]
				var rb: float = re[b]
				var ib: float = im[b]
				var br: float = rb * wr - ib * wi
				var bi: float = rb * wi + ib * wr
				var ra: float = re[a]
				var ia: float = im[a]
				re[b] = ra - br
				im[b] = ia - bi
				re[a] = ra + br
				im[a] = ia + bi
				t += stride
			block += length
		length <<= 1
	var out := PackedFloat32Array()
	out.resize(h + 1)
	# X[k] = E[k] + W^k O[k], E = (Z[k] + conj Z[h-k]) / 2, O = (Z[k] - conj Z[h-k]) / 2i
	out[0] = (re[0] + im[0]) * (re[0] + im[0])
	out[h] = (re[0] - im[0]) * (re[0] - im[0])
	var pc := _post_cos
	var ps := _post_sin
	for k in range(1, h):
		var zr: float = re[k]
		var zi: float = im[k]
		var cr: float = re[h - k]
		var ci: float = -im[h - k]
		var er: float = 0.5 * (zr + cr)
		var ei: float = 0.5 * (zi + ci)
		var dr: float = 0.5 * (zr - cr)
		var di: float = 0.5 * (zi - ci)
		# O = D / i = (di, -dr)
		var or_: float = di
		var oi: float = -dr
		var wr: float = pc[k]
		var wi: float = ps[k]
		var xr: float = er + wr * or_ - wi * oi
		var xi: float = ei + wr * oi + wi * or_
		out[k] = xr * xr + xi * xi
	return out

## In-place-style complex FFT of arbitrary power-of-two length. Returns [re, im].
## `inverse` computes the unscaled inverse transform.
static func complex_transform(re_in: PackedFloat64Array, im_in: PackedFloat64Array, inverse: bool = false) -> Array:
	var n: int = re_in.size()
	assert((n & (n - 1)) == 0)
	var rev := bit_reversal(n)
	var re := PackedFloat64Array()
	var im := PackedFloat64Array()
	re.resize(n)
	im.resize(n)
	for i in n:
		re[rev[i]] = re_in[i]
		im[rev[i]] = im_in[i]
	var sign: float = 1.0 if inverse else -1.0
	var length: int = 2
	while length <= n:
		var hl: int = length >> 1
		var tc := PackedFloat64Array()
		var ts := PackedFloat64Array()
		tc.resize(hl)
		ts.resize(hl)
		for k in hl:
			tc[k] = cos(sign * TAU * float(k) / float(length))
			ts[k] = sin(sign * TAU * float(k) / float(length))
		var block: int = 0
		while block < n:
			for k in hl:
				var a: int = block + k
				var b: int = a + hl
				var wr: float = tc[k]
				var wi: float = ts[k]
				var br: float = re[b] * wr - im[b] * wi
				var bi: float = re[b] * wi + im[b] * wr
				re[b] = re[a] - br
				im[b] = im[a] - bi
				re[a] += br
				im[a] += bi
			block += length
		length <<= 1
	return [re, im]
