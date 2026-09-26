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
        let feedback = KeyboardFeedbackController(preferences: preferences, requestSystemClick: { _ in clicks += 1 })
        let input = KeyboardInputView(frame: .zero, inputViewStyle: .default)
        input.inputClicksEnabled = { feedback.inputClicksEnabled }

        func typeAndCorrect() {
            feedback.keyTouched(.character("a"))
            feedback.keyTouched(.space)
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
        XCTAssertEqual(clicks, 5)

        // A settings change is picked up when the existing keyboard reappears.
        KeyboardPreferences(defaults: defaults).typingSoundsEnabled = false
        feedback.prepare(hasFullAccess: true)
        XCTAssertFalse(input.enableInputClicksWhenVisible)
        typeAndCorrect()
        XCTAssertEqual(clicks, 5)

        preferences.typingSoundsEnabled = true
        feedback.prepare(hasFullAccess: true)
        typeAndCorrect()
        XCTAssertEqual(clicks, 10)

        feedback.prepare(hasFullAccess: false)
        XCTAssertFalse(input.enableInputClicksWhenVisible)
        typeAndCorrect()
        XCTAssertEqual(clicks, 10)
    }

    func testEachFeedbackEventRequestsExactlyItsSound() throws {
        let suite = "KeyboardSoundRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyboardPreferences(defaults: defaults)
        preferences.hapticFeedbackEnabled = false
        var sounds: [KeyboardClickSound] = []
        let feedback = KeyboardFeedbackController(preferences: preferences, requestSystemClick: { sounds.append($0) })
        feedback.prepare(hasFullAccess: true)
        let keys: [KeyboardKey] = [.character("a"), .backspace, .returnKey, .space,
                                   .shift, .modeSwitch("123"), .modeSwitch("ABC"), .emoji]
        keys.forEach(feedback.keyTouched)
        feedback.suggestionAccepted()
        for unit: BackspaceDeletionUnit in [.character, .word, .sentence, .availableContext] {
            feedback.backspaceRepeated(unit: unit)
        }
        XCTAssertEqual(sounds, [.input, .delete, .modifier, .modifier, .modifier,
                                .modifier, .modifier, .modifier, .input,
                                .delete, .delete, .delete, .delete])
        let enabledCount = sounds.count
        preferences.typingSoundsEnabled = false
        feedback.reloadPreferences()
        keys.forEach(feedback.keyTouched)
        feedback.backspaceRepeated(unit: .character)
        feedback.suggestionAccepted()
        XCTAssertEqual(sounds.count, enabledCount, "The app switch must gate all three sound types")
    }

    func testNoFullAccessSkipsAllFeedbackWorkEvenDuringRapidTyping() throws {
        let suite = "KeyboardNoAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyboardPreferences(defaults: defaults)
        let fallback = RecordingImpactFeedbackGenerator(style: .rigid)
        var engineCreations = 0
        var sounds = 0
        let feedback = KeyboardFeedbackController(
            preferences: preferences, fallbackFeedback: fallback, supportsHaptics: true,
            makeHapticEngine: { engineCreations += 1; throw FeedbackTestError.unavailable }
        ) { _ in sounds += 1 }
        feedback.prepare(hasFullAccess: false)
        for _ in 0..<1_000 {
            feedback.keyTouched(.character("a"))
            feedback.keyTouched(.space)
            feedback.keyTouched(.backspace)
            feedback.backspaceRepeated(unit: .word)
            feedback.suggestionAccepted()
        }
        XCTAssertEqual(engineCreations, 0)
        XCTAssertEqual(sounds, 0)
        XCTAssertEqual(fallback.preparations, 0)
        XCTAssertEqual(fallback.impacts, 0)

        // After access was granted and then revoked, all paths must go quiet again.
        feedback.prepare(hasFullAccess: true)
        feedback.keyTouched(.character("a"))
        XCTAssertEqual(engineCreations, 1)
        let impactsBeforeRevocation = fallback.impacts
        let preparationsBeforeRevocation = fallback.preparations
        let soundsBeforeRevocation = sounds
        feedback.prepare(hasFullAccess: false)
        feedback.keyTouched(.space)
        feedback.backspaceRepeated(unit: .character)
        feedback.suggestionAccepted()
        XCTAssertEqual(engineCreations, 1)
        XCTAssertEqual(sounds, soundsBeforeRevocation)
        XCTAssertEqual(fallback.impacts, impactsBeforeRevocation)
        XCTAssertEqual(fallback.preparations, preparationsBeforeRevocation)
    }

    func testFailedHapticEngineIsNotRetriedByKeystrokes() throws {
        let suite = "KeyboardFailedFeedbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var engineCreations = 0
        let feedback = KeyboardFeedbackController(
            preferences: KeyboardPreferences(defaults: defaults),
            fallbackFeedback: RecordingImpactFeedbackGenerator(style: .rigid), supportsHaptics: true,
            makeHapticEngine: { engineCreations += 1; throw FeedbackTestError.unavailable }
        ) { _ in }
        feedback.prepare(hasFullAccess: true)
        for _ in 0..<1_000 { feedback.keyTouched(.character("a")) }
        feedback.prepare(hasFullAccess: true)
        XCTAssertEqual(engineCreations, 1, "Failed engine creation must not be retried on each key or presentation")
    }

}


private enum FeedbackTestError: Error { case unavailable }

@MainActor
private final class RecordingImpactFeedbackGenerator: UIImpactFeedbackGenerator {
    var preparations = 0
    var impacts = 0
    override func prepare() { preparations += 1 }
    override func impactOccurred(intensity: CGFloat) { impacts += 1 }
}
