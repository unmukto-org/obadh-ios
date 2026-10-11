import Foundation
import QuartzCore

/// Thread-safe access to the shared level page, for renderers that draw off the main
/// thread. Opening is retried at most twice a second until the app has created the
/// page (a cold start), so a reader never blocks a frame on the file system.
final class VoiceLevelFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: VoiceLevelReader?
    private var url: URL?
    private var lastAttempt: CFTimeInterval = 0
    #if DEBUG
    /// Speech-like synthetic levels, for reviewing the visual without a microphone.
    var isSynthetic = false
    #endif

    func attach(_ url: URL?) {
        lock.withLock {
            self.url = url
            reader = nil
            lastAttempt = 0
        }
    }

    func detach() {
        lock.withLock {
            url = nil
            reader = nil
        }
    }

    func read() -> VoiceLevelFrame {
        #if DEBUG
        if isSynthetic { return SyntheticVoiceLevels.frame(at: CACurrentMediaTime()) }
        #endif
        return lock.withLock {
            if reader == nil, let url, CACurrentMediaTime() - lastAttempt > 0.5 {
                lastAttempt = CACurrentMediaTime()
                reader = VoiceLevelReader(url: url)
            }
            return reader?.read() ?? .silent
        }
    }
}
