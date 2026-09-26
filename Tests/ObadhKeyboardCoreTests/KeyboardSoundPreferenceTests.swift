import Foundation
import XCTest
@testable import ObadhKeyboardCore

final class KeyboardSoundPreferenceTests: XCTestCase {
    func testSoundsDefaultOnAndPersistIndependentlyOfHaptics() throws {
        let suite = "KeyboardSoundPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyboardPreferences(defaults: defaults)
        XCTAssertTrue(preferences.typingSoundsEnabled)
        preferences.typingSoundsEnabled = false
        let reloaded = KeyboardPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(reloaded.typingSoundsEnabled)
        XCTAssertTrue(reloaded.hapticFeedbackEnabled)
        reloaded.hapticFeedbackEnabled = false
        reloaded.typingSoundsEnabled = true
        XCTAssertTrue(preferences.typingSoundsEnabled)
        XCTAssertFalse(preferences.hapticFeedbackEnabled)
    }
}
