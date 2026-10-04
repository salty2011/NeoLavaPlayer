// `now`, `watch` and `control` subcommands: talk to the Music app with
// Apple Events (NSAppleScript). Never launches Music for `now`/`watch`.
import AppKit
import Foundation

let musicBundleID = "com.apple.Music"

/// errAEEventNotPermitted: the user denied (or has not yet granted)
/// Automation permission for the responsible app to control Music.
private let errAEEventNotPermitted = -1743
private let errAEEventWouldRequireUserConsent = -1744

func musicIsRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).isEmpty
}

struct ScriptFailure: Error {
    let number: Int
    let message: String
    var isPermission: Bool { number == errAEEventNotPermitted || number == errAEEventWouldRequireUserConsent }
}

final class CompiledScript {
    private let script: NSAppleScript
    init(_ source: String) throws {
        guard let s = NSAppleScript(source: source) else {
            throw ScriptFailure(number: -1, message: "could not create script")
        }
        var err: NSDictionary?
        if !s.compileAndReturnError(&err) {
            throw ScriptFailure(number: (err?[NSAppleScript.errorNumber] as? Int) ?? -1,
                                message: (err?[NSAppleScript.errorMessage] as? String) ?? "compile failed")
        }
        script = s
    }

    func run() throws -> NSAppleEventDescriptor {
        var err: NSDictionary?
        let r = script.executeAndReturnError(&err)
        if let err = err {
            throw ScriptFailure(number: (err[NSAppleScript.errorNumber] as? Int) ?? -1,
                                message: (err[NSAppleScript.errorMessage] as? String) ?? "script error")
        }
        return r
    }
}

// MARK: - now / watch

// The `is running` guard means a Music quit between our NSRunningApplication
// check and execution cannot relaunch it.
private let nowScriptSource = """
if application id "com.apple.Music" is not running then return {"notrunning"}
tell application id "com.apple.Music"
    set st to "stopped"
    set ps to player state
    if ps is playing or ps is fast forwarding or ps is rewinding then
        set st to "playing"
    else if ps is paused then
        set st to "paused"
    end if
    set vol to sound volume
    set pos to 0
    try
        set pos to player position
        if pos is missing value then set pos to 0
    end try
    set tid to ""
    set tt to ""
    set ar to ""
    set al to ""
    set du to 0
    try
        set ct to current track
        set tid to persistent ID of ct
        set tt to name of ct
        set ar to artist of ct
        set al to album of ct
        set du to duration of ct
        if du is missing value then set du to 0
    end try
    try
        if tt is "" then
            set cs to current stream title
            if cs is not missing value then set tt to cs
        end if
    end try
    return {st, vol, pos, tid, tt, ar, al, du}
end tell
"""

private func descString(_ d: NSAppleEventDescriptor?) -> String {
    guard let d = d else { return "" }
    if d.descriptorType == typeType && d.typeCodeValue == 0x6D736E67 { return "" } // 'msng'
    return d.stringValue ?? ""
}

private func descDouble(_ d: NSAppleEventDescriptor?) -> Double {
    guard let d = d else { return 0 }
    if let c = d.coerce(toDescriptorType: typeIEEE64BitFloatingPoint) { return c.doubleValue }
    return Double(d.stringValue ?? "") ?? 0
}

final class NowReader {
    private var compiled: CompiledScript?

    /// Returns (json line, exit code if this should terminate the caller).
    func read() -> (String, Int32?) {
        var w = JSONWriter()
        if !musicIsRunning() {
            w.raw("{\"running\":false,\"state\":\"stopped\",\"id\":\"\",\"title\":\"\",\"artist\":\"\",\"album\":\"\",\"position\":0,\"duration\":0,\"volume\":0}")
            return (w.text, nil)
        }
        do {
            if compiled == nil { compiled = try CompiledScript(nowScriptSource) }
            let r = try compiled!.run()
            if r.numberOfItems < 8 {
                // "notrunning" sentinel (quit between checks)
                w.raw("{\"running\":false,\"state\":\"stopped\",\"id\":\"\",\"title\":\"\",\"artist\":\"\",\"album\":\"\",\"position\":0,\"duration\":0,\"volume\":0}")
                return (w.text, nil)
            }
            // NSAppleEventDescriptor lists are 1-based.
            let state = descString(r.atIndex(1))
            let vol = Int(descDouble(r.atIndex(2)).rounded())
            let pos = descDouble(r.atIndex(3))
            let id = descString(r.atIndex(4))
            let title = descString(r.atIndex(5))
            let artist = descString(r.atIndex(6))
            let album = descString(r.atIndex(7))
            let dur = descDouble(r.atIndex(8))
            w.raw("{\"running\":true,\"state\":"); w.string(state.isEmpty ? "stopped" : state)
            w.raw(",\"id\":"); w.string(id)
            w.raw(",\"title\":"); w.string(title)
            w.raw(",\"artist\":"); w.string(artist)
            w.raw(",\"album\":"); w.string(album)
            w.raw(",\"position\":"); w.double(pos)
            w.raw(",\"duration\":"); w.double(dur)
            w.raw(",\"volume\":"); w.int(max(0, min(100, vol)))
            w.raw("}")
            return (w.text, nil)
        } catch let f as ScriptFailure {
            w.raw("{\"running\":true,\"state\":\"stopped\",\"id\":\"\",\"title\":\"\",\"artist\":\"\",\"album\":\"\",\"position\":0,\"duration\":0,\"volume\":0,\"error\":")
            w.string(f.isPermission ? "automation_denied" : "script_error")
            w.raw(",\"message\":"); w.string("\(f.number): \(f.message)")
            w.raw("}")
            if f.isPermission {
                IO.stderrLine("oozic-music-helper: not allowed to control Music (Apple Events error \(f.number)). "
                    + "Enable it under System Settings > Privacy & Security > Automation.")
                return (w.text, ExitCode.permissionDenied)
            }
            compiled = nil
            return (w.text, nil)
        } catch {
            return ("{\"running\":true,\"error\":\"script_error\"}", nil)
        }
    }
}

func runNow() -> Int32 {
    let (line, code) = NowReader().read()
    IO.stdoutLine(line)
    return code ?? ExitCode.ok
}

func runWatch(args: [String]) -> Int32 {
    var interval = 0.5
    if let i = args.firstIndex(of: "--interval"), i + 1 < args.count, let v = Double(args[i + 1]) {
        interval = max(0.05, v)
    }
    installSignalHandlers {}
    let reader = NowReader()
    let tick = {
        exitIfOrphaned()
        let (line, code) = reader.read()
        if !IO.stdoutLine(line) { exit(ExitCode.ok) } // parent closed pipe
        if let c = code { exit(c) }
    }
    tick()
    let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
    RunLoop.main.add(timer, forMode: .default)
    RunLoop.main.run()
    return ExitCode.ok
}

// MARK: - control

private func controlResult(_ cmd: String, ok: Bool, error: String? = nil, message: String? = nil) -> String {
    var w = JSONWriter()
    w.raw("{\"ok\":"); w.bool(ok)
    w.raw(",\"command\":"); w.string(cmd)
    if let e = error { w.raw(",\"error\":"); w.string(e) }
    if let m = message { w.raw(",\"message\":"); w.string(m) }
    w.raw("}")
    return w.text
}

func runControl(args: [String]) -> Int32 {
    guard let cmd = args.first else {
        IO.stdoutLine(controlResult("", ok: false, error: "bad_args", message: "missing command"))
        return ExitCode.usage
    }
    let rest = Array(args.dropFirst())
    var body: String
    var launches = false // commands allowed to launch Music if it is not running

    switch cmd {
    case "play": body = "play"; launches = true
    case "pause": body = "pause"
    case "playpause": body = "playpause"; launches = true
    case "stop": body = "stop"
    case "next": body = "next track"
    case "previous": body = "previous track"
    case "seek":
        guard let s = rest.first.flatMap(Double.init), s >= 0, s.isFinite else {
            IO.stdoutLine(controlResult(cmd, ok: false, error: "bad_args", message: "seek needs SECONDS >= 0"))
            return ExitCode.usage
        }
        body = "set player position to \(s)"
    case "volume":
        guard let v = rest.first.flatMap(Double.init), v.isFinite else {
            IO.stdoutLine(controlResult(cmd, ok: false, error: "bad_args", message: "volume needs 0-100"))
            return ExitCode.usage
        }
        body = "set sound volume to \(Int(max(0, min(100, v)).rounded()))"
    case "play-id":
        guard let id = rest.first?.uppercased(), isPersistentIDHex(id) else {
            IO.stdoutLine(controlResult(cmd, ok: false, error: "bad_args", message: "play-id needs a 16-digit hex persistent ID"))
            return ExitCode.usage
        }
        body = "play (first track of library playlist 1 whose persistent ID is \"\(id)\")"
        launches = true
    default:
        IO.stdoutLine(controlResult(cmd, ok: false, error: "bad_args", message: "unknown command"))
        return ExitCode.usage
    }

    if !launches && !musicIsRunning() {
        IO.stdoutLine(controlResult(cmd, ok: false, error: "not_running", message: "Music is not running"))
        return ExitCode.notRunning
    }

    let guardLine = launches ? "" : "if application id \"com.apple.Music\" is not running then return \"notrunning\"\n"
    let source = guardLine + "tell application id \"com.apple.Music\"\n\(body)\nend tell\nreturn \"ok\""
    do {
        let r = try CompiledScript(source).run()
        if r.stringValue == "notrunning" {
            IO.stdoutLine(controlResult(cmd, ok: false, error: "not_running", message: "Music is not running"))
            return ExitCode.notRunning
        }
        IO.stdoutLine(controlResult(cmd, ok: true))
        return ExitCode.ok
    } catch let f as ScriptFailure {
        if f.isPermission {
            IO.stdoutLine(controlResult(cmd, ok: false, error: "automation_denied", message: "\(f.number): \(f.message)"))
            IO.stderrLine("oozic-music-helper: not allowed to control Music (Apple Events error \(f.number)). "
                + "Enable it under System Settings > Privacy & Security > Automation.")
            return ExitCode.permissionDenied
        }
        // -1719 invalid index / -1728 no such object: track id not in library.
        if cmd == "play-id" && (f.number == -1719 || f.number == -1728) {
            IO.stdoutLine(controlResult(cmd, ok: false, error: "not_found", message: "no library track with that persistent ID"))
            return ExitCode.notFound
        }
        IO.stdoutLine(controlResult(cmd, ok: false, error: "script_error", message: "\(f.number): \(f.message)"))
        return ExitCode.scriptError
    } catch {
        IO.stdoutLine(controlResult(cmd, ok: false, error: "script_error", message: "\(error)"))
        return ExitCode.scriptError
    }
}
