/// Semantic routing for the differentiated-sound candidate. Actual playback
/// and its permission/settings gates belong to KeyboardFeedbackController.
enum KeyboardClickSound: Equatable {
    case input
    case delete
    case modifier

    init(key: KeyboardKey) {
        switch key {
        case .backspace:
            self = .delete
        case .space, .returnKey, .shift, .modeSwitch, .emoji:
            self = .modifier
        case .character, .symbol, .globe, .tab, .capsLock, .hideKeyboard:
            // Keep the previous click on keys not covered by the phone comparison.
            self = .input
        }
    }
}
