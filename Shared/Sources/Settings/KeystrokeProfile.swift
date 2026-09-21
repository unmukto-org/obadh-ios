#if DEBUG
import Foundation
import os
import QuartzCore

/// DEBUG-only per-keystroke profiler, so typing latency is diagnosed from device
/// measurements instead of from reasoning about the code.
///
/// It splits the main-thread cost of one keypress into the three things that can
/// take time:
///
///   engine  - the Rust transliteration, measured at ~0.001 ms
///   proxy   - UITextDocumentProxy traffic, which is synchronous XPC to the HOST app:
///             every `documentContextBeforeInput` read and every insert/delete is a
///             round-trip out of our process and back
///   render  - suggestion bar update, key restyling, layout
///
/// Results are STREAMED, not stored. An earlier version persisted samples to the
/// App Group for an in-app viewer; that was the wrong channel (the extension and the
/// app did not reliably resolve the same container) and it is unnecessary, because
/// the device already has a log stream over USB:
///
///     idevicesyslog -u <udid> -m OBADH-
///
/// Read it together with OBADH-FRAMES and OBADH-STALL from KeyboardViewController:
/// on an iPhone 16e this trio localised a 3.7-SECOND main-thread stall to the haptic
/// engine, while every path here stayed near 1 ms.
///
/// Thread-safe rather than actor-isolated ON PURPOSE: it is called from the proxy
/// accessors, and instrumentation must never be able to crash the thing it measures.
/// Compile-excluded from Release, which measures nothing and logs nothing.
final class KeystrokeProfile: @unchecked Sendable {
    static let shared = KeystrokeProfile()

    private let log = Logger(subsystem: "org.unmukto.obadh.keyboard", category: "perf")
    private let lock = NSLock()
    private var keystrokeStart: CFTimeInterval = 0
    private var engineAccum: Double = 0
    private var proxyAccum: Double = 0
    private var calls = (context: 0, delete: 0, insert: 0)
    private var recording = false

    enum ProxyCall { case context, delete, insert }

    func beginKeystroke() {
        lock.lock(); defer { lock.unlock() }
        recording = true
        keystrokeStart = CACurrentMediaTime()
        engineAccum = 0
        proxyAccum = 0
        calls = (0, 0, 0)
    }

    func measureEngine<T>(_ body: () -> T) -> T {
        let t0 = CACurrentMediaTime()
        let value = body()
        let elapsed = (CACurrentMediaTime() - t0) * 1000
        lock.lock(); if recording { engineAccum += elapsed }; lock.unlock()
        return value
    }

    func measureProxy<T>(_ kind: ProxyCall, _ body: () -> T) -> T {
        let t0 = CACurrentMediaTime()
        let value = body()
        let elapsed = (CACurrentMediaTime() - t0) * 1000
        lock.lock()
        if recording {
            proxyAccum += elapsed
            switch kind {
            case .context: calls.context += 1
            case .delete: calls.delete += 1
            case .insert: calls.insert += 1
            }
        }
        lock.unlock()
        return value
    }

    func endKeystroke() {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
        recording = false
        let total = (CACurrentMediaTime() - keystrokeStart) * 1000
        let render = max(0, total - engineAccum - proxyAccum)
        let all = calls.context + calls.delete + calls.insert
        log.notice("OBADH-PERF total \(total, privacy: .public) engine \(self.engineAccum, privacy: .public) proxy \(self.proxyAccum, privacy: .public) render \(render, privacy: .public) calls \(all, privacy: .public) ctx \(self.calls.context, privacy: .public) del \(self.calls.delete, privacy: .public) ins \(self.calls.insert, privacy: .public)")
    }
}
#endif
