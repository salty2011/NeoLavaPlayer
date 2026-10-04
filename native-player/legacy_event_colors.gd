extends RefCounted
## Original shared HSI routines 0x10010730/0x10010880.
## Caller's draws are the original three uniform [0,1] CRT draws, in H/S/I order.
const HSI = preload("res://ripple_pools.gd")

static func random_color(base: Color, preset: Dictionary, draws: Vector3) -> Color:
	var hsi: Vector3 = HSI.rgb_to_hsi(base)
	hsi.x += lerpf(-float(preset.get("CHSigma",0.0)),float(preset.get("CHSigma",0.0)),draws.x)+float(preset.get("CHOffset",0.0))
	if hsi.x<0.0: hsi.x += 360.0
	if hsi.x>360.0: hsi.x -= 360.0
	hsi.y = clampf(hsi.y+lerpf(-float(preset.get("CSSigma",0.0)),float(preset.get("CSSigma",0.0)),draws.y)+float(preset.get("CSOffset",0.0)),0.0,1.0)
	hsi.z = clampf(hsi.z+lerpf(-float(preset.get("CISigma",0.0)),float(preset.get("CISigma",0.0)),draws.z)+float(preset.get("CIOffset",0.0)),0.0,1.0)
	return HSI.hsi_to_rgb(hsi)

static func event_color(color0: Color, color1: Color, color2: Color, elapsed: float, duration: float) -> Color:
	var phase := elapsed*2.0/duration
	if phase<=1.0: return color0.lerp(color1,phase)
	return color1.lerp(color2,minf(phase-1.0,1.0))

static func blend(source: Color, target: Color, weight: float, clamp_upper: bool = false) -> Color:
	var amount := maxf(weight,0.0)
	if clamp_upper: amount = minf(amount,1.0)
	return Color(lerpf(source.r,target.r,amount),lerpf(source.g,target.g,amount),lerpf(source.b,target.b,amount),source.a)
