import CoreTransferable
import FoundationModels
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

struct PhotoKeyStyleSuggestion: Sendable {
  let transparency: Double
  let outlines: Bool
  let borderStrength: Double
}

@available(iOS 27, *)
@Generable
private struct GeneratedPhotoKeyStyle {
  @Guide(description: "Key transparency percentage; lower for detailed or high-contrast photos.",
    .range(10...70))
  var transparencyPercent: Int
  @Guide(description: "Whether a subtle key border improves separation from this photo.")
  var outlines: Bool
  @Guide(description: "Border definition percentage; prefer a restrained outline.",
    .range(20...70))
  var borderStrengthPercent: Int
}

/// Serializes every app-side manifest mutation. The keyboard is strictly a reader.
actor ThemePhotoLibrary {
  static let shared = ThemePhotoLibrary()
  private let store = KeyboardPhotoThemeStore()
  func photos() -> [KeyboardPhotoTheme] { store.photos }
  /// Replace the old shared placeholder with stable, distinct names. Failure is
  /// intentionally non-fatal: the catalog remains readable and can be repaired
  /// on the next launch.
  func migrateLegacyNames() { try? store.migrateLegacyPhotoNames() }
  func nextAvailableName() -> String { store.nextAvailablePhotoName() }
  func isGeneratedName(_ name: String) -> Bool { store.isGeneratedPhotoName(name) }
  func canSuggestName() -> Bool {
    if #available(iOS 27, *) {
      let model = SystemLanguageModel.default
      return model.isAvailable && model.capabilities.contains(.vision)
    }
    return false
  }
  func canSuggestKeyStyle() -> Bool {
    if #available(iOS 27, *) {
      let model = SystemLanguageModel.default
      return model.isAvailable && model.capabilities.contains(.vision)
        && model.capabilities.contains(.guidedGeneration)
    }
    return false
  }

  /// On-demand and never used in the keyboard extension. A model error leaves
  /// the user's current controls untouched; guided values are bounded again
  /// before they reach the UI.
  func suggestedKeyStyle(for jpeg: Data, crop: ThemePhotoCrop) async
    -> PhotoKeyStyleSuggestion?
  {
    guard canSuggestKeyStyle(), #available(iOS 27, *),
      !Task.isCancelled, let image = try? ThemePhotoCodec.image(jpeg)
    else { return nil }
    let rectangle = crop.rectangle(imageWidth: Double(image.width), imageHeight: Double(image.height))
    let region = CGRect(
      x: rectangle.x * Double(image.width), y: rectangle.y * Double(image.height),
      width: rectangle.width * Double(image.width), height: rectangle.height * Double(image.height))
    guard let cropped = image.cropping(to: region) else { return nil }
    do {
      let session = LanguageModelSession(instructions: """
        You design elegant, readable Liquid Glass keyboard keys over personal photos.
        Use the visible image only to recommend restrained key-surface settings.
        Transparent keys reveal the image but can reduce legibility over busy detail.
        Do not identify people or infer private information.
        """)
      let response = try await session.respond(generating: GeneratedPhotoKeyStyle.self) {
        "Choose key transparency and subtle border settings for this cropped keyboard photo."
        Attachment(cropped)
      }
      guard !Task.isCancelled else { return nil }
      let style = response.content
      return PhotoKeyStyleSuggestion(
        transparency: Double(min(70, max(10, style.transparencyPercent))) / 100,
        outlines: style.outlines,
        borderStrength: Double(min(70, max(20, style.borderStrengthPercent))) / 100)
    } catch {
      return nil
    }
  }

  /// A failed or unavailable model only leaves the already assigned Custom n
  /// fallback. The imported image is bounded before it reaches this actor.
  func suggestedName(for jpeg: Data, crop: ThemePhotoCrop, excluding id: UUID? = nil) async
    -> String?
  {
    guard canSuggestName(), #available(iOS 27, *),
      !Task.isCancelled,
      let image = try? ThemePhotoCodec.image(jpeg)
    else { return nil }
    let rectangle = crop.rectangle(imageWidth: Double(image.width), imageHeight: Double(image.height))
    let region = CGRect(
      x: rectangle.x * Double(image.width), y: rectangle.y * Double(image.height),
      width: rectangle.width * Double(image.width), height: rectangle.height * Double(image.height))
    guard let cropped = image.cropping(to: region) else { return nil }
    let occupied = Set(store.photos.filter { $0.id != id }.map { $0.name.lowercased() })
      .union(KeyboardThemeCatalog.presets.map { $0.name.lowercased() })
    let avoid = occupied.sorted().joined(separator: ", ")
    do {
      let session = LanguageModelSession(instructions: """
        You name keyboard color themes from photos. Return only a concise, evocative
        two-word English title in Title Case. Use a visible subject or dominant
        colors. Never identify a person, infer a precise place, or use 'My Photo'.
        """)
      let response = try await session.respond {
        "Name this photo theme. Do not use any of these existing names: \(avoid)"
        Attachment(cropped)
      }
      guard !Task.isCancelled,
        let candidate = Self.validThemeName(response.content),
        !occupied.contains(candidate.lowercased()),
        store.nameIsAvailable(candidate, excluding: id)
      else { return nil }
      return candidate
    } catch {
      return nil
    }
  }

  func renameGeneratedPhoto(_ photo: KeyboardPhotoTheme) async -> Bool {
    guard store.isGeneratedPhotoName(photo.name),
      let data = try? source(photo),
      let suggested = await suggestedName(for: data, crop: photo.crop, excluding: photo.id),
      !Task.isCancelled
    else { return false }
    return (try? store.renameGeneratedPhoto(photo, to: suggested)) ?? false
  }

  private static func validThemeName(_ response: String) -> String? {
    let words = response.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.,!?;:"))
      .split(whereSeparator: \.isWhitespace)
    guard words.count == 2,
      words.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(CharacterSet.letters.contains) })
    else { return nil }
    let name = words.map { $0.capitalized }.joined(separator: " ")
    guard name.count <= 80, !["My Photo", "Photo Theme"].contains(name) else { return nil }
    return name
  }
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
