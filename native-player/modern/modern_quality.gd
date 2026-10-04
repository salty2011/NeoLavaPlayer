extends RefCounted
## Modern quality presets (Low / Medium / High / Ultra). Pure data plus the
## viewport/RenderingServer knobs that are not Environment properties.
## Environment features are applied by modern_environment.gd from the same row.

const NAMES := ["low", "medium", "high", "ultra"]
const LABELS := {"low": "Low", "medium": "Medium", "high": "High", "ultra": "Ultra"}

## gi: "none" | "ssil" | "sdfgi". shadows: 0 off, else atlas size.
## fog: "depth" | "volumetric". aa: "fxaa" | "msaa2" | "msaa4" | "msaa4+taa".
const PRESETS := {
	"low": {"gi": "none", "shadows": 0, "soft_shadows": false, "ssao": false, "ssr": false, "fog": "depth",
		"fog_volume": 64, "fog_depth": 32, "glow_bicubic": false, "aa": "fxaa", "scale": 0.77, "scaling": "fsr",
		"particles": 0.4, "trails": false, "dof": false, "anisotropy": 2},
	"medium": {"gi": "none", "shadows": 2048, "soft_shadows": false, "ssao": true, "ssao_quality": 1, "ssr": false, "fog": "volumetric",
		"fog_volume": 64, "fog_depth": 48, "glow_bicubic": false, "aa": "msaa2", "scale": 1.0, "scaling": "bilinear",
		"particles": 0.7, "trails": true, "dof": false, "anisotropy": 4},
	"high": {"gi": "ssil", "shadows": 4096, "soft_shadows": true, "shadow_quality": 3, "ssao": true, "ssao_quality": 2, "ssr": true, "ssr_steps": 48,
		"fog": "volumetric", "fog_volume": 96, "fog_depth": 64, "glow_bicubic": true, "aa": "msaa4", "scale": 1.0, "scaling": "bilinear",
		"particles": 1.0, "trails": true, "dof": true, "anisotropy": 8},
	"ultra": {"gi": "sdfgi", "ssil": true, "shadows": 8192, "soft_shadows": true, "shadow_quality": 5, "ssao": true, "ssao_quality": 3, "ssr": true, "ssr_steps": 96,
		"fog": "volumetric", "fog_volume": 160, "fog_depth": 96, "glow_bicubic": true, "aa": "msaa4+taa", "scale": 1.0, "scaling": "bilinear",
		"particles": 1.0, "trails": true, "dof": true, "anisotropy": 16},
}

static func preset(name: String) -> Dictionary:
	return PRESETS.get(name if PRESETS.has(name) else "high")

static func sanitize(name) -> String:
	var value := str(name).to_lower()
	return value if NAMES.has(value) else "high"

## Viewport settings the preset owns; returns the previous values so Classic
## can be restored exactly.
static func apply_viewport(viewport: Viewport, row: Dictionary) -> Dictionary:
	var previous := {"msaa_3d": viewport.msaa_3d, "screen_space_aa": viewport.screen_space_aa, "use_taa": viewport.use_taa,
		"scaling_3d_mode": viewport.scaling_3d_mode, "scaling_3d_scale": viewport.scaling_3d_scale,
		"anisotropic_filtering_level": viewport.anisotropic_filtering_level,
		"positional_shadow_atlas_size": viewport.positional_shadow_atlas_size}
	var aa := str(row.aa)
	viewport.msaa_3d = Viewport.MSAA_4X if aa.begins_with("msaa4") else (Viewport.MSAA_2X if aa == "msaa2" else Viewport.MSAA_DISABLED)
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if aa == "fxaa" else Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.use_taa = aa.ends_with("taa")
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if row.scaling == "fsr" else Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = float(row.scale)
	viewport.anisotropic_filtering_level = {2: Viewport.ANISOTROPY_2X, 4: Viewport.ANISOTROPY_4X, 8: Viewport.ANISOTROPY_8X, 16: Viewport.ANISOTROPY_16X}.get(int(row.anisotropy), Viewport.ANISOTROPY_4X)
	viewport.positional_shadow_atlas_size = maxi(int(row.shadows), 256)
	if int(row.shadows) > 0:
		RenderingServer.positional_soft_shadow_filter_set_quality(int(row.get("shadow_quality", 1)) as RenderingServer.ShadowQuality)
		RenderingServer.directional_soft_shadow_filter_set_quality(int(row.get("shadow_quality", 1)) as RenderingServer.ShadowQuality)
	RenderingServer.environment_set_volumetric_fog_volume_size(int(row.fog_volume), int(row.fog_depth))
	RenderingServer.environment_glow_set_use_bicubic_upscale(bool(row.glow_bicubic))
	if row.get("ssao", false): RenderingServer.environment_set_ssao_quality(int(row.get("ssao_quality", 1)) as RenderingServer.EnvironmentSSAOQuality, true, 0.5, 2, 50.0, 300.0)
	return previous

static func restore_viewport(viewport: Viewport, previous: Dictionary) -> void:
	for key in previous: viewport.set(key, previous[key])
