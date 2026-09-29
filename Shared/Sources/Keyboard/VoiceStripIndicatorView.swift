import UIKit

/// Voice typing in the suggestion strip: the voice light fills the ribbon's free
/// space, everything right of the mic, drawn straight onto the keyboard. The light
/// itself is the status (live, waiting, finishing); words appear only for a problem
/// the user has to act on.
final class VoiceStripIndicatorView: UIView {
    var levelFeed: VoiceLevelFeed? {
        get { lens.levelFeed }
        set { lens.levelFeed = newValue }
    }

    private let lens = VoiceLensView()
    private let label = UILabel()
    /// The mic's slot at the head of the strip (SuggestionBarView.micSlotWidth).
    static let micSlotWidth: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = [.button, .updatesFrequently]

        lens.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lens)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.alpha = 0
        addSubview(label)

        NSLayoutConstraint.activate([
            // Everything right of the mic slot, edge to edge, top to bottom.
            lens.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.micSlotWidth),
            lens.trailingAnchor.constraint(equalTo: trailingAnchor),
            lens.topAnchor.constraint(equalTo: topAnchor),
            lens.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 52),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Aligns the light with the strip's content line (the mic and the suggestions),
    /// which sits off the strip's geometric centre.
    func setContentOffset(_ offset: CGFloat) {
        lens.setHorizonOffset(offset)
    }

    /// `textColor` is the strip's own candidate colour, for the rare problem line.
    func setPhase(_ phase: VoicePanelPhase, textColor: UIColor) {
        label.textColor = textColor
        var message: String?
        switch phase {
        case .connecting:
            lens.setMode(.waiting)
            accessibilityLabel = "Starting voice typing"
        case .ready, .listening:
            lens.setMode(.live)
            accessibilityLabel = "Listening. Tap to finish."
        case .finishing:
            lens.setMode(.finishing)
            accessibilityLabel = "Finishing"
        case .problem(let text):
            message = text
            accessibilityLabel = text
        }
        label.text = message
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.label.alpha = message == nil ? 0 : 1
            self.lens.alpha = message == nil ? 1 : 0
        }
    }
}
