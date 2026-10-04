extends RefCounted
## Synthetic Music library for tests and proof captures: made-up artists,
## albums and titles in the oozic-music-helper `library` JSON shape (see
## docs/MUSIC_HELPER.md). Deterministic for a given size. Never real data.
##   MusicBridge.build_library(LibraryFixture.helper_json(1430)) -> PlayerBus.library

const ADJECTIVES := ["Molten", "Slow", "Amber", "Velvet", "Liquid", "Neon", "Quiet", "Glass", "Hollow", "Golden", "Static", "Drifting", "Paper", "Midnight", "Copper", "Silver", "Electric", "Lunar", "Wax", "Thermal", "Crystal", "Faded", "Rising", "Tidal"]
const NOUNS := ["Lamp", "Bloom", "Current", "Orbit", "Signal", "Harbour", "Garden", "Engine", "Echo", "River", "Mirror", "Comet", "Lantern", "Canyon", "Meadow", "Circuit", "Tide", "Cathedral", "Avenue", "Satellite", "Ember", "Prism", "Valley", "Horizon"]
const FIRST := ["Lena", "Marco", "Ines", "Theo", "Noor", "Felix", "Ada", "Kai", "Rosa", "Otto", "Mira", "Jonas", "Elif", "Bram", "Zoë", "Rémi", "Björn", "Chloé", "Søren", "Aurélie"]
const LAST := ["Vance", "Okafor", "Lindqvist", "Moreau", "Tanaka", "Brennan", "Castillo", "Haddad", "Novak", "Ferreira", "Kowalski", "Duval", "Nakamura", "Whitlock", "Ångström", "Delacroix"]
const BANDS := ["The %s %ss", "%s %s", "%s & the %ss", "%s %s Orchestra", "%s %s Collective"]
const PLAYLISTS := ["Late Night Lava", "Focus — Deep Work", "Sunday Morning Coffee & Slow Records", "Road Trip 2026", "Favourites", "Ambient Drift", "Workout", "Best of the Thermal Years (Remastered Collection)", "Recently Added"]

## Helper JSON with `count` tracks (about 0.39 artists and 0.5 albums per
## track, 9 playlists, every 400th track a local file).
static func helper_json(count: int, seed := 7) -> String:
	return JSON.stringify(helper_data(count, seed))

static func helper_data(count: int, seed := 7) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var artist_count := maxi(int(count * 0.39), 1)
	var artists := []
	var seen := {}
	for i in artist_count:
		var artist_name := _artist_name(i, rng)
		if seen.has(artist_name): artist_name += " (%d)" % i
		seen[artist_name] = true
		artists.append(artist_name)
	var tracks := []
	var album := ""
	var album_artist := ""
	var track_no := 0
	var album_size := 0
	var album_index := 0
	for i in count:
		if track_no >= album_size:
			album_index += 1
			album_artist = artists[(album_index * 3) % artists.size()] if rng.randf() < 0.75 else artists[rng.randi_range(0, artists.size() - 1)]
			album = _album_name(album_index, rng)
			album_size = 1 if rng.randf() < 0.7 else rng.randi_range(2, 7)
			track_no = 0
		track_no += 1
		var local := i % 400 == 17
		var featured := rng.randf() < 0.08
		var artist: String = album_artist + (" feat. " + artists[rng.randi_range(0, artists.size() - 1)] if featured else "")
		var id := "%016X" % (0x5EED000000000000 + i * 7919)
		var title := _title(i, rng)
		tracks.append({"id": id, "title": title, "artist": artist, "album": album, "album_artist": album_artist if featured else "",
			"track_number": track_no, "disc_number": 1, "duration_ms": rng.randi_range(95, 620) * 1000, "genre": "Electronic",
			"location": "/Users/Shared/Oozic Fixture/%s/%02d %s.m4a" % [album, track_no, title] if local else null,
			"playable_file": local, "protected": false, "cloud_only": not local, "kind": "AAC audio file" if local else "Apple Music AAC audio file"})
	var playlists := []
	for p in PLAYLISTS.size():
		var ids := []
		var size := mini(count, [24, 60, 12, 85, 140, 33, 48, 210, 50][p])
		for k in size: ids.append(tracks[(p * 131 + k * 17) % count].id)
		playlists.append({"id": "%016X" % (0x71A7000000000000 + p), "name": PLAYLISTS[p], "track_ids": ids})
	return {"tracks": tracks, "playlists": playlists}

static func _artist_name(i: int, rng: RandomNumberGenerator) -> String:
	if i % 3 == 0: return "%s %s" % [FIRST[i % FIRST.size()], LAST[(i / FIRST.size()) % LAST.size()]] + ("" if i < FIRST.size() * LAST.size() else " %d" % (i / (FIRST.size() * LAST.size())))
	var pattern: String = BANDS[i % BANDS.size()]
	var a: String = ADJECTIVES[(i * 7) % ADJECTIVES.size()]
	var n: String = NOUNS[(i * 5 + i / ADJECTIVES.size()) % NOUNS.size()]
	var name := pattern % [a, n]
	if i >= ADJECTIVES.size() * 4: name += " " + ["II", "III", "IV", "Revival", "Unit", "Ensemble", "Project", "Sound System"][(i / 96) % 8] + ("" if i < 768 else " %d" % (i / 768))
	return name

static func _album_name(i: int, rng: RandomNumberGenerator) -> String:
	var a: String = ADJECTIVES[(i * 11) % ADJECTIVES.size()]
	var n: String = NOUNS[(i * 3 + i / 24) % NOUNS.size()]
	match i % 6:
		0: return "%s %s" % [a, n]
		1: return "The %s %s Sessions" % [a, n]
		2: return "%s %s (Deluxe Edition)" % [a, n]
		3: return "Songs from the %s %s, Volume %d" % [a, n, 1 + i % 4]
		4: return "%s" % n + "s"
	return "%s %s — Live at the %s %s %d" % [a, n, ADJECTIVES[(i * 5) % ADJECTIVES.size()], NOUNS[(i * 13) % NOUNS.size()], 1990 + i % 35]

static func _title(i: int, rng: RandomNumberGenerator) -> String:
	var a: String = ADJECTIVES[rng.randi_range(0, ADJECTIVES.size() - 1)]
	var n: String = NOUNS[rng.randi_range(0, NOUNS.size() - 1)]
	match i % 9:
		0: return "%s %s" % [a, n]
		1: return "%s" % n
		2: return "%s %s (Extended Mix)" % [a, n]
		3: return "In the %s %s" % [a, n]
		4: return "%s %s, Part %d" % [a, n, 1 + i % 3]
		5: return "Café %s" % n
		6: return "%s %s — Interlude" % [a, n]
		7: return "A Very Long Song Title About the %s %s and Everything It Remembers" % [a, n]
	return "%s %s %s" % [n, a, NOUNS[(i * 3) % NOUNS.size()]]
