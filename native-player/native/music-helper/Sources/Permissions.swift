// `permissions` subcommand: report TCC status for every capability without
// prompting, so the host app can show a setup screen before using them.
import AppKit
import CoreGraphics
import Foundation

func runPermissions() -> Int32 {
    var w = JSONWriter()

    // System Audio Recording (process taps). Private TCC SPI preflight.
    func name(_ s: TCC.Status) -> String {
        switch s {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "not_determined"
        case .unavailable: return "unknown"
        }
    }
    let audio = name(TCC.preflight(TCC.audioCapture))
    let media = name(TCC.preflight(TCC.mediaLibrary))

    // Screen Recording (ScreenCaptureKit fallback). Public preflight; it
    // cannot distinguish "denied" from "never asked".
    let screen = CGPreflightScreenCaptureAccess() ? "granted" : "not_granted"

    // Automation (Apple Events -> Music). Needs Music running to answer.
    var automation = "unknown_music_not_running"
    if musicIsRunning() {
        let target = NSAppleEventDescriptor(bundleIdentifier: musicBundleID)
        let st = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        switch st {
        case noErr: automation = "granted"
        case OSStatus(-1743): automation = "denied"
        case OSStatus(-1744): automation = "not_determined"
        default: automation = "error_\(st)"
        }
    }

    w.raw("{\"media_library\":"); w.string(media)
    w.raw(",\"audio_capture\":"); w.string(audio)
    w.raw(",\"screen_capture\":"); w.string(screen)
    w.raw(",\"automation_music\":"); w.string(automation)
    w.raw(",\"music_running\":"); w.bool(musicIsRunning())
    w.raw("}")
    IO.stdoutLine(w.text)
    return ExitCode.ok
}
