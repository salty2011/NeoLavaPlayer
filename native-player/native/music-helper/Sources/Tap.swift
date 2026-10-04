// `tap` subcommand: stream captured audio as raw f32le stereo PCM on stdout.
import CoreGraphics
import Foundation

/// TCC (privacy database) access via the private TCC.framework, loaded
/// dynamically. Process taps never return an error when permission is
/// missing; they just deliver silence. Preflighting/requesting
/// kTCCServiceAudioCapture is the only way to tell "denied" from "quiet".
/// If the SPI is unavailable we proceed and capture may be silent.
enum TCC {
    enum Status { case granted, denied, undetermined, unavailable }

    static let audioCapture = "kTCCServiceAudioCapture"
    static let mediaLibrary = "kTCCServiceMediaLibrary"

    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static func preflight(_ service: String) -> Status {
        guard let h = handle, let sym = dlsym(h, "TCCAccessPreflight") else { return .unavailable }
        let fn = unsafeBitCast(sym, to: PreflightFn.self)
        switch fn(service as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Shows the system prompt (attributed to the responsible app) and blocks
    /// until the user answers. Returns nil if the SPI is unavailable. Returns
    /// false immediately, without a prompt, when the responsible app has no
    /// usage-description key for the service.
    static func request(_ service: String) -> Bool? {
        guard let h = handle, let sym = dlsym(h, "TCCAccessRequest") else { return nil }
        let fn = unsafeBitCast(sym, to: RequestFn.self)
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        fn(service as CFString, nil) { ok in
            granted = ok
            sem.signal()
        }
        sem.wait()
        return granted
    }
}

private func headerLine(rate: Int, source: String, backend: String) -> String {
    "{\"rate\":\(rate),\"channels\":2,\"format\":\"f32le\",\"source\":\"\(source)\",\"backend\":\"\(backend)\"}"
}

private func denyExit(_ message: String) -> Never {
    IO.stderrLine("{\"event\":\"error\",\"error\":\"permission_denied\",\"message\":\"\(message)\"}")
    exit(ExitCode.permissionDenied)
}

func runTap(args: [String]) -> Int32 {
    var appID: String? = musicBundleID
    var rate = 48000
    var backendPref = "auto"
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--system": appID = nil
        case "--app":
            guard i + 1 < args.count else { IO.stderrLine("--app needs a bundle id"); return ExitCode.usage }
            appID = args[i + 1]; i += 1
        case "--rate":
            guard i + 1 < args.count, let r = Int(args[i + 1]), (8000...192000).contains(r) else {
                IO.stderrLine("--rate needs an integer 8000-192000"); return ExitCode.usage
            }
            rate = r; i += 1
        case "--backend":
            guard i + 1 < args.count, ["auto", "tap", "sck"].contains(args[i + 1]) else {
                IO.stderrLine("--backend must be auto, tap or sck"); return ExitCode.usage
            }
            backendPref = args[i + 1]; i += 1
        default:
            IO.stderrLine("unknown tap option \(args[i])"); return ExitCode.usage
        }
        i += 1
    }
    let source = appID == nil ? "system" : "app"
    let sink = PCMSink(rate: Double(rate))

    var cleanup: () -> Void = {}
    installSignalHandlers { cleanup() }
    sink.onPipeClosed = { cleanup(); exit(ExitCode.ok) }
    if ProcessInfo.processInfo.environment["OOZIC_DEBUG"] == "1" {
        let t = Timer(timeInterval: 1.0, repeats: true) { _ in IO.stderrLine(sink.debugSummary) }
        RunLoop.main.add(t, forMode: .default)
    }

    // --- Decide backend -------------------------------------------------
    var useTap = false
    var tapDeniedReason: String? = nil
    if backendPref != "sck" {
        if #available(macOS 14.2, *) {
            // Debug only: OOZIC_TAP_SKIP_TCC=1 bypasses the TCC gate (no prompt) to
            // exercise the capture plumbing; without permission the tap is silent.
            let skipTCC = ProcessInfo.processInfo.environment["OOZIC_TAP_SKIP_TCC"] == "1"
            switch skipTCC ? .granted : TCC.preflight(TCC.audioCapture) {
            case .granted, .unavailable: useTap = true
            case .undetermined:
                if TCC.request(TCC.audioCapture) == false {
                    if TCC.preflight(TCC.audioCapture) == .undetermined {
                        // TCC refused to even show a prompt.
                        tapDeniedReason = "System Audio Recording permission was denied without a prompt (the app that launched this helper must declare NSAudioCaptureUsageDescription in its Info.plist)"
                    } else {
                        tapDeniedReason = "System Audio Recording permission was denied"
                    }
                } else { useTap = true }
            case .denied:
                tapDeniedReason = "System Audio Recording permission is denied"
            }
        } else {
            tapDeniedReason = "process taps need macOS 14.2+"
        }
        if !useTap && backendPref == "tap" {
            if tapDeniedReason?.contains("denied") == true {
                denyExit("\(tapDeniedReason!). Enable the app that launched this helper under System Settings > Privacy & Security > Screen & System Audio Recording (System Audio Recording Only).")
            }
            IO.stderrLine("{\"event\":\"error\",\"message\":\"\(tapDeniedReason ?? "tap unavailable")\"}")
            return ExitCode.usage
        }
    }

    // --- Process tap path ----------------------------------------------
    if useTap, #available(macOS 14.2, *) {
        let backend = ProcessTapBackend(appBundleID: appID, sink: sink)
        cleanup = { backend.stop() }
        IO.stderrLine(headerLine(rate: rate, source: source, backend: "tap"))
        do {
            try backend.start()
            // Permission can be revoked (or denied at a late prompt) while running.
            let t = Timer(timeInterval: 3.0, repeats: true) { _ in
                if TCC.preflight(TCC.audioCapture) == .denied {
                    backend.stop()
                    denyExit("System Audio Recording permission is denied. Enable the app that launched this helper under System Settings > Privacy & Security > Screen & System Audio Recording.")
                }
            }
            RunLoop.main.add(t, forMode: .default)
            RunLoop.main.run()
            return ExitCode.ok
        } catch {
            backend.stop()
            if backendPref == "tap" {
                IO.stderrLine("{\"event\":\"error\",\"message\":\"process tap failed: \(error)\"}")
                return ExitCode.usage
            }
            IO.stderrLine("{\"event\":\"fallback\",\"from\":\"tap\",\"to\":\"sck\",\"message\":\"\(error)\"}")
        }
    } else if let r = tapDeniedReason, backendPref == "auto" {
        IO.stderrLine("{\"event\":\"fallback\",\"from\":\"tap\",\"to\":\"sck\",\"message\":\"\(r)\"}")
    }

    // --- ScreenCaptureKit path -----------------------------------------
    guard #available(macOS 13.0, *) else {
        IO.stderrLine("{\"event\":\"error\",\"message\":\"no capture backend available on this macOS version\"}")
        return ExitCode.usage
    }
    if !CGPreflightScreenCaptureAccess() {
        // Shows the system prompt the first time; access only takes effect
        // after the user enables it in Settings and the app is relaunched.
        if !CGRequestScreenCaptureAccess() {
            let tapPart = tapDeniedReason.map { "\($0); " } ?? ""
            denyExit("\(tapPart)Screen Recording permission is not granted. Enable the app that launched this helper under System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch it.")
        }
    }
    let sck = SCKBackend(appBundleID: appID, sink: sink)
    cleanup = { sck.stop() }
    sck.onDenied = { msg in sck.stop(); denyExit(msg) }
    IO.stderrLine(headerLine(rate: rate, source: source, backend: "sck"))
    sck.start()
    RunLoop.main.run()
    return ExitCode.ok
}
