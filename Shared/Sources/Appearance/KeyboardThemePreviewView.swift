#if canImport(UIKit)
  import UIKit

  /// Full previews and catalog thumbnails share production keys, layout and
  /// native glass. This presentation-only renderer never loads the typing engine.
  @MainActor
  final class KeyboardThemePreviewView: UIView {
    private let board = UIView()
    private let nativeBackground = UIInputView(frame: .zero, inputViewStyle: .keyboard)
    private let backdrop = KeyboardThemeBackdropView()
    private var group: UIView = UIView()
    private var rows: [[KeyboardKeyButton]] = []
    private let suggestions = UILabel()
    private var selection: KeyboardAppearance?
    private var photo: CGImage?
    private var editingCrop: ThemePhotoCrop?
    private var editingBrightness: Double = 1
    private var renderedScheme: ThemeColorScheme?

    override init(frame: CGRect) {
      super.init(frame: frame)
      registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
        (view: KeyboardThemePreviewView, _) in
        if let selection = view.selection {
          view.display(selection, photo: view.photo, editingCrop: view.editingCrop,
            editingBrightness: view.editingBrightness)
        }
        view.setNeedsLayout()
      }
      isUserInteractionEnabled = false
      accessibilityElementsHidden = true
      clipsToBounds = true
      layer.cornerRadius = 16
      addSubview(board)
      // The containing app has no host-owned keyboard backdrop. A semantic
      // gray underlay makes the unchanged translucent System keys visible here;
      // the actual extension keeps its existing UIInputView material untouched.
      nativeBackground.backgroundColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGray6 : .systemGray4
      }
      board.addSubview(nativeBackground)
      board.addSubview(backdrop)
      if #available(iOS 26.0, *) {
        let effect = UIGlassContainerEffect()
        effect.spacing = 0
        let container = UIVisualEffectView(effect: effect)
        board.addSubview(container)
        group = container.contentView
      } else {
        board.addSubview(group)
      }
      suggestions.text = "আমি                  বাংলা                  লিখি"
      suggestions.textAlignment = .center
      suggestions.font = .systemFont(ofSize: 17)
      board.addSubview(suggestions)
    }
    required init?(coder: NSCoder) { fatalError("Unused") }
    func display(_ appearance: KeyboardAppearance, photo: CGImage?,
      editingCrop: ThemePhotoCrop? = nil, editingBrightness: Double = 1) {
      let scheme: ThemeColorScheme = appearance.mode == .dark ? .dark
        : appearance.mode == .light ? .light
        : traitCollection.userInterfaceStyle == .dark ? .dark : .light
      guard selection != appearance || self.photo !== photo
        || self.editingCrop != editingCrop || self.editingBrightness != editingBrightness
        || renderedScheme != scheme else {
        return
      }
      let rebuildKeys = selection?.themeID != appearance.themeID || renderedScheme != scheme
      renderedScheme = scheme
      selection = appearance
      self.photo = photo
      self.editingCrop = editingCrop
      self.editingBrightness = editingBrightness
      let preset = KeyboardThemeCatalog.preset(appearance.themeID)
      let palette = preset.map { KeyboardThemePalette(preset: $0, scheme: scheme) }
        ?? (appearance.photoID != nil ? .photo(for: scheme) : nil)
      overrideUserInterfaceStyle = appearance.mode == .light ? .light
        : appearance.mode == .dark ? .dark : .unspecified
      let keyStyle: UIUserInterfaceStyle = palette == nil ? .unspecified
        : scheme == .dark ? .dark : .light
      (group.superview as? UIVisualEffectView)?.overrideUserInterfaceStyle = keyStyle
      group.overrideUserInterfaceStyle = keyStyle
      backdrop.display(preset: preset, photo: photo, palette: palette,
        editingCrop: editingCrop, editingBrightness: editingBrightness)
      suggestions.textColor = KeyboardTheme.suggestionTextColor(for: traitCollection)
      if rebuildKeys {
        rows.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        rows = KeyboardLayoutProvider.rows(for: .letters).map { row in
          row.keys.map { key in
            let button = KeyboardKeyButton(
              key: key, themePalette: palette, keyOutlines: appearance.keyOutlines,
              keyTransparency: appearance.keyTransparency,
              keyBorderStrength: appearance.keyBorderStrength)
            group.addSubview(button)
            return button
          }
        }
      }
      if !rebuildKeys {
        for button in rows.flatMap({ $0 }) {
          button.updateThemeSurface(transparency: appearance.keyTransparency,
            outlines: appearance.keyOutlines, borderStrength: appearance.keyBorderStrength)
        }
      }
      if rebuildKeys { setNeedsLayout() }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      suggestions.textColor = KeyboardTheme.suggestionTextColor(for: traitCollection)
      let width: CGFloat = 414
      let metrics = KeyboardTheme.metrics(
        for: CGSize(width: width, height: 280),
        traitCollection: traitCollection.modifyingTraits {
          $0.userInterfaceIdiom = .phone
          $0.verticalSizeClass = .regular
          $0.horizontalSizeClass = .compact
        })
      let height: CGFloat = 280
      let scale = min(bounds.width / width, bounds.height / height)
      board.bounds = CGRect(x: 0, y: 0, width: width, height: height)
      board.center = CGPoint(x: bounds.midX, y: bounds.midY)
      board.transform = CGAffineTransform(scaleX: scale, y: scale)
      nativeBackground.frame = board.bounds
      backdrop.frame = board.bounds
      backdrop.alignWithNativeSuggestionBand(
        height: metrics.suggestionHeight,
        keyFieldTop: metrics.suggestionHeight + metrics.keyboardInsets.top)
      (group.superview as? UIVisualEffectView)?.frame = board.bounds
      group.frame = board.bounds
      suggestions.frame = CGRect(x: 0, y: 0, width: width, height: metrics.suggestionHeight)
      let layouts = KeyboardLayoutProvider.rows(for: .letters)
      for (index, buttons) in rows.enumerated() {
        let frames = KeyboardLayoutGeometry.keyFrames(
          for: layouts[index], availableWidth: Double(width - 12),
          keySpacing: Double(metrics.keySpacing))
        for (button, frame) in zip(buttons, frames) {
          button.frame = CGRect(
            x: frame.x + 6,
            y: Double(
              metrics.suggestionHeight + metrics.keyboardInsets.top + CGFloat(index)
                * (metrics.minimumKeyHeight + metrics.rowSpacing)),
            width: frame.width, height: Double(metrics.minimumKeyHeight))
          button.updateAppearance(
            shifted: false, traitCollection: button.traitCollection, metrics: metrics,
            showsSpaceIntro: true)
        }
      }
    }
  }
#endif
