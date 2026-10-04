extends RefCounted
## Original LAVA! "effects" mask (scene header `Style`, property 0x1c5).
## Evidence (static, Lava3.dll / LAVA.exe; see docs/ENGINE_API.md):
## - GetEfxInfo 0x10015d10 reads property 0x1c5 (Style) into EFXINFO+4;
##   SetEfxInfo 0x10017630 writes it back. LAVA.exe key handler 0x40e75c XORs
##   bits into its copy (toggle helper 0x40e96c) and pushes it with SetEfxInfo.
## - Consumers: camera 0x10001880 (0x40), light 0x10019be0 (0x04, 0x08),
##   scene 0x10026440 (0x01, 0x02, 0x10, 0x80).
## - 0x20 / 0x100 / 0x200 have no Lava3.dll consumer at those Style reads.
##   Names come from the Oozic 3 LVC header field order
##   (Tmap Wframe Strobe Clights DynCol Lights Pause Flat TRot EnvMap), which
##   matches the seven confirmed bits exactly.
const TEXTURE := 0x01
const WIREFRAME := 0x02
const STROBE := 0x04
const COLORED_LIGHTING := 0x08
const DYNAMIC_COLORING := 0x10
const LIGHTS := 0x20
const PAUSE_CAMERA := 0x40
const FLAT_SHADING := 0x80
const TEXT_ROTATION := 0x100
const ENV_MAP := 0x200
const LVC_FIELDS := ["Tmap", "Wframe", "Strobe", "Clights", "DynCol", "Lights", "Pause", "Flat", "TRot", "EnvMap"]
const NAMES := {
	TEXTURE: "Texture", WIREFRAME: "Wire frame", STROBE: "Strobe", COLORED_LIGHTING: "Colored lighting",
	DYNAMIC_COLORING: "Dynamic coloring", LIGHTS: "Lights (0x20)", PAUSE_CAMERA: "Pause camera",
	FLAT_SHADING: "Flat shading", TEXT_ROTATION: "Text rotation (0x100)", ENV_MAP: "Environment map (0x200)",
}
## Original hotkey letters (LAVA.exe jump table 0x40e8f4/0x40e934). F3 (flat
## shading) is our debug overlay, so the player maps flat shading to Shift+F3;
## F4 (0x20) is our FPS-cap debug key, so 0x20 is Shift+F4. F11 (0x100) is
## fullscreen here; 0x100 has no hotkey.
const ORIGINAL_KEYS := {TEXTURE: "T", WIREFRAME: "W", STROBE: "S", COLORED_LIGHTING: "L", DYNAMIC_COLORING: "C", LIGHTS: "F4", PAUSE_CAMERA: "P", FLAT_SHADING: "F3", TEXT_ROTATION: "F11"}

## Default mask of a parsed scene (scene_data.gd result).
static func from_scene(data: Dictionary) -> int:
	var header: Dictionary = data.get("header", {})
	if str(data.get("format", "")) == "LVC":
		var mask := 0
		var found := false
		for i in LVC_FIELDS.size():
			if header.has(LVC_FIELDS[i]):
				found = true
				if int(str(header[LVC_FIELDS[i]]).to_float()) != 0: mask |= 1 << i
		if found: return mask
		return int(str(header.get("Style", "49")).to_int())
	# ASHEX v2: sixth header line (scene_data stores it as render_flags_raw).
	return int(str(header.get("render_flags_raw", "49")).to_int())

static func describe(mask: int) -> Dictionary:
	var result := {}
	for bit in NAMES: result[NAMES[bit]] = (mask & bit) != 0
	return result
