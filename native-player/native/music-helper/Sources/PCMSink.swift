// Converts captured audio into interleaved stereo float32 LE at the requested
// rate and writes it to stdout from a dedicated queue so a slow reader never
// blocks the Core Audio IO thread.
import AVFoundation
import Foundation

final class PCMSink {
    let outRate: Double
    let outFormat: AVAudioFormat
    private let writeQueue = DispatchQueue(label: "oozic.music-helper.stdout")
    private let lock = NSLock()
    private var pending = 0
    private let maxPending: Int
    private var converter: AVAudioConverter?
    private var converterInFormat: AVAudioFormat?
    private(set) var bytesWritten: UInt64 = 0
    // Diagnostics (read racily from the main thread; good enough for logs).
    var ioCalls = 0
    private(set) var pushes = 0
    private(set) var inFrames = 0
    private(set) var convertFailures = 0
    var lastInputFormat: String = ""
    var onPipeClosed: () -> Void = {}
    // Level tracking for the health check (written on the capture queue, read
    // racily on the main thread; a stale value only delays a decision by 1 s).
    /// Sample magnitude that counts as sound (the tap delivers exact zeros
    /// when the tapped app is paused or capture is not permitted).
    static let soundLevel: Float = 1e-4
    private var lastSoundTime: CFAbsoluteTime = 0
    private var peak: Float = 0
    /// When the last non-silent block arrived (distantPast: never).
    var lastSound: Date { lastSoundTime == 0 ? .distantPast : Date(timeIntervalSinceReferenceDate: lastSoundTime) }

    /// Peak magnitude since the previous call.
    func takePeak() -> Float {
        let p = peak
        peak = 0
        return p
    }

    init(rate: Double) {
        outRate = rate
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true)!
        maxPending = Int(rate) * 8 * 2 // ~2 s of audio; beyond that we drop rather than grow
    }

    /// Reset conversion state (call when the capture source changes).
    func reset() {
        converter = nil
        converterInFormat = nil
    }

    /// Convert and enqueue one block of input audio. Must be called from a
    /// single serial context (the capture callback queue).
    func push(_ input: AVAudioPCMBuffer) {
        pushes += 1
        inFrames += Int(input.frameLength)
        guard input.frameLength > 0 else { return }
        if converter == nil || converterInFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outFormat)
            converterInFormat = input.format
            lastInputFormat = "\(input.format)"
            if converter == nil {
                IO.stderrLine("{\"event\":\"error\",\"message\":\"unsupported capture format \(input.format)\"}")
                return
            }
        }
        guard let conv = converter else { return }
        let ratio = outRate / input.format.sampleRate
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { convertFailures += 1; return }
        if out.frameLength == 0 { return }
        let abl = out.audioBufferList.pointee
        guard let p = abl.mBuffers.mData else { return }
        let n = Int(out.frameLength) * 8
        let floats = p.assumingMemoryBound(to: Float.self)
        var blockPeak: Float = 0
        for i in 0..<(Int(out.frameLength) * 2) { blockPeak = max(blockPeak, abs(floats[i])) }
        if blockPeak > peak { peak = blockPeak }
        if blockPeak > PCMSink.soundLevel { lastSoundTime = CFAbsoluteTimeGetCurrent() }
        enqueue(Data(bytes: p, count: n))
    }

    var debugSummary: String {
        "{\"event\":\"debug\",\"io_calls\":\(ioCalls),\"pushes\":\(pushes),\"in_frames\":\(inFrames),\"convert_failures\":\(convertFailures),\"bytes_written\":\(bytesWritten),\"in_format\":\"\(lastInputFormat)\"}"
    }

    private func enqueue(_ data: Data) {
        lock.lock()
        if pending + data.count > maxPending {
            lock.unlock()
            return // reader is not keeping up; drop this block
        }
        pending += data.count
        lock.unlock()
        writeQueue.async { [self] in
            let ok = data.withUnsafeBytes { IO.writeAll(1, $0.baseAddress!, $0.count) }
            lock.lock()
            pending -= data.count
            lock.unlock()
            if !ok {
                DispatchQueue.main.async { self.onPipeClosed() }
                return
            }
            bytesWritten += UInt64(data.count)
        }
    }
}
