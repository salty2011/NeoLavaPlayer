// Core Audio process tap capture (macOS 14.2+).
//
// Flow: find the target's Core Audio process objects -> CATapDescription ->
// AudioHardwareCreateProcessTap -> private aggregate device containing the
// tap (clocked by the default output device) -> IOProc reads the tap stream.
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
}

func audioProcesses() -> [AudioProcessInfo] {
    caGetObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { obj in
        let pid = caGet(obj, kAudioProcessPropertyPID, pid_t(-1)) ?? -1
        let bid = caGetString(obj, kAudioProcessPropertyBundleID) ?? ""
        return AudioProcessInfo(objectID: obj, pid: pid, bundleID: bid)
    }
}

func defaultOutputDeviceUID() -> String? {
    guard let dev = caGet(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0)),
          dev != 0 else { return nil }
    return caGetString(dev, kAudioDevicePropertyDeviceUID)
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
    let outputUID: String

    /// include: tap exactly these process objects. exclude: tap everything but these.
    init(include: [AudioObjectID]?, exclude: [AudioObjectID], sink: PCMSink) throws {
        guard let outUID = defaultOutputDeviceUID() else { throw TapError.noOutputDevice }
        outputUID = outUID
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


        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OozicPlayer-Tap",
            kAudioAggregateDeviceUIDKey: "oozic-music-helper-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard st == noErr else { destroy(); throw TapError.status("AudioHardwareCreateAggregateDevice", st) }
        aggregateID = agg

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

// MARK: - Backend with wait/attach/re-attach

@available(macOS 14.2, *)
final class ProcessTapBackend {
    let appBundleID: String? // nil = system-wide
    let sink: PCMSink
    private var session: TapSession?
    private var attachedSignature: [pid_t] = []
    private var attachedOutputUID: String?
    private var timer: Timer?
    private var announcedWaiting = false
    private var consecutiveFailures = 0
    // IO watchdog
    private var attachTime = Date()
    private var ioAtAttach = 0
    private var stallRetried = false

    init(appBundleID: String?, sink: PCMSink) {
        self.appBundleID = appBundleID
        self.sink = sink
    }

    /// Start immediately if possible; throws only on the *first* attach
    /// failure in system mode (so the caller can fall back to SCK).
    func start() throws {
        primeOutputDevice() // see primeOutputDevice(); avoids a 2 s watchdog stall
        if appBundleID == nil {
            try attach(include: nil, signature: [])
        } else {
            poll()
        }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .default)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        session?.destroy()
        session = nil
    }

    private func attach(include: [AudioProcessInfo]?, signature: [pid_t]) throws {
        session?.destroy(); session = nil
        let me = getpid()
        let exclude = include == nil ? audioProcesses().filter { $0.pid == me }.map(\.objectID) : []
        session = try TapSession(include: include?.map(\.objectID), exclude: exclude, sink: sink)
        attachedSignature = signature
        attachedOutputUID = session?.outputUID
        attachTime = Date()
        ioAtAttach = sink.ioCalls
        if include == nil {
            IO.stderrLine("{\"event\":\"attached\",\"backend\":\"tap\",\"source\":\"system\"}")
        } else {
            IO.stderrLine("{\"event\":\"attached\",\"backend\":\"tap\",\"source\":\"app\",\"pids\":\(signature)}")
        }
    }

    private func matchingProcesses() -> [AudioProcessInfo] {
        guard let bid = appBundleID else { return [] }
        return audioProcesses().filter { $0.bundleID == bid || $0.bundleID.hasPrefix(bid + ".") }
    }

    private func poll() {
        exitIfOrphaned { self.stop() }
        let outUID = defaultOutputDeviceUID()

        // Watchdog: an attached tap that has produced no IO callbacks.
        if session != nil && !stallRetried && sink.ioCalls == ioAtAttach && Date().timeIntervalSince(attachTime) > 2.0 {
            stallRetried = true
            IO.stderrLine("{\"event\":\"stalled\",\"message\":\"no audio IO from tap; priming output device and re-attaching\"}")
            session?.destroy(); session = nil
            primeOutputDevice()
            attachedOutputUID = nil // force re-attach below
        }

        if appBundleID == nil {
            // System mode: (re)attach if detached or the output device changed.
            if outUID != nil && (session == nil || outUID != attachedOutputUID) {
                do { try attach(include: nil, signature: []) } catch {
                    IO.stderrLine("{\"event\":\"error\",\"message\":\"re-attach failed: \(error)\"}")
                }
            }
            return
        }

        let procs = matchingProcesses()
        let sig = procs.map(\.pid).sorted()
        if sig.isEmpty {
            if session != nil {
                session?.destroy(); session = nil
                attachedSignature = []
                IO.stderrLine("{\"event\":\"detached\",\"reason\":\"app_exited\"}")
            }
            if !announcedWaiting {
                announcedWaiting = true
                IO.stderrLine("{\"event\":\"waiting\",\"app\":\"\(appBundleID!)\"}")
            }
            return
        }
        if session != nil && sig == attachedSignature && outUID == attachedOutputUID { return }
        if sig != attachedSignature { stallRetried = false } // new app instance: allow one more retry

        do {
            try attach(include: procs, signature: sig)
            announcedWaiting = false
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures == 1 || consecutiveFailures % 30 == 0 {
                IO.stderrLine("{\"event\":\"error\",\"message\":\"attach failed: \(error)\"}")
            }
        }
    }
}

