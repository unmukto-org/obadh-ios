import XCTest

@MainActor
final class KeyboardFieldContextUITests: XCTestCase {
    private func selectObadh(_ app: XCUIApplication) {
        select("Obadh", app)
    }

    private func select(_ name: String, _ app: XCUIApplication) {
        let globe = app.buttons["Next keyboard"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 10), app.debugDescription)
        globe.press(forDuration: 1)
        let choice = app.staticTexts[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
    }

    func testNativeReturnInTheSameHost() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-field-test"]
        app.launch()
        defer { app.terminate() }
        select("English (US)", app)
        let predicate = NSPredicate(format: "label ==[c] %@", "send")
        let key = app.keyboards.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5), app.debugDescription)
        key.tap()
        XCTAssertTrue(app.staticTexts["field-action-status"].label.hasPrefix("field-prose:"), app.debugDescription)
        app.textFields["field-search"].tap()
        let go = app.keyboards.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] %@", "go")).firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func press(_ title: String, _ app: XCUIApplication) {
        let key = app.buttons[title].firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5), "Missing key: \(title)\n" + app.debugDescription)
        XCTAssertTrue(key.isEnabled)
        // The transparent touch surface intentionally covers semantic buttons.
        // XCTest's element.tap can fall back to accessibility instead of a finger.
        // Coordinates exercise the actual touch resolver at the visible key centre.
        XCTAssertGreaterThan(key.frame.width, 8)
        XCTAssertGreaterThan(key.frame.height, 8)
        key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBothSmileAliasesOfferEmojiAndLiteralBeforeAutomaticReplacement() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-field-test"]
        app.launch()
        defer { app.terminate() }
        selectObadh(app)
        let prose = app.textFields["field-prose"]
        press("123", app)
        for key in [":", ")"] { press(key, app) }
        XCTAssertEqual(prose.value as? String, ":)")
        XCTAssertTrue(app.buttons["😃"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons[":)"].exists, app.debugDescription)
        capture("emoticon-smile-before-space", app)
        press("Space", app)
        XCTAssertEqual(prose.value as? String, "😃 ")
        press("Delete", app)
        XCTAssertEqual(prose.value as? String, ":)")
        press("Space", app)
        XCTAssertEqual(prose.value as? String, ":) ")
        for key in [":", "-", ")"] { press(key, app) }
        XCTAssertEqual(prose.value as? String, ":) :-)")
        XCTAssertTrue(app.buttons["😃"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons[":-)"].exists, app.debugDescription)
        capture("emoticon-nose-before-space", app)
        // Accept the exact literal through the real suggestion control.
        app.buttons[":-)"].tap()
        XCTAssertEqual(prose.value as? String, ":) :-) ")
        for key in [":", "-", ")"] { press(key, app) }
        press("Space", app)
        XCTAssertEqual(prose.value as? String, ":) :-) 😃 ")
        for key in [":", ")"] { press(key, app) }
        app.buttons["😃"].tap()
        XCTAssertEqual(prose.value as? String, ":) :-) 😃 😃 ")
    }

    func testReturnActionOnNativeTextField() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-field-test"]
        app.launch()
        defer { app.terminate() }
        selectObadh(app)
        for key in ["b", "u", "s"] { press(key, app) }
        press("Send", app)
        capture("custom-return-action", app)
        let verify = {
            XCTAssertEqual(app.staticTexts["field-action-status"].label, "field-prose: বাস")
            XCTAssertEqual(app.textFields["field-prose"].value as? String, "বাস")
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion == 26 && version.minorVersion == 5 {
            // Keep the expected failure narrow: arbitrary lost/mutated text or a
            // different host status must still fail qualification normally.
            let text = app.textFields["field-prose"].value as? String
            XCTAssertTrue(text == "বাস" || text == "বাস ", "Unexpected Return mutation: \(text ?? "nil")")
            let status = app.staticTexts["field-action-status"].label
            XCTAssertTrue(status == "Ready" || status == "field-prose: বাস", status)
            XCTExpectFailure("KI-005: iOS 26.5 converts the public proxy newline to a space instead of invoking UITextField Return; native reference passes", failingBlock: verify)
        } else {
            verify()
        }
    }

    // Obadh must already be enabled; the existing presentation test enables it.
    func testFieldHintsCrossTheRealKeyboardServiceAndPreserveInput() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-field-test"]
        app.launch()
        defer { app.terminate() }
        selectObadh(app)
        let prose = app.textFields["field-prose"]
        for key in ["b", "u", "s"] { press(key, app) }
        XCTAssertTrue(app.buttons["Send"].exists)
        press("Space", app)
        XCTAssertEqual(prose.value as? String, "বাস ")
        capture("field-prose", app)
        press("a", app) // Switch away with a live phonetic word still owned.
        let proseBeforeFocusChange = try XCTUnwrap(prose.value as? String)
        XCTAssertEqual(proseBeforeFocusChange, "বাস আ")

        let email = app.textFields["field-email"]
        email.tap()
        for key in ["a", "@", "b", ".", "c"] { press(key, app) }
        XCTAssertEqual(email.value as? String, "a@b.c")
        XCTAssertEqual(prose.value as? String, proseBeforeFocusChange)
        XCTAssertTrue(app.buttons["Next"].exists)
        capture("field-email", app)

        let url = app.textFields["field-url"]
        url.tap()
        for key in ["a", ".com", "/", "b"] { press(key, app) }
        XCTAssertEqual(url.value as? String, "a.com/b")
        XCTAssertTrue(app.buttons["Go"].exists)
        capture("field-url", app)

        let number = app.textFields["field-number"]
        number.tap()
        for key in ["1", "2", "0"] { press(key, app) }
        XCTAssertEqual(number.value as? String, "120")
        XCTAssertFalse(app.buttons["a"].exists)
        press("Delete", app)
        XCTAssertEqual(number.value as? String, "12")
        capture("field-number", app)

        let decimal = app.textFields["field-decimal"]
        decimal.tap()
        for key in ["1", ".", "2"] { press(key, app) }
        XCTAssertEqual(decimal.value as? String, "1.2")

        let search = app.textFields["field-search"]
        search.tap()
        // UIKit's web-search keyboard exposes Go, including on native English,
        // even though this host assigns returnKeyType = .search.
        XCTAssertTrue(app.buttons["Go"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Go"].isEnabled)
        press("a", app)
        XCTAssertTrue(app.buttons["Go"].isEnabled)
        XCTAssertTrue(app.buttons["."].exists)

        let code = app.textFields["field-code"]
        code.tap()
        for key in ["b", "u", "s"] { press(key, app) }
        XCTAssertEqual(code.value as? String, "bus")
        XCTAssertTrue(app.buttons["Done"].exists)

        let latin = app.textFields["field-latin"]
        latin.tap()
        for key in ["H", "e", "l", "l", "o"] { press(key, app) }
        XCTAssertEqual(latin.value as? String, "Hello")

        let uncorrected = app.textFields["field-uncorrected"]
        uncorrected.tap()
        for key in ["b", "u", "s"] { press(key, app) }
        let literal = try XCTUnwrap(uncorrected.value as? String)
        press("Space", app)
        XCTAssertEqual(uncorrected.value as? String, literal + " ")
        XCTAssertNotEqual(literal, "বাস")

        let multiline = app.textViews["field-multiline"]
        multiline.tap()
        for key in ["b", "u", "s"] { press(key, app) }
        press("Return", app)
        XCTAssertEqual(multiline.value as? String, "বাস\n")
        capture("field-multiline-return", app)
    }
}
