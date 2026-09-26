import XCTest

@MainActor
final class KeyboardSoundSettingsUITests: XCTestCase {
    func testTypingSoundSwitchPersistsAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--screen=settings"]
        app.launch()
        let toggle = app.switches["typing-sounds-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        // SwiftUI exposes the entire row as the switch; tap its trailing control.
        let original = try XCTUnwrap(toggle.value as? String)
        defer {
            if toggle.exists, toggle.value as? String != original { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let changed = original == "1" ? "0" : "1"
        XCTAssertEqual(toggle.value as? String, changed)
        app.terminate()
        app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, changed)
        XCTAssertTrue(app.staticTexts["Typing sounds follow Silent Mode and Settings › Sounds & Haptics › Keyboard Feedback › Sound."].exists)
    }
}
