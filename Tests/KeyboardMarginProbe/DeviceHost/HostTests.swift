import XCTest

@MainActor
final class HostTests: XCTestCase {
    private func select(_ name: String, in app: XCUIApplication) {
        let globe = app.buttons["Next keyboard"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5))
        globe.press(forDuration: 1)
        let choice = app.staticTexts[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        XCTAssertTrue(choice.waitForNonExistence(timeout: 5))
    }

    private func height(_ app: XCUIApplication) throws -> Double {
        try XCTUnwrap(Double(try XCTUnwrap(app.staticTexts["probe-host-height"].value as? String)))
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        // Keep the whole screen so it can be compared with the test recording.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHostReloadPreservesTextAndSelection() throws {
        try checkRepair(button: "Reload input views")
    }

    func testHostRepresentationPreservesTextAndSelection() throws {
        try checkRepair(button: "Re-present keyboard")
    }

    func testHostRepresentationWithSelectionFirst() throws {
        // Distinguish selection dependence from the order of repeated attempts.
        try checkRepair(button: "Re-present keyboard", selections: [true])
    }

    func testRepeatedHostRepresentationWithoutSelection() throws {
        try checkRepair(button: "Re-present keyboard", selections: [false, false, false])
    }

    func testSettledSwitchAppearance() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.unmukto.obadh.marginhostprobe")
        app.launch()
        for source in ["English (US)", "Emoji"] {
            select(source, in: app)
            select("Obadh", in: app)
            capture("switch-immediate-\(source)", in: app)
            // Deliberately observe the settled compositor, not just AX menu exit.
            Thread.sleep(forTimeInterval: 8)
            capture("switch-settled-\(source)", in: app)
            XCTAssertEqual(app.textViews["probe-editor"].value as? String, "hello ")
        }
    }

    private func checkRepair(button: String, selections: [Bool] = [false, true]) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.unmukto.obadh.marginhostprobe")
        app.launch()
        for selected in selections {
            select("English (US)", in: app)
            select("Obadh", in: app)
            let baseline = try height(app)
            if selected { app.buttons["Select test word"].tap() }
            select("Emoji", in: app)
            select("Obadh", in: app)
            capture("before-reload-selection-\(selected)", in: app)
            let before = try height(app)
            app.buttons[button].tap()
            let result = app.staticTexts["probe-reload-result"]
            let expected = "text=true selection=true focus=true mode=true"
            let predicate = NSPredicate(format: "value BEGINSWITH %@", "text=")
            expectation(for: predicate, evaluatedWith: result)
            waitForExpectations(timeout: 5)
            capture("after-reload-selection-\(selected)", in: app)
            let after = try height(app)
            let status = result.value as? String
            print("DEVICE-HOST-COMPARISON repair=\(button) selected=\(selected) baseline=\(baseline) before=\(before) after=\(after) preservation=\(status ?? "missing")")
            XCTAssertEqual(status, expected, "Repair must preserve the editor and selected input mode")
            XCTAssertEqual(app.textViews["probe-editor"].value as? String, "hello ")
            XCTAssertEqual(baseline - before, 17, accuracy: 1, "Must first reproduce the defect")
            XCTAssertEqual(after, baseline, accuracy: 1, "Host repair should restore original height")
        }
    }
}
