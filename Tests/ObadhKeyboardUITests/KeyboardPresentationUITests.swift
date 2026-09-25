import XCTest

@MainActor
final class KeyboardPresentationUITests: XCTestCase {
    func testNormalLaunchClearsExperimentalRibbonSizing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test", "--experimental-sizing"]
        app.launch()
        XCTAssertTrue(app.buttons["Next keyboard"].firstMatch.waitForExistence(timeout: 10))
        let bandless = app.buttons["Band-less"].firstMatch
        let scroll = app.scrollViews.firstMatch
        scroll.swipeUp()
        for _ in 0..<5 where !bandless.isHittable { scroll.swipeUp() }
        XCTAssertTrue(bandless.isHittable)
        bandless.tap()
        XCTAssertTrue(bandless.isSelected)

        app.terminate()
        app.launchArguments = ["--keyboard-test"]
        app.launch()
        XCTAssertFalse(app.buttons["Band-less"].exists,
                       "Experimental layout controls must not be everyday settings")

        // Reopen the explicit experiment screen to inspect the stored selection.
        app.terminate()
        app.launchArguments = ["--keyboard-test", "--experimental-sizing"]
        app.launch()
        let automatic = app.buttons["Auto"].firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        XCTAssertTrue(automatic.isSelected, "A normal launch must clear the persisted override")
        app.terminate()
    }

    func testEnableAndPresentKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test", "--measure-bg"]
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
        if !settings.cells.containing(.staticText, identifier: "Obadh").firstMatch.exists {
            let addKeyboard = settings.cells["AddNewKeyboard"].firstMatch
            XCTAssertTrue(addKeyboard.waitForExistence(timeout: 5), settings.debugDescription)
            addKeyboard.tap()
            let obadh = settings.staticTexts["Obadh"].firstMatch
            XCTAssertTrue(obadh.waitForExistence(timeout: 5), settings.debugDescription)
            obadh.tap()
        }
        app.terminate()
        app.launch()
        let globe = app.buttons["Next keyboard"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 10), app.debugDescription)
        globe.press(forDuration: 1)
        let choice = app.staticTexts["Obadh"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        XCTAssertTrue(app.descendants(matching: .any)["a"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "after-enabling"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func select(_ name: String, in app: XCUIApplication) {
        let globe = app.buttons["Next keyboard"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5), app.debugDescription)
        globe.press(forDuration: 1)
        let choice = app.staticTexts[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Run testEnableAndPresentKeyboard first on a fresh simulator. Both genuine
    // system menu switching and host foregrounding are exercised here; the text
    // input mode override is deliberately absent.
    func testRepeatedSwitchingAndForegrounding() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        for accessory in [false, true] {
            app.launchArguments = ["--keyboard-test", "--measure-bg", "--seed=hello "]
                + (accessory ? ["--accessory=44"] : [])
            app.launch()
            select("English (US)", in: app)
            capture("native-accessory-\(accessory)", app: app)
            select("Obadh", in: app)
            let a = app.descendants(matching: .any)["a"].firstMatch
            XCTAssertTrue(a.waitForExistence(timeout: 10))
            XCTAssertTrue(a.isEnabled, "Keys must be available to accessibility")
            let baseline = a.frame
            capture("obadh-cold-accessory-\(accessory)", app: app)
            for round in 1...2 {
                select("English (US)", in: app)
                select("Obadh", in: app)
                XCTAssertTrue(a.waitForExistence(timeout: 10))
                XCTAssertEqual(a.frame.minY, baseline.minY, accuracy: 1)
                XCTAssertEqual(a.frame.height, baseline.height, accuracy: 0.5)
                capture("obadh-switch-\(round)-accessory-\(accessory)", app: app)
            }
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(a.waitForExistence(timeout: 10))
            XCTAssertEqual(a.frame.minY, baseline.minY, accuracy: 1)
            capture("obadh-foreground-accessory-\(accessory)", app: app)
            XCTAssertEqual(app.textViews.firstMatch.value as? String, "hello ")
            a.tap()
            XCTAssertNotEqual(app.textViews.firstMatch.value as? String, "hello ",
                              "Finger input must still pass through the touch surface")
            app.terminate()
        }
    }

    func testSwitchingFromSystemEmojiWithAccessory() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test", "--measure-bg", "--seed=hello ",
                               "--keyboard-default", "--accessory=44"]
        app.launch()
        select("English (US)", in: app)
        select("Obadh", in: app)
        let a = app.descendants(matching: .any)["a"].firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 10))
        let baseline = a.frame
        capture("from-English-with-accessory", app: app)
        let fromEnglishHeight = try XCTUnwrap(Double(try XCTUnwrap(
            app.staticTexts["keyboard-host-geometry"].value as? String)))
        select("Emoji", in: app)
        select("Obadh", in: app)
        XCTAssertTrue(a.waitForExistence(timeout: 10))
        XCTAssertEqual(a.frame.minY, baseline.minY, accuracy: 1)
        XCTAssertEqual(a.frame.height, baseline.height, accuracy: 0.5)
        capture("from-system-emoji-with-accessory", app: app)
        let fromEmojiHeight = try XCTUnwrap(Double(try XCTUnwrap(
            app.staticTexts["keyboard-host-geometry"].value as? String)))
        if abs((fromEnglishHeight - fromEmojiHeight) - 17) <= 1 {
            XCTExpectFailure("System-owned top margin changes after Emoji: FB21449121 / FB24460699") {
                XCTAssertEqual(fromEmojiHeight, fromEnglishHeight, accuracy: 1)
            }
        } else {
            // A fix passes; a different height regression must fail normally.
            XCTAssertEqual(fromEmojiHeight, fromEnglishHeight, accuracy: 1)
        }
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "hello ")
    }

    func testLandscapeSwitchingKeepsRowsInsideKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-test", "--measure-bg", "--seed=hello ", "--landscape"]
        app.launch()
        select("English (US)", in: app)
        capture("landscape-native", app: app)
        select("Obadh", in: app)
        let a = app.descendants(matching: .any)["a"].firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 10))
        let initial = a.frame
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertTrue(app.frame.contains(initial))
        XCTAssertGreaterThan(initial.height, 20)
        capture("landscape-obadh", app: app)
        select("English (US)", in: app)
        select("Obadh", in: app)
        XCTAssertEqual(a.frame.minY, initial.minY, accuracy: 1)
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "hello ")
        a.tap()
        XCTAssertNotEqual(app.textViews.firstMatch.value as? String, "hello ")
        app.terminate()
    }

}
