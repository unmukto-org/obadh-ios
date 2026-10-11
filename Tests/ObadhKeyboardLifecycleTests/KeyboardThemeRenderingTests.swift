import UIKit
import XCTest

@MainActor
final class KeyboardThemeRenderingTests: XCTestCase {
  override func setUp() {
    super.setUp()
    KeyboardGlassStyle.current = .translucent
    KeyboardTheme.legacyPresentation = false
  }
  func testSystemKeepsOriginalFillAndHasNoPerKeyGlassOrOutline() throws {
    let key = KeyboardKeyButton(key: .character("a"))
    let traits = UITraitCollection(userInterfaceStyle: .dark)
    key.updateAppearance(
      shifted: false, traitCollection: traits, metrics: KeyboardTheme.defaultMetrics)
    XCTAssertEqual(key.backgroundColor, KeyboardTheme.glassKeyTint(for: traits, highlighted: false))
    XCTAssertEqual(key.titleColor(for: .normal), KeyboardTheme.textColor(for: traits))
    XCTAssertEqual(key.layer.borderWidth, 0)
    XCTAssertFalse(key.subviews.contains { $0 is UIVisualEffectView })
    let backdrop = KeyboardThemeBackdropView()
    backdrop.display(preset: nil, photo: nil, palette: nil)
    XCTAssertTrue(backdrop.isHidden)
  }
  func testCustomThemeUsesRealNativeGlassAndOpaqueHighContrastFallback() throws {
    guard #available(iOS 26.0, *) else { return }
    let preset = try XCTUnwrap(KeyboardThemeCatalog.preset("blue"))
    let palette = KeyboardThemePalette(preset: preset)
    let key = KeyboardKeyButton(key: .character("a"), themePalette: palette, keyOutlines: true)
    key.updateAppearance(
      shifted: false, traitCollection: UITraitCollection(userInterfaceStyle: .dark),
      metrics: KeyboardTheme.defaultMetrics)
    let glass = try XCTUnwrap(
      key.subviews.first { $0 is UIVisualEffectView } as? UIVisualEffectView)
    XCTAssertTrue(glass.effect is UIGlassEffect)
    XCTAssertFalse(glass.isUserInteractionEnabled)
    XCTAssertEqual(key.titleColor(for: .normal), palette.ink.uiColor)
    let high = UITraitCollection(traitsFrom: [
      .init(userInterfaceStyle: .dark), .init(accessibilityContrast: .high),
    ])
    key.updateAppearance(
      shifted: false, traitCollection: high, metrics: KeyboardTheme.defaultMetrics)
    XCTAssertTrue(glass.isHidden)
    XCTAssertEqual(key.backgroundColor, palette.opaqueKey.uiColor)
    XCTAssertEqual(key.layer.borderWidth, 1)
    key.isHighlighted = true
    key.isHighlighted = false
    XCTAssertEqual(key.titleColor(for: .normal), palette.ink.uiColor)
  }
  func testReturningToSystemReleasesArtwork() throws {
    let backdrop = KeyboardThemeBackdropView()
    let preset = try XCTUnwrap(KeyboardThemeCatalog.preset("dark_gradient_28"))
    backdrop.display(preset: preset, photo: nil, palette: .init(preset: preset))
    XCTAssertFalse(backdrop.isHidden)
    XCTAssertTrue(backdrop.layer.sublayers?.contains { $0.contents != nil } == true)
    backdrop.display(preset: nil, photo: nil, palette: nil)
    XCTAssertTrue(backdrop.isHidden)
    XCTAssertFalse(backdrop.layer.sublayers?.contains { $0.contents != nil } == true)
  }
  func testLiveThemeChangePreservesCompositionAndDoesNotRetainInactiveArtwork() async throws {
    let preferences = KeyboardPreferences()
    let previous = preferences.appearance
    preferences.appearance = .init()
    defer { preferences.appearance = previous }
    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 414, height: 280)
    controller.beginAppearanceTransition(true, animated: false)
    controller.endAppearanceTransition()
    controller.handleDebugCommand("tap", argument: "a,b")
    func stored<T>(_ name: String, as: T.Type) throws -> T {
      try XCTUnwrap(
        Mirror(reflecting: controller).children.first {
          $0.label == name || $0.label == "$__lazy_storage_$_" + name
        }?.value as? T)
    }
    let composer = try stored("composer", as: KeyboardComposer.self)
    let roman = composer.romanBuffer
    XCTAssertFalse(roman.isEmpty)
    preferences.appearance = .init(themeID: "blue")
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(
      composer.romanBuffer, roman, "Changing appearance must not discard in-progress typing")
    let keys = try stored("keyButtons", as: [KeyboardKeyButton].self)
    XCTAssertTrue(keys.contains { $0.subviews.contains { $0 is UIVisualEffectView } })
    preferences.appearance = .init()
    try await Task.sleep(for: .milliseconds(120))
    let restored = try stored("keyButtons", as: [KeyboardKeyButton].self)
    XCTAssertFalse(restored.contains { $0.subviews.contains { $0 is UIVisualEffectView } })
    XCTAssertEqual(composer.romanBuffer, roman)
    controller.beginAppearanceTransition(false, animated: false)
    controller.endAppearanceTransition()
  }

}
