import XCTest

/// Run on a dedicated simulator: these tests temporarily change system appearance
/// preferences and restore the original values before returning.
@MainActor
final class KeyboardMaterialUITests: XCTestCase {
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func displayAccessibility(_ settings: XCUIApplication) {
        settings.activate()
        for _ in 0..<6 where !settings.navigationBars["Settings"].exists {
            let back = settings.navigationBars.buttons.firstMatch
            guard back.exists else { break }
            back.tap()
        }
        for _ in 0..<4 { settings.swipeDown() }
        let accessibility = settings.staticTexts["Accessibility"].firstMatch
        for _ in 0..<5 where !accessibility.isHittable { settings.swipeUp() }
        XCTAssertTrue(accessibility.waitForExistence(timeout: 5))
        accessibility.tap()
        let display = settings.staticTexts["Display & Text Size"].firstMatch
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        display.tap()
    }

    private func select(_ name: String, app: XCUIApplication) {
        let globe = app.buttons["Next keyboard"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5))
        globe.press(forDuration: 1)
        let choice = app.staticTexts[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        for _ in 0..<2 {
            choice.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: choice)
            if XCTWaiter.wait(for: [dismissed], timeout: 3) == .completed { return }
        }
        XCTFail("Keyboard selection menu did not dismiss")
    }

    private func set(_ toggle: XCUIElement, to value: String) {
        // A tap during Settings' foreground transition can be ignored. Re-read
        // the actual state before retrying, so we never toggle a successful tap back.
        for _ in 0..<2 {
            guard toggle.value as? String != value else { return }
            // Settings exposes the entire row as the switch's accessibility frame.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
            if XCTWaiter.wait(for: [updated], timeout: 3) == .completed { return }
        }
        XCTAssertEqual(toggle.value as? String, value)
    }

    /// Captures ink placement separately from key geometry and font size.
    func testNativeLetterCaseScreenshots() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test", "--measure-bg", "--seed=hello "]
        app.launch()
        try XCTSkipUnless(app.frame.size == CGSize(width: 440, height: 956), "Measured portrait fixture")
        for keyboard in ["English (US)", "Obadh"] {
            select(keyboard, app: app)
            XCTAssertTrue(app.descendants(matching: .any)["q"].firstMatch.waitForExistence(timeout: 5))
            capture("type-\(keyboard)-lowercase", app: app)
            // The already measured portrait shift-key centre. This avoids the
            // different accessibility roles of native and extension keys.
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 30, dy: 795)).tap()
            XCTAssertTrue(app.descendants(matching: .any)["Q"].firstMatch.waitForExistence(timeout: 5))
            capture("type-\(keyboard)-uppercase", app: app)
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 25, dy: 850)).tap()
            capture("type-\(keyboard)-numbers", app: app)
            XCTAssertEqual(app.textViews.firstMatch.value as? String, "hello ")
        }
    }

    func testMaterialsFollowAccessibilityPreferences() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test", "--measure-bg", "--seed=hello "]
        app.launch()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        displayAccessibility(settings)
        let transparency = settings.switches["Reduce Transparency"].firstMatch
        let contrast = settings.switches["Increase Contrast"].firstMatch
        for _ in 0..<3 where !transparency.isHittable { settings.swipeUp() }
        XCTAssertTrue(transparency.exists, settings.debugDescription)
        XCTAssertTrue(contrast.exists, settings.debugDescription)
        let originalTransparency = try XCTUnwrap(transparency.value as? String)
        let originalContrast = try XCTUnwrap(contrast.value as? String)
        defer {
            settings.activate()
            set(transparency, to: originalTransparency)
            set(contrast, to: originalContrast)
            app.activate()
        }
        for (name, reduced, increased) in [("default", false, false), ("reduced-transparency", true, false), ("increased-contrast", false, true)] {
            settings.activate()
            set(transparency, to: reduced ? "1" : "0")
            set(contrast, to: increased ? "1" : "0")
            XCTAssertEqual(transparency.value as? String, reduced ? "1" : "0")
            XCTAssertEqual(contrast.value as? String, increased ? "1" : "0")
            app.activate()
            select("English (US)", app: app)
            capture("material-\(name)-native", app: app)
            select("Obadh", app: app)
            let a = app.descendants(matching: .any)["a"].firstMatch
            XCTAssertTrue(a.waitForExistence(timeout: 5))
            capture("material-\(name)-obadh", app: app)
            XCTAssertEqual(app.textViews.firstMatch.value as? String, "hello ")
        }
        app.descendants(matching: .any)["a"].firstMatch.tap()
        XCTAssertNotEqual(app.textViews.firstMatch.value as? String, "hello ")
    }
}
