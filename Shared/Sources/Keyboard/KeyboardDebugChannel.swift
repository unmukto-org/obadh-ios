#if DEBUG
import Foundation
import os

/// DEBUG-ONLY agentic control channel for the keyboard extension.
///
/// SECURITY / SAFETY: this entire file is inside `#if DEBUG`, so it is
/// compile-time excluded from Release builds — the polling, input-mode
/// advancement, and any state injection it enables are *physically absent* from
/// the shipping binary (verified: the Release config defines neither `DEBUG`
/// nor `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`). It must NEVER be enabled in
/// Release: a keyboard that advances input modes or mutates state on external
/// command is a keylogger-class risk and an automatic App Store rejection.
///
/// Transport is a single-line command file in the shared App Group container,
/// which only the app + this extension can read (sandboxed, no network, no
/// remote trigger). A dev tool (`scripts/sim-kbd.py debug <cmd>`) writes the
/// file; this channel polls it while the keyboard is on screen and dispatches
/// to the handler. Every command is echoed to os_log for observability.
@MainActor
protocol KeyboardDebugCommandHandler: AnyObject {
    func handleDebugCommand(_ command: String, argument: String?)
}

@MainActor
final class KeyboardDebugChannel {
    private weak var handler: KeyboardDebugCommandHandler?
    private var timer: Timer?
    private let log = Logger(subsystem: "org.unmukto.obadh.keyboard", category: "debug")
    private let commandURL: URL?

    init(handler: KeyboardDebugCommandHandler) {
        self.handler = handler
        self.commandURL = Self.makeCommandURL()
    }

    /// `<base>/obadh-debug/command` — the dev tool writes here; we consume it.
    /// Prefers the shared App Group (works on device); falls back to the
    /// extension's own Caches dir on the Simulator, where unsigned builds don't
    /// provision App Groups but the container is still reachable from the Mac
    /// (`…/Containers/Data/PluginKitPlugin/<uuid>/Library/Caches/`), which is
    /// where `scripts/sim-kbd.py debug` writes.
    private static func makeCommandURL() -> URL? {
        let fileManager = FileManager.default
        let base: URL
        if let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroupIdentifier
        ) {
            base = group
        } else if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            base = caches
        } else {
            return nil
        }
        let dir = base.appendingPathComponent("obadh-debug", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("command", isDirectory: false)
    }

    func start() {
        guard let commandURL, timer == nil else { return }
        // Clear any stale command from a previous session so we don't replay it.
        try? FileManager.default.removeItem(at: commandURL)
        log.notice("OBADH-DEBUG channel start path=\(commandURL.path, privacy: .public)")
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let commandURL,
              let raw = try? String(contentsOf: commandURL, encoding: .utf8) else { return }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        try? FileManager.default.removeItem(at: commandURL) // consume once

        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        let command = parts[0]
        let argument = parts.count > 1 ? parts[1] : nil
        log.notice("OBADH-DEBUG cmd=\(command, privacy: .public) arg=\(argument ?? "", privacy: .public)")
        handler?.handleDebugCommand(command, argument: argument)
    }
}
#endif
