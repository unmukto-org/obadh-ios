import Foundation

/// Which keyword language the emoji-panel search runs in. English is the default;
/// the Bangla index loads lazily only when this is `.bangla`.
enum EmojiSearchLanguage: String {
    case english
    case bangla

    var toggled: EmojiSearchLanguage { self == .english ? .bangla : .english }
    /// Short label for the in-search toggle button.
    var shortLabel: String { self == .english ? "EN" : "বাং" }
}

struct KeyboardPreferences {
    static var appGroupIdentifier: String { ObadhIdentity.appGroupID }
    private static let hapticFeedbackEnabledKey = "keyboard.hapticFeedbackEnabled"
    private static let emojiSearchLanguageKey = "keyboard.emojiSearchLanguage"
    private static let fullAccessConfirmedAtKey = "keyboard.fullAccessConfirmedAt"
    private static let autoInsertTopCorrectionKey = "keyboard.autoInsertTopCorrection"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = KeyboardPreferences.sharedDefaults) {
        self.defaults = defaults
    }

    var hapticFeedbackEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.hapticFeedbackEnabledKey) != nil else {
                return true
            }
            return defaults.bool(forKey: Self.hapticFeedbackEnabledKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.hapticFeedbackEnabledKey)
        }
    }

    /// Default language the emoji search opens in (set in the Obadh app). The
    /// in-search EN⇄BN toggle overrides it for the current session.
    var defaultEmojiSearchLanguage: EmojiSearchLanguage {
        get {
            EmojiSearchLanguage(rawValue: defaults.string(forKey: Self.emojiSearchLanguageKey) ?? "")
                ?? .english
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.emojiSearchLanguageKey)
        }
    }

    /// Opt-in, off by default: when a typed word isn't a real word and a confident
    /// correction exists, space/return commit the correction and the shown word is
    /// offered in quotes to keep instead. Off, typing commits exactly what is shown.
    var autoInsertTopCorrection: Bool {
        get { defaults.bool(forKey: Self.autoInsertTopCorrectionKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.autoInsertTopCorrectionKey) }
    }

    /// Stamped by the keyboard extension every time it launches with Full Access.
    ///
    /// A keyboard without Full Access cannot reach the shared App Group container at
    /// all, so a value here is proof that access was granted. Its *absence* proves
    /// nothing — the keyboard may simply never have run. Revoking access likewise
    /// leaves the last stamp behind, since the extension can no longer write to clear
    /// it. Treat this as "confirmed" versus "unconfirmed", never as on versus off.
    var fullAccessConfirmedAt: Date? {
        get { defaults.object(forKey: Self.fullAccessConfirmedAtKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.fullAccessConfirmedAtKey) }
    }

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    #if DEBUG
    // DEBUG-only live haptic tuning: the container app writes these from on-screen
    // sliders and the keyboard extension reads them per keystroke, so haptic feel
    // can be dialed in on real hardware without rebuilds. Compile-excluded from
    // Release. Defaults mirror the shipped letter tick (intensity 0.8/sharpness
    // 0.75). See KeyboardFeedbackController + KeyboardTestViewController.
    private static let debugHapticOverrideKey = "debug.hapticOverrideEnabled"
    private static let debugHapticIntensityKey = "debug.hapticIntensity"
    private static let debugHapticSharpnessKey = "debug.hapticSharpness"

    var debugHapticOverrideEnabled: Bool {
        get { defaults.bool(forKey: Self.debugHapticOverrideKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.debugHapticOverrideKey) }
    }

    var debugHapticIntensity: Double {
        get { defaults.object(forKey: Self.debugHapticIntensityKey) as? Double ?? 0.5 }
        nonmutating set { defaults.set(newValue, forKey: Self.debugHapticIntensityKey) }
    }

    var debugHapticSharpness: Double {
        get { defaults.object(forKey: Self.debugHapticSharpnessKey) as? Double ?? 0.9 }
        nonmutating set { defaults.set(newValue, forKey: Self.debugHapticSharpnessKey) }
    }

    // NOTE: the live key-tint/shadow override system was removed deliberately. Its
    // prefs persisted in the App Group across reinstalls and silently re-themed the
    // keyboard (near-white keys in dark mode) long after the tuning session ended.
    // Tuned values are baked into KeyboardTheme; render code reads no debug prefs.
    static let debugKeyTintDarwinName = "org.unmukto.obadh.debug.keytint"

    // On-keyboard overlay that dumps the presentation context the system hands us
    // (bounds, safe-area insets, window width, nearest rounded-corner ancestor). Lets
    // us read how iOS 26/27 frames the extension in different host apps (Messenger vs
    // Safari vs a legacy app) without a Mac log stream, then adapt to match.
    private static let debugPresentationProbeKey = "debug.presentationProbeEnabled"

    var debugPresentationProbeEnabled: Bool {
        get { defaults.bool(forKey: Self.debugPresentationProbeKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.debugPresentationProbeKey) }
    }

    /// Sizing diagnosis: pins the presentation class instead of detecting it, so a
    /// capture run holds OUR asked height constant across presentations. If the
    /// system's container band still varies while pinned, the band is genuinely
    /// nondeterministic; if it stops varying, our own mid-presentation height
    /// changes were driving it. 0 = auto (shipping detector), 1 = banded, 2 = bandless.
    private static let debugPinnedPresentationKey = "debug.pinnedPresentation"

    var debugPinnedPresentation: Int {
        get { defaults.integer(forKey: Self.debugPinnedPresentationKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.debugPinnedPresentationKey) }
    }

    /// Fire a cross-process Darwin notification so the running keyboard re-reads the
    /// tint and re-styles its keys immediately (the extension is a separate process).
    static func postKeyTintChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(debugKeyTintDarwinName as CFString),
            nil, nil, true
        )
    }
    #endif
}
