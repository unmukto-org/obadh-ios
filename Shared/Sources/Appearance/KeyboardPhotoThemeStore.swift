import Foundation

struct KeyboardPhotoTheme: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let revision: UUID
  var name: String
  let crop: ThemePhotoCrop
  let brightness: Double
  let keyTransparency: Double
  let keyOutlines: Bool
  let keyBorderStrength: Double
  var themeID: String { "photo." + id.uuidString }

  init(id: UUID, revision: UUID, name: String, crop: ThemePhotoCrop, brightness: Double,
    keyTransparency: Double = 0, keyOutlines: Bool = false, keyBorderStrength: Double = 0.5) {
    self.id = id
    self.revision = revision
    self.name = name
    self.crop = crop
    self.brightness = brightness
    self.keyTransparency = keyTransparency
    self.keyOutlines = keyOutlines
    self.keyBorderStrength = keyBorderStrength
  }

  private enum CodingKeys: String, CodingKey {
    case id, revision, name, crop, brightness, keyTransparency, keyOutlines, keyBorderStrength
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    revision = try values.decode(UUID.self, forKey: .revision)
    name = try values.decode(String.self, forKey: .name)
    crop = try values.decode(ThemePhotoCrop.self, forKey: .crop)
    brightness = try values.decode(Double.self, forKey: .brightness)
    keyTransparency = try values.decodeIfPresent(Double.self, forKey: .keyTransparency) ?? 0
    keyOutlines = try values.decodeIfPresent(Bool.self, forKey: .keyOutlines) ?? false
    keyBorderStrength = try values.decodeIfPresent(Double.self, forKey: .keyBorderStrength) ?? 0.5
  }
}

/// The containing app is the sole writer. Immutable revision files are published
/// before the atomic manifest, so readers never see an incomplete image.
struct KeyboardPhotoThemeStore: Sendable {
  enum Failure: Error { case unavailable, invalidImage, storageFailure, invalidMetadata }
  let directory: URL?
  init(
    directory: URL? = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: ObadhIdentity.appGroupID)?.appendingPathComponent(
        "KeyboardThemes", isDirectory: true)
  ) {
    self.directory = directory
  }
  private struct Manifest: Codable {
    var version = 1
    var photos: [KeyboardPhotoTheme]
  }
  var photos: [KeyboardPhotoTheme] {
    guard directory != nil, let manifest = try? loadManifest() else { return [] }
    var seen = Set<UUID>()
    return manifest.photos.filter { seen.insert($0.id).inserted && isReadable($0) }
  }
  /// Finds the first positive `Custom n` name not used by any saved record.
  /// Parsing treats spelling and whitespace variants as the same name, so a
  /// generated name cannot collide with a prior generated or user-entered one.
  func nextAvailablePhotoName() -> String {
    let records = (try? loadManifest().photos) ?? []
    let used = Set(records.compactMap { customPhotoNumber(in: $0.name) })
    var number = 1
    while used.contains(number) { number += 1 }
    return "Custom \(number)"
  }
  func isGeneratedPhotoName(_ name: String) -> Bool {
    customPhotoNumber(in: name) != nil
  }

  func nameIsAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
    let normalized = normalizedPhotoName(name)
    guard !normalized.isEmpty else { return false }
    let records = (try? loadManifest().photos) ?? []
    return !records.contains { $0.id != id && normalizedPhotoName($0.name) == normalized }
  }

  /// The model may return after a photo was edited or deleted. Only update the
  /// exact generated-name revision that was analyzed.
  func renameGeneratedPhoto(_ photo: KeyboardPhotoTheme, to name: String) throws -> Bool {
    guard let directory else { throw Failure.unavailable }
    var manifest = try loadManifest()
    guard let index = manifest.photos.firstIndex(where: { $0.id == photo.id }),
      manifest.photos[index].revision == photo.revision,
      manifest.photos[index].name == photo.name,
      isGeneratedPhotoName(photo.name),
      !name.isEmpty, name.count <= 80,
      !manifest.photos.contains(where: {
        $0.id != photo.id && normalizedPhotoName($0.name) == normalizedPhotoName(name)
      })
    else { return false }
    manifest.photos[index].name = name
    try write(JSONEncoder().encode(manifest), to: directory.appendingPathComponent("catalog.json"))
    return true
  }

  /// Migrates the former universal placeholder without touching image files or
  /// revisions. Manifest publication is atomic, exactly like a normal save.
  func migrateLegacyPhotoNames() throws {
    guard let directory else { throw Failure.unavailable }
    var manifest = try loadManifest()
    let legacyIndexes = manifest.photos.indices.filter {
      normalizedPhotoName(manifest.photos[$0].name) == "my photo"
    }
    guard !legacyIndexes.isEmpty else { return }

    var used = Set(manifest.photos.enumerated().compactMap { index, photo in
      legacyIndexes.contains(index) ? nil : customPhotoNumber(in: photo.name)
    })
    var candidate = 1
    for index in legacyIndexes {
      while used.contains(candidate) { candidate += 1 }
      manifest.photos[index].name = "Custom \(candidate)"
      used.insert(candidate)
      candidate += 1
    }
    try write(JSONEncoder().encode(manifest), to: directory.appendingPathComponent("catalog.json"))
  }
  func photo(id: UUID) -> KeyboardPhotoTheme? {
    guard let record = try? loadManifest().photos.first(where: { $0.id == id }), isReadable(record)
    else { return nil }
    return record
  }
  private func isReadable(_ photo: KeyboardPhotoTheme) -> Bool {
    guard let url = renderURL(photo) else { return false }
    return !photo.name.isEmpty && photo.name.count <= 80
      && photo.brightness.isFinite && (0...1).contains(photo.brightness)
      && photo.keyTransparency.isFinite && (0...0.85).contains(photo.keyTransparency)
      && photo.keyBorderStrength.isFinite && (0...1).contains(photo.keyBorderStrength)
      && photo.crop.zoom.isFinite && (1...4).contains(photo.crop.zoom)
      && photo.crop.centerX.isFinite && (0...1).contains(photo.crop.centerX)
      && photo.crop.centerY.isFinite && (0...1).contains(photo.crop.centerY)
      && FileManager.default.fileExists(atPath: url.path)
  }
  func originalURL(_ id: UUID) -> URL? {
    directory?.appendingPathComponent(id.uuidString + "-source.jpg")
  }
  func renderURL(_ photo: KeyboardPhotoTheme) -> URL? {
    directory?.appendingPathComponent(
      photo.id.uuidString + "-" + photo.revision.uuidString + "-render.jpg")
  }
  func thumbnailURL(_ photo: KeyboardPhotoTheme) -> URL? {
    directory?.appendingPathComponent(
      photo.id.uuidString + "-" + photo.revision.uuidString + "-thumb.jpg")
  }

  func save(_ photo: KeyboardPhotoTheme, original: Data?, rendered: Data, thumbnail: Data) throws {
    guard let directory else { throw Failure.unavailable }
    guard photo.name.count <= 80, !photo.name.isEmpty,
      photo.brightness.isFinite, (0...1).contains(photo.brightness),
      photo.keyTransparency.isFinite, (0...0.85).contains(photo.keyTransparency),
      photo.keyBorderStrength.isFinite, (0...1).contains(photo.keyBorderStrength),
      photo.crop.zoom.isFinite, (1...4).contains(photo.crop.zoom),
      photo.crop.centerX.isFinite, (0...1).contains(photo.crop.centerX),
      photo.crop.centerY.isFinite, (0...1).contains(photo.crop.centerY),
      rendered.count <= 4_000_000, thumbnail.count <= 250_000,
      !rendered.isEmpty, !thumbnail.isEmpty, (original?.count ?? 0) <= 8_000_000
    else { throw Failure.invalidImage }
    var records = try loadManifest().photos
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = originalURL(photo.id)!
    let render = renderURL(photo)!
    let thumb = thumbnailURL(photo)!
    guard !FileManager.default.fileExists(atPath: render.path),
      !FileManager.default.fileExists(atPath: thumb.path)
    else { throw Failure.invalidMetadata }
    let createdSource = !FileManager.default.fileExists(atPath: source.path)
    do {
      if createdSource {
        guard let original, !original.isEmpty else { throw Failure.invalidImage }
        try write(original, to: source)
      }
      try write(rendered, to: render)
      try write(thumbnail, to: thumb)
      records.removeAll { $0.id == photo.id }
      records.append(photo)
      let manifestData = try JSONEncoder().encode(Manifest(photos: records))
      guard manifestData.count <= 512_000 else { throw Failure.invalidMetadata }
      try write(manifestData, to: directory.appendingPathComponent("catalog.json"))
    } catch {
      try? FileManager.default.removeItem(at: render)
      try? FileManager.default.removeItem(at: thumb)
      if createdSource { try? FileManager.default.removeItem(at: source) }
      throw error
    }
  }

  /// Publish removal first; the caller switches an active selection to System
  /// after this succeeds. A failed publication leaves the theme intact.
  func remove(_ photo: KeyboardPhotoTheme) throws {
    guard let directory else { throw Failure.unavailable }
    let remaining = try loadManifest().photos.filter { $0.id != photo.id }
    try write(
      JSONEncoder().encode(Manifest(photos: remaining)),
      to: directory.appendingPathComponent("catalog.json"))
    // Delete every revision of this photo, including superseded edits.
    // UUID-prefixed filenames cannot match a different theme or escape here.
    if let files = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      for file in files where file.lastPathComponent.hasPrefix(photo.id.uuidString + "-") {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }

  /// Old immutable revisions are retained for a day to protect a concurrent
  /// keyboard read, then reclaimed by the app. Never called by the extension.
  func collectUnusedRevisions(now: Date = Date()) {
    guard let directory, let manifest = try? loadManifest() else { return }
    let keep = Set(
      manifest.photos.flatMap {
        [
          originalURL($0.id)!.lastPathComponent,
          renderURL($0)!.lastPathComponent, thumbnailURL($0)!.lastPathComponent,
        ]
      } + ["catalog.json"])
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    for file in files where !keep.contains(file.lastPathComponent) {
      guard
        let date = try? file.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate,
        now.timeIntervalSince(date) > 86_400
      else { continue }
      try? FileManager.default.removeItem(at: file)
    }
  }
  private func loadManifest() throws -> Manifest {
    guard let directory else { throw Failure.unavailable }
    let url = directory.appendingPathComponent("catalog.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return Manifest(photos: []) }
    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512_000,
      let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)),
      manifest.version == 1
    else { throw Failure.invalidMetadata }
    return manifest
  }

  private func write(_ data: Data, to url: URL) throws {
    #if os(iOS)
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
    #endif
  }

  private func customPhotoNumber(in name: String) -> Int? {
    let words = normalizedPhotoName(name).split(separator: " ")
    guard words.count == 2, words[0] == "custom", let number = Int(words[1]), number > 0 else {
      return nil
    }
    return number
  }

  private func normalizedPhotoName(_ name: String) -> String {
    name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
