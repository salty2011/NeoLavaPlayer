// Core Audio process tap capture (macOS 14.2+).
//
// Flow: find the target's Core Audio process objects -> CATapDescription ->
// AudioHardwareCreateProcessTap -> private aggregate device containing the
// tap (clocked by an output device) -> IOProc reads the tap stream.
//
// Robustness (see docs/MUSIC_HELPER.md, "Rebuilds and health"):
// - Property listeners on the system object (default output / system output
//   device, device list, process object list), on the clock device (alive,
//   sample rate), on the tap (format) and on each tapped process
//   (IsRunningOutput) trigger a debounced re-evaluation; sleep/wake too.
// - A 1 s health check rebuilds the tap with backoff when IO callbacks stop
//   (stalled) or when a tapped process is outputting but the tap delivers
//   only zeros (silent).
import AppKit
import AVFoundation
import CoreAudio
import Foundation

// MARK: - Core Audio property helpers

func caGet<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
    return st == noErr ? value : nil
}

func caGetString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf)
    guard st == noErr, let s = cf?.takeRetainedValue() else { return nil }
    return s as String
}

func caGetObjectList(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

struct AudioProcessInfo: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    var runningOutput = false
}

func processIsRunningOutput(_ obj: AudioObjectID) -> Bool {
    if #available(macOS 14.2, *) {
        return (caGet(obj, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
    }
    return false
}

func audioProcesses() -> [AudioProcessInfo] {
    guard #available(macOS 14.2, *) else { return [] }
    return caGetObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { obj in
        let pid = caGet(obj, kAudioProcessPropertyPID, pid_t(-1)) ?? -1
        let bid = caGetString(obj, kAudioProcessPropertyBundleID) ?? ""
        return AudioProcessInfo(objectID: obj, pid: pid, bundleID: bid, runningOutput: processIsRunningOutput(obj))
    }
}

/// The processes to tap for an app: bundle ID equal to `bundleID` or below it
/// (`com.apple.Music.*`), sorted by pid. Pure, so `selftest` can check it.
func matchProcesses(_ procs: [AudioProcessInfo], bundleID: String) -> [AudioProcessInfo] {
    procs.filter { $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".") }.sorted { $0.pid < $1.pid }
}

/// Processes outside `tapped` that are producing output now (diagnostics only:
/// they are reported, never captured).
func otherOutputProcesses(_ procs: [AudioProcessInfo], tapped: [AudioProcessInfo]) -> [AudioProcessInfo] {
    let mine = Set(tapped.map(\.objectID))
    let me = getpid()
    return procs.filter { $0.runningOutput && !mine.contains($0.objectID) && $0.pid != me }.sorted { $0.pid < $1.pid }
}

struct OutputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

func outputDevice(_ selector: AudioObjectPropertySelector) -> OutputDevice? {
    guard let dev = caGet(AudioObjectID(kAudioObjectSystemObject), selector, AudioObjectID(0)), dev != 0,
          let uid = caGetString(dev, kAudioDevicePropertyDeviceUID) else { return nil }
    return OutputDevice(id: dev, uid: uid, name: caGetString(dev, kAudioObjectPropertyName) ?? "")
}

/// Where apps (Music) play: System Settings > Sound > Output.
func defaultOutput() -> OutputDevice? { outputDevice(kAudioHardwarePropertyDefaultOutputDevice) }
/// Where alerts play; the tap aggregate's preferred clock (known to work with taps).
func defaultSystemOutput() -> OutputDevice? { outputDevice(kAudioHardwarePropertyDefaultSystemOutputDevice) }

/// Clock devices to try for the tap aggregate, in order (unique UIDs).
func clockCandidates() -> [OutputDevice] {
    var out: [OutputDevice] = []
    for d in [defaultSystemOutput(), defaultOutput()].compactMap({ $0 }) where !out.contains(where: { $0.uid == d.uid }) {
        out.append(d)
    }
    return out
}

func defaultOutputDeviceUID() -> String? { clockCandidates().first?.uid }

/// "a|b" signature of both default devices, so a change of either rebuilds.
func outputSignature() -> String {
    "\(defaultOutput()?.uid ?? "-")|\(defaultSystemOutput()?.uid ?? "-")"
}

// MARK: - Backoff

/// Health-driven rebuild delays: 2 s, 5 s, 10 s, then every 30 s.
struct Backoff {
    static let schedule: [Double] = [2, 5, 10, 30]
    private(set) var attempts = 0
    mutating func next() -> Double {
        let d = Backoff.schedule[min(attempts, Backoff.schedule.count - 1)]
        attempts += 1
        return d
    }
    mutating func reset() { attempts = 0 }
}

// MARK: - Tap session

enum TapError: Error, CustomStringConvertible {
    case status(String, OSStatus)
    case noOutputDevice
    case badFormat

    var description: String {
        switch self {
        case let .status(what, st): return "\(what) failed (OSStatus \(st) '\(fourCC(st))')"
        case .noOutputDevice: return "no default output device"
        case .badFormat: return "could not read tap stream format"
        }
    }
}

func fourCC(_ st: OSStatus) -> String {
    let u = UInt32(bitPattern: st)
    let bytes = [UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return String(decoding: bytes, as: UTF8.self) }
    return String(st)
}

@available(macOS 14.2, *)
final class TapSession {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "oozic.music-helper.tap-io", qos: .userInteractive)
    private(set) var clock = OutputDevice(id: 0, uid: "", name: "")

    /// include: tap exactly these process objects. exclude: tap everything but these.
    /// The tap is private and `.unmuted`: the tapped app keeps playing to its
    /// device exactly as before; nothing is rerouted or muted.
    init(include: [AudioObjectID]?, exclude: [AudioObjectID], sink: PCMSink) throws {
        let candidates = clockCandidates()
        guard !candidates.isEmpty else { throw TapError.noOutputDevice }
        let desc: CATapDescription
        if let include = include {
            desc = CATapDescription(stereoMixdownOfProcesses: include)
        } else {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        }
        desc.name = "OozicPlayer music tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else { throw TapError.status("AudioHardwareCreateProcessTap", st) }
        tapID = tap

        // Clock: the system output device first (the known-good choice); if the
        // aggregate can't be built on it (e.g. some AirPlay routes), the default
        // output device.
        var chosen: OutputDevice?
        var lastStatus: OSStatus = noErr
        for dev in candidates {
            let aggDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "OozicPlayer-Tap",
                kAudioAggregateDeviceUIDKey: "oozic-music-helper-" + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: dev.uid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: dev.uid]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                ]],
            ]
            var agg = AudioObjectID(kAudioObjectUnknown)
            lastStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
            if lastStatus == noErr {
                aggregateID = agg
                chosen = dev
                break
            }
        }
        guard let clockDevice = chosen else { destroy(); throw TapError.status("AudioHardwareCreateAggregateDevice", lastStatus) }
        clock = clockDevice

        guard var asbd = caGet(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
              let format = AVAudioFormat(streamDescription: &asbd) else {
            destroy(); throw TapError.badFormat
        }

        sink.reset()
        var procID: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, _, _, _ in
            sink.ioCalls += 1
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else { return }
            sink.push(buf)
        }
        guard st == noErr, let pid = procID else { destroy(); throw TapError.status("AudioDeviceCreateIOProcIDWithBlock", st) }
        ioProcID = pid

        st = AudioDeviceStart(aggregateID, pid)
        guard st == noErr else { destroy(); throw TapError.status("AudioDeviceStart", st) }
    }

    func destroy() {
        if aggregateID != kAudioObjectUnknown {
            if let p = ioProcID {
                AudioDeviceStop(aggregateID, p)
                AudioDeviceDestroyIOProcID(aggregateID, p)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { destroy() }
}

/// Briefly run a tap-less private aggregate on the default output device.
/// Observed on macOS 27 (no System Audio Recording grant): a fresh process
/// whose *first* HAL IO is a tap aggregate gets no IO callbacks at all, while
/// the same tap runs after the process has done one plain IO cycle. Silent:
/// the IOProc writes no samples (the HAL pre-zeroes output buffers and mixes
/// them with everything else).
func primeOutputDevice() {
    guard let out = defaultOutputDeviceUID() else { return }
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "OozicPlayer-Prime",
        kAudioAggregateDeviceUIDKey: "oozic-music-helper-prime-" + UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: out,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: out]],
    ]
    var agg = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg) == noErr else { return }
    defer { AudioHardwareDestroyAggregateDevice(agg) }
    var pid: AudioDeviceIOProcID?
    guard AudioDeviceCreateIOProcIDWithBlock(&pid, agg, nil, { _, _, _, _, _ in }) == noErr, let p = pid else { return }
    defer { AudioDeviceDestroyIOProcID(agg, p) }
    if AudioDeviceStart(agg, p) == noErr {
        Thread.sleep(forTimeInterval: 0.25)
        AudioDeviceStop(agg, p)
    }
}

// MARK: - Change listeners

/// Core Audio property listeners plus sleep/wake, delivered on the main queue
/// and debounced: `onChange` gets the set of reasons collected in 0.25 s.
final class AudioChangeWatcher {
    typealias Reasons = Set<String>
    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var system: [Registration] = []
    private var scoped: [Registration] = [] // clock device, tap, tapped processes
    private var pending: Reasons = []
    private var scheduled = false
    private var wakeObserver: NSObjectProtocol?
    let onChange: (Reasons) -> Void

    /// Selectors on the system object and the reason each one reports.
    static let systemSelectors: [(AudioObjectPropertySelector, String)] = {
        var list: [(AudioObjectPropertySelector, String)] = [
            (kAudioHardwarePropertyDefaultOutputDevice, "default_output_changed"),
            (kAudioHardwarePropertyDefaultSystemOutputDevice, "system_output_changed"),
            (kAudioHardwarePropertyDevices, "device_list_changed"),
        ]
        if #available(macOS 14.2, *) { list.append((kAudioHardwarePropertyProcessObjectList, "process_list_changed")) }
        return list
    }()

    init(onChange: @escaping (Reasons) -> Void) { self.onChange = onChange }

    /// Registers the system listeners and the wake observer; returns how many
    /// Core Audio registrations succeeded (selftest checks this).
    @discardableResult
    func start() -> Int {
        var ok = 0
        for (sel, reason) in AudioChangeWatcher.systemSelectors {
            if let r = add(AudioObjectID(kAudioObjectSystemObject), sel, reason) { system.append(r); ok += 1 }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Devices come back a moment after wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.fire("wake") }
        }
        return ok
    }

    /// Replace the per-session listeners (clock device, tap format, tapped
    /// processes' IsRunningOutput).
    func watchSession(clock: AudioObjectID?, tap: AudioObjectID?, processes: [AudioObjectID]) {
        clearScoped()
        if let dev = clock {
            if let r = add(dev, kAudioDevicePropertyDeviceIsAlive, "device_gone") { scoped.append(r) }
            if let r = add(dev, kAudioDevicePropertyNominalSampleRate, "device_rate_changed") { scoped.append(r) }
        }
        if #available(macOS 14.2, *) {
            if let t = tap, let r = add(t, kAudioTapPropertyFormat, "tap_format_changed") { scoped.append(r) }
            for p in processes {
                if let r = add(p, kAudioProcessPropertyIsRunningOutput, "output_state_changed") { scoped.append(r) }
            }
        }
    }

    func stop() {
        clearScoped()
        for var r in system { AudioObjectRemovePropertyListenerBlock(r.object, &r.address, DispatchQueue.main, r.block) }
        system.removeAll()
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wakeObserver = nil
    }

    var registrationCount: Int { system.count + scoped.count }

    /// Test hook (selftest) and the wake observer: queue a reason as if a
    /// listener had fired.
    func fire(_ reason: String) {
        pending.insert(reason)
        if scheduled { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            self.scheduled = false
            let reasons = self.pending
            self.pending = []
            if !reasons.isEmpty { self.onChange(reasons) }
        }
    }

    private func clearScoped() {
        for var r in scoped { AudioObjectRemovePropertyListenerBlock(r.object, &r.address, DispatchQueue.main, r.block) }
        scoped.removeAll()
    }

    private func add(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ reason: String) -> Registration? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.fire(reason) }
        guard AudioObjectAddPropertyListenerBlock(obj, &addr, DispatchQueue.main, block) == noErr else { return nil }
        return Registration(object: obj, address: addr, block: block)
    }
}

// MARK: - Event JSON helpers

func jsonProcs(_ procs: [AudioProcessInfo]) -> String {
    var w = JSONWriter()
    w.raw("[")
    for (i, p) in procs.enumerated() {
        if i > 0 { w.raw(",") }
        w.raw("{\"pid\":"); w.int(p.pid)
        w.raw(",\"bundle\":"); w.string(p.bundleID)
        w.raw(",\"output\":"); w.bool(p.runningOutput)
        w.raw("}")
    }
    w.raw("]")
    return w.text
}

func jsonString(_ s: String) -> String {
    var w = JSONWriter()
    w.string(s)
    return w.text
}

func jsonReasons(_ reasons: Set<String>) -> String {
    jsonString(reasons.sorted().joined(separator: ","))
}

// MARK: - Backend with wait/attach/re-attach/health

@available(macOS 14.2, *)
final class ProcessTapBackend {
    /// Seconds without IO callbacks before a tap counts as stalled.
    static let stallSeconds = 2.0
    /// Seconds of digital silence while a tapped process is outputting.
    static let silentSeconds = 4.0
    /// Silent rebuilds per output episode (Music might keep its IO running
    /// while paused; don't rebuild forever on a false positive).
    static let maxSilentRebuilds = 4
    /// Seconds between `level` events.
    static let levelInterval = 5.0

    let appBundleID: String? // nil = system-wide
    let sink: PCMSink
    private var session: TapSession?
    private var attached: [AudioProcessInfo] = []
    private var attachedSignature: [pid_t] = []
    private var attachedOutputSignature = ""
    private var timer: Timer?
    private var watcher: AudioChangeWatcher?
    private var announcedWaiting = false
    private var consecutiveFailures = 0
    // Health
    private var attachTime = Date()
    private var lastIOCount = 0
    private var lastIOChange = Date()
    private var backoff = Backoff()
    private var nextHealthRebuild = Date.distantPast
    private var stalledAnnounced = false
    private var silentAnnounced = false
    private var silentRebuilds = 0
    private var outputRunning: Bool?
    private var outputSince = Date()
    private var lastOthers: [AudioProcessInfo] = []
    private var lastLevel = Date()

    init(appBundleID: String?, sink: PCMSink) {
        self.appBundleID = appBundleID
        self.sink = sink
    }

    /// Start immediately if possible; throws only on the *first* attach
    /// failure in system mode (so the caller can fall back to SCK).
    func start() throws {
        primeOutputDevice() // see primeOutputDevice(); avoids a 2 s watchdog stall
        let w = AudioChangeWatcher { [weak self] reasons in self?.changed(reasons) }
        w.start()
        watcher = w
        if appBundleID == nil {
            try attach(include: nil, signature: [], reason: nil)
        } else {
            poll()
        }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .default)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        watcher?.stop()
        session?.destroy()
        session = nil
    }

    private func attach(include: [AudioProcessInfo]?, signature: [pid_t], reason: String?) throws {
        let wasAttached = session != nil
        session?.destroy(); session = nil
        let me = getpid()
        let exclude = include == nil ? audioProcesses().filter { $0.pid == me }.map(\.objectID) : []
        let s = try TapSession(include: include?.map(\.objectID), exclude: exclude, sink: sink)
        session = s
        attached = include ?? []
        attachedSignature = signature
        attachedOutputSignature = outputSignature()
        attachTime = Date()
        lastIOCount = sink.ioCalls
        lastIOChange = Date()
        stalledAnnounced = false
        watcher?.watchSession(clock: s.clock.id, tap: s.tapID, processes: attached.map(\.objectID))
        let device = "\"device\":\(jsonString(s.clock.name)),\"device_uid\":\(jsonString(s.clock.uid))"
        if include == nil {
            IO.stderrLine("{\"event\":\"attached\",\"backend\":\"tap\",\"source\":\"system\",\(device)}")
        } else {
            IO.stderrLine("{\"event\":\"attached\",\"backend\":\"tap\",\"source\":\"app\",\"pids\":\(signature),\"processes\":\(jsonProcs(attached)),\(device)}")
        }
        if let r = reason, wasAttached || r != "app_started" {
            IO.stderrLine("{\"event\":\"rebuilt\",\"reason\":\(jsonString(r)),\"pids\":\(signature),\(device)}")
        }
    }

    private func matchingProcesses() -> [AudioProcessInfo] {
        guard let bid = appBundleID else { return [] }
        return matchProcesses(audioProcesses(), bundleID: bid)
    }

    /// A listener fired (debounced). Device/format changes always rebuild;
    /// process-list changes rebuild only when the tapped set changes.
    private func changed(_ reasons: Set<String>) {
        let deviceReasons: Set<String> = ["default_output_changed", "system_output_changed", "device_list_changed",
                                          "device_gone", "device_rate_changed", "tap_format_changed", "wake"]
        let outSig = outputSignature()
        if !reasons.isDisjoint(with: ["default_output_changed", "system_output_changed"]) || outSig != attachedOutputSignature {
            IO.stderrLine("{\"event\":\"device\",\"reason\":\(jsonReasons(reasons)),\"output\":\(jsonString(defaultOutput()?.name ?? "")),\"output_uid\":\(jsonString(defaultOutput()?.uid ?? "")),\"system_output\":\(jsonString(defaultSystemOutput()?.name ?? ""))}")
        }
        // A device list change alone (some unrelated device appeared) only
        // matters when our devices changed or the clock device went away.
        var rebuild = !reasons.isDisjoint(with: deviceReasons.subtracting(["device_list_changed"]))
        if reasons.contains("device_list_changed") && (outSig != attachedOutputSignature || !(session.map { clockAlive($0) } ?? true)) {
            rebuild = true
        }
        if reasons.contains("output_state_changed") { checkOutput() }
        if rebuild && (session != nil || appBundleID == nil) {
            reattach(reason: reasons.intersection(deviceReasons).sorted().joined(separator: ","))
            return
        }
        if reasons.contains("process_list_changed") { poll() }
    }

    private func clockAlive(_ s: TapSession) -> Bool {
        (caGet(s.clock.id, kAudioDevicePropertyDeviceIsAlive, UInt32(1)) ?? 0) != 0
    }

    /// Rebuild the current tap (same processes) for `reason`.
    private func reattach(reason: String) {
        if appBundleID == nil {
            do { try attach(include: nil, signature: [], reason: reason) } catch {
                IO.stderrLine("{\"event\":\"error\",\"message\":\(jsonString("re-attach failed: \(error)"))}")
            }
            return
        }
        let procs = matchingProcesses()
        if procs.isEmpty { poll(); return }
        do { try attach(include: procs, signature: procs.map(\.pid), reason: reason) } catch {
            session = nil
            IO.stderrLine("{\"event\":\"error\",\"message\":\(jsonString("re-attach failed: \(error)"))}")
        }
    }

    private func poll() {
        exitIfOrphaned { self.stop() }
        health()

        if appBundleID == nil {
            // System mode: (re)attach if detached or the output device changed.
            if session == nil || outputSignature() != attachedOutputSignature {
                reattach(reason: session == nil ? "detached" : "device_changed")
            }
            return
        }

        let procs = matchingProcesses()
        let sig = procs.map(\.pid)
        if sig.isEmpty {
            if session != nil {
                session?.destroy(); session = nil
                attached = []
                attachedSignature = []
                watcher?.watchSession(clock: nil, tap: nil, processes: [])
                IO.stderrLine("{\"event\":\"detached\",\"reason\":\"app_exited\"}")
            }
            if !announcedWaiting {
                announcedWaiting = true
                IO.stderrLine("{\"event\":\"waiting\",\"app\":\(jsonString(appBundleID!))}")
            }
            return
        }
        // Safety net for missed notifications: the 1 s poll compares too.
        if session != nil && sig == attachedSignature && outputSignature() == attachedOutputSignature { return }
        let reason: String
        if session == nil { reason = attachedSignature.isEmpty ? "app_started" : "retry" }
        else if sig != attachedSignature { reason = "processes_changed" }
        else { reason = "device_changed" }
        if sig != attachedSignature { silentRebuilds = 0 }

        do {
            try attach(include: procs, signature: sig, reason: reason)
            announcedWaiting = false
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures == 1 || consecutiveFailures % 30 == 0 {
                IO.stderrLine("{\"event\":\"error\",\"message\":\(jsonString("attach failed: \(error)"))}")
            }
        }
    }

    /// Output state of the tapped processes. Transitions are reported with the
    /// other processes that are outputting at that moment (diagnostics: if
    /// Music says it plays but outputs nothing, its audio may be going through
    /// another process or an AirPlay route).
    private func checkOutput() {
        guard appBundleID != nil, session != nil else { return }
        let all = audioProcesses()
        let mine = Set(attached.map(\.objectID))
        let tappedNow = all.filter { mine.contains($0.objectID) }
        let running = tappedNow.contains { $0.runningOutput }
        lastOthers = running ? [] : otherOutputProcesses(all, tapped: tappedNow)
        if running == outputRunning { return }
        outputSince = Date()
        if running { silentRebuilds = 0; silentAnnounced = false }
        outputRunning = running
        IO.stderrLine("{\"event\":\"output\",\"running\":\(running),\"pids\":\(attachedSignature),\"others\":\(jsonProcs(lastOthers))}")
    }

    /// Runs every second: IO stall and silence detection, rebuild with backoff,
    /// periodic level report.
    private func health() {
        guard let s = session else { return }
        let now = Date()
        let io = sink.ioCalls
        if io != lastIOCount { lastIOCount = io; lastIOChange = now; stalledAnnounced = false }
        checkOutput()

        if sink.lastSound > attachTime {
            // Real sound since this attach: healthy again.
            if backoff.attempts > 0 || silentAnnounced {
                IO.stderrLine("{\"event\":\"recovered\",\"rebuilds\":\(backoff.attempts)}")
            }
            backoff.reset()
            silentAnnounced = false
            silentRebuilds = 0
        }

        if now.timeIntervalSince(lastIOChange) > ProcessTapBackend.stallSeconds {
            if !stalledAnnounced {
                stalledAnnounced = true
                IO.stderrLine("{\"event\":\"stalled\",\"message\":\"no audio IO from tap\",\"device\":\(jsonString(s.clock.name)),\"io\":\(io)}")
            }
            if now >= nextHealthRebuild {
                nextHealthRebuild = now.addingTimeInterval(backoff.next())
                primeOutputDevice()
                reattach(reason: "stalled")
            }
            return
        }

        if appBundleID != nil, outputRunning == true,
           now.timeIntervalSince(max(outputSince, attachTime)) > ProcessTapBackend.silentSeconds,
           now.timeIntervalSince(max(sink.lastSound, attachTime)) > ProcessTapBackend.silentSeconds {
            if !silentAnnounced {
                silentAnnounced = true
                IO.stderrLine("{\"event\":\"silent\",\"message\":\"tapped process is outputting but the tap delivers zeros\",\"pids\":\(attachedSignature)}")
            }
            if silentRebuilds < ProcessTapBackend.maxSilentRebuilds && now >= nextHealthRebuild {
                silentRebuilds += 1
                nextHealthRebuild = now.addingTimeInterval(backoff.next())
                reattach(reason: "silent")
                return
            }
        }

        if now.timeIntervalSince(lastLevel) >= ProcessTapBackend.levelInterval {
            lastLevel = now
            let peak = sink.takePeak()
            let db = peak > 0 ? 20 * log10(Double(peak)) : -120
            IO.stderrLine("{\"event\":\"level\",\"peak_db\":\(String(format: "%.1f", max(db, -120))),\"io\":\(io),\"bytes\":\(sink.bytesWritten),\"output\":\(outputRunning ?? false),\"others\":\(jsonProcs(lastOthers)),\"device\":\(jsonString(s.clock.name))}")
        }
    }
}
