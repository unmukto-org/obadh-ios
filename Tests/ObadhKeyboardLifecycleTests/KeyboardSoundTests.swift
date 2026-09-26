import XCTest
import UIKit

@MainActor
final class KeyboardSoundTests: XCTestCase {
    func testInputViewOptsIntoSystemKeyboardClicks() throws {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        let inputView = try XCTUnwrap(controller.inputView)
        XCTAssertNotNil(inputView as? UIInputViewAudioFeedback)
        XCTAssertEqual(inputView.inputViewStyle, .default)
        XCTAssertTrue(inputView.allowsSelfSizing)
    }

    func testClickRoutingRespectsPreferenceAccessAndReload() throws {
        let suite = "KeyboardSoundTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyboardPreferences(defaults: defaults)
        preferences.hapticFeedbackEnabled = false
        var clicks = 0
        let feedback = KeyboardFeedbackController(preferences: preferences) { clicks += 1 }
        let input = KeyboardInputView(frame: .zero, inputViewStyle: .default)
        input.inputClicksEnabled = { feedback.inputClicksEnabled }

        func typeAndCorrect() {
            feedback.keyTouched(.character("a"))
            feedback.suggestionAccepted()
            feedback.backspaceRepeated(unit: .character)
            feedback.backspaceRepeated(unit: .word)
        }

        // No access: neither the view nor callers enable clicks.
        feedback.prepare(hasFullAccess: false)
        XCTAssertFalse(input.enableInputClicksWhenVisible)
        typeAndCorrect()
        XCTAssertEqual(clicks, 0)

        // Sounds work independently of disabled haptics, once access is granted.
        feedback.prepare(hasFullAccess: true)
        XCTAssertTrue(input.enableInputClicksWhenVisible)
        typeAndCorrect()
        XCTAssertEqual(clicks, 4)

        // A settings change is picked up when the existing keyboard reappears.
        KeyboardPreferences(defaults: defaults).typingSoundsEnabled = false
        feedback.prepare(hasFullAccess: true)
        XCTAssertFalse(input.enableInputClicksWhenVisible)
        typeAndCorrect()
        XCTAssertEqual(clicks, 4)

        preferences.typingSoundsEnabled = true
        feedback.prepare(hasFullAccess: true)
        typeAndCorrect()
        XCTAssertEqual(clicks, 8)

        feedback.prepare(hasFullAccess: false)
        XCTAssertFalse(input.enableInputClicksWhenVisible)
        typeAndCorrect()
        XCTAssertEqual(clicks, 8)
    }
}
