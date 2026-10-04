extends RefCounted
## Music library browser model: no nodes, no drawing. Turns PlayerBus.library
## into the rows the library panel shows (songs, artists, albums, playlists
## and one level of drill-in), with search, sorting, selection-to-ids and the
## bus commands for each action. test_library_browser.gd drives it directly.
##
## A view is {source, group, query, sort_key, sort_desc}. `rows` holds track
## ids (track lists) or group keys (artist names, album keys, playlist ids).
## Search keys and the sorted orders of the whole library are built once per
## library change, so filtering and re-sorting 20k tracks stays cheap.
const Fmt = preload("res://player/player_format.gd")

const SOURCES := ["songs", "artists", "albums", "playlists"]
const SOURCE_LABELS := {"songs": "Songs", "artists": "Artists", "albums": "Albums", "playlists": "Playlists"}
## Group kind of each source (songs has none).
const KINDS := {"artists": "artist", "albums": "album", "playlists": "playlist"}
const SEP := "\u0001"

var library: Dictionary = {}
var tracks: Dictionary = {}
var source := "songs"
## Drilled-in group key ("" = the source's top level).
var group := ""
var query := ""
## "" = natural order (library / album / playlist order).
var sort_key := ""
var sort_desc := false
## Track ids or group keys, in display order.
var rows: Array = []

var _search := {}          # id -> folded "title artist album album_artist"
var _artists: Array = []   # names, sorted
var _artist_tracks := {}   # name -> ids (album, disc, track order)
var _albums: Array = []    # album keys, sorted by title
var _playlists: Array = [] # ids, library order
var _playlist_by_id := {}
var _songs_sorted := {}    # sort key -> ids ascending (whole library)
var _top_query := ""       # the group list's query while drilled in

# --- Library ---------------------------------------------------------------

func set_library(data: Dictionary) -> void:
	library = data
	tracks = data.get("tracks", {})
	_search.clear()
	_songs_sorted.clear()
	for id in tracks:
		var t: Dictionary = tracks[id]
		_search[id] = fold("%s %s %s %s" % [t.get("title", ""), t.get("artist", ""), t.get("album", ""), t.get("album_artist", "")])
	var artists: Dictionary = data.get("artists", {})
	_artists = _sorted_keys(artists.keys(), func(name): return fold(name))
	_artist_tracks.clear()
	for name in artists:
		_artist_tracks[name] = _sort_ids(artists[name], "album", false)
	var albums: Dictionary = data.get("albums", {})
	_albums = _sorted_keys(albums.keys(), func(key): return fold(str(albums[key].get("title", ""))) + SEP + fold(str(albums[key].get("artist", ""))))
	_playlists.clear()
	_playlist_by_id.clear()
	for p in data.get("playlists", []):
		_playlists.append(str(p.get("id", "")))
		_playlist_by_id[str(p.get("id", ""))] = p
	# Keep the view when its group still exists (a refresh); else go to the top.
	if not group.is_empty() and not has_group(source, group): group = ""
	rebuild()

func is_empty() -> bool: return tracks.is_empty()

func counts() -> Dictionary:
	return {"songs": tracks.size(), "artists": _artists.size(), "albums": _albums.size(), "playlists": _playlists.size()}

func has_group(src: String, key: String) -> bool:
	match src:
		"artists": return _artist_tracks.has(key)
		"albums": return library.get("albums", {}).has(key)
		"playlists": return _playlist_by_id.has(key)
	return false

# --- View --------------------------------------------------------------------

## "track" for track lists, else the group kind ("artist" | "album" | "playlist").
func row_kind() -> String:
	return "track" if source == "songs" or not group.is_empty() else KINDS[source]

func is_group_list() -> bool: return row_kind() != "track"

func set_source(value: String) -> void:
	if not value in SOURCES: return
	source = value
	group = ""
	query = ""
	_top_query = ""
	sort_key = ""
	sort_desc = false
	rebuild()

func open_group(key: String) -> void:
	if source == "songs" or not has_group(source, key): return
	_top_query = query
	group = key
	query = ""
	sort_key = ""
	sort_desc = false
	rebuild()

## Back from a group to its list; false at the top level.
func back() -> bool:
	if group.is_empty(): return false
	var left := group
	group = ""
	query = _top_query
	sort_key = ""
	sort_desc = false
	rebuild()
	rows_hint = rows.find(left)
	return true

## Row of the group just left (back()), so the panel can select it; -1 otherwise.
var rows_hint := -1

func set_query(text: String) -> void:
	query = text
	rebuild()

## Header click: ascending, then descending, then natural order.
func toggle_sort(key: String) -> void:
	if sort_key != key:
		sort_key = key
		sort_desc = false
	elif not sort_desc:
		sort_desc = true
	else:
		sort_key = ""
		sort_desc = false
	rebuild()

func view_state() -> Dictionary:
	return {"source": source, "group": group, "sort_key": sort_key, "sort_desc": sort_desc}

func apply_view_state(state: Dictionary) -> void:
	source = str(state.get("source", "songs"))
	if not source in SOURCES: source = "songs"
	group = str(state.get("group", ""))
	if not group.is_empty() and not tracks.is_empty() and not has_group(source, group): group = ""
	if source == "songs": group = ""
	query = ""
	_top_query = ""
	sort_key = str(state.get("sort_key", ""))
	if not sort_key in sort_keys(): sort_key = ""
	sort_desc = bool(state.get("sort_desc", false)) and not sort_key.is_empty()
	rebuild()

## Column specs for the current rows: {id, label, width (fixed) | flex, align, sort}.
## `narrow` drops the least useful column.
func columns(narrow := false) -> Array:
	var right := HORIZONTAL_ALIGNMENT_RIGHT
	match row_kind():
		"artist": return [{"id": "name", "label": "ARTIST", "flex": 1.0}, {"id": "tracks", "label": "TRACKS", "width": 26.0, "align": right}]
		"album":
			if narrow: return [{"id": "name", "label": "ALBUM", "flex": 1.0}, {"id": "tracks", "label": "TRACKS", "width": 26.0, "align": right}]
			return [{"id": "name", "label": "ALBUM", "flex": 0.56}, {"id": "artist", "label": "ARTIST", "flex": 0.44}, {"id": "tracks", "label": "TRACKS", "width": 26.0, "align": right}]
		"playlist": return [{"id": "name", "label": "PLAYLIST", "flex": 1.0}, {"id": "tracks", "label": "TRACKS", "width": 26.0, "align": right}]
	var cols: Array = []
	if source == "albums": cols.append({"id": "track", "label": "#", "width": 11.0, "align": right})
	cols.append({"id": "title", "label": "TITLE", "flex": 0.42})
	if source != "artists": cols.append({"id": "artist", "label": "ARTIST", "flex": 0.3})
	if source != "albums" and not (narrow and source != "artists"): cols.append({"id": "album", "label": "ALBUM", "flex": 0.28})
	cols.append({"id": "time", "label": "TIME", "width": 20.0, "align": right})
	return cols

func sort_keys() -> Array:
	var out := []
	for c in columns(): out.append(c.id)
	return out

func rebuild() -> void:
	rows_hint = -1
	var words := fold(query).split(" ", false)
	var kind := row_kind()
	if kind == "track":
		var base: Array
		if source == "songs":
			base = _songs_order(sort_key)
		else:
			base = group_track_ids(source, group)
			if not sort_key.is_empty(): base = _sort_ids(base, sort_key, false)
		if sort_desc and not sort_key.is_empty():
			base = base.duplicate()
			base.reverse()
		if words.is_empty():
			rows = base # shared, read-only
			return
		var out := []
		for id in base:
			if _matches(_search.get(id, ""), words): out.append(id)
		rows = out
		return
	var keys: Array = {"artist": _artists, "album": _albums, "playlist": _playlists}[kind]
	# Artists and albums are already in name order; playlists in library order.
	var presorted := sort_key == "name" and kind != "playlist"
	if not sort_key.is_empty() and not presorted:
		keys = _sorted_keys(keys, func(key): return _group_sort_text(kind, key, sort_key))
	if sort_desc and not sort_key.is_empty():
		keys = keys.duplicate()
		keys.reverse()
	if words.is_empty():
		rows = keys.duplicate()
		return
	var found := []
	for key in keys:
		if _matches(fold(group_label(kind, key) + " " + group_detail(kind, key)), words): found.append(key)
	rows = found

static func _matches(haystack: String, words: PackedStringArray) -> bool:
	for word in words:
		if not haystack.contains(word): return false
	return true

# --- Groups ------------------------------------------------------------------

func group_track_ids(src: String, key: String) -> Array:
	match src:
		"artists": return _artist_tracks.get(key, [])
		"albums": return library.get("albums", {}).get(key, {}).get("track_ids", [])
		"playlists": return _playlist_by_id.get(key, {}).get("track_ids", [])
	return []

func source_of(kind: String) -> String:
	for s in KINDS:
		if KINDS[s] == kind: return s
	return "songs"

## Display name of a group row.
func group_label(kind: String, key: String) -> String:
	match kind:
		"artist": return key
		"album": return str(library.get("albums", {}).get(key, {}).get("title", key))
		"playlist": return str(_playlist_by_id.get(key, {}).get("name", "Playlist"))
	return key

## Second column text of a group row (albums: the album artist).
func group_detail(kind: String, key: String) -> String:
	return str(library.get("albums", {}).get(key, {}).get("artist", "")) if kind == "album" else ""

func group_count(kind: String, key: String) -> int:
	return group_track_ids(source_of(kind), key).size()

## Key of the album / artist a track belongs to ("" when it has none).
func album_key_of(id: String) -> String:
	var t: Dictionary = tracks.get(id, {})
	if str(t.get("album", "")).is_empty(): return ""
	var artist := str(t.get("album_artist", ""))
	if artist.is_empty(): artist = artist_of(id)
	var key := artist + " — " + str(t.album)
	return key if library.get("albums", {}).has(key) else ""

func artist_of(id: String) -> String:
	var artist := str(tracks.get(id, {}).get("artist", ""))
	return "Unknown Artist" if artist.is_empty() else artist

# --- Cells -------------------------------------------------------------------

## Text of one cell: row is a track id or a group key.
func cell(row: String, column: String) -> String:
	var kind := row_kind()
	if kind != "track":
		match column:
			"name": return group_label(kind, row)
			"artist": return group_detail(kind, row)
			"tracks": return str(group_count(kind, row))
		return ""
	var t: Dictionary = tracks.get(row, {})
	match column:
		"title":
			var title := str(t.get("title", ""))
			return title if not title.is_empty() else "Untitled"
		"artist": return str(t.get("artist", ""))
		"album": return str(t.get("album", ""))
		"time":
			var ms := int(t.get("duration_ms", 0))
			return Fmt.time_text(ms / 1000.0) if ms > 0 else ""
		"track":
			var n := int(t.get("track_number", 0))
			return str(n) if n > 0 else ""
	return ""

## True for tracks the Music app plays (streaming, cloud, protected).
func is_streaming(id: String) -> bool:
	return not bool(tracks.get(id, {}).get("playable_file", false))

## Total length of a set of track ids, in seconds.
func total_seconds(ids: Array) -> float:
	var ms := 0
	for id in ids: ms += int(tracks.get(id, {}).get("duration_ms", 0))
	return ms / 1000.0

# --- Actions -------------------------------------------------------------------

## Track ids for rows of the current view, in display order (groups expand
## to their tracks).
func ids_for(row_keys: Array) -> Array:
	var kind := row_kind()
	if kind == "track": return row_keys.duplicate()
	var out := []
	var src := source_of(kind)
	for key in row_keys: out.append_array(group_track_ids(src, key))
	return out

## Bus commands for an action on rows of the current view:
##   "play"    replace the playlist and play (clear_playlist, then add);
##   "add"     append, keep playing what plays;
##   "enqueue" append and play the first added (double-click, Enter).
## Playlists go through add_library_playlist, everything else through
## add_library_tracks. Returns [[name, args], ...]; [] when nothing to add.
func commands(action: String, row_keys: Array) -> Array:
	if row_keys.is_empty(): return []
	if row_kind() == "playlist": return playlist_commands(action, row_keys)
	return track_commands(action, ids_for(row_keys))

func track_commands(action: String, ids: Array) -> Array:
	if ids.is_empty(): return []
	var out := []
	if action == "play": out.append([&"clear_playlist", {}])
	out.append([&"add_library_tracks", {"ids": ids.duplicate(), "play": action != "add"}])
	return out

func playlist_commands(action: String, playlist_ids: Array) -> Array:
	var out := []
	if action == "play": out.append([&"clear_playlist", {}])
	for i in playlist_ids.size():
		out.append([&"add_library_playlist", {"id": str(playlist_ids[i]), "play": action != "add" and i == 0}])
	return out

## Commands for the whole drilled-in group (PLAY ALL / ADD ALL).
func group_commands(action: String) -> Array:
	if group.is_empty(): return []
	if source == "playlists": return playlist_commands(action, [group])
	return track_commands(action, group_track_ids(source, group))

## Noun for the drilled-in group / a group kind ("album", "artist", "playlist").
func group_noun() -> String:
	return KINDS.get(source, "") if not group.is_empty() else ""

# --- Sorting -------------------------------------------------------------------

func _songs_order(key: String) -> Array:
	var order: Array = library.get("order", [])
	if key.is_empty(): return order
	if not _songs_sorted.has(key): _songs_sorted[key] = _sort_ids(order, key, false)
	return _songs_sorted[key]

## Stable sort of track ids by a column (native PackedStringArray sort on
## "folded key \1 index" strings: fast even for 20k tracks).
func _sort_ids(ids: Array, key: String, desc: bool) -> Array:
	var keyed := PackedStringArray()
	keyed.resize(ids.size())
	for i in ids.size():
		keyed[i] = _track_sort_text(str(ids[i]), key) + SEP + "%07d" % i
	keyed.sort()
	var out := []
	out.resize(ids.size())
	for i in keyed.size():
		var s: String = keyed[i]
		out[i] = ids[s.substr(s.rfind(SEP) + 1).to_int()]
	if desc: out.reverse()
	return out

func _track_sort_text(id: String, key: String) -> String:
	var t: Dictionary = tracks.get(id, {})
	var number := "%03d%04d" % [int(t.get("disc_number", 0)), int(t.get("track_number", 0))]
	match key:
		"title": return fold(str(t.get("title", ""))) + SEP + fold(str(t.get("artist", "")))
		"artist": return fold(str(t.get("artist", ""))) + SEP + fold(str(t.get("album", ""))) + SEP + number
		"album": return fold(str(t.get("album", ""))) + SEP + number
		"time": return "%010d" % int(t.get("duration_ms", 0))
		"track": return number
	return ""

func _group_sort_text(kind: String, key: String, column: String) -> String:
	match column:
		"name": return fold(group_label(kind, key))
		"artist": return fold(group_detail(kind, key)) + SEP + fold(group_label(kind, key))
		"tracks": return "%07d" % group_count(kind, key)
	return ""

static func _sorted_keys(keys: Array, text: Callable) -> Array:
	var keyed := PackedStringArray()
	keyed.resize(keys.size())
	for i in keys.size(): keyed[i] = str(text.call(keys[i])) + SEP + "%07d" % i
	keyed.sort()
	var out := []
	out.resize(keys.size())
	for i in keyed.size():
		var s: String = keyed[i]
		out[i] = keys[s.substr(s.rfind(SEP) + 1).to_int()]
	return out

# --- Text folding ------------------------------------------------------------------

const _FOLD_FROM := ["àáâãäåāăą", "çćĉċč", "ďđð", "èéêëēĕėęě", "ĝğġģ", "ĥħ", "ìíîïĩīĭįı", "ĵ", "ķ", "ĺļľŀł", "ñńņňŉ", "òóôõöøōŏő", "ŕŗř", "śŝşšș", "ţťŧț", "ùúûüũūŭůűų", "ŵ", "ýÿŷ", "źżž", "‘’ʼ`´", "“”„", "‐‑‒–—"]
const _FOLD_TO := ["a", "c", "d", "e", "g", "h", "i", "j", "k", "l", "n", "o", "r", "s", "t", "u", "w", "y", "z", "'", "\"", "-"]
const _FOLD_MULTI := {"æ": "ae", "œ": "oe", "ß": "ss", "þ": "th"}
static var _fold_map := {}

## Lower case without diacritics ("Beyoncé" -> "beyonce", "Ærø" -> "aero").
## ASCII text skips the per-character pass.
static func fold(text: String) -> String:
	var lower := text.to_lower()
	if lower.to_utf8_buffer().size() == lower.length(): return lower
	if _fold_map.is_empty():
		for i in _FOLD_FROM.size():
			for ch in _FOLD_FROM[i]: _fold_map[ch] = _FOLD_TO[i]
		_fold_map.merge(_FOLD_MULTI)
	var out := ""
	for ch in lower: out += _fold_map.get(ch, ch)
	return out

# --- State line ------------------------------------------------------------------

## The library state box: {word, tone ("dim" | "busy" | "ok" | "error"), detail, hint}.
## `status` is the bus status published with the last library change.
static func state_info(state: String, status: String, updated: int, count: int) -> Dictionary:
	match state:
		"cached": return {"word": "CACHED", "tone": "dim", "detail": "%s tracks, saved %s. Refreshing in the background when Music allows it." % [_thousands(count), _when(updated)] if updated > 0 else "%s tracks from the last session." % _thousands(count), "hint": ""}
		"refreshing": return {"word": "REFRESHING", "tone": "busy", "detail": "Reading your Music library…", "hint": "macOS may ask for access to Media & Apple Music."}
		"ready": return {"word": "READY", "tone": "ok", "detail": status if status.begins_with("Music library") else "%s tracks." % _thousands(count), "hint": ""}
		"error": return {"word": "ERROR", "tone": "error", "detail": status if not status.is_empty() else "Couldn't read your Music library.", "hint": "" if "Privacy" in status else "Allow Oozic in System Settings › Privacy & Security › Media & Apple Music, then press REFRESH."}
	return {"word": "NOT LOADED", "tone": "dim", "detail": "Load your Music library to browse it here.", "hint": ""}

static func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out

static func _when(unix: int) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(unix + bias)
	var now := Time.get_datetime_dict_from_unix_time(int(Time.get_unix_time_from_system()) + bias)
	if d.year == now.year and d.month == now.month and d.day == now.day: return "today %02d:%02d" % [d.hour, d.minute]
	return "%d-%02d-%02d" % [d.year, d.month, d.day]
