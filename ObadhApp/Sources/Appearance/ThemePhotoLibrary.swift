import CoreTransferable
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// File transfers avoid ever loading an unbounded Photos asset into Data.
/// The picker owns the source URL only during this closure; decode there and
/// retain a bounded JPEG with orientation applied and source metadata stripped.
struct ThemePhotoImport: Transferable, Sendable {
  let jpeg: Data
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      guard let image = KeyboardThemeImage.decode(received.file, maxSide: 2048) else {
        throw KeyboardPhotoThemeStore.Failure.invalidImage
      }
      return ThemePhotoImport(jpeg: try ThemePhotoCodec.jpeg(image))
    }
  }
}

enum ThemePhotoCodec {
  static func image(_ data: Data) throws -> CGImage {
    guard data.count <= 8_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      (1...2048).contains(width.intValue), (1...2048).contains(height.intValue),
      let image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
      image.width <= 2048, image.height <= 2048
    else { throw KeyboardPhotoThemeStore.Failure.invalidImage }
    return image
  }
  static func jpeg(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw KeyboardPhotoThemeStore.Failure.invalidImage }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    guard CGImageDestinationFinalize(destination), data.length <= 8_000_000 else {
      throw KeyboardPhotoThemeStore.Failure.invalidImage
    }
    return data as Data
  }
  static func render(_ image: CGImage, crop: ThemePhotoCrop, brightness: Double, width: Int) throws
    -> CGImage
  {
    let rect = crop.rectangle(imageWidth: Double(image.width), imageHeight: Double(image.height))
    guard
      let cropped = image.cropping(
        to: CGRect(
          x: rect.x * Double(image.width), y: rect.y * Double(image.height),
          width: rect.width * Double(image.width), height: rect.height * Double(image.height))),
      let context = CGContext(
        data: nil, width: width, height: Int(Double(width) / ThemePhotoCrop.aspectRatio),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw KeyboardPhotoThemeStore.Failure.invalidImage }
    let bounds = CGRect(x: 0, y: 0, width: context.width, height: context.height)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(bounds)
    context.interpolationQuality = .high
    context.setAlpha(min(1, max(0, brightness)))
    context.draw(cropped, in: bounds)
    guard let result = context.makeImage() else {
      throw KeyboardPhotoThemeStore.Failure.invalidImage
    }
    return result
  }
}

/// Serializes every app-side manifest mutation. The keyboard is strictly a reader.
actor ThemePhotoLibrary {
  static let shared = ThemePhotoLibrary()
  private let store = KeyboardPhotoThemeStore()
  func photos() -> [KeyboardPhotoTheme] { store.photos }
  func collect() { store.collectUnusedRevisions() }
  func source(_ photo: KeyboardPhotoTheme) throws -> Data {
    guard let url = store.originalURL(photo.id), let data = try? Data(contentsOf: url),
      data.count <= 8_000_000
    else {
      throw KeyboardPhotoThemeStore.Failure.invalidImage
    }
    return data
  }
  func save(_ photo: KeyboardPhotoTheme, source: Data) throws {
    let image = try ThemePhotoCodec.image(source)
    let rendered = try ThemePhotoCodec.jpeg(
      ThemePhotoCodec.render(image, crop: photo.crop, brightness: photo.brightness, width: 1280))
    let thumb = try ThemePhotoCodec.jpeg(
      ThemePhotoCodec.render(image, crop: photo.crop, brightness: photo.brightness, width: 240))
    try Task.checkCancellation()
    try store.save(photo, original: source, rendered: rendered, thumbnail: thumb)
  }
  func remove(_ photo: KeyboardPhotoTheme) throws { try store.remove(photo) }
}
