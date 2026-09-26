import UIKit

final class KeyboardKeyButton: UIButton {
    let key: KeyboardKey
    // Finger input is resolved by the overlay. Assistive technologies activate
    // the semantic key directly and need the same controller action.
    var onAccessibilityActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard isEnabled, let onAccessibilityActivate else { return false }
        onAccessibilityActivate()
        return true
    }

    /// iPad draws a flick-down glyph above the primary one. Set by the controller
    /// from the idiom, so iPhone keys never grow a second label.
    /// Where a command key's glyph sits inside its key.
    ///
    /// Native iPadOS does NOT centre them: it pins each one to the key's
    /// bottom-OUTER corner, so the row's modifiers hug the outside edges of the
    /// keyboard. Measured on an iPad Pro 11-inch, in points from the key's edges:
    ///
    /// | key | left | right | bottom |
    /// |---|---|---|---|
    /// | tab, caps lock, left shift, globe, mic | 6.5 | — | 6.0 |
    /// | backspace, return, right shift, hide | — | 8.0 | 6.0 |
    /// | `.?123` (text rather than a symbol) | 8.0 | 9.0 | 9.0 |
    ///
    /// We centred all of them, which is the single loudest reason the keyboard
    /// read as "not native" next to Apple's.
    enum GlyphAlignment {
        case centred
        case bottomLeading
        case bottomTrailing
    }

    var glyphAlignment: GlyphAlignment = .centred
    var showsSecondaryLabel = false
    /// This key's row height, when the row is shorter than `minimumKeyHeight`.
    /// Only the 13-inch iPad's number row is (45.5pt against 61pt letter rows, 59
    /// against 79 in landscape); zero everywhere else, meaning "no adjustment".
    /// Type is scaled by the ratio, because `characterFontSize` is derived from the
    /// LETTER key — a 31.2pt Bangla digit in a 45.5pt key gave 19.5pt of ink where
    /// native's digit is 10pt, and no vertical placement rescues a glyph that size.
    var rowHeight: CGFloat = 0
    /// 0...1 through a downward flick. Native's Key Flicks animate the secondary
    /// glyph INTO the primary's place while the primary sinks and fades, so the key
    /// shows you what it is about to type before you commit. iPadOS does that in a
    /// private layer, so this reproduces it with plain transforms: the secondary
    /// travels to the primary's centre and grows to its size, the primary slides
    /// down and dissolves. Reset to 0 when the touch ends, whichever way it went.
    var flickProgress: CGFloat = 0 {
        didSet {
            guard oldValue != flickProgress else { return }
            applyFlickProgress()
        }
    }
    private let spaceLanguageLabel = UILabel()
    private let secondaryLabel = UILabel()
    private var keyPreviewText: String?
    private var currentMetrics = KeyboardTheme.defaultMetrics
    private var spaceLanguageTrailingConstraint: NSLayoutConstraint?
    private var spaceLanguageBottomConstraint: NSLayoutConstraint?
    private var secondaryTopConstraint: NSLayoutConstraint?
    private var titleOffsetRatio: CGFloat = 0
    /// Resting colours, captured so the flick can interpolate between them and
    /// restore exactly what was there — resolved for the current trait collection,
    /// since both are dynamic.
    private var restingSecondaryColor: UIColor = .secondaryLabel
    private var restingTitleColor: UIColor = .label
    /// How far down the resting (small) secondary is scaled from the size it is
    /// actually rendered at.
    private var secondaryRestScale: CGFloat = 1
    /// iOS 26+ Liquid Glass backing (a backmost, non-interactive glass view).
    /// nil below iOS 26, where the solid `backgroundColor` fill is used instead.
    /// Touches are owned entirely by `KeyboardTouchSurfaceView`, so this is purely
    /// visual (`isInteractive = false`).
    private var glassEffectView: UIVisualEffectView?

    init(key: KeyboardKey) {
        self.key = key
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateAppearance(
        shifted: Bool,
        traitCollection: UITraitCollection,
        metrics: KeyboardMetrics,
        showsSpaceIntro: Bool = false,
        spaceIntroText: String = "বাংলা (অবাধ)",
        spaceCaption: String = "বাংলা",
        capsLocked: Bool = false
    ) {
        currentMetrics = metrics
        let typeScale = rowHeight > 0 && metrics.minimumKeyHeight > 0
            ? rowHeight / metrics.minimumKeyHeight
            : 1
        layer.cornerRadius = metrics.keyCornerRadius
        layer.shadowRadius = metrics.keyShadowRadius
        layer.shadowOffset = metrics.keyShadowOffset
        if #available(iOS 26.0, *) {
            glassEffectView?.cornerConfiguration = .uniformCorners(radius: .fixed(metrics.keyCornerRadius))
        }
        spaceLanguageLabel.font = .systemFont(ofSize: metrics.spaceLanguageFontSize, weight: .regular)
        spaceLanguageTrailingConstraint?.constant = -max(8, metrics.keySpacing + 5)
        spaceLanguageBottomConstraint?.constant = -max(5, metrics.keyboardInsets.bottom + 3)

        applyPressedState(animated: false)
        setTitleColor(KeyboardTheme.textColor(for: traitCollection), for: .normal)
        tintColor = KeyboardTheme.textColor(for: traitCollection)
        setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: metrics.commandFontSize, weight: .regular),
            forImageIn: .normal
        )
        spaceLanguageLabel.textColor = KeyboardTheme.secondaryTextColor(for: traitCollection)

        switch key {
        case let .character(value):
            let displayText = shifted ? value.uppercased() : value
            setTitle(displayText, for: .normal)
            setImage(nil, for: .normal)
            titleLabel?.font = .systemFont(ofSize: metrics.characterFontSize * typeScale, weight: .regular)
            keyPreviewText = displayText
        case let .symbol(symbol):
            setTitle(symbol.label, for: .normal)
            setImage(nil, for: .normal)
            titleLabel?.font = .systemFont(ofSize: metrics.symbolFontSize * typeScale, weight: .regular)
            keyPreviewText = symbol.label
        case .space:
            setTitle(showsSpaceIntro ? spaceIntroText : nil, for: .normal)
            setImage(nil, for: .normal)
            titleLabel?.font = .systemFont(ofSize: metrics.spaceIntroFontSize, weight: .regular)
            spaceLanguageLabel.text = showsSpaceIntro ? nil : spaceCaption
            spaceLanguageLabel.alpha = showsSpaceIntro ? 0 : 1
            keyPreviewText = nil
        case .returnKey:
            setTitle(nil, for: .normal)
            setImage(UIImage(systemName: "arrow.turn.down.left"), for: .normal)
            keyPreviewText = nil
        case .shift:
            setTitle(nil, for: .normal)
            setImage(UIImage(systemName: shifted ? "shift.fill" : "shift"), for: .normal)
            keyPreviewText = nil
        case .backspace:
            setTitle(nil, for: .normal)
            setImage(UIImage(systemName: "delete.left"), for: .normal)
            keyPreviewText = nil
        case let .modeSwitch(value):
            setTitle(value, for: .normal)
            setImage(nil, for: .normal)
            titleLabel?.font = .systemFont(ofSize: metrics.modeSwitchFontSize, weight: .regular)
            keyPreviewText = nil
        case .emoji:
            setTitle(nil, for: .normal)
            setImage(nativeEmojiGlyph(pointSize: metrics.commandFontSize + 2), for: .normal)
            keyPreviewText = nil
        case .globe:
            setTitle(nil, for: .normal)
            setImage(
                UIImage(
                    systemName: "globe",
                    withConfiguration: UIImage.SymbolConfiguration(
                        pointSize: metrics.commandFontSize,
                        weight: .regular
                    )
                ),
                for: .normal
            )
            keyPreviewText = nil
        case .tab:
            setTitle(nil, for: .normal)
            setImage(UIImage(systemName: "arrow.right.to.line.compact"), for: .normal)
            keyPreviewText = nil
        case .capsLock:
            setTitle(nil, for: .normal)
            setImage(UIImage(systemName: capsLocked ? "capslock.fill" : "capslock"), for: .normal)
            keyPreviewText = nil
        case .hideKeyboard:
            setTitle(nil, for: .normal)
            setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
            keyPreviewText = nil
        }

        isAccessibilityElement = true
        accessibilityTraits = [.button, .keyboardKey]
        accessibilityValue = nil
        switch key {
        case .character, .symbol, .modeSwitch:
            accessibilityLabel = title(for: .normal)
        case .space: accessibilityLabel = "Space"
        case .returnKey: accessibilityLabel = "Return"
        case .shift:
            accessibilityLabel = "Shift"
            accessibilityValue = shifted ? "On" : "Off"
        case .backspace: accessibilityLabel = "Delete"
        case .emoji: accessibilityLabel = "Emoji"
        case .globe: accessibilityLabel = "Next keyboard"
        case .tab: accessibilityLabel = "Tab"
        case .capsLock:
            accessibilityLabel = "Caps Lock"
            accessibilityValue = capsLocked ? "On" : "Off"
        case .hideKeyboard: accessibilityLabel = "Hide keyboard"
        }

        updateSecondaryLabel(traitCollection: traitCollection, metrics: metrics, typeScale: typeScale)
    }

    /// The iPad flick-down glyph, drawn small in the top-left the way native does.
    /// Nothing is drawn when the key has no secondary, which is every key on
    /// iPhone and every command key everywhere.
    private func updateSecondaryLabel(
        traitCollection: UITraitCollection,
        metrics: KeyboardMetrics,
        typeScale: CGFloat
    ) {
        guard showsSecondaryLabel, let secondary = key.padSecondary else {
            secondaryLabel.isHidden = true
            titleOffsetRatio = 0
            return
        }
        secondaryLabel.isHidden = false
        secondaryLabel.text = secondary.label
        // Rendered at the PRIMARY size and scaled DOWN to rest. The flick then
        // scales toward 1.0, where the glyph is drawn at its native resolution.
        // Rendering small and scaling UP is what made it look zoomed and soft — a
        // 2x raster upscale of an 11.8pt glyph.
        let restFont = metrics.padSecondaryFontSize * typeScale
        let fullFont = metrics.characterFontSize * typeScale
        secondaryRestScale = fullFont > 0 ? restFont / fullFont : 1
        secondaryLabel.font = .systemFont(ofSize: fullFont, weight: .regular)
        restingSecondaryColor = KeyboardTheme.padSecondaryTextColor(for: traitCollection)
        restingTitleColor = KeyboardTheme.textColor(for: traitCollection)
        secondaryLabel.textColor = restingSecondaryColor
        secondaryTopConstraint?.constant = metrics.padSecondaryTopInset * typeScale
            + UIFont.systemFont(ofSize: restFont).lineHeight / 2
        // Native centres the primary glyph at ~70% of the key height rather than at
        // 50%, which is what makes room for the secondary without shrinking it.
        titleOffsetRatio = 0.185
        if flickProgress == 0 {
            secondaryLabel.transform = restTransform
        }
        setNeedsLayout()
    }

    /// Offset the primary glyph by a fraction of THIS key's height, not of
    /// `minimumKeyHeight`. The two are the same on every row except the 13-inch
    /// iPad's number row, which native draws 45.5pt tall against 61pt letter rows
    /// (59 against 79 in landscape). Measuring from the letter-row height there
    /// pushed the digit to 78% of its key with the ink flush against the bottom
    /// edge, where native sits at 70.3% with 8.5pt of clearance.
    /// Both labels are laid out at progress 0 and then transformed, so the resting
    /// geometry stays the single source of truth and nothing re-lays-out mid-drag.
    private func applyFlickProgress() {
        guard showsSecondaryLabel, !secondaryLabel.isHidden, let title = titleLabel else { return }
        let t = max(0, min(1, flickProgress))
        guard t > 0 else {
            secondaryLabel.transform = restTransform
            secondaryLabel.textColor = restingSecondaryColor
            title.alpha = 1
            return
        }
        // Ends at the KEY's centre, not the primary's. The primary rests at ~70% of
        // the key height to leave room for this label above it; sending the glyph
        // there left it sitting low. A key showing one glyph centres it, and that is
        // what this becomes.
        let rise = bounds.midY - secondaryLabel.center.y
        let scale = secondaryRestScale + (1 - secondaryRestScale) * t
        secondaryLabel.transform = CGAffineTransform(translationX: 0, y: rise * t)
            .scaledBy(x: scale, y: scale)
        // Size AND colour. Without the colour it grows into a big faint grey glyph
        // that never actually becomes the primary — the morph is what sells the
        // gesture, and half a morph reads as a bug.
        secondaryLabel.textColor = Self.blend(restingSecondaryColor, restingTitleColor, t)
        // The primary only fades; it does NOT move. Translating it as well meant a
        // half-transparent glyph visibly sliding back up on release, which is the
        // "awkward" part — there is nothing to slide back if it never left.
        title.alpha = 1 - t
    }

    /// Put the key back to rest with no animation, cancelling any spring-back in
    /// flight. Used when the flick COMMITS: the character is already in the
    /// document, so animating the old glyph back would show the key un-typing
    /// itself for the length of the animation.
    func snapFlickToRest() {
        secondaryLabel.layer.removeAllAnimations()
        titleLabel?.layer.removeAllAnimations()
        flickProgress = 0
        secondaryLabel.transform = restTransform
        secondaryLabel.textColor = restingSecondaryColor
        titleLabel?.alpha = 1
    }

    private var restTransform: CGAffineTransform {
        CGAffineTransform(scaleX: secondaryRestScale, y: secondaryRestScale)
    }

    private static func blend(_ from: UIColor, _ to: UIColor, _ t: CGFloat) -> UIColor {
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        guard from.getRed(&fr, green: &fg, blue: &fb, alpha: &fa),
              to.getRed(&tr, green: &tg, blue: &tb, alpha: &ta) else { return to }
        return UIColor(
            red: fr + (tr - fr) * t,
            green: fg + (tg - fg) * t,
            blue: fb + (tb - fb) * t,
            alpha: fa + (ta - fa) * t
        )
    }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        let rect = super.titleRect(forContentRect: contentRect)
            .offsetBy(dx: 0, dy: contentRect.height * titleOffsetRatio)
        // Text glyphs (`.?123`) sit a point further in and a point lower than the
        // symbols do — measured 8.0/9.0 against the symbols' 6.5/8.0 and 6.0.
        return align(rect, in: contentRect, textGlyph: true)
    }

    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        align(super.imageRect(forContentRect: contentRect), in: contentRect, textGlyph: false)
    }

    /// The insets here are the RECT's, not the ink's. An SF Symbol's visible ink
    /// sits inside its image rect by a couple of points, and a title rect carries
    /// its font's leading, so these are native's measured ink insets less that
    /// padding: aligning the rects to native's numbers directly put every glyph
    /// 2-3pt too far into the key.
    private func align(_ rect: CGRect, in contentRect: CGRect, textGlyph: Bool) -> CGRect {
        // nil insets means this family centres its command glyphs, which the iPad
        // mini does and every larger iPad does not.
        guard glyphAlignment != .centred, let ink = currentMetrics.padGlyphInsets else {
            return rect
        }
        // Native's numbers are INK insets; an SF Symbol's ink sits inside its image
        // rect and a title rect carries its font's leading, so back that padding out
        // or every glyph lands 2-3pt further into the key than it should.
        let padding: CGFloat = textGlyph ? 0.5 : 2
        let leading = max(0, ink.left - padding)
        let trailing = max(0, ink.right - padding)
        let bottom = max(0, ink.bottom - (textGlyph ? 4.5 : 2.5))
        var aligned = rect
        aligned.origin.y = contentRect.maxY - bottom - rect.height
        switch glyphAlignment {
        case .bottomLeading:
            aligned.origin.x = contentRect.minX + leading
        case .bottomTrailing:
            aligned.origin.x = contentRect.maxX - trailing - rect.width
        case .centred:
            break
        }
        return aligned
    }

    var previewText: String? {
        keyPreviewText
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = true
        layer.cornerRadius = KeyboardTheme.defaultMetrics.keyCornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = KeyboardTheme.defaultMetrics.keyShadowOpacity
        layer.shadowRadius = KeyboardTheme.defaultMetrics.keyShadowRadius
        layer.shadowOffset = KeyboardTheme.defaultMetrics.keyShadowOffset
        contentHorizontalAlignment = .center
        contentVerticalAlignment = .center

        // Only the `.regular`/`.clear` styles use a Liquid Glass effect view (its
        // specular rim is what the product owner flagged as "raised"); the
        // default `.translucent` and `.solid` use a plain fill in
        // applyPressedState instead. The touch surface owns hit-testing, so the
        // glass is non-interactive; the button's own layer keeps the shadow
        // (a clipped effect view can't cast an outer shadow).
        if #available(iOS 26.0, *) {
            let glassStyle: UIGlassEffect.Style?
            switch KeyboardGlassStyle.current {
            case .regular: glassStyle = .regular
            case .clear: glassStyle = .clear
            case .translucent, .solid: glassStyle = nil
            }
            if let glassStyle {
                let effect = UIGlassEffect(style: glassStyle)
                effect.isInteractive = false
                let effectView = UIVisualEffectView(effect: effect)
                effectView.isUserInteractionEnabled = false
                effectView.frame = bounds
                effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                effectView.cornerConfiguration = .uniformCorners(
                    radius: .fixed(KeyboardTheme.defaultMetrics.keyCornerRadius)
                )
                effectView.layer.cornerCurve = .continuous
                effectView.clipsToBounds = true
                insertSubview(effectView, at: 0)
                glassEffectView = effectView
            }
        }

        // Native iPad prints the flick-down glyph horizontally CENTRED near the top
        // of the key (not in a corner — verified by zooming the reference capture),
        // in the secondary text colour, with the primary glyph pushed below centre.
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryLabel.textAlignment = .center
        secondaryLabel.isUserInteractionEnabled = false
        secondaryLabel.isHidden = true
        addSubview(secondaryLabel)
        // Pinned by its CENTRE, not its top: the flick scales this label about its
        // centre, and a top-pinned label would drift as it grew.
        let secondaryCentre = secondaryLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 14)
        secondaryTopConstraint = secondaryCentre
        NSLayoutConstraint.activate([
            secondaryLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            secondaryCentre
        ])

        spaceLanguageLabel.translatesAutoresizingMaskIntoConstraints = false
        spaceLanguageLabel.font = .systemFont(
            ofSize: KeyboardTheme.defaultMetrics.spaceLanguageFontSize,
            weight: .regular
        )
        spaceLanguageLabel.textAlignment = .right
        spaceLanguageLabel.isHidden = key != .space
        spaceLanguageLabel.isUserInteractionEnabled = false
        addSubview(spaceLanguageLabel)

        let trailingConstraint = spaceLanguageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        let bottomConstraint = spaceLanguageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        spaceLanguageTrailingConstraint = trailingConstraint
        spaceLanguageBottomConstraint = bottomConstraint

        NSLayoutConstraint.activate([
            trailingConstraint,
            bottomConstraint
        ])
    }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            applyPressedState(animated: true)
        }
    }

    private func backgroundColor(for traitCollection: UITraitCollection, highlighted: Bool) -> UIColor {
        switch key {
        case .character, .symbol, .space:
            highlighted
                ? KeyboardTheme.highlightedPrimaryKeyColor(for: traitCollection)
                : KeyboardTheme.primaryKeyColor(for: traitCollection)
        case .shift, .backspace, .modeSwitch, .emoji, .globe, .returnKey,
             .tab, .capsLock, .hideKeyboard:
            highlighted
                ? KeyboardTheme.highlightedUtilityKeyColor(for: traitCollection)
                : KeyboardTheme.utilityKeyColor(for: traitCollection)
        }
    }

    private func applyPressedState(animated: Bool) {
        let updates = {
            if #available(iOS 26.0, *), let effectView = self.glassEffectView,
               let effect = effectView.effect as? UIGlassEffect {
                // Glass path (.regular/.clear): the fill is the glass view; tint
                // it (brighter when pressed) instead of swapping a solid color.
                self.backgroundColor = .clear
                effect.tintColor = KeyboardTheme.glassKeyTint(
                    for: self.traitCollection,
                    highlighted: self.isHighlighted
                )
                effectView.effect = effect
            } else if KeyboardGlassStyle.current == .translucent {
                // Flat translucent fill: native-like "simple transparency" with
                // no specular rim / raised edge.
                self.backgroundColor = KeyboardTheme.glassKeyTint(
                    for: self.traitCollection,
                    highlighted: self.isHighlighted
                )
            } else {
                self.backgroundColor = self.backgroundColor(
                    for: self.traitCollection,
                    highlighted: self.isHighlighted
                )
            }
            let restShadow = self.currentMetrics.keyShadowOpacity
            self.layer.shadowOpacity = self.isHighlighted
                ? max(0, restShadow - 0.12)
                : restShadow
            self.transform = self.isHighlighted
                ? CGAffineTransform(scaleX: 0.985, y: 0.985)
                : .identity
        }

        guard animated else {
            updates()
            return
        }
        UIView.animate(
            withDuration: isHighlighted ? 0.045 : 0.075,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: updates
        )
    }

    private func nativeEmojiGlyph(pointSize: CGFloat) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        // Apple's own keyboard emoji key uses the PRIVATE symbol `emoji.face.grinning`
        // (a thin OUTLINE grinning face). That symbol is unavailable to third parties
        // (`UIImage(systemName:)` returns nil and private names risk review). The
        // faithful PUBLIC match is the OUTLINE `face.smiling` — NOT `face.smiling.inverse`,
        // which is a filled disc and was the visual mismatch vs. native. Rendered as a
        // template so `tintColor` (the key text color) applies.
        if let nativeImage = UIImage(systemName: "face.smiling", withConfiguration: configuration) {
            return nativeImage
        }

        // Fallback (dead in practice — face.smiling resolves on iOS 14+): stroke an
        // OUTLINE face so it stays consistent with the outline glyph above.
        let side = max(22, ceil(pointSize + 4))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false

        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let lineWidth = max(1, side * 0.05)
            UIColor.black.setStroke()

            let ring = UIBezierPath(ovalIn: CGRect(
                x: lineWidth,
                y: lineWidth,
                width: side - lineWidth * 2,
                height: side - lineWidth * 2
            ))
            ring.lineWidth = lineWidth
            ring.stroke()

            let eyeRadius = max(1, side * 0.05)
            for eyeCenterX in [side * 0.34, side * 0.66] {
                let eye = UIBezierPath(ovalIn: CGRect(
                    x: eyeCenterX - eyeRadius,
                    y: side * 0.38 - eyeRadius,
                    width: eyeRadius * 2,
                    height: eyeRadius * 2
                ))
                UIColor.black.setFill()
                eye.fill()
            }

            let mouth = UIBezierPath()
            mouth.move(to: CGPoint(x: side * 0.33, y: side * 0.58))
            mouth.addQuadCurve(
                to: CGPoint(x: side * 0.67, y: side * 0.58),
                controlPoint: CGPoint(x: side * 0.50, y: side * 0.72)
            )
            mouth.lineWidth = lineWidth
            mouth.lineCapStyle = .round
            mouth.stroke()
        }

        return image.withRenderingMode(.alwaysTemplate)
    }
}
