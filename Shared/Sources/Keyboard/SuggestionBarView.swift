import UIKit

/// One inline emoji suggestion: `display` is what's shown/inserted (already
/// resolved to the user's preferred skin tone), `base` is the neutral form used
/// to look up skin-tone variants on long-press.
struct EmojiSuggestion: Equatable {
    let base: String
    let display: String
}

@MainActor
protocol SuggestionBarViewDelegate: AnyObject {
    func suggestionBar(_ suggestionBar: SuggestionBarView, didSelect suggestion: KeyboardSuggestion)
    func suggestionBar(_ suggestionBar: SuggestionBarView, didSelectEmoji emoji: String)
    /// A skin-tone variant was picked via long-press; host should remember it and insert.
    func suggestionBar(_ suggestionBar: SuggestionBarView, didPickEmojiVariant emoji: String, base: String)
    /// Skin-tone options (base + variants) for an emoji, loaded lazily on long-press only.
    func suggestionBar(_ suggestionBar: SuggestionBarView, variantOptionsFor base: String) -> [EmojiItem]
    /// The voice-typing mic at the head of the strip was tapped.
    func suggestionBarDidTapMic(_ suggestionBar: SuggestionBarView)
}

final class SuggestionBarView: UIView {
    weak var delegate: SuggestionBarViewDelegate?

    private var suggestions: [KeyboardSuggestion] = []
    private var emojis: [EmojiSuggestion] = []
    private var quotedText: String?
    private let stackView = UIStackView()
    private var separators: [UIView] = []
    private var slotControls: [SuggestionSlotControl] = []
    private let emojiGroup = EmojiSuggestionGroupView()
    private var variantPopover: EmojiVariantPopoverView?
    private var variantPopoverBase: String?
    private var heightConstraint: NSLayoutConstraint?
    private var contentTopConstraint: NSLayoutConstraint?
    private var contentBottomConstraint: NSLayoutConstraint?
    private var emojiGroupConstraints: [NSLayoutConstraint] = []
    private var metrics = KeyboardTheme.defaultMetrics
    private let micButton = SuggestionMicControl()
    private var stackLeadingConstraint: NSLayoutConstraint?
    private var micWidthConstraint: NSLayoutConstraint?
    /// Whether the strip leads with the voice-typing mic. The candidates shift right
    /// by the mic's width; with it hidden the strip is exactly the old layout.
    private(set) var showsMicButton = false
    private var micState: SuggestionMicControl.Mode = .idle
    /// Voice typing's live waveform. While shown it replaces the candidates: there is
    /// nothing to autocomplete while speaking, and the keys stay untouched.
    private let voiceIndicator = VoiceStripIndicatorView()
    private(set) var isShowingVoiceIndicator = false

    /// Fixed so the candidates never jump as the mic's state changes. Wide enough for
    /// a 44pt touch target on every strip height.
    static let micSlotWidth: CGFloat = 44

    /// Separator height. On iPad the strip mirrors the system shortcuts bar, whose
    /// separators native draws 27.5pt tall — that is `suggestionContentHeight`.
    /// Elsewhere: proportional on short strips (the shipped iPhone look) but capped
    /// at native's ~27pt so a taller strip doesn't grow a giant divider.
    private func separatorHeight(for metrics: KeyboardMetrics) -> CGFloat {
        metrics.suggestionContentHeight > 0
            ? metrics.suggestionContentHeight
            : min(27, metrics.suggestionHeight * 0.58)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `quotedText`, when set, is the shown word that auto-insert will replace on space:
    /// it renders in quotes and becomes tappable, the "keep my spelling" affordance.
    func update(
        suggestions: [KeyboardSuggestion],
        emojis: [EmojiSuggestion] = [],
        quotedText: String? = nil
    ) {
        self.suggestions = suggestions
        self.emojis = Array(emojis.prefix(3))
        self.quotedText = quotedText
        let slotCount = slotControls.count
        let visibleSuggestions = Array(suggestions.prefix(slotCount))
        let hasEmoji = !self.emojis.isEmpty
        // A lone suggestion sits in the middle slot rather than hard left.
        let startIndex = (!hasEmoji && visibleSuggestions.count == 1) ? (slotCount - 1) / 2 : 0
        let textSlotCount = hasEmoji ? slotCount - 1 : slotCount
        let showsChrome = (!visibleSuggestions.isEmpty || hasEmoji) && !isShowingVoiceIndicator
        stackView.isHidden = !showsChrome
        setSeparatorsHidden(!showsChrome)

        for (index, slotControl) in slotControls.enumerated() {
            let suggestionIndex = index - startIndex
            let withinTextSlots = index < textSlotCount
            let suggestion = withinTextSlots && visibleSuggestions.indices.contains(suggestionIndex)
                ? visibleSuggestions[suggestionIndex]
                : nil
            slotControl.tag = suggestionIndex
            slotControl.update(
                suggestion: suggestion,
                isQuoted: quotedText != nil && suggestion?.text == quotedText,
                showsChrome: showsChrome,
                traitCollection: traitCollection,
                metrics: metrics
            )
        }

        emojiGroup.isHidden = !hasEmoji || isShowingVoiceIndicator
        if hasEmoji {
            emojiGroup.update(emojis: self.emojis, traitCollection: traitCollection, metrics: metrics)
        } else {
            dismissVariantPopover(animated: false)
        }

        let separatorColor = KeyboardTheme.separatorColor(for: traitCollection)
        for separator in separators {
            separator.backgroundColor = separatorColor
        }
    }

    func setMicButton(visible: Bool, state: SuggestionMicControl.Mode) {
        let layoutChanged = visible != showsMicButton
        showsMicButton = visible
        micState = state
        micButton.isHidden = !visible
        micButton.update(state: state, traitCollection: traitCollection, metrics: metrics)
        guard layoutChanged else { return }
        micWidthConstraint?.constant = visible ? Self.micSlotWidth : 0
        setNeedsLayout()
    }

    /// Show the voice waveform (or a short status) in place of the candidates;
    /// `nil` restores them.
    func setVoiceIndicator(_ phase: VoicePanelPhase?, levelSource: (() -> VoiceLevelFrame)?) {
        let showing = phase != nil
        if let phase {
            voiceIndicator.levelSource = levelSource
            voiceIndicator.setPhase(phase, textColor: KeyboardTheme.suggestionTextColor(for: traitCollection))
        }
        guard showing != isShowingVoiceIndicator else { return }
        isShowingVoiceIndicator = showing
        if showing {
            dismissVariantPopover(animated: false)
            voiceIndicator.alpha = 0
            voiceIndicator.isHidden = false
        }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.voiceIndicator.alpha = showing ? 1 : 0
            self.stackView.alpha = showing ? 0 : 1
            self.emojiGroup.alpha = showing ? 0 : 1
            for separator in self.separators { separator.alpha = showing ? 0 : 1 }
        } completion: { _ in
            if !self.isShowingVoiceIndicator { self.voiceIndicator.isHidden = true }
        }
        update(suggestions: suggestions, emojis: emojis, quotedText: quotedText)
    }

    func applyMetrics(_ metrics: KeyboardMetrics) {
        self.metrics = metrics
        rebuildSlotsIfNeeded(count: max(1, metrics.suggestionSlotCount))
        heightConstraint?.constant = metrics.suggestionHeight
        contentTopConstraint?.constant = metrics.suggestionContentTopInset
        contentBottomConstraint?.constant = -metrics.suggestionContentBottomInset
        setNeedsLayout()
        micButton.update(state: micState, traitCollection: traitCollection, metrics: metrics)
        update(suggestions: suggestions, emojis: emojis, quotedText: quotedText)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        voiceIndicator.translatesAutoresizingMaskIntoConstraints = false
        voiceIndicator.isHidden = true
        voiceIndicator.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleMicTap)))
        addSubview(voiceIndicator)

        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.isHidden = true
        micButton.addTarget(self, action: #selector(handleMicTap), for: .touchUpInside)
        addSubview(micButton)

        emojiGroup.translatesAutoresizingMaskIntoConstraints = false
        emojiGroup.isHidden = true
        emojiGroup.onSelect = { [weak self] emoji in
            guard let self else { return }
            self.delegate?.suggestionBar(self, didSelectEmoji: emoji)
        }
        addSubview(emojiGroup)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleEmojiLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        emojiGroup.addGestureRecognizer(longPress)

        let heightConstraint = heightAnchor.constraint(equalToConstant: metrics.suggestionHeight)
        self.heightConstraint = heightConstraint
        let contentTopConstraint = stackView.topAnchor.constraint(equalTo: topAnchor, constant: metrics.suggestionContentTopInset)
        let contentBottomConstraint = stackView.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -metrics.suggestionContentBottomInset
        )
        self.contentTopConstraint = contentTopConstraint
        self.contentBottomConstraint = contentBottomConstraint

        let micWidth = micButton.widthAnchor.constraint(equalToConstant: 0)
        micWidthConstraint = micWidth
        NSLayoutConstraint.activate([
            micButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            micButton.topAnchor.constraint(equalTo: stackView.topAnchor),
            micButton.bottomAnchor.constraint(equalTo: stackView.bottomAnchor),
            micWidth,
            stackView.leadingAnchor.constraint(equalTo: micButton.trailingAnchor),
            voiceIndicator.leadingAnchor.constraint(equalTo: micButton.trailingAnchor),
            voiceIndicator.trailingAnchor.constraint(equalTo: trailingAnchor),
            voiceIndicator.topAnchor.constraint(equalTo: stackView.topAnchor),
            voiceIndicator.bottomAnchor.constraint(equalTo: stackView.bottomAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentTopConstraint,
            contentBottomConstraint,
            heightConstraint
        ])

        rebuildSlotsIfNeeded(count: metrics.suggestionSlotCount)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SuggestionBarView, _) in
            view.update(suggestions: view.suggestions, emojis: view.emojis, quotedText: view.quotedText)
            view.micButton.update(state: view.micState, traitCollection: view.traitCollection, metrics: view.metrics)
        }

        update(suggestions: [])
    }

    /// Lay out `count` equal slots with `count - 1` hairlines between them.
    ///
    /// Slot count is a per-device constant (three on iPhone, up to six on iPad), so
    /// this runs on first layout and again only if the keyboard moves to a width in
    /// a different class — a rotation. It is not a per-keystroke path. The
    /// separators use multiplier constraints against `trailing`, which cannot be
    /// mutated after the fact, hence the teardown.
    private func rebuildSlotsIfNeeded(count: Int) {
        guard count != slotControls.count else { return }

        for slotControl in slotControls {
            stackView.removeArrangedSubview(slotControl)
            slotControl.removeFromSuperview()
        }
        for separator in separators {
            separator.removeFromSuperview()
        }
        slotControls.removeAll()
        separators.removeAll()

        for _ in 0..<count {
            let slotControl = SuggestionSlotControl()
            slotControl.addTarget(self, action: #selector(handleSuggestionTap(_:)), for: .touchUpInside)
            slotControls.append(slotControl)
            stackView.addArrangedSubview(slotControl)
        }

        var constraints: [NSLayoutConstraint] = []
        // Separators are laid out by frame in layoutSubviews: they sit at fractions of
        // the candidate area, which starts after the mic when it is shown, and a
        // multiplier constraint can only express fractions of the whole bar.
        for _ in 1..<max(1, count) {
            let separator = UIView()
            separator.isUserInteractionEnabled = false
            separator.isHidden = true
            addSubview(separator)
            separators.append(separator)
        }

        // Emoji live in the trailing slot, native-style, so the text candidates
        // ahead of them are untouched.
        NSLayoutConstraint.deactivate(emojiGroupConstraints)
        if let trailingSlot = slotControls.last {
            emojiGroupConstraints = [
                emojiGroup.leadingAnchor.constraint(equalTo: trailingSlot.leadingAnchor),
                emojiGroup.trailingAnchor.constraint(equalTo: trailingSlot.trailingAnchor),
                emojiGroup.topAnchor.constraint(equalTo: trailingSlot.topAnchor),
                emojiGroup.bottomAnchor.constraint(equalTo: trailingSlot.bottomAnchor)
            ]
            constraints += emojiGroupConstraints
        }
        NSLayoutConstraint.activate(constraints)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let count = CGFloat(max(1, slotControls.count))
        let areaMinX = showsMicButton ? Self.micSlotWidth : 0
        let areaWidth = bounds.width - areaMinX
        let hairline = 1 / (window?.screen.scale ?? UIScreen.main.scale)
        let height = separatorHeight(for: metrics)
        let centerY = bounds.midY + contentVerticalOffset(for: metrics)
        for (offset, separator) in separators.enumerated() {
            let centerX = areaMinX + areaWidth * CGFloat(offset + 1) / count
            separator.frame = CGRect(x: centerX - hairline / 2, y: centerY - height / 2, width: hairline, height: height)
        }
    }

    @objc private func handleMicTap() {
        delegate?.suggestionBarDidTapMic(self)
    }

    private func setSeparatorsHidden(_ hidden: Bool) {
        for separator in separators {
            separator.isHidden = hidden
        }
    }

    private func contentVerticalOffset(for metrics: KeyboardMetrics) -> CGFloat {
        metrics.suggestionContentOffset
    }

    @objc private func handleSuggestionTap(_ sender: UIControl) {
        guard suggestions.indices.contains(sender.tag) else { return }
        delegate?.suggestionBar(self, didSelect: suggestions[sender.tag])
    }

    // MARK: Emoji skin-tone long-press

    @objc private func handleEmojiLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            let point = gesture.location(in: emojiGroup)
            guard let (suggestion, cellFrame) = emojiGroup.suggestion(at: point) else { return }
            let options = delegate?.suggestionBar(self, variantOptionsFor: suggestion.base) ?? []
            guard options.count > 1 else { return }
            showVariantPopover(options: options, base: suggestion.base, cellFrame: emojiGroup.convert(cellFrame, to: self))
        case .changed:
            variantPopover?.updateSelection(at: gesture.location(in: self))
        case .ended:
            if let base = variantPopoverBase, let item = variantPopover?.selectedItem {
                delegate?.suggestionBar(self, didPickEmojiVariant: item.emoji, base: base)
            }
            dismissVariantPopover(animated: true)
        case .cancelled, .failed:
            dismissVariantPopover(animated: true)
        default:
            break
        }
    }

    private func showVariantPopover(options: [EmojiItem], base: String, cellFrame: CGRect) {
        dismissVariantPopover(animated: false)
        let popover = EmojiVariantPopoverView(options: options)
        popover.updateTheme(traitCollection: traitCollection)
        addSubview(popover)

        let size = popover.preferredSize
        let x = min(max(4, cellFrame.midX - size.width / 2), max(4, bounds.width - size.width - 4))
        // Present BELOW the bar (over the top key rows) — the bar sits at the very
        // top of the keyboard, so there's no room above it.
        let y = cellFrame.maxY + 6
        popover.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        popover.updateSelection(at: CGPoint(x: cellFrame.midX, y: cellFrame.midY))
        variantPopover = popover
        variantPopoverBase = base

        popover.alpha = 0
        popover.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
            popover.alpha = 1
            popover.transform = .identity
        }
    }

    private func dismissVariantPopover(animated: Bool) {
        guard let popover = variantPopover else { return }
        variantPopover = nil
        variantPopoverBase = nil
        guard animated else { popover.removeFromSuperview(); return }
        UIView.animate(withDuration: 0.1, animations: {
            popover.alpha = 0
            popover.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        }, completion: { _ in popover.removeFromSuperview() })
    }
}

private final class SuggestionSlotControl: UIControl {
    private let label = UILabel()
    private var isSelectableSuggestion = false

    init() {
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        suggestion: KeyboardSuggestion?,
        isQuoted: Bool = false,
        showsChrome: Bool,
        traitCollection: UITraitCollection,
        metrics: KeyboardMetrics
    ) {
        label.text = suggestion.map { isQuoted ? "\u{201C}\($0.text)\u{201D}" : $0.text }
        label.textColor = suggestion == nil ? .clear : KeyboardTheme.suggestionTextColor(for: traitCollection)
        label.font = font(for: suggestion, metrics: metrics)
        label.transform = CGAffineTransform(translationX: 0, y: metrics.suggestionContentOffset)
        // Native-style: every shown slot is tappable. The deterministic literal is the
        // "keep my spelling" button (quoted when it isn't a dictionary word); the rest
        // are corrections / next-word picks.
        isSelectableSuggestion = suggestion != nil
        isEnabled = isSelectableSuggestion
        accessibilityLabel = suggestion?.text
        accessibilityTraits = isSelectableSuggestion ? .button : .staticText
        applyHighlightedState(animated: false)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 20, weight: .regular)
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func font(for suggestion: KeyboardSuggestion?, metrics: KeyboardMetrics) -> UIFont {
        guard let suggestion else {
            return .systemFont(ofSize: metrics.suggestionFontSize, weight: .regular)
        }
        switch suggestion.source {
        case .deterministic:
            return .systemFont(ofSize: metrics.deterministicSuggestionFontSize, weight: .regular)
        case .autocorrect, .autosuggest:
            return .systemFont(ofSize: metrics.suggestionFontSize, weight: .regular)
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            applyHighlightedState(animated: true)
        }
    }

    private func applyHighlightedState(animated: Bool) {
        let targetColor = isHighlighted && isSelectableSuggestion
            ? KeyboardTheme.suggestionHighlightColor(for: traitCollection)
            : .clear
        let updates = { self.backgroundColor = targetColor }
        guard animated else { updates(); return }
        UIView.animate(
            withDuration: isHighlighted ? 0.05 : 0.10,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: updates
        )
    }
}

/// The trailing emoji region: up to 3 evenly-sized emoji cells with hairline
/// dividers (matching the native keyboard's emoji suggestions).
private final class EmojiSuggestionGroupView: UIView {
    var onSelect: ((String) -> Void)?
    private let stackView = UIStackView()
    private var cells: [EmojiCellControl] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        for _ in 0..<3 {
            let cell = EmojiCellControl()
            cell.addTarget(self, action: #selector(handleTap(_:)), for: .touchUpInside)
            cells.append(cell)
            stackView.addArrangedSubview(cell)
        }
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(emojis: [EmojiSuggestion], traitCollection: UITraitCollection, metrics: KeyboardMetrics) {
        for (index, cell) in cells.enumerated() {
            if emojis.indices.contains(index) {
                cell.isHidden = false
                cell.update(
                    suggestion: emojis[index],
                    showsLeadingDivider: index > 0,
                    traitCollection: traitCollection,
                    metrics: metrics
                )
            } else {
                cell.isHidden = true
                cell.update(suggestion: nil, showsLeadingDivider: false, traitCollection: traitCollection, metrics: metrics)
            }
        }
    }

    /// The (suggestion, cellFrame-in-group) under a point, for the long-press picker.
    func suggestion(at point: CGPoint) -> (EmojiSuggestion, CGRect)? {
        for cell in cells where !cell.isHidden {
            if cell.frame.contains(point), let suggestion = cell.suggestion {
                return (suggestion, cell.frame)
            }
        }
        return nil
    }

    @objc private func handleTap(_ sender: EmojiCellControl) {
        guard let display = sender.suggestion?.display else { return }
        onSelect?(display)
    }
}

private final class EmojiCellControl: UIControl {
    private(set) var suggestion: EmojiSuggestion?
    private let label = UILabel()
    private let leadingDivider = UIView()
    private var dividerCenterYConstraint: NSLayoutConstraint?
    private var dividerHeightConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)

        leadingDivider.translatesAutoresizingMaskIntoConstraints = false
        leadingDivider.isUserInteractionEnabled = false
        addSubview(leadingDivider)

        // The cell spans the whole strip, so the divider has to be placed against
        // the content block rather than the cell's own centre — otherwise it drifts
        // away from the slot separators either side of it.
        let dividerCenterY = leadingDivider.centerYAnchor.constraint(equalTo: centerYAnchor)
        let dividerHeight = leadingDivider.heightAnchor.constraint(equalToConstant: 16)
        dividerCenterYConstraint = dividerCenterY
        dividerHeightConstraint = dividerHeight

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            dividerCenterY,
            leadingDivider.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            dividerHeight
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(suggestion: EmojiSuggestion?, showsLeadingDivider: Bool, traitCollection: UITraitCollection, metrics: KeyboardMetrics) {
        self.suggestion = suggestion
        label.text = suggestion?.display
        label.font = .systemFont(ofSize: metrics.suggestionFontSize + 4, weight: .regular)
        label.transform = CGAffineTransform(translationX: 0, y: metrics.suggestionContentOffset)
        dividerCenterYConstraint?.constant = metrics.suggestionContentOffset
        dividerHeightConstraint?.constant = metrics.suggestionContentHeight > 0
            ? metrics.suggestionContentHeight
            : min(27, metrics.suggestionHeight * 0.58)
        leadingDivider.isHidden = !showsLeadingDivider
        leadingDivider.backgroundColor = KeyboardTheme.separatorColor(for: traitCollection)
        isEnabled = suggestion != nil
        accessibilityLabel = suggestion?.display
        accessibilityTraits = .button
    }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            backgroundColor = isHighlighted && isEnabled
                ? KeyboardTheme.suggestionHighlightColor(for: traitCollection)
                : .clear
        }
    }
}

/// The voice-typing mic that leads the strip. Drawn in the strip's own text colour
/// and with the slots' pressed highlight, so it reads as part of the keyboard rather
/// than a toolbar button bolted onto it.
final class SuggestionMicControl: UIControl {
    enum Mode: Equatable {
        /// No warm session: a tap bounces through the app once.
        case idle
        /// The app is holding the microphone open; a tap starts instantly.
        case warm
        /// Dictating now.
        case listening
    }

    /// Obadh teal (#3CBFBC), the one accent the keyboard uses.
    static let accent = UIColor(red: 0x3C / 255, green: 0xBF / 255, blue: 0xBC / 255, alpha: 1)

    private let glyph = UIImageView()
    private let warmDot = UIView()
    private var mode: Mode = .idle

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)

        warmDot.translatesAutoresizingMaskIntoConstraints = false
        warmDot.isUserInteractionEnabled = false
        warmDot.backgroundColor = Self.accent
        warmDot.layer.cornerRadius = 2.5
        warmDot.alpha = 0
        addSubview(warmDot)

        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            warmDot.widthAnchor.constraint(equalToConstant: 5),
            warmDot.heightAnchor.constraint(equalToConstant: 5),
            warmDot.centerXAnchor.constraint(equalTo: glyph.centerXAnchor, constant: 8),
            warmDot.centerYAnchor.constraint(equalTo: glyph.centerYAnchor, constant: -9)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(state: Mode, traitCollection: UITraitCollection, metrics: KeyboardMetrics) {
        let changed = state != mode
        mode = state
        let pointSize = min(20, max(15, metrics.suggestionFontSize * 0.92))
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        glyph.image = UIImage(systemName: state == .listening ? "mic.fill" : "mic", withConfiguration: configuration)
        glyph.tintColor = state == .listening ? Self.accent : KeyboardTheme.suggestionTextColor(for: traitCollection)
        glyph.transform = CGAffineTransform(translationX: 0, y: metrics.suggestionContentOffset)
        warmDot.transform = glyph.transform
        let dotAlpha: CGFloat = state == .warm ? 1 : 0
        if changed, window != nil {
            UIView.animate(withDuration: 0.2) { self.warmDot.alpha = dotAlpha }
        } else {
            warmDot.alpha = dotAlpha
        }
        switch state {
        case .idle: accessibilityLabel = "Voice typing"
        case .warm: accessibilityLabel = "Voice typing, microphone ready"
        case .listening: accessibilityLabel = "Stop voice typing"
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            let color = isHighlighted ? KeyboardTheme.suggestionHighlightColor(for: traitCollection) : .clear
            UIView.animate(
                withDuration: isHighlighted ? 0.05 : 0.10, delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
            ) { self.backgroundColor = color }
        }
    }
}
