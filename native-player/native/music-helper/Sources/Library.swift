// `library` subcommand: dump the Music library via iTunesLibrary.framework.
import Foundation
import iTunesLibrary

private let playableExtensions: Set<String> = ["mp3", "m4a", "aac", "aiff", "aif", "wav", "flac", "alac"]

/// Distinguished playlists that are just media-type views of the whole
/// library (they duplicate the master list and would bloat the output).
private let skippedDistinguished: Set<ITLibDistinguishedPlaylistKind> = [
    .kindMovies, .kindTVShows, .kindMusic, .kindAudiobooks, .kindRingtones,
    .kindPodcasts, .kindVoiceMemos, .kindiTunesU, .kindHomeVideos,
    .kindApplications, .kindMusicShowsAndMovies, .kindLibraryMusicVideos,
    .kindMusicVideos,
]

/// Media kinds exported as tracks. Movies/TV/podcasts/books are excluded.
private let includedMediaKinds: Set<ITLibMediaItemMediaKind> = [
    .kindSong, .kindMusicVideo, .kindUnknown,
]

func runLibrary(args: [String]) -> Int32 {
    let stats = args.contains("--stats")
    let t0 = Date()

    let lib: ITLibrary
    do {
        lib = try ITLibrary(apiVersion: "1.0")
    } catch {
        let ns = error as NSError
        IO.stderrLine("oozic-music-helper: cannot open the Music library (\(ns.domain) \(ns.code): \(ns.localizedDescription)). "
            + "If access was denied, enable this app under System Settings > Privacy & Security > Media & Apple Music.")
        return ExitCode.libraryUnavailable
    }
    let tOpen = Date()

    let items = lib.allMediaItems
    var w = JSONWriter(capacity: max(4096, items.count * 420))
    var included = Set<UInt64>()
    included.reserveCapacity(items.count)

    var nPlayable = 0, nProtected = 0, nCloudOnly = 0, nLocation = 0

    w.raw("{\"tracks\":[")
    var first = true
    for item in items {
        guard includedMediaKinds.contains(item.mediaKind) else { continue }
        let pid = item.persistentID.uint64Value
        included.insert(pid)

        var path: String? = nil
        if item.locationType == .file, let url = item.location, url.isFileURL {
            path = url.path
        }
        let protected = item.isDRMProtected
        let ext = path.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        let playable = path != nil && !protected && playableExtensions.contains(ext)
        let cloudOnly = item.isCloud && path == nil

        if playable { nPlayable += 1 }
        if protected { nProtected += 1 }
        if cloudOnly { nCloudOnly += 1 }
        if path != nil { nLocation += 1 }

        if !first { w.raw(",") }
        first = false
        w.raw("{\"id\":"); w.string(persistentIDHex(pid))
        w.raw(",\"title\":"); w.string(item.title)
        w.raw(",\"artist\":"); w.string(item.artist?.name ?? "")
        w.raw(",\"album\":"); w.string(item.album.title ?? "")
        w.raw(",\"album_artist\":"); w.string(item.album.albumArtist ?? "")
        w.raw(",\"track_number\":"); w.int(item.trackNumber)
        w.raw(",\"disc_number\":"); w.int(item.album.discNumber)
        w.raw(",\"duration_ms\":"); w.int(item.totalTime)
        w.raw(",\"genre\":"); w.string(item.genre)
        w.raw(",\"location\":"); w.stringOrNull(path)
        w.raw(",\"playable_file\":"); w.bool(playable)
        w.raw(",\"protected\":"); w.bool(protected)
        w.raw(",\"cloud_only\":"); w.bool(cloudOnly)
        w.raw(",\"kind\":"); w.string(item.kind ?? "")
        w.raw("}")
    }
    w.raw("],\"playlists\":[")

    var nPlaylists = 0
    first = true
    for pl in lib.allPlaylists {
        if pl.isMaster || !pl.isVisible { continue }
        if skippedDistinguished.contains(pl.distinguishedKind) { continue }
        nPlaylists += 1
        if !first { w.raw(",") }
        first = false
        w.raw("{\"id\":"); w.string(persistentIDHex(pl.persistentID.uint64Value))
        w.raw(",\"name\":"); w.string(pl.name)
        w.raw(",\"track_ids\":[")
        var firstID = true
        for it in pl.items {
            let pid = it.persistentID.uint64Value
            guard included.contains(pid) else { continue }
            if !firstID { w.raw(",") }
            firstID = false
            w.string(persistentIDHex(pid))
        }
        w.raw("]}")
    }
    w.raw("]}\n")

    let tBuild = Date()
    guard IO.writeAll(1, w.buf) else { return ExitCode.ok } // parent closed the pipe
    let tDone = Date()

    if stats {
        func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }
        IO.stderrLine("{\"tracks\":\(included.count),\"items_total\":\(items.count),\"playlists\":\(nPlaylists),"
            + "\"with_location\":\(nLocation),\"playable_file\":\(nPlayable),\"protected\":\(nProtected),\"cloud_only\":\(nCloudOnly),"
            + "\"bytes\":\(w.buf.count),\"open_ms\":\(ms(t0, tOpen)),\"build_ms\":\(ms(tOpen, tBuild)),\"write_ms\":\(ms(tBuild, tDone)),\"total_ms\":\(ms(t0, tDone))}")
    }
    return ExitCode.ok
}
