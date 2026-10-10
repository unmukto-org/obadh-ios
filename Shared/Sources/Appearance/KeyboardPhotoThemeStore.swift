import Foundation

struct KeyboardPhotoTheme: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let revision: UUID
  var name: String
  let crop: ThemePhotoCrop
  let brightness: Double
  var themeID: String { "photo." + id.uuidString }
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
    let photos: [KeyboardPhotoTheme]
  }
  var photos: [KeyboardPhotoTheme] {
    guard directory != nil, let manifest = try? loadManifest() else { return [] }
    var seen = Set<UUID>()
    return manifest.photos.filter { seen.insert($0.id).inserted && isReadable($0) }
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
}
