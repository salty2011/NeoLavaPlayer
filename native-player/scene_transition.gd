extends Node
## Scene transitions (Phase 4e). While the current scene keeps running in the
## window, the next scene is built in a SubViewport with its own World3D and
## its own Modern layer ("stage"). A full-window overlay blends the stage over
## the window with a shader (crossfade, dip to black, iris). Both scenes keep
## simulating during the blend. When it ends the Visualiser hands the stage's
## runtime over to the window and frees the old one; this node then holds the
## last stage frame for two rendered frames so the handover cannot flash.
##
## Lifecycle: prepare() (load once, offscreen, rendered a single time so GPU
## uploads and pipeline compiles happen early) -> start() -> advance() every
## frame -> `blend_finished` -> release_runtime() + begin_hold() -> freed.
## See docs/TRANSITIONS.md.
const SceneRuntime = preload("res://scene_runtime.gd")
const ModernLayer = preload("res://modern/modern_layer.gd")
const BlendShader = preload("res://scene_transition.gdshader")

signal blend_finished()

const STYLE_IDS := ["cut", "crossfade", "dip", "iris"]
const STYLE_LABELS := {"cut": "Cut (original)", "crossfade": "Crossfade", "dip": "Dip to black", "iris": "Iris wipe"}
const DURATIONS := [0.5, 1.0, 2.0, 3.0, 5.0]
const DEFAULT_STYLE := "crossfade"
const DEFAULT_DURATION := 2.0

var stage: SubViewport
var runtime
var modern
## Phase 4d: the stage layer's director/animator, passed to the window's layer on adoption.
var handoff: Dictionary = {}
var index := -1
var scene_path := ""
## Milliseconds the last prepare() blocked the main thread (load + Modern attach + first render request).
var load_ms := 0.0
var style := DEFAULT_STYLE
var duration := DEFAULT_DURATION
var progress := 0.0
var blending := false
## Simulation time offset for the incoming sampler (keeps mock beat phase continuous).
var sampler_offset := 0.0

var _layer: CanvasLayer
var _rect: ColorRect
var _material: ShaderMaterial
var _hold_frames := 0
var _start_frame := -1

static func normalise_style(value) -> String:
	var text := str(value).to_lower()
	return text if STYLE_IDS.has(text) else DEFAULT_STYLE

## Nearest allowed duration; accepts any value in 0.25..10 s as-is (rounded to 0.25).
static func normalise_duration(value) -> float:
	return snappedf(clampf(float(value), 0.25, 10.0), 0.25)

static func style_code(id: String) -> int:
	match id:
		"crossfade": return 1
		"dip": return 2
		"iris": return 3
	return 0

func _init():
	name = "SceneTransition"
	process_mode = Node.PROCESS_MODE_ALWAYS

func is_active() -> bool:
	return stage != null

func is_prepared_for(scene_index: int) -> bool:
	return stage != null and not blending and index == scene_index and runtime != null

## Build the incoming scene offscreen. `use_modern` attaches a Modern layer to
## it (the Visualiser has already decided that from the render settings).
func prepare(scene_index: int, path: String, options: Dictionary) -> Dictionary:
	discard()
	var started := Time.get_ticks_usec()
	index = scene_index
	scene_path = path
	stage = SubViewport.new()
	stage.name = "TransitionStage"
	stage.own_world_3d = true
	stage.transparent_bg = false
	stage.gui_disable_input = true
	stage.handle_input_locally = false
	stage.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_match_window(stage)
	add_child(stage)
	runtime = SceneRuntime.new()
	runtime.use_reconstructions = bool(options.get("use_reconstructions", true))
	runtime.interpolate = bool(options.get("interpolate", true))
	runtime.fixed_step = bool(options.get("fixed_step", true))
	stage.add_child(runtime)
	var result: Dictionary = runtime.load_scene(path)
	modern = ModernLayer.new()
	stage.add_child(modern)
	if bool(options.get("use_modern", false)):
		modern.quality = str(options.get("quality", "high"))
		modern.effects = (options.get("effects", {}) as Dictionary).duplicate()
		modern.camera_mode = str(options.get("camera_mode", "director"))
		modern.attach(runtime)
	# One render now: textures, meshes and shader pipelines reach the GPU before
	# the blend begins instead of during its first frames.
	stage.render_target_update_mode = SubViewport.UPDATE_ONCE
	_build_overlay()
	load_ms = float(Time.get_ticks_usec() - started) / 1000.0
	var window := get_window()
	if window != null and not window.size_changed.is_connected(_on_resize): window.size_changed.connect(_on_resize)
	return result

func _match_window(viewport: SubViewport) -> void:
	var window := get_window()
	var size := window.size if window != null else Vector2i(1200, 760)
	viewport.size = Vector2i(maxi(size.x, 2), maxi(size.y, 2))
	# Same 3D buffer settings as the window, so a finished blend matches.
	var root: Viewport = window if window != null else null
	if root != null:
		viewport.msaa_3d = root.msaa_3d
		viewport.screen_space_aa = root.screen_space_aa
		viewport.use_taa = root.use_taa
		viewport.use_debanding = root.use_debanding
		viewport.scaling_3d_mode = root.scaling_3d_mode
		viewport.scaling_3d_scale = root.scaling_3d_scale

func _build_overlay() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 50
	add_child(_layer)
	_rect = ColorRect.new()
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_material = ShaderMaterial.new()
	_material.shader = BlendShader
	_material.set_shader_parameter("incoming", stage.get_texture())
	_material.set_shader_parameter("progress", 0.0)
	_material.set_shader_parameter("style", 1)
	_rect.material = _material
	_rect.visible = false
	_layer.add_child(_rect)

func _on_resize() -> void:
	if stage == null: return
	var window := get_window()
	stage.size = Vector2i(maxi(window.size.x, 2), maxi(window.size.y, 2))
	_update_aspect()

func _update_aspect() -> void:
	var window := get_window()
	if _material != null and window != null and window.size.y > 0:
		_material.set_shader_parameter("aspect", float(window.size.x) / float(window.size.y))

## Begin the blend. Call after prepare().
func start(blend_style: String, seconds: float) -> void:
	if stage == null or runtime == null: return
	style = normalise_style(blend_style)
	duration = normalise_duration(seconds)
	progress = 0.0
	blending = true
	_start_frame = Engine.get_process_frames()
	stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_material.set_shader_parameter("style", style_code(style))
	_material.set_shader_parameter("progress", 0.0)
	_update_aspect()
	# First frame at progress 0 draws nothing, so the stage's first live render is never shown half-ready.
	_rect.visible = true

## Advance the incoming scene and the blend. `sampler` feeds the incoming
## runtime exactly as the Visualiser feeds the window's (null = scene paused).
func advance(delta: float, sampler) -> void:
	if not blending: return
	if sampler is Callable and runtime != null: runtime.advance(delta, sampler)
	if modern != null and modern.attached: modern.update(delta)
	if Engine.get_process_frames() > _start_frame: progress = minf(1.0, progress + delta / maxf(duration, 0.05))
	_material.set_shader_parameter("progress", progress)
	if progress >= 1.0:
		blending = false
		blend_finished.emit()

## Skip to the end now (used when the user changes scene again mid-blend).
func complete_now() -> void:
	if not blending: return
	progress = 1.0
	_material.set_shader_parameter("progress", 1.0)
	blending = false
	blend_finished.emit()

## Detach the incoming runtime from the stage for the Visualiser to adopt.
## The stage freezes on its last frame and the overlay stays at full cover.
func release_runtime():
	var released = runtime
	if modern != null:
		handoff = modern.take_motion()
		modern.detach()
		modern.queue_free()
		modern = null
	if released != null and released.get_parent() == stage: stage.remove_child(released)
	runtime = null
	stage.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return released

## Keep the frozen stage frame covering the window for `frames` rendered frames, then clean up.
func begin_hold(frames := 2) -> void:
	_hold_frames = maxi(frames, 1)
	set_process(true)

func _process(_delta: float) -> void:
	if _hold_frames <= 0: return
	_hold_frames -= 1
	if _hold_frames == 0: discard()

## Free the stage and overlay (and the incoming runtime, if it was never adopted).
func discard() -> void:
	blending = false
	_hold_frames = 0
	var window := get_window()
	if window != null and window.size_changed.is_connected(_on_resize): window.size_changed.disconnect(_on_resize)
	if modern != null and is_instance_valid(modern):
		modern.detach()
		modern.free()
	modern = null
	if _layer != null and is_instance_valid(_layer):
		remove_child(_layer)
		_layer.free()
	_layer = null
	_rect = null
	_material = null
	if stage != null and is_instance_valid(stage):
		remove_child(stage)
		stage.free()
	stage = null
	runtime = null
	index = -1
	progress = 0.0
