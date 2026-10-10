import XCTest

final class AccuracyLabUITests: XCTestCase {
    @MainActor
    func testSwipeStudyRecordsOnePromptedGesture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-swipe-study"]
        app.launch()
        let next = app.buttons["swipe-study-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        XCTAssertTrue(app.staticTexts["আমি  ·  ami"].exists)
        XCTAssertFalse(next.isEnabled)
        let start = app.buttons["a"].firstMatch
        let end = app.buttons["i"].firstMatch
        XCTAssertTrue(start.exists && end.exists)
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                thenDragTo: end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(next.isEnabled)
        XCTAssertTrue(app.buttons["Retry gesture"].exists)
        next.tap()
        XCTAssertTrue(app.buttons["Export recorded gestures"].exists)
        XCTAssertTrue(app.staticTexts["তুমি  ·  tumi"].exists)
    }

    @MainActor
    func testPracticeAcceptsTouchesAndSavesTrial() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-accuracy-ui-test"]
        app.launch()
        XCTAssertTrue(app.buttons["Begin"].waitForExistence(timeout: 10))
        app.buttons["Begin"].tap()
        for letter in ["a", "b"] {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", letter)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
        }
        XCTAssertTrue(app.staticTexts["ab"].exists)
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "a")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Accuracy lab typing"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Next"].tap()
        XCTAssertTrue(app.buttons["Export results"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Round 2 of")).firstMatch.exists)
    }
}
