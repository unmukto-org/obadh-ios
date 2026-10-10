import XCTest

@MainActor
final class KeyboardAppearanceUITests: XCTestCase {
  private func capture(_ name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func reveal(_ card: XCUIElement, app: XCUIApplication, attempts: Int = 30) {
    for _ in 0..<attempts {
      if card.exists, card.isHittable {
        let frame = card.frame
        if frame.width > 100, frame.height > 70,
          frame.minY > app.navigationBars.firstMatch.frame.maxY,
          frame.maxY <= app.scrollViews.firstMatch.frame.maxY - 4 { return }
      }
      app.scrollViews.firstMatch.swipeUp()
    }
    XCTFail("Theme card never became fully visible: " + card.identifier, file: #filePath, line: #line)
  }
  private func selectCollection(_ name: String, app: XCUIApplication) {
    let segment = app.segmentedControls.buttons[name]
    for _ in 0..<12 where !segment.isHittable { app.scrollViews.firstMatch.swipeDown() }
    XCTAssertTrue(segment.isHittable, app.debugDescription)
    segment.tap()
  }
  func testThemePreviewApplyPersistenceSystemAndPhotoPickerCancellation() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--screen=settings"]
    app.launch()
    let appearanceLink = app.buttons["appearance-settings"]
    XCTAssertTrue(appearanceLink.waitForExistence(timeout: 10))
    appearanceLink.tap()
    XCTAssertTrue(app.buttons["theme-system"].waitForExistence(timeout: 5))
    selectCollection("Colors", app: app)
    capture("appearance-catalog", app: app)
    let blue = app.buttons["theme-blue"]
    reveal(blue, app: app)
    XCTAssertTrue(blue.isHittable)
    blue.tap()
    XCTAssertTrue(app.buttons["use-theme"].waitForExistence(timeout: 5))
    capture("theme-blue-native-glass-preview", app: app)
    app.buttons["Cancel"].tap()
    XCTAssertTrue(blue.waitForExistence(timeout: 5))
    blue.tap()
    app.buttons["use-theme"].tap()
    app.terminate()
    app.launch()
    appearanceLink.tap()
    reveal(blue, app: app)
    XCTAssertTrue(blue.isSelected)
    for _ in 0..<10 where !app.buttons["theme-system"].isHittable { app.swipeDown() }
    app.buttons["theme-system"].tap()
    XCTAssertTrue(app.buttons["use-theme"].waitForExistence(timeout: 5))
    capture("theme-system-unchanged-preview", app: app)
    app.buttons["use-theme"].tap()
    let add = app.buttons["add-photo-theme"]
    XCTAssertTrue(add.waitForExistence(timeout: 5))
    add.tap()
    XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
    capture("native-photos-picker", app: app)
    app.buttons["Cancel"].tap()
    XCTAssertTrue(add.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["theme-system"].isSelected)
  }
  private func liveKeyboard(_ app: XCUIApplication, name: String) {
    app.terminate()
    app.launchArguments = ["--keyboard-test", "--seed=hello ", "--measure-bg"]
    app.launch()
    let globe = app.buttons["Next keyboard"].firstMatch
    XCTAssertTrue(globe.waitForExistence(timeout: 10), app.debugDescription)
    globe.press(forDuration: 1)
    let choice = app.staticTexts["Obadh"].firstMatch
    XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
    choice.tap()
    let key = app.buttons["a"].firstMatch
    XCTAssertTrue(key.waitForExistence(timeout: 5), app.debugDescription)
    let before = app.textViews.firstMatch.value as? String
    key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    app.buttons["b"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertNotEqual(app.textViews.firstMatch.value as? String, before)
    let screenshot = app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "live-keyboard-" + name
    attachment.lifetime = .keepAlways
    add(attachment)
    // The keys alone prove the extension loaded; verify that the selected
    // artwork actually reached its background. A stale System appearance
    // previously let this UI flow pass while its screenshots were gray.
    if name == "blue" || name == "dark_gradient_28" {
      let color = keyFieldColor(in: screenshot)
      if name == "blue" {
        XCTAssertGreaterThan(color.blue, color.red + 0.1)
        XCTAssertGreaterThan(color.blue, color.green + 0.08)
      } else {
        XCTAssertGreaterThan(color.red, color.blue + 0.04)
        XCTAssertGreaterThan(color.red, color.green + 0.04)
      }
    }
    app.terminate()
    app.launchArguments = ["--screen=settings"]
    app.launch()
    app.buttons["appearance-settings"].tap()
  }

  private func keyFieldColor(in screenshot: XCUIScreenshot) ->
    (red: CGFloat, green: CGFloat, blue: CGFloat) {
    let image = screenshot.image.cgImage!
    let sample = image.cropping(to: CGRect(x: 4, y: Int(CGFloat(image.height) * 0.8),
      width: 1, height: 1))!
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
  }

  func testThumbnailFidelityForSolidGradientAndMesh() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--screen=settings"]
    app.launch()
    XCTAssertTrue(app.buttons["appearance-settings"].waitForExistence(timeout: 10))
    app.buttons["appearance-settings"].tap()
    selectCollection("Colors", app: app)
    for id in ["blue", "light_gradient_8", "dark_gradient_28"] {
      if id == "light_gradient_8" { selectCollection("Daylight", app: app) }
      if id == "dark_gradient_28" { selectCollection("After Dark", app: app) }
      let card = app.buttons["theme-" + id]
      reveal(card, app: app)
      let thumbnail = XCTAttachment(screenshot: card.screenshot())
      thumbnail.name = "thumbnail-" + id
      thumbnail.lifetime = .keepAlways
      add(thumbnail)
      card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
      XCTAssertTrue(app.buttons["use-theme"].waitForExistence(timeout: 5))
      capture("preview-" + id, app: app)
      app.buttons["Cancel"].tap()
    }
  }

  func testColorAndMeshOnLiveKeyboard() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--screen=settings"]
    app.launch()
    let link = app.buttons["appearance-settings"]
    XCTAssertTrue(link.waitForExistence(timeout: 10))
    link.tap()
    selectCollection("Colors", app: app)
    for id in ["blue", "dark_gradient_28"] {
      if id == "dark_gradient_28" { selectCollection("After Dark", app: app) }
      let card = app.buttons["theme-" + id]
      reveal(card, app: app)
      XCTAssertTrue(card.isHittable, app.debugDescription)
      let thumbnail = XCTAttachment(screenshot: card.screenshot())
      thumbnail.name = "thumbnail-" + id
      thumbnail.lifetime = .keepAlways
      add(thumbnail)
      card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      XCTAssertTrue(app.buttons["use-theme"].waitForExistence(timeout: 5))
      capture("preview-" + id, app: app)
      app.buttons["use-theme"].tap()
      liveKeyboard(app, name: id)
    }
    app.buttons["theme-system"].tap()
    app.buttons["use-theme"].tap()
  }

  func testPhotoImportCropSaveEditAndDelete() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--screen=settings"]
    app.launch()
    let link = app.buttons["appearance-settings"]
    XCTAssertTrue(link.waitForExistence(timeout: 10))
    link.tap()
    app.buttons["add-photo-theme"].tap()
    let asset = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
    XCTAssertTrue(asset.waitForExistence(timeout: 10), app.debugDescription)
    asset.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let save = app.buttons["save-photo-theme"]
    XCTAssertTrue(save.waitForExistence(timeout: 15), app.debugDescription)
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: save)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
    capture("native-photo-editor", app: app)
    app.segmentedControls.buttons["Keyboard"].tap()
    capture("native-photo-keyboard-live-preview", app: app)
    app.segmentedControls.buttons["Photo"].tap()
    let crop = app.descendants(matching: .any)["photo-crop-preview"].firstMatch
    XCTAssertTrue(crop.waitForExistence(timeout: 5))
    crop.pinch(withScale: 1.7, velocity: 1)
    XCTAssertTrue(app.buttons["reset-photo-crop"].waitForExistence(timeout: 5))
    app.segmentedControls.buttons["Keyboard"].tap()
    capture("native-photo-keyboard-after-zoom", app: app)
    let brightness = app.sliders["Photo Brightness"]
    for _ in 0..<4 where !brightness.isHittable { app.scrollViews.firstMatch.swipeUp() }
    brightness.adjust(toNormalizedSliderPosition: 0.5)
    save.tap()
    let photo = app.buttons["My Photo"].firstMatch
    XCTAssertTrue(photo.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(photo.isSelected)
    let thumbnail = XCTAttachment(screenshot: photo.screenshot())
    thumbnail.name = "thumbnail-photo"
    thumbnail.lifetime = .keepAlways
    add(thumbnail)
    liveKeyboard(app, name: "photo")
    XCTAssertTrue(photo.waitForExistence(timeout: 5))
    photo.tap()
    XCTAssertTrue(app.buttons["Edit Photo"].waitForExistence(timeout: 5))
    capture("saved-photo-glass-preview", app: app)
    app.buttons["Edit Photo"].tap()
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(photo.waitForExistence(timeout: 5))
    photo.tap()
    app.buttons["Delete Theme"].tap()
    let confirmation = app.sheets["Delete this photo theme?"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    confirmation.buttons["Delete Theme"].tap()
    XCTAssertTrue(app.buttons["theme-system"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["theme-system"].isSelected)
    XCTAssertFalse(photo.exists)
  }

}
