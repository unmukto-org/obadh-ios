import XCTest

@testable import ObadhKeyboardCore

final class VoicePreferencesTests: XCTestCase {
  func testVoiceTypingDefaultsOffAndExplicitChoicePersists() throws {
    let suite = "voice-default-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let preferences = VoicePreferences(defaults: defaults)
    XCTAssertFalse(preferences.micButtonEnabled)
    preferences.micButtonEnabled = true
    XCTAssertTrue(VoicePreferences(defaults: defaults).micButtonEnabled)
    preferences.micButtonEnabled = false
    XCTAssertFalse(VoicePreferences(defaults: defaults).micButtonEnabled)
  }
}
