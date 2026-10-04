extends RefCounted
## Persisted player settings (user://settings.cfg). Standalone so a later
## UI/scene window split can share it without main.gd.
## Defaults: vsync on, uncapped render rate, fixed 60 Hz scene ticks. Scene
## speed no longer depends on render rate. "Original" caps rendering at 60 fps,
## the original Lava3Aud MaxFrameRate default (not the scene FramesPerSecond).
signal changed
const PATH := "user://settings.cfg"
const ORIGINAL := -1
const UNCAPPED := 0
const ORIGINAL_MAX_FRAME_RATE := 60
const FPS_CHOICES := [ORIGINAL, 30, 60, 144, UNCAPPED]
var path := PATH
var vsync := true
var fps_cap := UNCAPPED
var interpolate := true
## "fixed" = 60 Hz scene ticks (default); "frame" = original per-frame dt.
var timing := "fixed"
var analysis_source := "real"
var mock_bpm := 128.0
## Reactivity layer (modern scenes; the classic scene path ignores these).
## Stored in [reactivity]; see analysis/reactivity_service.gd.
const REACTIVITY_DEFAULTS := {"sensitivity": 1.0, "camera_intensity": 1.0, "effects_intensity": 1.0, "prefetch": true}
var reactivity := REACTIVITY_DEFAULTS.duplicate()
## Use procedurally generated stand-ins for textures that were never recovered
## (labelled "reconstruction"). Recovered originals are always used.
var use_reconstructions := true
## Render mode (Phase 4c): "classic" renders exactly as the recovered
## original; "modern" adds the Lava-25 layer (modern/modern_layer.gd) on scenes
## that have a Modern profile. Per-scene overrides live in [render_scenes]
## keyed by "<set>/<scene>" (value "classic"/"modern"); see effective_render_mode.
const RENDER_MODES := ["classic", "modern"]
const MODERN_QUALITIES := ["low", "medium", "high", "ultra"]
const MODERN_EFFECT_DEFAULTS := {"particles": true, "trails": true, "dof": true, "post": true}
var render_mode := "modern"
var render_overrides := {}
var modern_quality := "high"
var modern_effects := MODERN_EFFECT_DEFAULTS.duplicate()
## Modern camera (Phase 4d, docs/DIRECTOR_AND_ANIMATION.md): "director" (the
## virtual director edits shots to the music), "original" (the recovered Lava3
## camera, exactly), "locked" (one static wide framing). Classic always uses
## the original camera. Stored as [render] camera_mode.
const CAMERA_MODES := ["director", "original", "locked"]
var camera_mode := "director"
## Player window size multiplier (Settings > Display > Player size), stored
## as [player] ui_size; the window renders at screen scale x this. See
## player/player_format.gd for the choices.
const PLAYER_SIZES := [1.0, 1.5, 2.0, 3.0]
const DEFAULT_PLAYER_SIZE := 2.0
## F4 debug override of fps_cap for this session; never saved. null = none.
var debug_cap_override = null

static func fps_label(cap: int) -> String:
	if cap == ORIGINAL: return "Original (%d fps)" % ORIGINAL_MAX_FRAME_RATE
	if cap == UNCAPPED: return "Uncapped"
	return "%d fps" % cap

## Engine.max_fps for a cap choice (0 = unlimited).
static func max_fps_for(cap: int) -> int:
	return ORIGINAL_MAX_FRAME_RATE if cap == ORIGINAL else maxi(cap, 0)

func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(path) != OK: return
	vsync = bool(config.get_value("display", "vsync", vsync))
	var cap := int(config.get_value("display", "fps_cap", fps_cap))
	fps_cap = cap if FPS_CHOICES.has(cap) else UNCAPPED
	interpolate = bool(config.get_value("display", "interpolate", interpolate))
	timing = "frame" if str(config.get_value("display", "timing", timing)) == "frame" else "fixed"
	var source := str(config.get_value("analysis", "source", analysis_source))
	analysis_source = source if source in ["real", "mock"] else "real"
	mock_bpm = clampf(float(config.get_value("analysis", "mock_bpm", mock_bpm)), 30.0, 300.0)
	reactivity = load_reactivity(path)
	use_reconstructions = bool(config.get_value("assets", "use_reconstructions", use_reconstructions))
	var mode := str(config.get_value("render", "mode", render_mode))
	render_mode = mode if RENDER_MODES.has(mode) else "modern"
	var quality := str(config.get_value("render", "quality", modern_quality))
	modern_quality = quality if MODERN_QUALITIES.has(quality) else "high"
	for key in MODERN_EFFECT_DEFAULTS: modern_effects[key] = bool(config.get_value("render", "effect_" + key, modern_effects[key]))
	var camera := str(config.get_value("render", "camera_mode", camera_mode))
	camera_mode = camera if CAMERA_MODES.has(camera) else "director"
	render_overrides = {}
	var scenes := load_section(path, "render_scenes")
	for key in scenes:
		if RENDER_MODES.has(str(scenes[key])): render_overrides[str(key)] = str(scenes[key])

## Merges into the existing file so other sections ([player], [scenes],
## [windows]) written by the services survive.
func save_settings() -> int:
	var config := ConfigFile.new()
	config.load(path)
	config.set_value("display", "vsync", vsync)
	config.set_value("display", "fps_cap", fps_cap)
	config.set_value("display", "interpolate", interpolate)
	config.set_value("display", "timing", timing)
	config.set_value("analysis", "source", analysis_source)
	config.set_value("analysis", "mock_bpm", mock_bpm)
	for key in reactivity: config.set_value("reactivity", key, reactivity[key])
	config.set_value("assets", "use_reconstructions", use_reconstructions)
	config.set_value("render", "mode", render_mode)
	config.set_value("render", "quality", modern_quality)
	for key in modern_effects: config.set_value("render", "effect_" + key, modern_effects[key])
	config.set_value("render", "camera_mode", camera_mode)
	if config.has_section("render_scenes"): config.erase_section("render_scenes")
	for key in render_overrides: config.set_value("render_scenes", key, render_overrides[key])
	return config.save(path)

## "<set>/<scene>" key for a scene folder (render overrides, Modern profiles).
static func scene_key(folder: String) -> String:
	var clean := folder.trim_suffix("/")
	return clean.get_base_dir().get_file() + "/" + clean.get_file()

## The mode a scene renders in: its override if any, else the global mode.
func effective_render_mode(folder: String) -> String:
	return str(render_overrides.get(scene_key(folder), render_mode))

func effective_cap() -> int:
	return int(debug_cap_override) if debug_cap_override != null else fps_cap

## Apply render pacing. Headless/dummy display servers ignore vsync safely.
func apply() -> void:
	Engine.max_fps = max_fps_for(effective_cap())
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	changed.emit()

## F4 cycle: 30 -> 60 -> 144 -> uncapped -> original -> 30 (session only).
func cycle_debug_cap() -> int:
	var order := [30, 60, 144, UNCAPPED, ORIGINAL]
	var index := order.find(effective_cap()) if debug_cap_override != null else -1
	debug_cap_override = order[(index + 1) % order.size()]
	return debug_cap_override

## Read one section of the settings file as a Dictionary (missing -> {}).
static func load_section(file_path: String, section: String) -> Dictionary:
	var config := ConfigFile.new()
	var values := {}
	if config.load(file_path) != OK or not config.has_section(section): return values
	for key in config.get_section_keys(section): values[key] = config.get_value(section, key)
	return values

## Merge values into one section, keeping the rest of the file.
static func save_section(file_path: String, section: String, values: Dictionary) -> int:
	var config := ConfigFile.new()
	config.load(file_path)
	for key in values: config.set_value(section, key, values[key])
	return config.save(file_path)

## [reactivity] values with defaults and range clamping (sensitivity 0..3,
## camera/effects intensity 0..2).
static func load_reactivity(file_path: String) -> Dictionary:
	return sanitize_reactivity(load_section(file_path, "reactivity"))

static func sanitize_reactivity(values: Dictionary) -> Dictionary:
	var out := REACTIVITY_DEFAULTS.duplicate()
	for key in out:
		if values.has(key): out[key] = values[key]
	out.sensitivity = clampf(float(out.sensitivity), 0.0, 3.0)
	out.camera_intensity = clampf(float(out.camera_intensity), 0.0, 2.0)
	out.effects_intensity = clampf(float(out.effects_intensity), 0.0, 2.0)
	out.prefetch = bool(out.prefetch)
	return out

static func save_reactivity(file_path: String, values: Dictionary) -> int:
	return save_section(file_path, "reactivity", sanitize_reactivity(values))

static func load_player_size(file_path: String = PATH) -> float:
	var value := float(load_section(file_path, "player").get("ui_size", DEFAULT_PLAYER_SIZE))
	return value if PLAYER_SIZES.has(value) else DEFAULT_PLAYER_SIZE

static func save_player_size(value: float, file_path: String = PATH) -> int:
	return save_section(file_path, "player", {"ui_size": value})
