import UIKit
import XCTest

@testable import Obadh

@MainActor
final class ThemeThumbnailTests: XCTestCase {
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
