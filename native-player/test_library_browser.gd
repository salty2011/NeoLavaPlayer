extends SceneTree
## Music library browser (player/library_model.gd, player/player_library_panel.gd)
## on a SYNTHETIC library (library_fixture.gd; never the user's Music library):
## views and counts, search (case/diacritics), sorting, drill-in and back,
## multi-select, every action's bus commands and ids, context menu, state box,
## empty/refreshing/error states, virtualised rows on 20k tracks, resize,
## persistence of open state/size/view, and the Settings window scale.
##   Godot --headless --audio-driver Dummy --path native-player --script res://test_library_browser.gd
const Main = preload("res://main.gd")
const Fmt = preload("res://player/player_format.gd")
const LibraryModel = preload("res://player/library_model.gd")
const LibraryFixture = preload("res://library_fixture.gd")
const MusicBridge = preload("res://music_bridge.gd")

func _initialize(): call_deferred("run")

func key(code: Key, shift := false, meta := false) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	e.shift_pressed = shift
	e.meta_pressed = meta
	return e

func click(list, row: int, shift := false, meta := false, double := false, button := MOUSE_BUTTON_LEFT):
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = true
	e.shift_pressed = shift
	e.meta_pressed = meta
	e.double_click = double
	e.position = Vector2(30, (row + 0.5) * list.ROW_HEIGHT - list.scroll)
	list._gui_input(e)

## Tiny hand-made library with known order, numbers, diacritics and a local file.
func small_library() -> Dictionary:
	var t := func(id, title, artist, album, disc, number, seconds, local := false, album_artist := ""):
		return {"id": id, "title": title, "artist": artist, "album": album, "album_artist": album_artist, "disc_number": disc, "track_number": number,
			"duration_ms": seconds * 1000, "location": "/Users/Shared/Fixture/%s.m4a" % title if local else null, "playable_file": local, "cloud_only": not local}
	var data := {"tracks": [
		t.call("A1", "Zebra Crossing", "Émile Fauré", "Night Shapes", 1, 2, 200),
		t.call("A2", "apple Orchard", "Émile Fauré", "Night Shapes", 1, 1, 100),
		t.call("A3", "Middle", "Émile Fauré", "Night Shapes", 2, 1, 300),
		t.call("B1", "Café Lights", "Björk Lund", "Harbour", 1, 1, 150, true),
		t.call("B2", "Bravo", "Björk Lund", "", 0, 0, 50),
		t.call("C1", "Guest Spot", "Ola feat. Émile Fauré", "Night Shapes", 1, 3, 250, false, "Émile Fauré"),
	], "playlists": [
		{"id": "P1", "name": "Evening", "track_ids": ["B1", "A1"]},
		{"id": "P2", "name": "Empty one", "track_ids": []},
	]}
	return MusicBridge.build_library(JSON.stringify(data))

func run():
	var t0 := Time.get_ticks_msec()
	# --- Model: folding, counts, views -------------------------------------
	assert(LibraryModel.fold("Beyoncé ÆRØ Straße") == "beyonce aero strasse" and LibraryModel.fold("plain") == "plain")
	var m := LibraryModel.new()
	m.set_library(small_library())
	assert(m.counts() == {"songs": 6, "artists": 3, "albums": 2, "playlists": 2})
	assert(m.rows == ["A1", "A2", "A3", "B1", "B2", "C1"] and m.row_kind() == "track")
	# Search: case and diacritic-insensitive, every word, title/artist/album.
	m.set_query("emile")
	assert(m.rows == ["A1", "A2", "A3", "C1"])
	m.set_query("CAFE")
	assert(m.rows == ["B1"])
	m.set_query("faure night zebra")
	assert(m.rows == ["A1"])
	m.set_query("harbour")
	assert(m.rows == ["B1"])
	m.set_query("")
	# Sorting: header click ascending, descending, then natural order.
	m.toggle_sort("title")
	assert(m.rows == ["A2", "B2", "B1", "C1", "A3", "A1"], str(m.rows))
	m.toggle_sort("title")
	assert(m.rows == ["A1", "A3", "C1", "B1", "B2", "A2"])
	m.toggle_sort("title")
	assert(m.sort_key == "" and m.rows == ["A1", "A2", "A3", "B1", "B2", "C1"])
	m.toggle_sort("time")
	assert(m.rows == ["B2", "A2", "B1", "A1", "C1", "A3"])
	m.toggle_sort("artist")
	assert(m.rows.slice(0, 2) == ["B2", "B1"] and m.rows[-1] == "C1", str(m.rows)) # Björk < Émile < Ola (folded)
	m.set_query("café")
	assert(m.rows == ["B1"]) # search keeps the sort
	# Artists -> tracks (album, disc, track order); back restores the query and selects the artist.
	m.set_source("artists")
	assert(m.row_kind() == "artist" and m.rows == ["Björk Lund", "Émile Fauré", "Ola feat. Émile Fauré"] and m.query == "")
	m.set_query("emile")
	assert(m.rows == ["Émile Fauré", "Ola feat. Émile Fauré"])
	m.open_group("Émile Fauré")
	assert(m.row_kind() == "track" and m.query == "" and m.rows == ["A2", "A1", "A3"])
	assert(m.back() and m.query == "emile" and m.rows_hint == 0 and not m.back())
	# Albums: album artist groups the guest track; drill-in in disc/track order with a # column.
	m.set_source("albums")
	assert(m.rows == ["Björk Lund — Harbour", "Émile Fauré — Night Shapes"])
	assert(m.cell("Émile Fauré — Night Shapes", "name") == "Night Shapes" and m.cell("Émile Fauré — Night Shapes", "artist") == "Émile Fauré" and m.cell("Émile Fauré — Night Shapes", "tracks") == "4")
	m.toggle_sort("tracks")
	m.toggle_sort("tracks")
	assert(m.rows[0] == "Émile Fauré — Night Shapes")
	m.open_group("Émile Fauré — Night Shapes")
	assert(m.rows == ["A2", "A1", "C1", "A3"] and m.columns()[0].id == "track" and m.cell("A1", "track") == "2" and m.cell("A1", "time") == "3:20")
	assert(m.album_key_of("C1") == "Émile Fauré — Night Shapes" and m.album_key_of("B2") == "")
	# Playlists: library order, drill-in in playlist order.
	m.set_source("playlists")
	assert(m.rows == ["P1", "P2"] and m.cell("P1", "name") == "Evening" and m.cell("P2", "tracks") == "0")
	m.open_group("P1")
	assert(m.rows == ["B1", "A1"] and m.is_streaming("A1") and not m.is_streaming("B1"))
	# Commands: replace = clear_playlist then add+play; add = append; enqueue = append+play.
	m.set_source("songs")
	assert(m.commands("play", ["A1", "B1"]) == [[&"clear_playlist", {}], [&"add_library_tracks", {"ids": ["A1", "B1"], "play": true}]])
	assert(m.commands("add", ["A1"]) == [[&"add_library_tracks", {"ids": ["A1"], "play": false}]])
	assert(m.commands("enqueue", ["B2"]) == [[&"add_library_tracks", {"ids": ["B2"], "play": true}]])
	assert(m.commands("play", []) == [])
	m.set_source("albums")
	assert(m.commands("add", ["Björk Lund — Harbour", "Émile Fauré — Night Shapes"]) == [[&"add_library_tracks", {"ids": ["B1", "A2", "A1", "C1", "A3"], "play": false}]])
	m.set_source("playlists")
	assert(m.commands("play", ["P1", "P2"]) == [[&"clear_playlist", {}], [&"add_library_playlist", {"id": "P1", "play": true}], [&"add_library_playlist", {"id": "P2", "play": false}]])
	m.open_group("P1")
	assert(m.group_commands("add") == [[&"add_library_playlist", {"id": "P1", "play": false}]])
	m.set_source("artists")
	m.open_group("Björk Lund")
	assert(m.group_commands("play") == [[&"clear_playlist", {}], [&"add_library_tracks", {"ids": ["B2", "B1"], "play": true}]], str(m.group_commands("play")))
	# View state round trip; a group that no longer exists falls back to the list.
	var state := m.view_state()
	var m2 := LibraryModel.new()
	m2.set_library(small_library())
	m2.apply_view_state(state)
	assert(m2.source == "artists" and m2.group == "Björk Lund" and m2.rows == ["B2", "B1"])
	m2.apply_view_state({"source": "albums", "group": "Nobody — Nothing", "sort_key": "bogus"})
	assert(m2.group == "" and m2.sort_key == "" and m2.row_kind() == "album")
	# State box texts.
	assert(LibraryModel.state_info("empty", "", 0, 0).word == "NOT LOADED")
	assert(LibraryModel.state_info("refreshing", "", 0, 0).hint.contains("Media & Apple Music"))
	assert(LibraryModel.state_info("ready", "Music library: 1430 tracks, 9 playlists.", 0, 1430).detail == "Music library: 1430 tracks, 9 playlists.")
	assert(LibraryModel.state_info("cached", "", 0, 1430).detail.contains("1,430"))
	var err := LibraryModel.state_info("error", "Couldn't read your Music library.", 0, 0)
	assert(err.tone == "error" and err.hint.contains("Privacy & Security › Media & Apple Music"))
	assert(LibraryModel.state_info("error", "Couldn't read your Music library. Allow Oozic under System Settings › Privacy & Security › Media & Apple Music.", 0, 0).hint == "")

	# --- 20k tracks: build, search, sort fast; only visible rows drawn -------
	var big_text := LibraryFixture.helper_json(20000)
	var tb := Time.get_ticks_usec()
	var big_lib := MusicBridge.build_library(big_text)
	var big := LibraryModel.new()
	big.set_library(big_lib)
	var build_ms := (Time.get_ticks_usec() - tb) / 1000.0
	tb = Time.get_ticks_usec()
	big.set_query("molten lamp")
	var search_ms := (Time.get_ticks_usec() - tb) / 1000.0
	assert(not big.rows.is_empty() and big.rows.size() < 20000)
	big.set_query("")
	tb = Time.get_ticks_usec()
	big.toggle_sort("title")
	var sort_ms := (Time.get_ticks_usec() - tb) / 1000.0
	tb = Time.get_ticks_usec()
	big.toggle_sort("title")
	big.set_query("café")
	var resort_ms := (Time.get_ticks_usec() - tb) / 1000.0
	assert(big.rows.size() > 100 and search_ms < 250.0 and resort_ms < 250.0, "20k search %.1f ms, re-sort+search %.1f ms" % [search_ms, resort_ms])
	print("LIBRARY_PERF tracks=20000 build+index=%.0fms search=%.1fms first_sort=%.0fms cached_sort+search=%.1fms" % [build_ms, search_ms, sort_ms, resort_ms])

	# --- The panel inside the app ------------------------------------------------
	var app = Main.new()
	app.persist_override = false
	root.add_child(app)
	await process_frame
	var bus = app.bus
	var audio = app.audio
	audio.music_bridge.helper_override = ProjectSettings.globalize_path("res://tools/fake_music_helper.sh")
	audio.music_bridge._refreshed = true # no background refresh racing the fixture
	var w = app.controller
	var lib = w.library_panel
	var list = lib.list
	assert(not w.library_open and not lib.visible)
	# Empty first run: the browser offers to load the library (library_refresh).
	bus.publish_library({}, "empty")
	bus.command(&"close_library")
	var saved_connections: Array = bus.command_requested.get_connections()
	var log: Array = []
	var recorder := func(name, args): log.append([name, args])
	bus.command_requested.connect(recorder)
	# LIB sends toggle_library; the window opens and asks MusicBridge (open_library).
	w.main_panel.buttons.library.click()
	var names := log.map(func(entry): return entry[0])
	assert(names.size() == 2 and names.has(&"toggle_library") and names.has(&"open_library"), str(log))
	assert(w.library_open and lib.visible and bus.library_open and w.main_panel.buttons.library.active)
	await process_frame
	assert(lib.load_button.visible and lib.load_button.label == "LOAD MUSIC LIBRARY" and lib.state_info().word == "NOT LOADED" and not lib.header.visible)
	for c in saved_connections: bus.command_requested.disconnect(c.callable)
	log.clear()
	lib.load_button.click()
	assert(log.size() == 1 and log[0][0] == &"library_refresh")
	bus.publish_library({}, "refreshing")
	assert(not lib.load_button.visible and lib.state_info().word == "REFRESHING" and lib.empty_message()[0].begins_with("Reading"))
	bus.publish_library({}, "error")
	bus.publish_status("Couldn't read your Music library. Allow Oozic under System Settings › Privacy & Security › Media & Apple Music.")
	await process_frame
	assert(lib.load_button.visible and lib.load_button.label == "TRY AGAIN" and lib.state_info().tone == "error" and lib.state_info().detail.contains("Privacy"))
	# Fixture library (1,430 tracks like a real one) arrives.
	var fixture := MusicBridge.build_library(LibraryFixture.helper_json(1430))
	bus.publish_library(fixture, "ready")
	bus.publish_status("Music library: %d tracks, %d playlists." % [fixture.count, fixture.playlists.size()])
	await process_frame
	assert(not lib.load_button.visible and lib.header.visible and lib.state_info().word == "READY" and lib.library_status.begins_with("Music library: 1430"))
	var counts: Dictionary = lib.model.counts()
	assert(counts.songs == 1430 and counts.playlists == 9 and counts.artists > 300 and counts.albums > 400, str(counts))
	assert(lib.crumb_text() == "SONGS  ·  1,430 songs")
	# Hit areas: inside the panel, no overlaps, at least 9 units.
	var controls: Array = lib.interactive_controls()
	var bounds := Rect2(Vector2.ZERO, lib.size)
	for i in controls.size():
		var a := Rect2(controls[i].position, controls[i].size)
		assert(bounds.encloses(a), "%s inside the library" % controls[i].name)
		assert(a.size.x >= 9.0 and a.size.y >= 9.0, "%s at least 9x9 units" % controls[i].name)
		for j in range(i + 1, controls.size()):
			assert(not a.intersects(Rect2(controls[j].position, controls[j].size)), "%s overlaps %s" % [controls[i].name, controls[j].name])
	# Virtualised: only the visible rows are drawn.
	# (_draw walks exactly visible_range(); headless runs never draw, the
	# windowed capture tool does and reports drawn_rows.)
	var visible_rows: int = int(ceil(list.size.y / list.ROW_HEIGHT)) + 1
	var drawn: Vector2i = list.visible_range()
	assert(drawn.x == 0 and drawn.y - drawn.x + 1 > 5 and drawn.y - drawn.x + 1 <= visible_rows, "draws %s of 1430 rows (view %d)" % [drawn, visible_rows])
	list.set_scroll(700 * list.ROW_HEIGHT)
	assert(list.visible_range().x == 700 and list.visible_range().y - list.visible_range().x < visible_rows)
	list.set_scroll(0)
	# Header click sorts; second click reverses.
	var title_col: Dictionary = lib.column_layout(list.size.x).filter(func(c): return c.id == "title")[0]
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = Vector2(title_col.x + 2, 4)
	lib.header._gui_input(e)
	assert(lib.model.sort_key == "title" and not lib.model.sort_desc)
	var first_title: String = lib.model.cell(lib.model.rows[0], "title")
	assert(LibraryModel.fold(first_title) <= LibraryModel.fold(lib.model.cell(lib.model.rows[1], "title")))
	lib.header._gui_input(e)
	assert(lib.model.sort_desc and LibraryModel.fold(lib.model.cell(lib.model.rows[0], "title")) >= LibraryModel.fold(first_title))
	lib.header._gui_input(e)
	assert(lib.model.sort_key == "")
	# Multi-select: click, Cmd-click, Shift-click, Shift+Down, Cmd+A, Escape.
	var rows: Array = lib.model.rows
	click(list, 2)
	assert(list.selected_keys() == [rows[2]] and lib.buttons.play.enabled)
	click(list, 5, false, true)
	assert(list.selected_keys() == [rows[2], rows[5]])
	click(list, 2, false, true)
	assert(list.selected_keys() == [rows[5]])
	click(list, 1)
	click(list, 4, true)
	assert(list.selected_keys() == rows.slice(1, 5))
	list._gui_input(key(KEY_DOWN, true))
	assert(list.selected_keys() == rows.slice(1, 6) and list.cursor == 5)
	list._gui_input(key(KEY_A, false, true))
	assert(list.selected_keys().size() == 1430 and lib.info_text().begins_with("1430 selected"))
	list._gui_input(key(KEY_ESCAPE))
	assert(list.selected_keys().is_empty() and not lib.buttons.play.enabled and lib.info_text().begins_with("1,430 songs"))
	# Actions dispatch the right commands with the right ids.
	click(list, 0)
	click(list, 2, true)
	log.clear()
	lib.buttons.play.click()
	assert(log == [[&"clear_playlist", {}], [&"add_library_tracks", {"ids": rows.slice(0, 3), "play": true}]], str(log))
	log.clear()
	lib.buttons.add.click()
	assert(log == [[&"add_library_tracks", {"ids": rows.slice(0, 3), "play": false}]])
	log.clear()
	list._gui_input(key(KEY_ENTER))
	assert(log == [[&"add_library_tracks", {"ids": rows.slice(0, 3), "play": true}]])
	log.clear()
	click(list, 7, false, false, true)
	assert(log == [[&"add_library_tracks", {"ids": [rows[7]], "play": true}]] and list.selected_keys() == [rows[7]])
	# Player hotkeys stay out of the focused list (Enter, arrows, Cmd+A).
	list.grab_focus()
	log.clear()
	w._input(key(KEY_DOWN))
	w._input(key(KEY_A, false, true))
	w._input(key(KEY_SPACE))
	assert(log.size() == 1 and log[0][0] == &"play_pause", str(log))
	# Context menu on a track: play/add, its album and artist.
	click(list, 3, false, false, false, MOUSE_BUTTON_RIGHT)
	var labels: PackedStringArray = lib.menu_labels()
	assert(labels[0] == "Play song" and labels[1] == "Add song to playlist" and labels[2] == "Add and play", str(labels))
	var track_id: String = rows[3]
	var album_key: String = lib.model.album_key_of(track_id)
	assert(labels.has("Show album") and labels.has("Show artist"))
	var album_label := ""
	for l in labels:
		if l.begins_with("Add album"): album_label = l
	log.clear()
	assert(lib.menu_run(album_label))
	assert(log == [[&"add_library_tracks", {"ids": lib.model.group_track_ids("albums", album_key), "play": false}]], str(log))
	assert(lib.menu_run("Show album") and lib.model.source == "albums" and lib.model.group == album_key)
	# Inside an album: PLAY ALL / ADD ALL and the back button.
	assert(lib.buttons.play_all.visible and lib.buttons.back.visible and lib.crumb_text().begins_with(lib.model.group_label("album", album_key)))
	var album_ids: Array = lib.model.group_track_ids("albums", album_key)
	assert(lib.model.rows == album_ids)
	log.clear()
	lib.buttons.play_all.click()
	assert(log == [[&"clear_playlist", {}], [&"add_library_tracks", {"ids": album_ids, "play": true}]])
	log.clear()
	lib.buttons.add_all.click()
	assert(log == [[&"add_library_tracks", {"ids": album_ids, "play": false}]])
	lib.buttons.back.click()
	assert(lib.model.group == "" and lib.model.row_kind() == "album" and list.selected_keys() == [album_key])
	# Sources: Albums list -> Enter opens; Playlists use add_library_playlist.
	lib.sources._gui_input(_press(Vector2(10, 3.5 * lib.SOURCE_ROW)))
	assert(lib.model.source == "playlists" and lib.model.rows.size() == 9 and lib.crumb_text() == "PLAYLISTS  ·  9 playlists")
	click(list, 1)
	click(list, 3, false, true)
	log.clear()
	lib.buttons.play.click()
	var pids: Array = lib.model.rows
	assert(log == [[&"clear_playlist", {}], [&"add_library_playlist", {"id": pids[1], "play": true}], [&"add_library_playlist", {"id": pids[3], "play": false}]], str(log))
	click(list, 0, false, false, false, MOUSE_BUTTON_RIGHT)
	assert(lib.menu_labels() == PackedStringArray(["Play playlist", "Add playlist to playlist", "Open playlist"]), str(lib.menu_labels()))
	list._gui_input(key(KEY_ENTER))
	assert(lib.model.group == pids[0] and lib.buttons.add_all.visible)
	log.clear()
	lib.buttons.add_all.click()
	assert(log == [[&"add_library_playlist", {"id": pids[0], "play": false}]])
	list._gui_input(key(KEY_LEFT))
	assert(lib.model.group == "")
	# Search field filters the current view (diacritics folded); Escape clears.
	lib.sources._gui_input(_press(Vector2(10, 0.5 * lib.SOURCE_ROW)))
	lib.search.text = "CAFE"
	lib.search.text_changed.emit("CAFE")
	assert(lib.model.rows.size() > 10 and lib.model.rows.size() < 1430 and lib.crumb_text().contains(" of 1,430"))
	for id in lib.model.rows: assert(LibraryModel.fold(lib.model.cell(id, "title") + lib.model.cell(id, "artist") + lib.model.cell(id, "album")).contains("cafe"))
	lib.search.gui_input.emit(key(KEY_ESCAPE))
	assert(lib.search.text == "" and lib.model.rows.size() == 1430)
	# Streaming vs local badge data: the fixture has a few local files.
	var local := 0
	for id in lib.model.rows:
		if not lib.model.is_streaming(id): local += 1
	assert(local == 4 and list._get_tooltip(Vector2(5, 4)).begins_with("Apple Music"))
	# Resize: corner grip changes width and height in base units, clamped.
	w.set_library_size(380, 290)
	w._on_library_resize(Vector2.ZERO, Vector2.ONE, true)
	w._on_library_resize(Vector2(80, 40), Vector2.ONE, false)
	assert(is_equal_approx(w.library_width, 420.0) and is_equal_approx(w.library_height, lib.size.y) and lib.size.x == 420.0)
	w._on_library_resize(Vector2(-4000, 0), Vector2(1, 0), false)
	assert(w.library_width == Fmt.LIBRARY_MIN_WIDTH and lib.size.x == Fmt.LIBRARY_MIN_WIDTH)
	await process_frame
	# Narrow: the album column goes; nothing overlaps.
	assert(lib.column_layout(lib.list.size.x).filter(func(c): return c.id == "album").is_empty())
	for c in lib.column_layout(lib.list.size.x): assert(c.x + c.w <= lib.list.size.x + 0.01)
	# Playlist closed: the library keeps its own height, a filler fills the column.
	w.set_playlist_open(false)
	w.set_library_size(380, 290)
	assert(w.filler.visible and w.size == Fmt.window_pixels(Vector2(275 + 380, 290), w.ui_scale) and w.filler.size.y == 290 - 116)
	w.set_playlist_open(true)
	w.set_playlist_height(300)
	assert(not w.filler.visible and lib.size.y == 416.0)
	# Persistence: open state, size and view in [windows].
	lib.set_source("albums")
	lib.open_group(lib.model.rows[3])
	var layout: Dictionary = w.layout_state()
	assert(layout.library_open and layout.library_width == 380.0 and layout.library_view.source == "albums" and layout.library_view.group == lib.model.group)
	var group_key: String = lib.model.group
	lib.set_source("songs")
	w.set_library_open(false)
	w.apply_layout_state(layout)
	assert(w.library_open and lib.visible and lib.model.source == "albums" and lib.model.group == group_key)
	# Through the real AudioService (handlers back): ADD appends applemusic: entries.
	bus.command_requested.disconnect(recorder)
	for c in saved_connections: bus.command_requested.connect(c.callable)
	audio.clear_playlist()
	lib.set_source("songs")
	click(list, 0)
	click(list, 1, true)
	lib.buttons.add.click()
	assert(audio.playlist.size() == 2 and audio.playlist[0] == fixture.tracks[rows[0]].entry and not audio.is_playing(), str(audio.playlist))
	audio.clear_playlist()

	# --- Settings window follows the player size (headless screen scale 1) ---
	for pair in [[1.0, 0.75], [2.0, 1.0], [3.0, 1.25]]:
		w.set_user_size(pair[0], false)
		w.open_settings()
		var s = w.settings_window
		assert(is_equal_approx(s.ui_scale, pair[1]) and is_equal_approx(s.content_scale_factor, pair[1]), "settings scale at %sx" % pair[0])
		await process_frame
		var needed: Vector2 = s.get_contents_minimum_size()
		assert(s.size.x >= int(s.BASE_MIN.x * pair[1]) and Vector2(s.size) / pair[1] >= needed - Vector2(1, 1), "settings content fits at %sx: %s / %s >= %s" % [pair[0], s.size, pair[1], needed])
		s.hide()
	w.set_user_size(2.0, false)

	app.queue_free()
	await create_timer(0.3).timeout
	print("PASS: library browser model (fold, counts, search case/diacritics, sort asc/desc/natural, artists/albums/playlists drill-in + back, commands play/add/enqueue, playlist commands, view state, state box), 20k tracks (search %.1f ms, cached re-sort+search %.1f ms), panel: LIB toggle + open_library, empty/refreshing/error states + LOAD/TRY AGAIN, 1,430-track fixture counts, hit areas, virtualised rows (%d of 1430 drawn), header sort, multi-select click/Cmd/Shift/Shift+Down/Cmd+A/Esc, PLAY/ADD/Enter/double-click/PLAY ALL/ADD ALL/context menu commands + ids, hotkeys kept out of the list, sources + Enter + Left, search + Esc, streaming/local badges, grip resize + clamp, narrow columns, filler, persistence, real AudioService add, Settings scale 0.75/1/1.25 fits (%d ms)" % [search_ms, resort_ms, drawn.y - drawn.x + 1, Time.get_ticks_msec() - t0])
	quit()

func _press(position: Vector2) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = position
	return e
