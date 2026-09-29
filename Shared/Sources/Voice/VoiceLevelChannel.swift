import Darwin
import Foundation

/// Audio level + a coarse spectrum, shared from the app's audio thread to the
/// keyboard's display link through one `mmap`ed page in the App Group.
///
/// Why not notifications: the listening visual reads this every frame (60 to 120 Hz).
/// Darwin notifications at that rate would cost two process wake-ups per frame and
/// still arrive late. A shared page costs nothing to read.
///
/// Why no lock: every field is an aligned 32-bit word, and arm64 stores and loads
/// of aligned words are single-copy atomic. A reader can see a mix of two adjacent
/// frames' values, never a torn float, which is invisible in an animation. The
/// writer never blocks and never allocates, so it is safe on the real-time thread.
struct VoiceLevelFrame: Equatable, Sendable {
    static let bandCount = 12

    /// Smoothed loudness, 0...1 (perceptual, from dBFS).
    var level: Float
    /// Whether the recognizer currently believes speech is present.
    var isSpeech: Bool
    /// Coarse spectrum, 0...1 per band, low to high.
    var bands: [Float]
    /// Increments on every write; a reader uses it to notice a stalled writer.
    var counter: UInt32

    static let silent = VoiceLevelFrame(
        level: 0,
        isSpeech: false,
        bands: Array(repeating: 0, count: bandCount),
        counter: 0
    )
}

enum VoiceLevelLayout {
    static let pageSize = 4096
    static let magic: UInt32 = 0x4F42_564C  // "OBVL"
    static let version: UInt32 = 1
    // Word offsets (32-bit words).
    static let magicWord = 0
    static let versionWord = 1
    static let counterWord = 2
    static let levelWord = 3
    static let speechWord = 4
    static let bandsWord = 5
}

/// App side. Opens (or creates) the page and writes frames from any thread.
final class VoiceLevelWriter: @unchecked Sendable {
    private let base: UnsafeMutableRawPointer
    private var counter: UInt32 = 0

    init?(url: URL) {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard ftruncate(fd, off_t(VoiceLevelLayout.pageSize)) == 0 else { return nil }
        let mapped = mmap(nil, VoiceLevelLayout.pageSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let mapped, mapped != MAP_FAILED else { return nil }
        base = mapped
        let words = base.assumingMemoryBound(to: UInt32.self)
        words[VoiceLevelLayout.magicWord] = VoiceLevelLayout.magic
        words[VoiceLevelLayout.versionWord] = VoiceLevelLayout.version
    }

    deinit {
        munmap(base, VoiceLevelLayout.pageSize)
    }

    /// Real-time safe: plain word stores into already-mapped memory.
    func write(level: Float, isSpeech: Bool, bands: UnsafeBufferPointer<Float>) {
        let words = base.assumingMemoryBound(to: UInt32.self)
        let floats = base.assumingMemoryBound(to: Float.self)
        floats[VoiceLevelLayout.levelWord] = level
        words[VoiceLevelLayout.speechWord] = isSpeech ? 1 : 0
        let count = min(bands.count, VoiceLevelFrame.bandCount)
        for index in 0..<count {
            floats[VoiceLevelLayout.bandsWord + index] = bands[index]
        }
        counter &+= 1
        words[VoiceLevelLayout.counterWord] = counter
    }

    func writeSilence() {
        let zeros = [Float](repeating: 0, count: VoiceLevelFrame.bandCount)
        zeros.withUnsafeBufferPointer { write(level: 0, isSpeech: false, bands: $0) }
    }
}

/// Keyboard side. Read-only mapping; `read()` is a handful of loads.
final class VoiceLevelReader {
    private let base: UnsafeMutableRawPointer

    init?(url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= off_t(VoiceLevelLayout.pageSize) else { return nil }
        let mapped = mmap(nil, VoiceLevelLayout.pageSize, PROT_READ, MAP_SHARED, fd, 0)
        guard let mapped, mapped != MAP_FAILED else { return nil }
        base = mapped
    }

    deinit {
        munmap(base, VoiceLevelLayout.pageSize)
    }

    func read() -> VoiceLevelFrame {
        let words = base.assumingMemoryBound(to: UInt32.self)
        guard words[VoiceLevelLayout.magicWord] == VoiceLevelLayout.magic,
              words[VoiceLevelLayout.versionWord] == VoiceLevelLayout.version else {
            return .silent
        }
        let floats = base.assumingMemoryBound(to: Float.self)
        var bands = [Float](repeating: 0, count: VoiceLevelFrame.bandCount)
        for index in 0..<VoiceLevelFrame.bandCount {
            bands[index] = Self.clamp(floats[VoiceLevelLayout.bandsWord + index])
        }
        return VoiceLevelFrame(
            level: Self.clamp(floats[VoiceLevelLayout.levelWord]),
            isSpeech: words[VoiceLevelLayout.speechWord] != 0,
            bands: bands,
            counter: words[VoiceLevelLayout.counterWord]
        )
    }

    private static func clamp(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
