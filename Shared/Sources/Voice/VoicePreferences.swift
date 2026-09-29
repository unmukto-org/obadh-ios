import Foundation

/// Voice settings that both processes read, stored in the App Group suite beside
/// `KeyboardPreferences`. Everything else about voice (models, permissions) is the
/// app's business: the keyboard only needs to know whether to show the mic.
struct VoicePreferences {
    private static let micButtonEnabledKey = "voice.micButtonEnabled"
    private static let activeStreamingModelKey = "voice.activeStreamingModel"
    private static let activeRefinerModelKey = "voice.activeRefinerModel"
    private static let refinementEnabledKey = "voice.refinementEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = KeyboardPreferences.sharedDefaults) {
        self.defaults = defaults
    }

    /// Whether the keyboard shows the mic at the head of the suggestion strip.
    var micButtonEnabled: Bool {
        get { defaults.object(forKey: Self.micButtonEnabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.micButtonEnabledKey) }
    }

    /// Whether finished phrases are re-transcribed by the larger model.
    var refinementEnabled: Bool {
        get { defaults.object(forKey: Self.refinementEnabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.refinementEnabledKey) }
    }

    var activeStreamingModelID: String? {
        get { defaults.string(forKey: Self.activeStreamingModelKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.activeStreamingModelKey) }
    }

    var activeRefinerModelID: String? {
        get { defaults.string(forKey: Self.activeRefinerModelKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.activeRefinerModelKey) }
    }
}
