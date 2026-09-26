import Foundation
#if canImport(ObadhBridge)
import ObadhBridge
#endif

/// App identity comes from the bundle; engine identity comes from its C ABI.
/// In the app the bundle stamp reflects the
/// app bundle; in the keyboard extension it reflects the extension bundle — so
/// comparing the two confirms both halves are the same build (and that the
/// extension isn't serving a cached old binary). Values are stamped per build by
/// `scripts/stamp-build.sh` via Config/BuildInfo.xcconfig.
enum AppBuildInfo {
    /// Marketing version, e.g. "0.1.0" (CFBundleShortVersionString).
    static var shortVersion: String { string("CFBundleShortVersionString") }
    /// Build number — the git commit count, e.g. "8" (CFBundleVersion).
    static var buildNumber: String { string("CFBundleVersion") }
    /// Short git SHA, with "-dirty" when built from an uncommitted tree.
    static var gitRevision: String { string("OBADHGitRevision") }
    /// UTC build timestamp, e.g. "2026-07-06.2015".
    static var buildTime: String { string("OBADHBuildTime") }

    /// Read the linked engine's own semver, independently of the iOS app and C ABI.
    /// This metadata query does not create an engine or load any language models.
    static let engineVersion: String = {
        #if canImport(ObadhBridge)
        let count = obadh_engine_version(nil, 0)
        guard count > 0 else { return "Unavailable" }
        var bytes = [UInt8](repeating: 0, count: count)
        let written = bytes.withUnsafeMutableBufferPointer {
            obadh_engine_version($0.baseAddress, $0.count)
        }
        guard written == count else { return "Unavailable" }
        return String(bytes: bytes, encoding: .utf8) ?? "Unavailable"
        #else
        // The portable Swift package does not link the iOS engine framework.
        return "Unavailable"
        #endif
    }()

    /// One-line app, engine and source identity for support reports.
    static var summary: String {
        var parts = ["\(shortVersion) (\(buildNumber))"]
        parts.append("Engine \(engineVersion)")
        if !gitRevision.isEmpty { parts.append(gitRevision) }
        if !buildTime.isEmpty { parts.append(buildTime) }
        return parts.joined(separator: " · ")
    }

    private static func string(_ key: String) -> String {
        (Bundle.main.infoDictionary?[key] as? String) ?? ""
    }
}
