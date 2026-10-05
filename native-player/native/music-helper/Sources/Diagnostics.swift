// `processes` and `selftest` subcommands (additive diagnostics; no
// permission prompts, no capture, no sound).
import Foundation

private func jsonDevice(_ d: OutputDevice?) -> String {
    guard let d = d else { return "null" }
    return "{\"uid\":\(jsonString(d.uid)),\"name\":\(jsonString(d.name))}"
}

/// Core Audio's view: every process object (pid, bundle, running output),
/// the default/system output devices and which processes `tap --app` would
/// include. Reading these needs no permission.
func runProcesses(args: [String]) -> Int32 {
    var bid = musicBundleID
    if let i = args.firstIndex(of: "--app"), i + 1 < args.count { bid = args[i + 1] }
    let all = audioProcesses()
    let matched = matchProcesses(all, bundleID: bid)
    IO.stdoutLine("{\"app\":\(jsonString(bid)),\"tapped\":\(jsonProcs(matched)),\"others_output\":\(jsonProcs(otherOutputProcesses(all, tapped: matched))),\"default_output\":\(jsonDevice(defaultOutput())),\"system_output\":\(jsonDevice(defaultSystemOutput())),\"processes\":\(jsonProcs(all))}")
    return ExitCode.ok
}

/// Unit-style checks of the tap plumbing that run without permissions:
/// process matching, backoff, listener wiring and debouncing, JSON helpers.
func runSelftest() -> Int32 {
    var checks: [(String, Bool, String)] = []
    func check(_ name: String, _ ok: Bool, _ detail: String = "") { checks.append((name, ok, detail)) }

    // Process matching.
    let procs = [
        AudioProcessInfo(objectID: 10, pid: 300, bundleID: "com.apple.Music.helper", runningOutput: false),
        AudioProcessInfo(objectID: 11, pid: 200, bundleID: "com.apple.Music", runningOutput: true),
        AudioProcessInfo(objectID: 12, pid: 100, bundleID: "com.apple.MusicX", runningOutput: true),
        AudioProcessInfo(objectID: 13, pid: 150, bundleID: "com.apple.Safari", runningOutput: true),
        AudioProcessInfo(objectID: 14, pid: 160, bundleID: "com.example.quiet", runningOutput: false),
    ]
    let m = matchProcesses(procs, bundleID: "com.apple.Music")
    check("match_bundle_and_children", m.map(\.pid) == [200, 300], "\(m.map(\.pid))")
    let others = otherOutputProcesses(procs, tapped: m)
    check("other_output_candidates", others.map(\.pid) == [100, 150], "\(others.map(\.pid))")
    check("match_none", matchProcesses(procs, bundleID: "com.apple.TV").isEmpty)

    // Backoff: 2, 5, 10, 30, 30; reset starts over.
    var b = Backoff()
    let delays = (0..<5).map { _ in b.next() }
    b.reset()
    check("backoff_schedule", delays == [2, 5, 10, 30, 30] && b.next() == 2, "\(delays)")

    // JSON helpers produce valid JSON.
    let json = "{\"p\":\(jsonProcs(m)),\"s\":\(jsonString("a\"b\n")),\"r\":\(jsonReasons(["wake", "device_gone"]))}"
    let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    check("json_helpers", (parsed?["r"] as? String) == "device_gone,wake" && (parsed?["p"] as? [Any])?.count == 2, json)

    // Listener wiring: every system selector registers; fired reasons are
    // debounced into one callback; stop() removes them.
    var calls: [Set<String>] = []
    let watcher = AudioChangeWatcher { calls.append($0) }
    let registered = watcher.start()
    check("listeners_registered", registered == AudioChangeWatcher.systemSelectors.count,
          "\(registered)/\(AudioChangeWatcher.systemSelectors.count)")
    watcher.fire("default_output_changed")
    watcher.fire("process_list_changed")
    let deadline = Date().addingTimeInterval(3)
    while calls.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check("listener_debounce", calls.count == 1 && calls.first == ["default_output_changed", "process_list_changed"], "\(calls)")
    watcher.stop()
    check("listeners_removed", watcher.registrationCount == 0)

    // Live Core Audio reads (informational: a CI Mac may have no output device).
    let live = audioProcesses()
    let out = defaultOutput()
    check("core_audio_reads", true, "processes=\(live.count) output=\(out?.name ?? "none") signature=\(outputSignature())")

    var w = JSONWriter()
    let allOK = checks.allSatisfy { $0.1 }
    w.raw("{\"ok\":"); w.bool(allOK); w.raw(",\"checks\":[")
    for (i, c) in checks.enumerated() {
        if i > 0 { w.raw(",") }
        w.raw("{\"name\":"); w.string(c.0); w.raw(",\"ok\":"); w.bool(c.1); w.raw(",\"detail\":"); w.string(c.2); w.raw("}")
    }
    w.raw("]}")
    IO.stdoutLine(w.text)
    return allOK ? ExitCode.ok : ExitCode.usage
}
