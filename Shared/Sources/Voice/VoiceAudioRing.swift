import Foundation

/// Continuous audio for a voice session: 16 kHz mono samples addressed by an
/// absolute, ever-increasing sample index.
///
/// The microphone writes; the recognizer reads at its own pace from wherever it has
/// got to. That decoupling is the point: a dictation's start and end are positions
/// in this buffer, not moments in a callback, so speech just before the tap (pre-
/// roll), during model loading, or just after Done (post-roll) is all still here to
/// recognize. Capacity bounds memory, not dictation length: the consumer must keep
/// up. An overwritten read reports its actual start; the recognition pipeline
/// treats a gap as a recoverable failure instead of silently skipping speech.
final class VoiceAudioRing: @unchecked Sendable {
    let capacity: Int
    private var storage: [Float]
    /// Absolute index of the next sample to be written.
    private var end: Int64 = 0
    /// Samples before this index have been discarded (zeroed) and cannot be read.
    private var retained: Int64 = 0
    /// Held only for a memory copy of one audio buffer (microseconds).
    private let lock = NSLock()

    init(seconds: Double = 60, sampleRate: Double = 16_000) {
        capacity = Int(seconds * sampleRate)
        storage = [Float](repeating: 0, count: capacity)
    }

    /// Absolute index one past the newest sample.
    var writeIndex: Int64 {
        lock.withLock { end }
    }

    /// Oldest index still held.
    var oldestIndex: Int64 {
        lock.withLock { max(retained, end - Int64(capacity)) }
    }

    /// Forget audio before `index`: it is zeroed in memory and can no longer be
    /// read. While no dictation is running the session keeps only the last moment
    /// (for pre-roll), so an idle warm session never holds more than that.
    func discard(before index: Int64) {
        lock.withLock {
            let oldest = max(retained, end - Int64(capacity))
            let upTo = min(index, end)
            guard upTo > oldest else { return }
            var position = Int(oldest % Int64(capacity))
            var remaining = Int(upTo - oldest)
            storage.withUnsafeMutableBufferPointer { ring in
                while remaining > 0 {
                    let run = min(remaining, capacity - position)
                    UnsafeMutableBufferPointer(rebasing: ring[position..<(position + run)]).update(repeating: 0)
                    remaining -= run
                    position = (position + run) % capacity
                }
            }
            retained = upTo
        }
    }

    func write(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            var source = samples
            // More than the whole ring at once: keep the newest.
            if source.count > capacity {
                source = UnsafeBufferPointer(rebasing: source.suffix(capacity))
                end += Int64(samples.count - capacity)
            }
            var position = Int(end % Int64(capacity))
            var remaining = source[...]
            storage.withUnsafeMutableBufferPointer { ring in
                while !remaining.isEmpty {
                    let run = min(remaining.count, capacity - position)
                    let chunk = remaining.prefix(run)
                    _ = UnsafeMutableBufferPointer(rebasing: ring[position..<(position + run)]).initialize(from: chunk)
                    remaining = remaining.dropFirst(run)
                    position = (position + run) % capacity
                }
            }
            end += Int64(source.count)
        }
    }

    func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { write($0) }
    }

    /// Up to `maxCount` samples starting at absolute `index`, and the index after
    /// them. If `index` has already been overwritten, reading starts at the oldest
    /// sample still held (the returned start says where).
    func read(from index: Int64, maxCount: Int) -> (samples: [Float], start: Int64, next: Int64) {
        lock.withLock {
            let oldest = max(retained, end - Int64(capacity))
            let start = min(max(index, oldest), end)
            let count = Int(min(Int64(maxCount), end - start))
            guard count > 0 else { return ([], start, start) }
            var out = [Float](repeating: 0, count: count)
            var position = Int(start % Int64(capacity))
            var filled = 0
            storage.withUnsafeBufferPointer { ring in
                out.withUnsafeMutableBufferPointer { destination in
                    while filled < count {
                        let run = min(count - filled, capacity - position)
                        _ = UnsafeMutableBufferPointer(rebasing: destination[filled..<(filled + run)])
                            .initialize(from: ring[position..<(position + run)])
                        filled += run
                        position = (position + run) % capacity
                    }
                }
            }
            return (out, start, start + Int64(count))
        }
    }

    func reset() {
        lock.withLock {
            storage.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            end = 0
            retained = 0
        }
    }
}
