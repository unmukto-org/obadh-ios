import SwiftUI
import UIKit

/// Gallery artwork uses the production backdrop, palette and key geometry.
/// Only the detail sheet allocates native glass effects.
struct ThemeThumbnail: UIViewRepresentable {
  let appearance: KeyboardAppearance
  var photo: CGImage? = nil

  /// Width ÷ height of the card artwork (the key block, without a suggestion band).
  @MainActor static var aspectRatio: CGFloat { ThemeThumbnailGeometry.aspectRatio }

  func makeUIView(context: Context) -> ThemeThumbnailView { ThemeThumbnailView() }
  func updateUIView(_ view: ThemeThumbnailView, context: Context) {
    view.display(appearance, photo: photo)
  }
}

/// Real iPhone portrait geometry at 414 × 280, cropped to the four key rows.
/// The suggestion band is not part of the thumbnail; the detail preview keeps it.
@MainActor
enum ThemeThumbnailGeometry {
  static let width: CGFloat = 414
  static let height: CGFloat = 280
  /// Matches the 6pt side inset used for the key rows.
  static let margin: CGFloat = 6
  static let rows = KeyboardLayoutProvider.rows(for: .letters)
  static let metrics = KeyboardTheme.metrics(
    for: CGSize(width: width, height: height),
    traitCollection: UITraitCollection { traits in
      traits.userInterfaceIdiom = .phone
      traits.verticalSizeClass = .regular
      traits.horizontalSizeClass = .compact
    })
  static var firstRowY: CGFloat { metrics.suggestionHeight + metrics.keyboardInsets.top }
  /// The visible canvas region: key rows plus a uniform margin.
  static var content: CGRect {
    let count = CGFloat(rows.count)
    let block = count * metrics.minimumKeyHeight + max(0, count - 1) * metrics.rowSpacing
    return CGRect(x: 0, y: firstRowY - margin, width: width, height: block + 2 * margin)
  }
  static var aspectRatio: CGFloat { content.width / content.height }
}

@MainActor
final class ThemeThumbnailView: UIView {
  private let backdrop = KeyboardThemeBackdropView()
  private let keys = ThemeThumbnailKeysView()
  private var appearance: KeyboardAppearance?
  private var photo: CGImage?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    clipsToBounds = true
    backgroundColor = UIColor { traits in
      traits.userInterfaceStyle == .dark ? .systemGray6 : .systemGray4
    }
    addSubview(backdrop)
    addSubview(keys)
    registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
      (view: ThemeThumbnailView, _) in view.refresh()
    }
  }
  required init?(coder: NSCoder) { fatalError("Unused") }

  func display(_ appearance: KeyboardAppearance, photo: CGImage?) {
    guard self.appearance != appearance || self.photo !== photo else { return }
    self.appearance = appearance
    self.photo = photo
    refresh()
  }
  private func refresh() {
    guard let appearance else { return }
    let preset = KeyboardThemeCatalog.preset(appearance.themeID)
    let palette = preset.map(KeyboardThemePalette.init)
      ?? (appearance.photoID != nil ? .photo : nil)
    overrideUserInterfaceStyle = appearance.mode == .light ? .light
      : appearance.mode == .dark ? .dark : .unspecified
    backdrop.display(preset: preset, photo: photo, palette: palette)
    keys.display(palette: palette, outlines: appearance.keyOutlines,
      transparency: appearance.keyTransparency, borderStrength: appearance.keyBorderStrength)
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    // No suggestion band in the thumbnail, so the backdrop is not masked to
    // imitate the native strip: it fills the card behind the key rows.
    backdrop.frame = bounds
    keys.frame = bounds
  }
}

/// Draw the real iPhone row geometry in one pass, cropped to the key block,
/// then scale it to the card. The detail preview shows the final native glass material.
private final class ThemeThumbnailKeysView: UIView {
  private var palette: KeyboardThemePalette?
  private var outlines = false
  private var transparency = 0.0
  private var borderStrength = 0.5
  private let rows = ThemeThumbnailGeometry.rows
  private let paragraph: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    return style
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    contentMode = .redraw
    isUserInteractionEnabled = false
  }
  required init?(coder: NSCoder) { fatalError("Unused") }
  func display(palette: KeyboardThemePalette?, outlines: Bool, transparency: Double,
    borderStrength: Double) {
    guard self.palette != palette || self.outlines != outlines
      || self.transparency != transparency || self.borderStrength != borderStrength else { return }
    self.palette = palette
    self.outlines = outlines
    self.transparency = transparency
    self.borderStrength = borderStrength
    setNeedsDisplay()
  }
  override func draw(_ rect: CGRect) {
    guard bounds.width > 0, bounds.height > 0, let context = UIGraphicsGetCurrentContext() else {
      return
    }
    let width = ThemeThumbnailGeometry.width
    let content = ThemeThumbnailGeometry.content
    let scale = min(bounds.width / content.width, bounds.height / content.height)
    context.saveGState()
    context.translateBy(x: (bounds.width - content.width * scale) / 2,
      y: (bounds.height - content.height * scale) / 2)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -content.minX, y: -content.minY)
    defer { context.restoreGState() }

    let metrics = ThemeThumbnailGeometry.metrics
    let ink = palette?.ink.uiColor ?? KeyboardTheme.textColor(for: traitCollection)
    let keyFill = palette?.surface.uiColor.withAlphaComponent(
      (palette?.tintOpacity ?? 0.55) * (1 - transparency))
      ?? UIColor.white.withAlphaComponent(0.65)
    for (rowIndex, row) in rows.enumerated() {
      let frames = KeyboardLayoutGeometry.keyFrames(for: row,
        availableWidth: Double(width - 12), keySpacing: Double(metrics.keySpacing))
      let y = ThemeThumbnailGeometry.firstRowY
        + CGFloat(rowIndex) * (metrics.minimumKeyHeight + metrics.rowSpacing)
      for frame in frames where frame.key != .spacer {
        let keyRect = CGRect(x: frame.x + 6, y: Double(y), width: frame.width,
          height: Double(metrics.minimumKeyHeight))
        let path = UIBezierPath(roundedRect: keyRect, cornerRadius: metrics.keyCornerRadius)
        keyFill.setFill()
        path.fill()
        if outlines {
          ink.withAlphaComponent(0.15 + borderStrength * 0.3).setStroke()
          path.lineWidth = 0.5 + borderStrength
          path.stroke()
        }
        guard let label = label(for: frame.key) else { continue }
        let fontSize: CGFloat = frame.key == .space ? 13 : 19
        let font = UIFont.systemFont(ofSize: fontSize)
        let labelRect = CGRect(x: keyRect.minX + 2,
          y: keyRect.midY - font.lineHeight / 2,
          width: keyRect.width - 4, height: font.lineHeight + 2)
        (label as NSString).draw(in: labelRect, withAttributes: [
          .font: font, .foregroundColor: ink,
          .paragraphStyle: paragraph,
        ])
      }
    }
  }
  private func label(for key: KeyboardKey) -> String? {
    switch key {
    case .character(let value): value
    case .symbol(let symbol): symbol.label
    case .modeSwitch(let value): value
    case .space: "বাংলা (অবাধ)"
    case .returnKey: "↵"
    case .shift: "⇧"
    case .backspace: "⌫"
    case .emoji: "☺"
    case .globe: "◎"
    case .tab: "⇥"
    case .capsLock: "⇪"
    case .hideKeyboard: "⌄"
    case .spacer: nil
    }
  }
}
