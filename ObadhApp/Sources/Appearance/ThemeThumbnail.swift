import SwiftUI
import UIKit

/// Gallery artwork uses the production backdrop, palette and key geometry.
/// Only the detail sheet allocates native glass effects.
struct ThemeThumbnail: UIViewRepresentable {
  let appearance: KeyboardAppearance
  var photo: CGImage? = nil

  func makeUIView(context: Context) -> ThemeThumbnailView { ThemeThumbnailView() }
  func updateUIView(_ view: ThemeThumbnailView, context: Context) {
    view.display(appearance, photo: photo)
  }
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
    keys.display(palette: palette, outlines: appearance.keyOutlines)
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    backdrop.frame = bounds
    keys.frame = bounds
    let metrics = KeyboardTheme.metrics(for: CGSize(width: 414, height: 280),
      traitCollection: traitCollection.modifyingTraits {
        $0.userInterfaceIdiom = .phone
        $0.verticalSizeClass = .regular
        $0.horizontalSizeClass = .compact
      })
    let scale = min(bounds.width / 414, bounds.height / 280)
    let topPadding = (bounds.height - 280 * scale) / 2
    backdrop.alignWithNativeSuggestionBand(
      height: topPadding + max(0, metrics.suggestionHeight - 5) * scale,
      revealHeight: (5 + metrics.keyboardInsets.top) * scale)
  }
}

/// Draw the real iPhone row geometry in one pass at 414 × 280, then scale it
/// to the card. The detail preview shows the final native glass material.
private final class ThemeThumbnailKeysView: UIView {
  private var palette: KeyboardThemePalette?
  private var outlines = false
  private let rows = KeyboardLayoutProvider.rows(for: .letters)
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
  func display(palette: KeyboardThemePalette?, outlines: Bool) {
    guard self.palette != palette || self.outlines != outlines else { return }
    self.palette = palette
    self.outlines = outlines
    setNeedsDisplay()
  }
  override func draw(_ rect: CGRect) {
    guard bounds.width > 0, bounds.height > 0, let context = UIGraphicsGetCurrentContext() else {
      return
    }
    let width: CGFloat = 414
    let height: CGFloat = 280
    let scale = min(bounds.width / width, bounds.height / height)
    context.saveGState()
    context.translateBy(x: (bounds.width - width * scale) / 2,
      y: (bounds.height - height * scale) / 2)
    context.scaleBy(x: scale, y: scale)
    defer { context.restoreGState() }

    let metrics = KeyboardTheme.metrics(for: CGSize(width: width, height: height),
      traitCollection: traitCollection.modifyingTraits {
        $0.userInterfaceIdiom = .phone
        $0.verticalSizeClass = .regular
        $0.horizontalSizeClass = .compact
      })
    let ink = palette?.ink.uiColor ?? KeyboardTheme.textColor(for: traitCollection)
    let keyFill = palette?.surface.uiColor.withAlphaComponent(palette?.tintOpacity ?? 0.55)
      ?? UIColor.white.withAlphaComponent(0.65)
    ("আমি                  বাংলা                  লিখি" as NSString).draw(
      in: CGRect(x: 8, y: 8, width: width - 16, height: metrics.suggestionHeight - 8),
      withAttributes: [.font: UIFont.systemFont(ofSize: 17),
        .foregroundColor: KeyboardTheme.suggestionTextColor(for: traitCollection),
        .paragraphStyle: paragraph])
    for (rowIndex, row) in rows.enumerated() {
      let frames = KeyboardLayoutGeometry.keyFrames(for: row,
        availableWidth: Double(width - 12), keySpacing: Double(metrics.keySpacing))
      let y = metrics.suggestionHeight + metrics.keyboardInsets.top
        + CGFloat(rowIndex) * (metrics.minimumKeyHeight + metrics.rowSpacing)
      for frame in frames where frame.key != .spacer {
        let keyRect = CGRect(x: frame.x + 6, y: Double(y), width: frame.width,
          height: Double(metrics.minimumKeyHeight))
        let path = UIBezierPath(roundedRect: keyRect, cornerRadius: metrics.keyCornerRadius)
        keyFill.setFill()
        path.fill()
        if outlines {
          ink.withAlphaComponent(0.25).setStroke()
          path.lineWidth = 1
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
