import XCTest

@testable import ObadhKeyboardCore

final class KeyboardAppearanceTests: XCTestCase {
  func testCatalogIsCompleteAndGradientsHaveValidSampling() {
    XCTAssertEqual(KeyboardThemeCatalog.presets.count, 71)
    XCTAssertEqual(Set(KeyboardThemeCatalog.presets.map(\.id)).count, 71)
    XCTAssertEqual(
      KeyboardThemeCatalog.groups.map { group in
        KeyboardThemeCatalog.presets.filter { $0.group == group }.count
      }, [18, 25, 28])
    XCTAssertEqual(KeyboardThemeCatalog.presets.filter { !$0.mesh.isEmpty }.count, 5)
    for preset in KeyboardThemeCatalog.presets {
      XCTAssertEqual(preset.palette.count, 5, preset.id)
      XCTAssertEqual(preset.gradient.count, preset.positions.count, preset.id)
      if !preset.gradient.isEmpty {
        XCTAssertEqual(preset.positions.first, 0)
        XCTAssertEqual(preset.positions.last, 1)
        XCTAssertEqual(preset.positions, preset.positions.sorted())
      }
      if !preset.mesh.isEmpty { XCTAssertEqual(preset.mesh.count, 289, preset.id) }
    }
  }
  func testEveryThemeMaintainsReadableInkIncludingInterpolatedColors() {
    for preset in KeyboardThemeCatalog.presets {
      let palette = KeyboardThemePalette(preset: preset)
      var samples = preset.samples.map(ThemeColor.init)
      let original = samples
      // Midpoints stress luminance minima between mesh/gradient vertices.
      for (a, b) in zip(original, original.dropFirst()) {
        samples.append(a.blended(over: b, opacity: 0.5))
      }
      for sample in samples {
        let background = palette.surface.blended(
          over: sample, opacity: palette.backdropScrimOpacity)
        XCTAssertGreaterThanOrEqual(palette.ink.contrast(with: background), 4.5, preset.id)
      }
      XCTAssertGreaterThanOrEqual(palette.ink.contrast(with: palette.opaqueKey), 4.5, preset.id)
      XCTAssertGreaterThanOrEqual(palette.actionInk.contrast(with: palette.accent), 4.5, preset.id)
    }
    let photo = KeyboardThemePalette.photo
    XCTAssertGreaterThanOrEqual(
      photo.ink.contrast(
        with: photo.surface.blended(over: .white, opacity: photo.backdropScrimOpacity)), 4.5)
  }
  func testDefaultAndCorruptAppearanceUseUnchangedSystemRendering() throws {
    let suite = "appearance-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = KeyboardPreferences(defaults: defaults)
    XCTAssertEqual(preferences.appearance, KeyboardAppearance())
    defaults.set(Data("invalid".utf8), forKey: "keyboard.appearance.v1")
    XCTAssertEqual(preferences.appearance, KeyboardAppearance())
    defaults.set(
      try JSONEncoder().encode(KeyboardAppearance(themeID: "future-theme")),
      forKey: "keyboard.appearance.v1")
    XCTAssertEqual(preferences.appearance, KeyboardAppearance())
    preferences.appearance = .init(themeID: "blue", mode: .dark, keyOutlines: true)
    let first = preferences.appearance
    XCTAssertEqual(first.themeID, "blue")
    XCTAssertTrue(first.keyOutlines)
    XCTAssertNotNil(first.revision)
    preferences.appearance = first
    XCTAssertNotEqual(preferences.appearance.revision, first.revision)
    XCTAssertEqual(KeyboardPreferences(defaults: defaults).appearance, preferences.appearance)
  }
  func testGlassSettingsRoundTripAndLegacyThemesKeepTheirOriginalLook() throws {
    let appearance = KeyboardAppearance(themeID: "blue", keyOutlines: true,
      keyTransparency: 0.7, keyBorderStrength: 0.9)
    XCTAssertEqual(try JSONDecoder().decode(KeyboardAppearance.self,
      from: JSONEncoder().encode(appearance)), appearance)
    let legacyAppearance = Data(#"{"themeID":"blue","mode":"automatic","keyOutlines":false}"#.utf8)
    let restored = try JSONDecoder().decode(KeyboardAppearance.self, from: legacyAppearance)
    XCTAssertEqual(restored.keyTransparency, 0)
    XCTAssertEqual(restored.keyBorderStrength, 0.5)
    XCTAssertFalse(KeyboardAppearance(themeID: "blue", keyTransparency: .nan).isRecognized)
    XCTAssertFalse(KeyboardAppearance(themeID: "blue", keyTransparency: 1).isRecognized)

    let photo = KeyboardPhotoTheme(id: UUID(), revision: UUID(), name: "Sea Light",
      crop: .init(), brightness: 0.7, keyTransparency: 0.6,
      keyOutlines: true, keyBorderStrength: 0.8)
    XCTAssertEqual(try JSONDecoder().decode(KeyboardPhotoTheme.self,
      from: JSONEncoder().encode(photo)), photo)
    let legacyPhoto = Data(#"{"id":"\#(photo.id)","revision":"\#(photo.revision)","name":"Sea Light","crop":{"centerX":0.5,"centerY":0.5,"zoom":1},"brightness":0.7}"#.utf8)
    let restoredPhoto = try JSONDecoder().decode(KeyboardPhotoTheme.self, from: legacyPhoto)
    XCTAssertEqual(restoredPhoto.keyTransparency, 0)
    XCTAssertFalse(restoredPhoto.keyOutlines)
    XCTAssertEqual(restoredPhoto.keyBorderStrength, 0.5)
  }
  func testCropAlwaysStaysInsideImageAndPreservesAspectRatio() {
    for size in [(10.0, 8000.0), (8000, 10), (2048, 2048), (4000, 3000)] {
      for center in [-10.0, 0, 0.5, 1, 10, .nan] {
        for zoom in [0.0, 1, 2, 4, 20, .nan] {
          let rect = ThemePhotoCrop(centerX: center, centerY: center, zoom: zoom).rectangle(
            imageWidth: size.0, imageHeight: size.1)
          XCTAssertGreaterThanOrEqual(rect.x, -0.00001)
          XCTAssertGreaterThanOrEqual(rect.y, -0.00001)
          XCTAssertLessThanOrEqual(rect.x + rect.width, 1.00001)
          XCTAssertLessThanOrEqual(rect.y + rect.height, 1.00001)
          XCTAssertEqual(
            rect.width * size.0 / (rect.height * size.1), ThemePhotoCrop.aspectRatio,
            accuracy: 0.00001)
        }
      }
    }
  }
  func testPhotoPublicationFailurePreservesPreviousRevisionAndSource() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardPhotoThemeStore(directory: directory)
    let first = KeyboardPhotoTheme(
      id: UUID(), revision: UUID(), name: "Original", crop: .init(), brightness: 0.6)
    let bytes = Data([1, 2, 3])
    try store.save(first, original: bytes, rendered: bytes, thumbnail: bytes)
    XCTAssertEqual(store.photos, [first])
    XCTAssertEqual(store.photo(id: first.id), first)
    XCTAssertNil(store.photo(id: UUID()))
    let updated = KeyboardPhotoTheme(
      id: first.id, revision: UUID(), name: "Edited", crop: .init(zoom: 2), brightness: 0.4)
    // Block publication after new image files have been written.
    let manifest = directory.appendingPathComponent("catalog.json")
    let savedManifest = try Data(contentsOf: manifest)
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.save(updated, original: nil, rendered: bytes, thumbnail: bytes))
    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.originalURL(first.id))), bytes)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: try XCTUnwrap(store.renderURL(first)).path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: try XCTUnwrap(store.renderURL(updated)).path))
    try FileManager.default.removeItem(at: manifest)
    try savedManifest.write(to: manifest)
    XCTAssertEqual(store.photos, [first])
    try store.save(updated, original: nil, rendered: bytes, thumbnail: bytes)
    XCTAssertEqual(store.photos, [updated])
    try store.remove(updated)
    XCTAssertTrue(store.photos.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: try XCTUnwrap(store.renderURL(first)).path),
      "Deletion must also remove superseded photo copies")
  }
  func testUnavailableStoreAndInvalidMetadataDoNotPublish() {
    let store = KeyboardPhotoThemeStore(directory: nil)
    let photo = KeyboardPhotoTheme(
      id: UUID(), revision: UUID(), name: "Photo", crop: .init(), brightness: 0.7)
    XCTAssertThrowsError(
      try store.save(photo, original: Data([1]), rendered: Data([1]), thumbnail: Data([1])))
    XCTAssertTrue(store.photos.isEmpty)
  }

  func testPhotoNameMigrationAndDefaultAvoidExistingCustomNames() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardPhotoThemeStore(directory: directory)
    let bytes = Data([1, 2, 3])
    let first = KeyboardPhotoTheme(
      id: UUID(), revision: UUID(), name: "My Photo", crop: .init(), brightness: 0.6)
    let second = KeyboardPhotoTheme(
      id: UUID(), revision: UUID(), name: " custom  1 ", crop: .init(), brightness: 0.6)
    let third = KeyboardPhotoTheme(
      id: UUID(), revision: UUID(), name: "My Photo", crop: .init(), brightness: 0.6)
    try store.save(first, original: bytes, rendered: bytes, thumbnail: bytes)
    try store.save(second, original: bytes, rendered: bytes, thumbnail: bytes)
    try store.save(third, original: bytes, rendered: bytes, thumbnail: bytes)

    XCTAssertEqual(store.nextAvailablePhotoName(), "Custom 2")
    try store.migrateLegacyPhotoNames()
    XCTAssertEqual(store.photo(id: first.id)?.name, "Custom 2")
    XCTAssertEqual(store.photo(id: second.id)?.name, " custom  1 ")
    XCTAssertEqual(store.photo(id: third.id)?.name, "Custom 3")
    XCTAssertEqual(store.nextAvailablePhotoName(), "Custom 4")
    XCTAssertFalse(try store.renameGeneratedPhoto(first, to: "Blue Meadow"),
      "A model result for stale metadata must not replace a newer name")
    let current = try XCTUnwrap(store.photo(id: first.id))
    XCTAssertTrue(try store.renameGeneratedPhoto(current, to: "Blue Meadow"))
    XCTAssertEqual(store.photo(id: first.id)?.name, "Blue Meadow")
    let other = try XCTUnwrap(store.photo(id: third.id))
    XCTAssertFalse(try store.renameGeneratedPhoto(other, to: "Blue Meadow"),
      "Model suggestions cannot collide with an existing photo name")
  }
}
