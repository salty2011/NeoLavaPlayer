// ScreenCaptureKit audio capture: fallback when process taps are unavailable
// (macOS < 14.2) or System Audio Recording permission is denied. Requires
// Screen Recording permission instead.
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@available(macOS 13.0, *)
final class SCKBackend: NSObject, SCStreamOutput, SCStreamDelegate {
    let appBundleID: String?
    let sink: PCMSink
    private var stream: SCStream?
    private var attachedPID: pid_t = 0
    private var timer: Timer?
    private var starting = false
    private var announcedWaiting = false
    private let queue = DispatchQueue(label: "oozic.music-helper.sck", qos: .userInteractive)
    /// Called on the main queue if capture permission is denied.
    var onDenied: (String) -> Void = { _ in }

    init(appBundleID: String?, sink: PCMSink) {
        self.appBundleID = appBundleID
        self.sink = sink
    }

    func start() {
        poll()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .default)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        stopStream()
    }

    private func targetPID() -> pid_t? {
        guard let bid = appBundleID else { return getpid() } // any non-zero marker for system mode
        return NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.processIdentifier
    }

    private func poll() {
        exitIfOrphaned { self.stop() }
        if starting { return }
        guard let pid = targetPID() else {
            if stream != nil {
                stopStream()
                IO.stderrLine("{\"event\":\"detached\",\"reason\":\"app_exited\"}")
            }
            attachedPID = 0
            if !announcedWaiting {
                announcedWaiting = true
                IO.stderrLine("{\"event\":\"waiting\",\"app\":\"\(appBundleID ?? "")\"}")
            }
            return
        }
        if stream != nil && pid == attachedPID { return }
        stopStream()
        starting = true
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            DispatchQueue.main.async {
                self.starting = false
                if let error = error {
                    let ns = error as NSError
                    // SCStreamErrorUserDeclined = -3801; TCC denials also surface here.
                    self.onDenied("ScreenCaptureKit refused (\(ns.domain) \(ns.code): \(ns.localizedDescription))")
                    return
                }
                guard let content = content else { return }
                self.startStream(content: content, pid: pid)
            }
        }
    }

    private func stopStream() {
        if let s = stream { s.stopCapture { _ in } }
        stream = nil
    }

    private func startStream(content: SCShareableContent, pid: pid_t) {
        guard let display = content.displays.first else {
            IO.stderrLine("{\"event\":\"error\",\"message\":\"no display available for ScreenCaptureKit\"}")
            return
        }
        let filter: SCContentFilter
        if appBundleID != nil {
            guard let app = content.applications.first(where: { $0.processID == pid }) else { return } // retry next poll
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            let me = content.applications.filter { $0.processID == getpid() }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        // Video is unavoidable with SCStream; make it as cheap as possible.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 3

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            IO.stderrLine("{\"event\":\"error\",\"message\":\"SCStream addStreamOutput failed: \(error)\"}")
            return
        }
        stream = s
        attachedPID = pid
        sink.reset()
        s.startCapture { error in
            DispatchQueue.main.async {
                if let error = error {
                    self.stream = nil
                    let ns = error as NSError
                    if ns.code == -3801 {
                        self.onDenied("ScreenCaptureKit: user declined (\(ns.localizedDescription))")
                    } else {
                        IO.stderrLine("{\"event\":\"error\",\"message\":\"SCStream start failed: \(ns.code) \(ns.localizedDescription)\"}")
                    }
                    return
                }
                self.announcedWaiting = false
                IO.stderrLine("{\"event\":\"attached\",\"backend\":\"sck\",\"source\":\"\(self.appBundleID == nil ? "system" : "app")\"}")
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid,
              let fmtDesc = sb.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        guard st == noErr else { return }
        sink.push(buf)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            if self.stream === stream { self.stream = nil; self.attachedPID = 0 }
            let ns = error as NSError
            IO.stderrLine("{\"event\":\"detached\",\"reason\":\"stream_stopped\",\"code\":\(ns.code)}")
            if ns.code == -3801 { self.onDenied("ScreenCaptureKit: user declined") }
        }
    }
}
