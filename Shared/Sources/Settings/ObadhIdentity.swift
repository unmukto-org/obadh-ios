import Foundation

/// Who this build is, resolved at runtime instead of spelled out in source.
///
/// The build-time source of truth is `Config/Identity.xcconfig`; everything here
/// reads back off the bundle so renaming the product is a one-line edit there.
/// Before this existed, the keyboard's identifier was written out in Swift, which
/// meant a temporary bundle-id workaround for a provisioning quota silently broke
/// the app's "is the keyboard enabled?" check — the app kept looking for an
/// extension id the build no longer had.
enum ObadhIdentity {
    /// The container app's identifier, whichever target is asking. Inside the
    /// keyboard extension `Bundle.main` is the EXTENSION, so the suffix is
    /// stripped to get back to the app.
    static let appBundleID: String = {
        let identifier = Bundle.main.bundleIdentifier ?? fallbackAppBundleID
        guard identifier.hasSuffix(keyboardSuffix) else { return identifier }
        return String(identifier.dropLast(keyboardSuffix.count))
    }()

    /// The keyboard extension's identifier — what `AppleKeyboards` lists once the
    /// user enables us, and what `KeyboardInstallState` looks for.
    static var keyboardBundleID: String { appBundleID + keyboardSuffix }

    /// The shared container holding learned words and preferences.
    ///
    /// Deliberately NOT derived from `appBundleID`: it is the user's data, and a
    /// rename must not silently repoint both processes at an empty container. It
    /// comes from the Info.plist value the build stamps from `OBADH_APP_GROUP`,
    /// and only falls back to a derived name when that is missing (SwiftPM test
    /// bundles, which have no such key and no entitlement either).
    static let appGroupID: String = {
        let key = "OBADHAppGroup"
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           !value.isEmpty,
           !value.hasPrefix("$(") {
            return value
        }
        return "group." + appBundleID
    }()

    private static let keyboardSuffix = ".keyboard"
    /// Only reached when there is no bundle at all, i.e. a unit-test host.
    private static let fallbackAppBundleID = "org.unmukto.obadh"
}
