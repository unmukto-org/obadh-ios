import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Obadh

final class ThemePhotoProcessingTests: XCTestCase {
  func testImportEncodingAndRenderAreBoundedAndStripSourceMetadata() throws {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 2048, height: 1536, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1536))
    let source = try XCTUnwrap(context.makeImage())
    let tagged = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(tagged, UTType.jpeg.identifier as CFString, 1, nil))
    let tags: [CFString: Any] = [
      kCGImagePropertyOrientation: 6,
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 0, kCGImagePropertyGPSLongitude: 0,
      ],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2000:01:01 12:00:00",
        kCGImagePropertyExifUserComment: "private source comment",
      ],
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Private Camera", kCGImagePropertyTIFFArtist: "Private Name",
      ],
    ]
    CGImageDestinationAddImage(destination, source, tags as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let taggedSource = try XCTUnwrap(CGImageSourceCreateWithData(tagged, nil))
    let taggedProperties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(taggedSource, 0, nil) as? [CFString: Any])
    XCTAssertNotNil(taggedProperties[kCGImagePropertyGPSDictionary])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".jpg")
    try (tagged as Data).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let imported = try XCTUnwrap(KeyboardThemeImage.decode(url, maxSide: 2048))
    XCTAssertEqual(imported.width, 1536)
    XCTAssertEqual(imported.height, 2048, "EXIF orientation must be baked into pixels")
    let decoded = try ThemePhotoCodec.image(ThemePhotoCodec.jpeg(imported))
    let rendered = try ThemePhotoCodec.render(
      decoded, crop: .init(centerX: 1, centerY: 0, zoom: 4), brightness: 0.4, width: 1280)
    XCTAssertEqual(rendered.width, 1280)
    XCTAssertEqual(rendered.height, 853)
    let saved = try ThemePhotoCodec.jpeg(rendered)
    XCTAssertLessThan(saved.count, 4_000_000)
    let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(saved as CFData, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
    XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    // ImageIO adds color-space/pixel dimensions; no source metadata survives.
    XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
    XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
    XCTAssertNil(tiff?[kCGImagePropertyTIFFArtist])
    XCTAssertThrowsError(try ThemePhotoCodec.image(Data("not an image".utf8)))
  }
}
