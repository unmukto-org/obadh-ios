import XCTest

@MainActor
final class ReproTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "org.unmukto.obadh.marginrepro")

    func testEnableKeyboard() {
        continueAfterFailure = false
        app.launch()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        for _ in 0..<5 where settings.navigationBars.buttons["BackButton"].firstMatch.exists {
            settings.navigationBars.buttons["BackButton"].firstMatch.tap()
        }
        let general = settings.staticTexts["General"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        general.tap()
        let keyboard = settings.staticTexts["Keyboard"].firstMatch
        for _ in 0..<4 where !keyboard.isHittable { settings.swipeUp() }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        let keyboards = settings.cells["KEYBOARDS"].firstMatch
        XCTAssertTrue(keyboards.waitForExistence(timeout: 5))
        keyboards.tap()
        if !settings.cells.containing(.staticText, identifier: "Margin Repro").firstMatch.exists {
            let add = settings.cells["AddNewKeyboard"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
            let choice = settings.staticTexts["Margin Repro"].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
        }
        app.activate()
        select("Margin Repro")
        XCTAssertTrue(app.buttons["Insert a"].waitForExistence(timeout: 5))
    }

    func testHeightIsStable() throws {
        continueAfterFailure = false
        app.launch()
        var heights: [Double] = []
        for source in ["English (US)", "Emoji"] {
            select(source)
            select("Margin Repro")
            Thread.sleep(forTimeInterval: 2)
            heights.append(try measuredHeight())
            capture(source)
            XCTAssertEqual(app.staticTexts["extension-height"].value as? String, "180.0")
        }
        XCUIDevice.shared.press(.home)
        app.activate()
        Thread.sleep(forTimeInterval: 2)
        heights.append(try measuredHeight())
        capture("foreground")
        XCTAssertEqual(app.textViews["probe-editor"].value as? String, "hello ")
        print("STANDALONE-MARGIN english=\(heights[0]) emoji=\(heights[1]) foreground=\(heights[2]) content=180")
        XCTAssertEqual(heights[1], heights[0], accuracy: 1, "System container height must be independent of the preceding keyboard")
        XCTAssertEqual(heights[2], heights[0], accuracy: 1)
    }

    func testInputWorks() {
        continueAfterFailure = false
        app.launch()
        select("Margin Repro")
        let key = app.buttons["Insert a"]
        print("STANDALONE-KEY frame=\(key.frame)")
        key.tap()
        expectation(for: NSPredicate(format: "value == %@", "tapped"), evaluatedWith: key)
        waitForExpectations(timeout: 3)
        expectation(for: NSPredicate(format: "value == %@", "hello a"),
                    evaluatedWith: app.textViews["probe-editor"])
        waitForExpectations(timeout: 3)
    }

    private func select(_ name: String) {
        let globe = app.buttons["Next keyboard"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5))
        globe.press(forDuration: 1)
        let choice = app.staticTexts[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        XCTAssertTrue(choice.waitForNonExistence(timeout: 5))
    }

    private func measuredHeight() throws -> Double {
        try XCTUnwrap(Double(try XCTUnwrap(app.staticTexts["probe-host-height"].value as? String)))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "standalone-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
