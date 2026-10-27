import Foundation

struct KeyboardAppearance: Codable, Equatable, Sendable {
  enum Mode: String, Codable, CaseIterable, Sendable { case automatic, light, dark }
  var themeID = "system"
  var mode: Mode = .automatic
  var keyOutlines = false
  /// Fraction of the themed key surface that reveals the artwork beneath it.
  var keyTransparency = 0.0
  var keyBorderStrength = 0.5
  var revision: UUID?

  init(themeID: String = "system", mode: Mode = .automatic, keyOutlines: Bool = false,
    keyTransparency: Double = 0, keyBorderStrength: Double = 0.5, revision: UUID? = nil) {
    self.themeID = themeID
    self.mode = mode
    self.keyOutlines = keyOutlines
    self.keyTransparency = keyTransparency
    self.keyBorderStrength = keyBorderStrength
    self.revision = revision
  }

  private enum CodingKeys: String, CodingKey {
    case themeID, mode, keyOutlines, keyTransparency, keyBorderStrength, revision
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    themeID = try values.decode(String.self, forKey: .themeID)
    mode = try values.decode(Mode.self, forKey: .mode)
    keyOutlines = try values.decode(Bool.self, forKey: .keyOutlines)
    keyTransparency = try values.decodeIfPresent(Double.self, forKey: .keyTransparency) ?? 0
    keyBorderStrength = try values.decodeIfPresent(Double.self, forKey: .keyBorderStrength) ?? 0.5
    revision = try values.decodeIfPresent(UUID.self, forKey: .revision)
  }

  var photoID: UUID? {
    guard themeID.hasPrefix("photo.") else { return nil }
    return UUID(uuidString: String(themeID.dropFirst(6)))
  }
  var isSystem: Bool { themeID == "system" }
  var isRecognized: Bool {
    keyTransparency.isFinite && (0...0.85).contains(keyTransparency)
      && keyBorderStrength.isFinite && (0...1).contains(keyBorderStrength)
      && (isSystem || photoID != nil || KeyboardThemeCatalog.preset(themeID) != nil)
  }
}

struct KeyboardThemePreset: Equatable, Identifiable, Sendable {
  let id: String
  let name: String
  let group: String
  /// ARGB reference colors: background, key, utility, ink, accent.
  let palette: [UInt32]
  let gradient: [UInt32]
  let positions: [Double]
  /// Row-major square color grid, with bilinear filtering between sample nodes.
  let mesh: [UInt32]
  var samples: [UInt32] { !mesh.isEmpty ? mesh : (!gradient.isEmpty ? gradient : [palette[0]]) }
}

enum KeyboardThemeCatalog {
  static let groups = ["Colors", "Light gradient", "Dark gradient"]
  private static let index = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
  static func preset(_ id: String) -> KeyboardThemePreset? { index[id] }
}

enum ThemeColorScheme: Sendable, Equatable {
  case light, dark
  var isDark: Bool { self == .dark }
}

/// Exact sRGB calculations shared by palette selection and its acceptance tests.
struct ThemeColor: Equatable, Sendable {
  let red: Double
  let green: Double
  let blue: Double
  init(_ argb: UInt32) {
    red = Double((argb >> 16) & 255) / 255
    green = Double((argb >> 8) & 255) / 255
    blue = Double(argb & 255) / 255
  }
  init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }
  static let black = ThemeColor(0xFF00_0000)
  static let white = ThemeColor(0xFFFF_FFFF)
  func blended(over background: ThemeColor, opacity: Double) -> ThemeColor {
    let a = min(1, max(0, opacity))
    return ThemeColor(
      red: red * a + background.red * (1 - a),
      green: green * a + background.green * (1 - a),
      blue: blue * a + background.blue * (1 - a))
  }
  var luminance: Double {
    func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
  }
  func contrast(with other: ThemeColor) -> Double {
    (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
  }
}

struct KeyboardThemePalette: Equatable, Sendable {
  let ink: ThemeColor
  let surface: ThemeColor
  let tintOpacity: Double
  let accent: ThemeColor
  let actionInk: ThemeColor
  let backdropScrimOpacity: Double
  let prefersDark: Bool
  let opaqueKey: ThemeColor

  init(preset: KeyboardThemePreset, scheme: ThemeColorScheme? = nil) {
    let samples = preset.samples.map(ThemeColor.init)
    let whiteInk = scheme?.isDark ?? (preset.palette[3] & 0xFFFFFF == 0xFFFFFF)
    prefersDark = whiteInk
    let chosenInk: ThemeColor = whiteInk ? .white : .black
    ink = chosenInk
    let tint: ThemeColor = whiteInk ? .black : .white
    // Establish a readable entire backdrop first (suggestions and flick
    // legends live outside the key surfaces), then use native glass above it.
    var scrim = 0.0
    while samples.contains(where: {
      chosenInk.contrast(with: tint.blended(over: $0, opacity: scrim)) < 4.5
    }), scrim < 0.75 {
      scrim += 0.025
    }
    backdropScrimOpacity = scrim
    surface = tint
    tintOpacity = whiteInk ? 0.24 : 0.42
    opaqueKey = whiteInk ? ThemeColor(0xFF1C_1C1E) : ThemeColor(0xFFF2_F2F7)
    let originalAccent = ThemeColor(preset.palette[4])
    accent = originalAccent
    actionInk =
      ThemeColor.white.contrast(with: originalAccent)
        >= ThemeColor.black.contrast(with: originalAccent) ? .white : .black
  }

  /// Both treatments remain readable over the worst-case opposing photo color.
  static func photo(for scheme: ThemeColorScheme) -> KeyboardThemePalette {
    KeyboardThemePalette(photoScheme: scheme)
  }
  private init(photoScheme scheme: ThemeColorScheme) {
    ink = scheme.isDark ? .white : .black
    surface = scheme.isDark ? .black : .white
    tintOpacity = scheme.isDark ? 0.24 : 0.42
    accent = ThemeColor(0xFF0A_84FF)
    actionInk = .black
    backdropScrimOpacity = 0.55
    prefersDark = scheme.isDark
    opaqueKey = scheme.isDark ? ThemeColor(0xFF1C_1C1E) : ThemeColor(0xFFF2_F2F7)
  }
}

struct ThemePhotoCrop: Codable, Equatable, Sendable {
  var centerX = 0.5
  var centerY = 0.5
  var zoom = 1.0
  static let aspectRatio = 1.5

  func rectangle(imageWidth: Double, imageHeight: Double) -> (
    x: Double, y: Double, width: Double, height: Double
  ) {
    guard imageWidth > 0, imageHeight > 0 else { return (0, 0, 1, 1) }
    let aspect = imageWidth / imageHeight
    let z = zoom.isFinite ? min(4, max(1, zoom)) : 1
    let w = min(1, Self.aspectRatio / aspect) / z
    let h = min(1, aspect / Self.aspectRatio) / z
    let cx = centerX.isFinite ? min(1 - w / 2, max(w / 2, centerX)) : 0.5
    let cy = centerY.isFinite ? min(1 - h / 2, max(h / 2, centerY)) : 0.5
    return (cx - w / 2, cy - h / 2, w, h)
  }
}
