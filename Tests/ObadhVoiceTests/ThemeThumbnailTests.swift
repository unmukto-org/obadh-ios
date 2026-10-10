import UIKit
import XCTest

@testable import Obadh

@MainActor
final class ThemeThumbnailTests: XCTestCase {
  func testPhotoRevisionInvalidatesSnapshotAndInactiveCardsReleaseLiveRendering() async throws {
    let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows).first { $0.isKeyWindow }
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 414, height: 896))
    window.windowScene = previousWindow?.windowScene
    let host = UIViewController()
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previousWindow?.makeKeyAndVisible()
    }
    let thumbnail = ThemeThumbnailView(frame: CGRect(x: 20, y: 100, width: 207, height: 140))
    host.view.addSubview(thumbnail)
    func photo(_ color: UIColor) throws -> CGImage {
      try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160)).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
      }.cgImage)
    }
    func snapshot(_ view: UIView) throws -> UIImage {
      XCTAssertFalse(view.subviews.isEmpty)
      return UIGraphicsImageRenderer(size: view.bounds.size).image { _ in
        XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
      }
    }
    func rgb(_ image: UIImage) throws -> [UInt8] {
      let source = try XCTUnwrap(image.cgImage)
      var pixel: [UInt8] = [0, 0, 0, 0]
      // The top center is the uncovered photo, away from suggestion glyphs.
      let sample = try XCTUnwrap(source.cropping(to: CGRect(
        x: source.width / 2, y: source.height / 50, width: 1, height: 1)))
      try pixel.withUnsafeMutableBytes { bytes in
        let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
          bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      }
      return pixel
    }
    var appearance = KeyboardAppearance(themeID: "photo." + UUID().uuidString, revision: UUID())
    thumbnail.display(appearance, photo: try photo(.red), active: true)
    thumbnail.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(600))
    let red = try rgb(snapshot(thumbnail))
    XCTAssertGreaterThan(Int(red[0]), Int(red[2]) + 30)
    XCTAssertFalse(thumbnail.subviews.contains { $0 is KeyboardThemePreviewView },
      "A completed card must release its live native effects")

    appearance.revision = UUID()
    thumbnail.display(appearance, photo: nil, active: true)
    thumbnail.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(350))
    thumbnail.display(appearance, photo: try photo(.blue), active: true)
    thumbnail.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(600))
    let blue = try rgb(snapshot(thumbnail))
    XCTAssertGreaterThan(Int(blue[2]), Int(blue[0]) + 30, "Editing a photo cannot reuse its old snapshot")
    let duplicate = ThemeThumbnailView(frame: thumbnail.frame.offsetBy(dx: 0, dy: 160))
    host.view.addSubview(duplicate)
    duplicate.display(appearance, photo: try photo(.blue), active: true)
    duplicate.layoutIfNeeded()
    XCTAssertFalse(duplicate.subviews.contains { $0 is KeyboardThemePreviewView },
      "Another card must reuse the snapshot without stealing the first card's view")
    XCTAssertEqual(try rgb(snapshot(duplicate)), blue)
    XCTAssertFalse(thumbnail.subviews.isEmpty)
    duplicate.stopDisplaying()
    thumbnail.stopDisplaying()
    XCTAssertTrue(thumbnail.subviews.isEmpty)
    XCTAssertFalse(thumbnail.subviews.contains { $0 is KeyboardThemePreviewView })
  }
}
