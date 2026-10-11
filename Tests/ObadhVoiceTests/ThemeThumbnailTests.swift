import UIKit
import XCTest

@testable import Obadh

@MainActor
final class ThemeThumbnailTests: XCTestCase {
  func testThemePreviewRebuildsKeysForEachHostAppearance() throws {
    let view = KeyboardThemePreviewView(frame: CGRect(x: 0, y: 0, width: 414, height: 280))
    func keys(in root: UIView) -> [KeyboardKeyButton] {
      (root as? KeyboardKeyButton).map { [$0] } ?? root.subviews.flatMap(keys)
    }
    let themeID = try XCTUnwrap(KeyboardThemeCatalog.presets.first?.id)
    view.display(.init(themeID: themeID, mode: .light), photo: nil)
    let lightKeys = keys(in: view)
    XCTAssertFalse(lightKeys.isEmpty)
    view.display(.init(themeID: themeID, mode: .dark), photo: nil)
    let darkKeys = keys(in: view)
    XCTAssertEqual(darkKeys.count, lightKeys.count)
    XCTAssertFalse(lightKeys[0] === darkKeys[0])
  }

  func testBackdropRevealsArtworkAcrossRibbonAndFadesAtBottom() throws {
    let backdrop = KeyboardThemeBackdropView(frame: CGRect(x: 0, y: 0, width: 414, height: 280))
    backdrop.alignWithNativeSuggestionBand(height: 44, keyFieldTop: 50, suggestionTop: 8)
    backdrop.layoutIfNeeded()
    let mask = try XCTUnwrap(backdrop.layer.mask as? CAGradientLayer)
    let stops = try XCTUnwrap(mask.locations?.map(\.doubleValue))
    XCTAssertEqual(stops.count, 6)
    XCTAssertEqual(stops[0], 0)
    XCTAssertEqual(stops[1], 8.0 / 280.0, accuracy: 0.001)
    XCTAssertEqual(stops[2], 50.0 / 280.0, accuracy: 0.001)
    XCTAssertGreaterThan(stops[3], stops[2])
    XCTAssertLessThan(stops[3], 1)
    XCTAssertGreaterThan(stops[4], stops[3])
    XCTAssertLessThan(stops[4], 1)
    XCTAssertEqual(stops[5], 1)
    let colors = try XCTUnwrap(mask.colors as? [CGColor])
    XCTAssertEqual(colors.map(\.alpha), [0, 0, 1, 1, 0.45, 0])
    backdrop.alignWithNativeSuggestionBand(height: 44, keyFieldTop: 50, suggestionTop: 8)
    XCTAssertTrue(backdrop.layer.mask === mask)
    XCTAssertEqual(mask.locations?.map(\.doubleValue), stops)
  }

  func testSystemOutlinePreviewUpdatesWithoutRebuildingKeys() throws {
    let view = KeyboardThemePreviewView(frame: CGRect(x: 0, y: 0, width: 414, height: 280))
    func keys(in root: UIView) -> [KeyboardKeyButton] {
      (root as? KeyboardKeyButton).map { [$0] } ?? root.subviews.flatMap(keys)
    }
    view.display(KeyboardAppearance(), photo: nil)
    let original = keys(in: view)
    XCTAssertFalse(original.isEmpty)
    XCTAssertEqual(original[0].layer.borderWidth, 0)
    view.display(KeyboardAppearance(keyOutlines: true), photo: nil)
    let outlined = keys(in: view)
    XCTAssertTrue(zip(original, outlined).allSatisfy { $0 === $1 })
    XCTAssertGreaterThan(outlined[0].layer.borderWidth, 0)
    view.display(KeyboardAppearance(), photo: nil)
    XCTAssertEqual(keys(in: view)[0].layer.borderWidth, 0)
  }

  func testPhotoEditorPreviewUpdatesCropAndBrightnessSynchronously() throws {
    let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400))
      .image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
      }.cgImage)
    let view = KeyboardThemePreviewView(frame: CGRect(x: 0, y: 0, width: 414, height: 280))
    let appearance = KeyboardAppearance(themeID: "photo." + UUID().uuidString)
    view.display(appearance, photo: image, editingCrop: .init(), editingBrightness: 0.8)
    func backdrop(in root: UIView) -> KeyboardThemeBackdropView? {
      if let result = root as? KeyboardThemeBackdropView { return result }
      return root.subviews.lazy.compactMap(backdrop).first
    }
    let layer = try XCTUnwrap(backdrop(in: view)?.layer.sublayers?[1])
    func keys(in root: UIView) -> [KeyboardKeyButton] {
      (root as? KeyboardKeyButton).map { [$0] } ?? root.subviews.flatMap(keys)
    }
    let firstKeys = keys(in: view)
    XCTAssertFalse(firstKeys.isEmpty)
    XCTAssertEqual(layer.opacity, 0.8, accuracy: 0.001)
    let first = layer.contentsRect
    var cropped = ThemePhotoCrop()
    cropped.zoom = 2
    cropped.centerX = 0.7
    view.display(appearance, photo: image, editingCrop: cropped, editingBrightness: 0.35)
    XCTAssertEqual(layer.opacity, 0.35, accuracy: 0.001)
    XCTAssertNotEqual(layer.contentsRect, first)
    let updatedKeys = keys(in: view)
    XCTAssertEqual(updatedKeys.count, firstKeys.count)
    XCTAssertTrue(zip(firstKeys, updatedKeys).allSatisfy { $0 === $1 },
      "Dragging a slider must not recreate native glass keys")
    let glassAppearance = KeyboardAppearance(themeID: appearance.themeID,
      keyOutlines: true, keyTransparency: 0.7, keyBorderStrength: 1)
    view.display(glassAppearance, photo: image, editingCrop: cropped, editingBrightness: 0.35)
    let glassKeys = keys(in: view)
    XCTAssertTrue(zip(firstKeys, glassKeys).allSatisfy { $0 === $1 },
      "Glass and border adjustments should update the existing keys")
    XCTAssertGreaterThan(glassKeys[0].layer.borderWidth, 0)
  }

  func testPhotoRevisionUpdatesArtworkWithoutAllocatingNativeGlassKeys() throws {
    let thumbnail = ThemeThumbnailView(frame: CGRect(x: 0, y: 0, width: 207, height: 140))
    func photo(_ color: UIColor) throws -> CGImage {
      try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160)).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
      }.cgImage)
    }
    func topPixel() throws -> [UInt8] {
      thumbnail.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(size: thumbnail.bounds.size).image { context in
        thumbnail.layer.render(in: context.cgContext)
      }
      let source = try XCTUnwrap(image.cgImage)
      let sample = try XCTUnwrap(source.cropping(to: CGRect(
        x: source.width / 2, y: source.height / 50, width: 1, height: 1)))
      var pixel: [UInt8] = [0, 0, 0, 0]
      try pixel.withUnsafeMutableBytes { bytes in
        let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
          bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      }
      return pixel
    }
    var appearance = KeyboardAppearance(themeID: "photo." + UUID().uuidString,
      revision: UUID())
    thumbnail.display(appearance, photo: try photo(.red))
    let red = try topPixel()
    XCTAssertGreaterThan(Int(red[0]), Int(red[2]) + 30)
    appearance.revision = UUID()
    thumbnail.display(appearance, photo: try photo(.blue))
    let blue = try topPixel()
    XCTAssertGreaterThan(Int(blue[2]), Int(blue[0]) + 30)
    XCTAssertFalse(thumbnail.subviews.contains { $0 is KeyboardThemePreviewView })
    XCTAssertEqual(thumbnail.subviews.count, 2, "A card has only a backdrop and one drawing view")
  }
}
