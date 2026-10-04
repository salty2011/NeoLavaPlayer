extends RefCounted
## Pure helpers for the player UI: track titles, times and scaling math.
## No nodes, no bus: test_player_ui.gd checks these directly.

## Main window design size in base units (Winamp-like proportions). Every
## rect in player_main_panel.gd / player_playlist_panel.gd is in these units;
## the window renders them at ui_scale (Window.content_scale_factor).
const MAIN_SIZE := Vector2(275, 116)
## Playlist panel height range (base units). The width is the main width.
const PLAYLIST_MIN_HEIGHT := 84.0
const PLAYLIST_DEFAULT_HEIGHT := 174.0
## Library panel (right of the player column): width and height ranges in
## base units. Its height is at least the player column's; the window is as
## tall as the taller of the two.
const LIBRARY_MIN_WIDTH := 250.0
const LIBRARY_DEFAULT_WIDTH := 380.0
const LIBRARY_MIN_HEIGHT := 116.0
const LIBRARY_DEFAULT_HEIGHT := 290.0
## User size choices (Settings > Display > Player size) and the default. The
## default 2x gives a 550-px-wide player per screen-scale unit: 550 points on
## a Retina screen (1100 physical pixels) and 550 px on a 1x screen.
const USER_SIZES := AppSettings.PLAYER_SIZES
const DEFAULT_USER_SIZE := AppSettings.DEFAULT_PLAYER_SIZE
const AppSettings = preload("res://app_settings.gd")

## Render scale: physical pixels per base unit.
static func ui_scale(screen_scale: float, user_size: float) -> float:
	return maxf(screen_scale, 1.0) * clampf(user_size, 0.5, 4.0)

static func nearest_user_size(value: float) -> float:
	var best: float = DEFAULT_USER_SIZE
	for choice in USER_SIZES:
		if absf(choice - value) < absf(best - value): best = choice
	return best

static func size_label(user_size: float) -> String:
	return ("%dx" % int(user_size)) if is_equal_approx(user_size, roundf(user_size)) else ("%.1fx" % user_size)

## Settings window render scale: the screen scale times a gentler step of the
## player size (1x -> 0.75, 2x -> 1, 3x -> 1.25), so it is readable on Retina
## without growing as much as the player.
static func settings_scale(screen_scale: float, user_size: float) -> float:
	return maxf(screen_scale, 1.0) * clampf(0.5 + 0.25 * user_size, 0.75, 1.25)

## Window size in physical pixels for a base-unit size. Rounded up to even
## pixels: macOS rounds odd sizes down on 2x screens.
static func window_pixels(base: Vector2, scale: float) -> Vector2i:
	var px := Vector2i(ceili(base.x * scale - 0.001), ceili(base.y * scale - 0.001))
	return px + Vector2i(px.x % 2, px.y % 2)

## Base-unit height of the whole player for a playlist state.
static func total_height(playlist_open: bool, playlist_height: float) -> float:
	return MAIN_SIZE.y + (clampf(playlist_height, PLAYLIST_MIN_HEIGHT, 4000.0) if playlist_open else 0.0)

## Base-unit size of the whole window: the player column, plus the library
## to its right when open (the taller of the two sets the height).
static func window_base_size(playlist_open: bool, playlist_height: float, library_open: bool, library_width: float, library_height: float) -> Vector2:
	var column := total_height(playlist_open, playlist_height)
	if not library_open: return Vector2(MAIN_SIZE.x, column)
	return Vector2(MAIN_SIZE.x + maxf(library_width, LIBRARY_MIN_WIDTH), maxf(column, maxf(library_height, LIBRARY_MIN_HEIGHT)))

## Playlist height (base units) for a dragged window height in pixels.
static func playlist_height_for(window_pixels_y: float, scale: float) -> float:
	return maxf(window_pixels_y / scale - MAIN_SIZE.y, PLAYLIST_MIN_HEIGHT)

## "m:ss" (or "h:mm:ss"); negative values get a leading minus.
static func time_text(seconds: float) -> String:
	var prefix := "-" if seconds < 0.0 else ""
	var total := int(absf(seconds))
	if total >= 3600: return "%s%d:%02d:%02d" % [prefix, total / 3600, (total / 60) % 60, total % 60]
	return "%s%d:%02d" % [prefix, total / 60, total % 60]

## The one place a playlist entry becomes display text. Entries are strings
## from bus.playlist: file paths and "applemusic:<ID>" items (also accepted:
## "scheme:id|Artist - Title" with an explicit label). Apple Music items and
## files the Music library knows show "Artist - Title" from
## PlayerBus.track_meta. Extend here, not at the call sites.
static func display_title(entry: String) -> String:
	if entry.is_empty(): return ""
	# Non-file item with an explicit label after "|".
	if "|" in entry and not entry.begins_with("/") and not entry.begins_with("res://"):
		return entry.get_slice("|", 1).strip_edges()
	var meta := library_meta(entry)
	if not meta.is_empty():
		return meta.title if str(meta.artist).is_empty() else "%s - %s" % [meta.artist, meta.title]
	var name := entry.get_file().get_basename() if entry.get_extension() != "" else entry.get_file()
	if name.is_empty(): name = entry
	name = name.replace("_", " ").strip_edges()
	# Leading track numbers: "01 - ", "01. ", "1 ", "01-".
	var regex := RegEx.create_from_string("^\\d{1,3}\\s*([.\\-]\\s*|\\s+)")
	var found := regex.search(name)
	if found != null and found.get_end() < name.length(): name = name.substr(found.get_end())
	return name

## PlayerBus.track_meta for applemusic: entries and library-known files; {}
## otherwise or when there is no bus (never creates one: these stay pure).
static func library_meta(entry: String) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null: return {}
	var bus = tree.root.get_node_or_null("PlayerBus")
	if bus == null and tree.root.has_meta("player_bus"): bus = tree.root.get_meta("player_bus")
	if bus == null or not bus.has_method("track_meta"): return {}
	if not entry.begins_with(bus.APPLE_MUSIC_PREFIX) and not bus.library.get("by_location", {}).has(entry): return {}
	return bus.track_meta(entry)

## "MP3" / "FLAC" from the entry, "" for unknown.
static func format_tag(entry: String) -> String:
	var ext := entry.get_extension().to_lower()
	return ext.to_upper() if ext in ["mp3", "flac", "m3u", "wav", "ogg", "m4a", "aac", "aiff", "aif", "caf", "alac"] else ""

## Indices of entries whose display title or path contains `query`
## (case-insensitive; every word must match). Empty query: all.
static func filter_indices(entries: PackedStringArray, query: String) -> Array[int]:
	var out: Array[int] = []
	var words := query.strip_edges().to_lower().split(" ", false)
	for i in entries.size():
		var haystack := (display_title(entries[i]) + " " + entries[i]).to_lower()
		var ok := true
		for word in words:
			if not word in haystack:
				ok = false
				break
		if ok: out.append(i)
	return out

## Sum of known durations and whether any entry is unknown.
static func total_time(entries: PackedStringArray, durations: Dictionary) -> Dictionary:
	var total := 0.0
	var unknown := 0
	for entry in entries:
		if durations.has(entry): total += float(durations[entry])
		else: unknown += 1
	return {"seconds": total, "unknown": unknown}

static func total_text(entries: PackedStringArray, durations: Dictionary) -> String:
	if entries.is_empty(): return "0:00"
	var t := total_time(entries, durations)
	return time_text(t.seconds) + ("+" if t.unknown > 0 else "")
