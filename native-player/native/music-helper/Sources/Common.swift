// Shared helpers: exit codes, stdout/stderr writing, JSON string building.
import Foundation

enum ExitCode {
    static let ok: Int32 = 0
    static let usage: Int32 = 1
    static let libraryUnavailable: Int32 = 2
    static let permissionDenied: Int32 = 3
    static let notRunning: Int32 = 4
    static let notFound: Int32 = 5
    static let scriptError: Int32 = 6
}

enum IO {
    /// Write all bytes to a file descriptor. Returns false on EPIPE or any
    /// other unrecoverable error (caller decides whether that means "exit").
    @discardableResult
    static func writeAll(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) -> Bool {
        var off = 0
        while off < count {
            let r = write(fd, ptr + off, count - off)
            if r < 0 {
                if errno == EINTR { continue }
                return false
            }
            off += r
        }
        return true
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { writeAll(fd, $0.baseAddress!, $0.count) }
    }

    @discardableResult
    static func stdoutLine(_ s: String) -> Bool {
        writeAll(1, Array((s + "\n").utf8))
    }

    static func stderrLine(_ s: String) {
        writeAll(2, Array((s + "\n").utf8))
    }
}

/// Minimal append-only JSON writer into a byte buffer. Much faster than
/// JSONSerialization for large libraries and keeps key order stable.
struct JSONWriter {
    var buf: [UInt8] = []

    init(capacity: Int = 1024) { buf.reserveCapacity(capacity) }

    mutating func raw(_ s: StaticString) {
        s.withUTF8Buffer { buf.append(contentsOf: $0) }
    }

    mutating func rawString(_ s: String) { buf.append(contentsOf: s.utf8) }

    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    mutating func string(_ s: String) {
        buf.append(0x22)
        for b in s.utf8 {
            switch b {
            case 0x22: buf.append(0x5C); buf.append(0x22)
            case 0x5C: buf.append(0x5C); buf.append(0x5C)
            case 0x0A: buf.append(0x5C); buf.append(0x6E)
            case 0x0D: buf.append(0x5C); buf.append(0x72)
            case 0x09: buf.append(0x5C); buf.append(0x74)
            case 0x00..<0x20:
                buf.append(contentsOf: Array("\\u00".utf8))
                buf.append(JSONWriter.hex[Int(b >> 4)])
                buf.append(JSONWriter.hex[Int(b & 0xF)])
            default: buf.append(b)
            }
        }
        buf.append(0x22)
    }

    mutating func stringOrNull(_ s: String?) {
        if let s = s { string(s) } else { raw("null") }
    }

    mutating func int<T: BinaryInteger>(_ v: T) { rawString(String(v)) }

    mutating func double(_ v: Double, decimals: Int = 3) {
        if !v.isFinite { raw("0"); return }
        rawString(String(format: "%.\(decimals)f", v))
    }

    mutating func bool(_ v: Bool) { if v { raw("true") } else { raw("false") } }

    var text: String { String(decoding: buf, as: UTF8.self) }
}

/// Persistent IDs are rendered as 16 upper-case hex digits, which is the
/// exact form the Music app's AppleScript `persistent ID` property returns,
/// so ids from `library`, `now` and `control play-id` are interchangeable.
func persistentIDHex(_ v: UInt64) -> String {
    let digits: [UInt8] = Array("0123456789ABCDEF".utf8)
    var out = [UInt8](repeating: 0x30, count: 16)
    var x = v
    var i = 15
    while i >= 0 {
        out[i] = digits[Int(x & 0xF)]
        x >>= 4
        i -= 1
    }
    return String(decoding: out, as: UTF8.self)
}

func isPersistentIDHex(_ s: String) -> Bool {
    s.count == 16 && s.allSatisfy { $0.isHexDigit }
}

/// Exit when the parent process goes away (we get re-parented to launchd).
/// Long-running subcommands call this from their periodic timers so an
/// orphaned helper never lingers when nothing is being written to the pipe.
func exitIfOrphaned(_ cleanup: () -> Void = {}) {
    if getppid() == 1 {
        cleanup()
        exit(ExitCode.ok)
    }
}

/// Install SIGTERM/SIGINT handlers that run `cleanup` on the main queue and
/// exit 0; SIGPIPE is ignored so writes fail with EPIPE instead (handled by
/// callers as a clean exit).
var signalSources: [DispatchSourceSignal] = []
func installSignalHandlers(_ cleanup: @escaping () -> Void) {
    signal(SIGPIPE, SIG_IGN)
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            cleanup()
            exit(ExitCode.ok)
        }
        src.resume()
        signalSources.append(src)
    }
}
