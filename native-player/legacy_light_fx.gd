extends RefCounted
## Strobe (Style 0x04) and Colored Lighting (Style 0x08) of the Lava3.dll light
## object. Static port; addresses in docs/ENGINE_API.md.
##
## Light ctor 0x10019310: +0x44 strobe phase = 1 (lit), +0x48 counter = 0,
## +0x54..0x5c dynamic colour = (1,0,0). Style reader 0x10019be0 copies
## Style&4 -> +0x40 (strobe) and Style&8 -> +0x50 (colored lighting).
##
## Update 0x10019430 (once per engine update, dt = ctx+4 after Responsivness):
##   if dt == 0: return
##   level(+0x4c) = ctx+0x10 (global S)
##   strobe: if 0.075/dt <= counter: phase = 1-phase, counter = 0
##           counter += 1
##   colored: if 0.1/dt > ccount: ccount += 1
##            elif maxA(ctx+0xc) * level >= 0.9:
##               hue += 60 (wrap <0 -> +360, >360 -> -360), sat = intensity = 1
##               dynamic colour = HSI->RGB 0x10019830; ccount = 0
## Draw 0x10019600:
##   colour = dynamic if colored else saved Diffuse (+0x30)
##   ambient = colour * Brightness (+0x2c)
##   if strobe and phase == 0: colour *= 1 - 0.75*level; ambient *= 1 - 0.25*level
##   GL light: diffuse = colour, specular = colour, ambient = ambient.
##
## Deviation: the hue/sat/intensity and ccount are process-global statics in the
## original (0x10036c34..0x10036c40), shared by every light and persisting
## across scene loads. Here they live per scene runtime and reset on reset().
const RipplePools = preload("res://ripple_pools.gd")
var strobe_phase := 1
var strobe_counter := 0.0
var level := 0.0
var color_counter := 0.0
var hsi := Vector3.ZERO
var dynamic_color := Color(1, 0, 0, 1)

func reset() -> void:
	strobe_phase = 1
	strobe_counter = 0.0
	level = 0.0
	color_counter = 0.0
	hsi = Vector3.ZERO
	dynamic_color = Color(1, 0, 0, 1)

func update(dt: float, max_a: float, global_s: float, strobe: bool, colored: bool) -> void:
	if dt == 0.0: return
	level = global_s
	if strobe:
		var threshold := 0.07500000298023224 / dt
		if threshold <= strobe_counter:
			strobe_phase = 1 - strobe_phase
			strobe_counter = 0.0
		strobe_counter += 1.0
	if not colored: return
	if 0.10000000149011612 / dt > color_counter:
		color_counter += 1.0
		return
	if max_a * level < 0.8999999761581421: return
	hsi.x += 60.0
	if hsi.x < 0.0: hsi.x += 360.0
	elif hsi.x > 360.0: hsi.x -= 360.0
	hsi.y = clampf(hsi.y + 1.0, 0.0, 1.0)
	hsi.z = clampf(hsi.z + 1.0, 0.0, 1.0)
	dynamic_color = RipplePools.hsi_to_rgb(hsi)
	color_counter = 0.0

## Returns {"diffuse": Color, "ambient": Color} for one light. saved_color is the
## scene's Lighting Diffuse; brightness the Brightness header value (or override).
func light_terms(saved_color: Color, brightness: float, strobe: bool, colored: bool) -> Dictionary:
	var color := dynamic_color if colored else saved_color
	var diffuse := Color(color.r, color.g, color.b, 1.0)
	var ambient := Color(color.r * brightness, color.g * brightness, color.b * brightness, 1.0)
	if strobe and strobe_phase == 0:
		var dim := 1.0 - 0.75 * level
		var dim_ambient := 1.0 - 0.25 * level
		diffuse = Color(diffuse.r * dim, diffuse.g * dim, diffuse.b * dim, 1.0)
		ambient = Color(ambient.r * dim_ambient, ambient.g * dim_ambient, ambient.b * dim_ambient, 1.0)
	return {"diffuse": diffuse, "ambient": ambient}

func state_snapshot() -> Dictionary:
	return {"strobe_phase": strobe_phase, "strobe_counter": strobe_counter, "level": level, "color_counter": color_counter, "hsi": hsi, "dynamic_color": dynamic_color}
