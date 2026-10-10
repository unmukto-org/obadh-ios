import Foundation

struct KeyboardAppearance: Codable, Equatable, Sendable {
  enum Mode: String, Codable, CaseIterable, Sendable { case automatic, light, dark }
  var themeID = "system"
  var mode: Mode = .automatic
  var keyOutlines = false
  var revision: UUID?

  var photoID: UUID? {
    guard themeID.hasPrefix("photo.") else { return nil }
    return UUID(uuidString: String(themeID.dropFirst(6)))
  }
  var isSystem: Bool { themeID == "system" }
  var isRecognized: Bool {
    isSystem || photoID != nil || KeyboardThemeCatalog.preset(themeID) != nil
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

  init(preset: KeyboardThemePreset) {
    let samples = preset.samples.map(ThemeColor.init)
    let whiteInk = preset.palette[3] & 0xFFFFFF == 0xFFFFFF
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
    opaqueKey = tint.blended(
      over: tint.blended(over: ThemeColor(preset.palette[0]), opacity: scrim),
      opacity: whiteInk ? 0.24 : 0.42)
    let originalAccent = ThemeColor(preset.palette[4])
    accent = originalAccent
    actionInk =
      ThemeColor.white.contrast(with: originalAccent)
        >= ThemeColor.black.contrast(with: originalAccent) ? .white : .black
  }

  /// Worst-case white photo remains readable; the editor may make it dimmer.
  static let photo = KeyboardThemePalette()
  private init() {
    ink = .white
    surface = .black
    tintOpacity = 0.24
    accent = ThemeColor(0xFF0A_84FF)
    actionInk = .black
    backdropScrimOpacity = 0.55
    prefersDark = true
    opaqueKey = ThemeColor(0xFF28_282C)
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
