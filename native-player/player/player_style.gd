extends RefCounted
## Palette, fonts and procedural drawing for the player UI. Everything is
## vector (polygons, lines, system fonts), drawn in base units and scaled by
## the window's content scale, so it stays sharp at any size. Original
## artwork: a dark brushed-steel body with a warm amber "lava" LCD.

# --- Palette ---------------------------------------------------------------
const BODY_TOP := Color("#30353d")
const BODY_BOTTOM := Color("#181b20")
const BODY_LINE := Color(1, 1, 1, 0.025)
const BEVEL_LIGHT := Color(1, 1, 1, 0.16)
const BEVEL_DARK := Color(0, 0, 0, 0.55)
const EDGE := Color("#07080a")
const STRIP_TOP := Color("#1d2026")
const STRIP_BOTTOM := Color("#121418")
const GROOVE_DARK := Color(0, 0, 0, 0.6)
const GROOVE_LIGHT := Color(1, 1, 1, 0.08)
const LABEL := Color("#9aa6b2")
const LABEL_DIM := Color("#5e6873")

const LCD_BG := Color("#0c0906")
const LCD_BG_2 := Color("#140e08")
const LCD_TEXT := Color("#ffb648")
const LCD_DIM := Color("#a8722c")
const LCD_GHOST := Color(1.0, 0.71, 0.28, 0.07)
const LCD_ACCENT := Color("#ff6a1f")

const BUTTON_TOP := Color("#454c56")
const BUTTON_BOTTOM := Color("#2a2f36")
const BUTTON_HOVER_TOP := Color("#535b66")
const BUTTON_DOWN_TOP := Color("#1d2126")
const BUTTON_DOWN_BOTTOM := Color("#2c3138")
const GLYPH := Color("#dfe6ee")
const GLYPH_DIM := Color("#dfe6ee", 0.3)
const LED_ON := Color("#ff7a1a")
const LED_OFF := Color("#3a2a1c")

const TRACK_BG := Color("#0a0b0d")
const FILL := Color("#ff8a2a")
const FILL_DIM := Color("#8a4c1c")
const THUMB_TOP := Color("#c9d1da")
const THUMB_BOTTOM := Color("#7c8692")

const LIST_BG := Color("#0b0d10")
const LIST_TEXT := Color("#c3ccd6")
const LIST_NUMBER := Color("#6f7a86")
const LIST_CURRENT := Color("#ffb648")
const LIST_CURRENT_BG := Color("#2b1a09")
const LIST_SELECTED_BG := Color("#1e3248")
const LIST_HOVER_BG := Color(1, 1, 1, 0.04)
const LIST_FAILED := Color("#59626c")
const LIST_DROP := Color("#ff8a2a")

# --- Fonts -------------------------------------------------------------------
static var _ui_font: Font
static var _bold_font: Font
static var _mono_font: Font

static func ui_font() -> Font:
	if _ui_font == null: _ui_font = _system(["SF Pro Text", "Helvetica Neue", "Helvetica", "Arial"], 500)
	return _ui_font

static func bold_font() -> Font:
	if _bold_font == null: _bold_font = _system(["SF Pro Text", "Helvetica Neue", "Helvetica", "Arial"], 700)
	return _bold_font

static func mono_font() -> Font:
	if _mono_font == null: _mono_font = _system(["SF Mono", "Menlo", "Monaco", "Courier New"], 500)
	return _mono_font

static func _system(names: Array, weight: int) -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(names)
	font.font_weight = weight
	font.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	font.hinting = TextServer.HINTING_LIGHT
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	font.fallbacks = [ThemeDB.fallback_font]
	return font

## Base-unit text in a box: vertically centred, clipped to width.
static func text(ci: CanvasItem, font: Font, rect: Rect2, value: String, size: int, color: Color, align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	var ascent := font.get_ascent(size)
	var descent := font.get_descent(size)
	var baseline := rect.position.y + (rect.size.y + ascent - descent) * 0.5
	ci.draw_string(font, Vector2(rect.position.x, baseline), value, align, rect.size.x, size, color, TextServer.JUSTIFICATION_NONE, TextServer.DIRECTION_AUTO, TextServer.ORIENTATION_HORIZONTAL)

# --- Surfaces ----------------------------------------------------------------
static func vgradient(ci: CanvasItem, rect: Rect2, top: Color, bottom: Color) -> void:
	var p := rect.position
	var s := rect.size
	ci.draw_polygon(PackedVector2Array([p, p + Vector2(s.x, 0), p + s, p + Vector2(0, s.y)]), PackedColorArray([top, top, bottom, bottom]))

## Hairline helpers: width in base units (0.5 = half a unit; 1 px at 2x).
static func hline(ci: CanvasItem, x0: float, x1: float, y: float, color: Color, width := 0.5) -> void:
	ci.draw_line(Vector2(x0, y), Vector2(x1, y), color, width)

static func vline(ci: CanvasItem, x: float, y0: float, y1: float, color: Color, width := 0.5) -> void:
	ci.draw_line(Vector2(x, y0), Vector2(x, y1), color, width)

## Raised bevel around rect (light top-left, dark bottom-right).
static func raised(ci: CanvasItem, rect: Rect2, strength := 1.0) -> void:
	var r := rect.grow(-0.25)
	hline(ci, r.position.x, r.end.x, r.position.y, Color(BEVEL_LIGHT, BEVEL_LIGHT.a * strength))
	vline(ci, r.position.x, r.position.y, r.end.y, Color(BEVEL_LIGHT, BEVEL_LIGHT.a * strength * 0.7))
	hline(ci, r.position.x, r.end.x, r.end.y, Color(BEVEL_DARK, BEVEL_DARK.a * strength))
	vline(ci, r.end.x, r.position.y, r.end.y, Color(BEVEL_DARK, BEVEL_DARK.a * strength))

## Recessed bevel (dark top-left, light bottom-right) with a hard outline.
static func sunken(ci: CanvasItem, rect: Rect2) -> void:
	ci.draw_rect(rect, EDGE, false, 0.5)
	var r := rect.grow(0.5)
	hline(ci, r.position.x, r.end.x, r.position.y, BEVEL_DARK)
	vline(ci, r.position.x, r.position.y, r.end.y, BEVEL_DARK)
	hline(ci, r.position.x, r.end.x, r.end.y, BEVEL_LIGHT)
	vline(ci, r.end.x, r.position.y, r.end.y, BEVEL_LIGHT)

## Brushed-steel body: vertical gradient plus faint horizontal grain.
static func brushed(ci: CanvasItem, rect: Rect2) -> void:
	vgradient(ci, rect, BODY_TOP, BODY_BOTTOM)
	var y := rect.position.y + 1.0
	var i := 0
	while y < rect.end.y:
		var a := 0.018 + 0.02 * float((i * 7919) % 5) / 4.0
		hline(ci, rect.position.x, rect.end.x, y, Color(1, 1, 1, a), 0.25)
		y += 1.5 + float((i * 104729) % 3) * 0.5
		i += 1

## Grooved line pair (title strips).
static func groove(ci: CanvasItem, x0: float, x1: float, y: float) -> void:
	if x1 - x0 < 2.0: return
	hline(ci, x0, x1, y, GROOVE_DARK)
	hline(ci, x0, x1, y + 0.75, GROOVE_LIGHT)

static func lcd(ci: CanvasItem, rect: Rect2) -> void:
	vgradient(ci, rect, LCD_BG_2, LCD_BG)
	# Faint scanlines.
	var y := rect.position.y + 0.75
	while y < rect.end.y:
		hline(ci, rect.position.x, rect.end.x, y, Color(0, 0, 0, 0.18), 0.25)
		y += 1.0
	sunken(ci, rect)

## Button face: gradient, bevel, outline. state: 0 normal, 1 hover, 2 down.
static func button_face(ci: CanvasItem, rect: Rect2, state: int) -> void:
	var top := BUTTON_TOP
	var bottom := BUTTON_BOTTOM
	if state == 1: top = BUTTON_HOVER_TOP
	if state == 2:
		top = BUTTON_DOWN_TOP
		bottom = BUTTON_DOWN_BOTTOM
	vgradient(ci, rect, top, bottom)
	if state == 2: sunken(ci, rect)
	else:
		raised(ci, rect)
		ci.draw_rect(rect.grow(0.25), EDGE, false, 0.5)

# --- Glyphs (centre c, unit u = base units per glyph unit) -------------------
static func glyph(ci: CanvasItem, name: String, c: Vector2, u: float, color: Color) -> void:
	match name:
		"play":
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-3, -4) * u, c + Vector2(4, 0) * u, c + Vector2(-3, 4) * u]), color)
		"pause":
			ci.draw_rect(Rect2(c + Vector2(-3.5, -4) * u, Vector2(2.5, 8) * u), color)
			ci.draw_rect(Rect2(c + Vector2(1, -4) * u, Vector2(2.5, 8) * u), color)
		"stop":
			ci.draw_rect(Rect2(c + Vector2(-3.5, -3.5) * u, Vector2(7, 7) * u), color)
		"previous", "next":
			var d := -1.0 if name == "previous" else 1.0
			for shift in [-3.0, 1.0]:
				ci.draw_colored_polygon(PackedVector2Array([c + Vector2((shift - 1.5) * d, -3.5) * u, c + Vector2((shift + 2.5) * d, 0) * u, c + Vector2((shift - 1.5) * d, 3.5) * u]), color)
			ci.draw_rect(Rect2(c + Vector2(3.6 * d - (0.0 if d > 0 else 1.2), -3.5) * u, Vector2(1.2, 7) * u), color)
		"eject":
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-4, 1) * u, c + Vector2(0, -3.5) * u, c + Vector2(4, 1) * u]), color)
			ci.draw_rect(Rect2(c + Vector2(-4, 2.2) * u, Vector2(8, 1.6) * u), color)
		"menu":
			for row in 3: ci.draw_rect(Rect2(c + Vector2(-3, -2.4 + row * 1.9) * u, Vector2(6, 0.9) * u), color)
		"minimize":
			ci.draw_rect(Rect2(c + Vector2(-2.5, 1.6) * u, Vector2(5, 1.0) * u), color)
		"close":
			ci.draw_line(c + Vector2(-2.3, -2.3) * u, c + Vector2(2.3, 2.3) * u, color, 1.0 * u)
			ci.draw_line(c + Vector2(-2.3, 2.3) * u, c + Vector2(2.3, -2.3) * u, color, 1.0 * u)
		"speaker", "speaker_muted":
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-4, -1.3) * u, c + Vector2(-2.2, -1.3) * u, c + Vector2(0.3, -3.6) * u, c + Vector2(0.3, 3.6) * u, c + Vector2(-2.2, 1.3) * u, c + Vector2(-4, 1.3) * u]), color)
			if name == "speaker":
				ci.draw_arc(c + Vector2(0.4, 0) * u, 2.0 * u, -0.9, 0.9, 8, color, 0.7 * u)
				ci.draw_arc(c + Vector2(0.4, 0) * u, 3.6 * u, -0.9, 0.9, 10, color, 0.7 * u)
			else:
				ci.draw_line(c + Vector2(1.6, -1.8) * u, c + Vector2(4.6, 1.8) * u, color, 0.8 * u)
				ci.draw_line(c + Vector2(1.6, 1.8) * u, c + Vector2(4.6, -1.8) * u, color, 0.8 * u)
		"grip":
			for k in 3:
				var o := float(k) * 2.2
				ci.draw_line(c + Vector2(3.5 - o, 3.5) * u, c + Vector2(3.5, 3.5 - o) * u, color, 0.6 * u)
		# Library: streaming (plays in the Music app) vs local file badges.
		"stream":
			ci.draw_circle(c + Vector2(-2.6, 0) * u, 0.9 * u, color)
			ci.draw_arc(c + Vector2(-2.6, 0) * u, 2.5 * u, -0.85, 0.85, 8, color, 0.75 * u)
			ci.draw_arc(c + Vector2(-2.6, 0) * u, 4.6 * u, -0.8, 0.8, 10, color, 0.75 * u)
		"file":
			var o := c + Vector2(-2.4, -3.2) * u
			ci.draw_polyline(PackedVector2Array([o + Vector2(3.0, 0) * u, o, o + Vector2(0, 6.4) * u, o + Vector2(4.8, 6.4) * u, o + Vector2(4.8, 1.8) * u, o + Vector2(3.0, 0) * u, o + Vector2(3.0, 1.8) * u, o + Vector2(4.8, 1.8) * u]), color, 0.6 * u)
		# Library sources.
		"note":
			ci.draw_circle(c + Vector2(-1.6, 2.4) * u, 1.5 * u, color)
			ci.draw_line(c + Vector2(-0.3, 2.4) * u, c + Vector2(-0.3, -3.6) * u, color, 0.7 * u)
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.3, -3.6) * u, c + Vector2(2.8, -2.2) * u, c + Vector2(2.8, -0.9) * u, c + Vector2(-0.3, -2.3) * u]), color)
		"person":
			ci.draw_circle(c + Vector2(0, -1.7) * u, 1.6 * u, color)
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-3.2, 3.6) * u, c + Vector2(-2.6, 1.4) * u, c + Vector2(-1.2, 0.6) * u, c + Vector2(1.2, 0.6) * u, c + Vector2(2.6, 1.4) * u, c + Vector2(3.2, 3.6) * u]), color)
		"disc":
			ci.draw_arc(c, 3.4 * u, 0, TAU, 20, color, 0.8 * u)
			ci.draw_arc(c, 1.9 * u, -0.6, 0.9, 8, Color(color, 0.6), 0.5 * u)
			ci.draw_circle(c, 0.8 * u, color)
		"list":
			for row in 3: ci.draw_rect(Rect2(c + Vector2(-3.4, -2.8 + row * 2.4) * u, Vector2(4.0 if row < 2 else 2.6, 0.8) * u), color)
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(1.6, 0.6) * u, c + Vector2(4.0, 2.0) * u, c + Vector2(1.6, 3.4) * u]), color)
		"back":
			ci.draw_polyline(PackedVector2Array([c + Vector2(1.4, -3) * u, c + Vector2(-1.6, 0) * u, c + Vector2(1.4, 3) * u]), color, 1.0 * u)
		"forward":
			ci.draw_polyline(PackedVector2Array([c + Vector2(-1.4, -3) * u, c + Vector2(1.6, 0) * u, c + Vector2(-1.4, 3) * u]), color, 1.0 * u)
		"fullscreen":
			# Four corner brackets.
			for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				var tip: Vector2 = c + corner * 3.2 * u
				ci.draw_polyline(PackedVector2Array([tip - Vector2(corner.x * 1.8, 0) * u, tip, tip - Vector2(0, corner.y * 1.8) * u]), color, 0.8 * u)
		"refresh":
			ci.draw_arc(c, 3.0 * u, -2.6, 2.2, 16, color, 0.8 * u)
			var tip := c + Vector2(cos(-2.6), sin(-2.6)) * 3.0 * u
			ci.draw_colored_polygon(PackedVector2Array([tip + Vector2(-1.6, -0.6) * u, tip + Vector2(1.4, -1.2) * u, tip + Vector2(0.4, 1.6) * u]), color)

## `value` shortened with "…" to fit `width` at `size` (cached; text that fits is returned as is).
static var _elide_cache := {}
static func elide(font: Font, value: String, width: float, size: int) -> String:
	if value.is_empty() or width <= 0.0: return ""
	if font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= width: return value
	var key := "%s|%d|%d|%d" % [value, int(width * 4.0), size, font.get_instance_id()]
	if _elide_cache.has(key): return _elide_cache[key]
	var lo := 0
	var hi := value.length()
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if font.get_string_size(value.substr(0, mid).strip_edges(false, true) + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= width: lo = mid
		else: hi = mid - 1
	var out := value.substr(0, lo).strip_edges(false, true) + "…" if lo > 0 else "…"
	if _elide_cache.size() > 4000: _elide_cache.clear()
	_elide_cache[key] = out
	return out

## Word-wrapped lines of `value` for `width`; at most `max_lines`, the last elided.
static func wrap(font: Font, value: String, width: float, size: int, max_lines := 99) -> PackedStringArray:
	var lines := PackedStringArray()
	var line := ""
	for word in value.split(" ", false):
		var trial := word if line.is_empty() else line + " " + word
		if line.is_empty() or font.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= width:
			line = trial
		else:
			lines.append(line)
			line = word
	if not line.is_empty(): lines.append(line)
	if lines.size() > max_lines:
		var rest := " ".join(lines.slice(max_lines - 1))
		lines = lines.slice(0, max_lines - 1)
		lines.append(elide(font, rest, width, size))
	for i in lines.size(): lines[i] = elide(font, lines[i], width, size)
	return lines

## Lava-drop mark: our own logo (two merged blobs, like the visualiser's oozing scenes).
static func lava_mark(ci: CanvasItem, rect: Rect2) -> void:
	var c := rect.get_center()
	var r := minf(rect.size.x, rect.size.y) * 0.5
	ci.draw_circle(c, r, Color("#2b1307"))
	ci.draw_circle(c + Vector2(-0.18, 0.12) * r, r * 0.55, Color("#ff5a14"))
	ci.draw_circle(c + Vector2(0.28, -0.22) * r, r * 0.36, Color("#ffa23a"))
	ci.draw_circle(c + Vector2(0.05, -0.02) * r, r * 0.3, Color("#ff7a1a"))
	ci.draw_circle(c + Vector2(-0.3, -0.12) * r, r * 0.12, Color(1, 0.9, 0.7, 0.8))
	ci.draw_arc(c, r, 0, TAU, 32, EDGE, 0.5)

# --- Seven-segment digits -----------------------------------------------------
## Segment bits a b c d e f g (bit 0 = a, top; then clockwise; g middle).
const SEGMENTS := {"0": 0x3f, "1": 0x06, "2": 0x5b, "3": 0x4f, "4": 0x66, "5": 0x6d, "6": 0x7d, "7": 0x07, "8": 0x7f, "9": 0x6f, "-": 0x40, " ": 0}

## Width of a seven-segment string for digit height h.
static func segment_width(value: String, h: float) -> float:
	var w := 0.0
	for ch in value:
		w += _seg_advance(ch, h)
	return w

static func _seg_advance(ch: String, h: float) -> float:
	if ch == ":": return h * 0.28
	if ch == "-" or ch == " ": return h * 0.42
	return h * 0.62

## Draw value (digits, '-', ':', ' ') with its top-left at origin. Unlit
## segments are drawn as faint ghosts, like a real LCD.
static func segment_text(ci: CanvasItem, origin: Vector2, value: String, h: float, color: Color, ghost: Color) -> void:
	var x := origin.x
	for ch in value:
		if ch == ":":
			var d := h * 0.09
			ci.draw_rect(Rect2(Vector2(x + h * 0.09, origin.y + h * 0.28), Vector2(d, d)), color)
			ci.draw_rect(Rect2(Vector2(x + h * 0.09, origin.y + h * 0.66), Vector2(d, d)), color)
		elif ch == "-":
			# Sign slot: a short bar, no ghost digit.
			_hseg(ci, x + h * 0.04, x + h * 0.32, origin.y + h * 0.5, h * 0.11, color)
		elif ch != " ":
			var bits: int = SEGMENTS.get(ch, 0)
			_digit(ci, Vector2(x, origin.y), h, bits, color, ghost)
		x += _seg_advance(ch, h)

static func _digit(ci: CanvasItem, o: Vector2, h: float, bits: int, color: Color, ghost: Color) -> void:
	var w := h * 0.5
	var t := h * 0.11
	var half := h * 0.5
	var g := t * 0.18 # gap between segments
	# Horizontal segments: a (top), g (middle), d (bottom); vertical: f b (upper), e c (lower).
	var horizontal := {0: o.y + t * 0.5, 6: o.y + half, 3: o.y + h - t * 0.5}
	for bit in horizontal:
		var y: float = horizontal[bit]
		_hseg(ci, o.x + t * 0.5 + g, o.x + w - t * 0.5 - g, y, t, color if bits & (1 << bit) else ghost)
	var vertical := {5: [o.x + t * 0.5, o.y + t * 0.5, o.y + half], 1: [o.x + w - t * 0.5, o.y + t * 0.5, o.y + half], 4: [o.x + t * 0.5, o.y + half, o.y + h - t * 0.5], 2: [o.x + w - t * 0.5, o.y + half, o.y + h - t * 0.5]}
	for bit in vertical:
		var v: Array = vertical[bit]
		_vseg(ci, v[0], v[1] + g, v[2] - g, t, color if bits & (1 << bit) else ghost)

static func _hseg(ci: CanvasItem, x0: float, x1: float, y: float, t: float, color: Color) -> void:
	var k := t * 0.5
	ci.draw_colored_polygon(PackedVector2Array([Vector2(x0, y), Vector2(x0 + k, y - k), Vector2(x1 - k, y - k), Vector2(x1, y), Vector2(x1 - k, y + k), Vector2(x0 + k, y + k)]), color)

static func _vseg(ci: CanvasItem, x: float, y0: float, y1: float, t: float, color: Color) -> void:
	var k := t * 0.5
	ci.draw_colored_polygon(PackedVector2Array([Vector2(x, y0), Vector2(x + k, y0 + k), Vector2(x + k, y1 - k), Vector2(x, y1), Vector2(x - k, y1 - k), Vector2(x - k, y0 + k)]), color)
