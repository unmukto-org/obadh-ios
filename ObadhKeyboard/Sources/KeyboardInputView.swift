import UIKit

/// UIKit queries the input view, not its controller, before playing input clicks.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var inputClicksEnabled: () -> Bool = { false }

    var enableInputClicksWhenVisible: Bool { inputClicksEnabled() }
}
