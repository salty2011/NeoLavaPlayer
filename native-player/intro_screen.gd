extends CanvasLayer
## Intro screen from the package's intro.ini (N in the original; WM_COMMAND
## 0x7d9). Static evidence (Lava3.dll; docs/ENGINE_API.md "Intro screen"):
## - Show 0x10011bf6..0x10011c22: timer(+0x94) = Time(ms)*0.001 (0x10012830)
##   + 1.5 s.
## - Update 0x10012a80, once per engine update: timer -= min(ctx.dt, 0.1),
##   clamped at 0 (dt is after Responsivness).
## - Draw 0x10012ae0: nothing when timer == 0; alpha = 0.85 while
##   timer >= 1.5, else timer * 0.566667 (linear fade over the last 1.5 s).
## - intro.ini keys (LavaFile strings 0x1004a4d0..): OnOff, Mode (0 artist,
##   1 greeting), Time, BkgColor, TextColor, TextFontInfo (LOGFONT fields),
##   Cover/Logo/Banner + *Loc rects, greeting Title/To/Message/From/Date,
##   artist Genre/Song/Artist/Album/Link/Email/Comments/YearCopyRight.
## Inferred (labelled): the 512x256 page (from the Loc rects), centring and
## scaling of the page in the window, and showing it at load when OnOff=1.
const PAGE := Vector2(512, 256)
const GREETING_FIELDS := ["Title", "To", "Message", "From", "Date"]
const ARTIST_FIELDS := ["Genre", "Song", "Artist", "Album", "Link", "Email", "Comments", "YearCopyRight"]
var settings: Dictionary = {}
var timer := 0.0
var duration := 5.0
var on_at_load := false
var available := false
var _runtime
var _root: Control
var _page: Control

func configure(scene: Dictionary, runtime) -> void:
	_runtime = runtime
	layer = 10
	var path := ""
	for file in scene.get("files", []):
		if str(file).to_lower() == "intro.ini": path = str(scene.folder).path_join(str(file))
	if path.is_empty(): return
	var section := ""
	for raw_line in FileAccess.get_file_as_string(path).replace("\r", "").split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with(";"): continue
		if line.begins_with("["): section = line; continue
		if section != "[Introduction]": continue
		var split := line.find("=")
		if split > 0: settings[line.left(split)] = line.substr(split + 1)
	available = not settings.is_empty()
	duration = float(settings.get("Time", "5000")) * 0.001
	on_at_load = int(settings.get("OnOff", "0")) != 0
	_build()

func _rect(key: String) -> Rect2:
	var values: PackedStringArray = str(settings.get(key, "0,0,0,0")).split(",")
	if values.size() < 4: return Rect2()
	return Rect2(values[0].to_float(), values[1].to_float(), values[2].to_float(), values[3].to_float())

func _color(key: String, fallback: Color) -> Color:
	var values: PackedStringArray = str(settings.get(key, "")).split(",")
	if values.size() < 3: return fallback
	return Color(values[0].to_float() / 255.0, values[1].to_float() / 255.0, values[2].to_float() / 255.0)

func _font_size() -> int:
	var values: PackedStringArray = str(settings.get("TextFontInfo", "")).split(",")
	return maxi(absi(values[2].to_int()) if values.size() > 2 else 11, 6)

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_page = Control.new()
	_page.size = PAGE
	_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_page)
	var background := ColorRect.new()
	background.color = _color("BkgColor", Color(0.78, 0.78, 0.78))
	background.size = PAGE
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_page.add_child(background)
	for key in ["Cover", "Logo", "Banner"]:
		var file := str(settings.get(key, ""))
		if file.is_empty() or _runtime == null: continue
		var resolved: String = _runtime.resource_path(file)
		if resolved.is_empty(): continue
		var texture: Texture2D = load(resolved) as Texture2D if ResourceLoader.exists(resolved) else null
		if texture == null: continue
		var image := TextureRect.new()
		image.texture = texture
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_SCALE
		var rect := _rect(key + "Loc")
		image.position = rect.position
		image.size = rect.size
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_page.add_child(image)
	var fields: Array = GREETING_FIELDS if int(settings.get("Mode", "1")) == 1 else ARTIST_FIELDS
	for key in fields:
		var text := str(settings.get(key, ""))
		if text.is_empty(): continue
		var label := Label.new()
		label.text = text
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.clip_text = true
		var rect := _rect(key + "Loc")
		label.position = rect.position
		label.size = rect.size
		label.add_theme_color_override("font_color", _color("TextColor", Color.BLACK))
		label.add_theme_font_size_override("font_size", _font_size())
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_page.add_child(label)
	_root.visible = false

func reset() -> void:
	timer = 0.0
	if available and on_at_load: show_intro()
	present()

func show_intro() -> bool:
	if not available: return false
	timer = duration + 1.5
	present()
	return true

func hide_intro() -> void:
	timer = 0.0
	present()

## One engine update.
func step(dt: float) -> void:
	if timer <= 0.0: return
	timer -= minf(dt, 0.1)
	if timer < 0.0: timer = 0.0

func current_alpha() -> float:
	if timer <= 0.0: return 0.0
	return 0.85 if timer >= 1.5 else timer * 0.5666667

func present() -> void:
	if _root == null: return
	var alpha := current_alpha()
	_root.visible = alpha > 0.0
	if not _root.visible: return
	_root.modulate.a = alpha
	var viewport_size: Vector2 = _root.get_viewport_rect().size if _root.is_inside_tree() else PAGE
	var scale_factor := minf(viewport_size.x * 0.8 / PAGE.x, viewport_size.y * 0.8 / PAGE.y)
	_page.scale = Vector2.ONE * maxf(scale_factor, 0.1)
	_page.position = (viewport_size - PAGE * _page.scale) * 0.5

func summary() -> Dictionary:
	return {"available": available, "on_at_load": on_at_load, "duration": duration, "mode": int(settings.get("Mode", "1")) if available else -1}
