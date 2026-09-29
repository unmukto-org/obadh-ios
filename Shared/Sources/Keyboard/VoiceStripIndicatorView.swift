import UIKit

/// The listening visual, drawn in the suggestion strip while voice typing is active.
/// The keys stay exactly as they are; the strip's candidate area becomes a live
/// waveform that follows the voice.
///
/// Deliberately plain UIKit: one shape layer (the bars) masking one gradient layer,
/// re-pathed from a display link that runs only while this view is on screen. It
/// costs a fraction of a millisecond per frame and no SwiftUI, Metal, or textures
/// inside the keyboard's memory ceiling.
final class VoiceStripIndicatorView: UIView {
    var levelSource: (() -> VoiceLevelFrame)?

    private let gradient = CAGradientLayer()
    private let bars = CAShapeLayer()
    private let label = UILabel()
    private var displayLink: CADisplayLink?
    private var smoother = VoiceLevelSmoother()
    private var phase: VoicePanelPhase = .ready
    private var startTime = CACurrentMediaTime()
    /// Per-bar heights carried between frames so each bar eases on its own.
    private var heights: [CGFloat] = []

    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = [.button, .updatesFrequently]

        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [
            UIColor(red: 0x8B / 255, green: 0x6C / 255, blue: 0xFF / 255, alpha: 1).cgColor,  // violet
            UIColor(red: 0x4F / 255, green: 0xA3 / 255, blue: 0xFF / 255, alpha: 1).cgColor,  // sky
            SuggestionMicControl.accent.cgColor,                                             // teal
            UIColor(red: 0x4F / 255, green: 0xA3 / 255, blue: 0xFF / 255, alpha: 1).cgColor,
            UIColor(red: 0x8B / 255, green: 0x6C / 255, blue: 0xFF / 255, alpha: 1).cgColor
        ]
        gradient.mask = bars
        layer.addSublayer(gradient)

        label.textAlignment = .center
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.alpha = 0
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPhase(_ phase: VoicePanelPhase, traitCollection: UITraitCollection) {
        self.phase = phase
        label.textColor = KeyboardTheme.suggestionTextColor(for: traitCollection).withAlphaComponent(0.72)
        let text: String?
        switch phase {
        case .connecting: text = "অবাধ খুলছে…"
        case .ready, .listening: text = nil
        case .finishing: text = "গুছিয়ে নিচ্ছি…"
        case .problem(let message): text = message
        }
        let showsBars = text == nil
        label.text = text
        accessibilityLabel = text ?? "Listening. Tap to finish."
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.label.alpha = showsBars ? 0 : 1
            self.gradient.opacity = showsBars ? 1 : 0.35
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        bars.frame = bounds
        CATransaction.commit()
        label.frame = bounds.insetBy(dx: 12, dy: 0)
        let count = max(0, Int((bounds.width - 24) / (Self.barWidth + Self.barGap)))
        if heights.count != count { heights = Array(repeating: 0, count: count) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !isHidden { startTicking() } else { stopTicking() }
    }

    override var isHidden: Bool {
        didSet { if isHidden { stopTicking() } else if window != nil { startTicking() } }
    }

    private func startTicking() {
        guard displayLink == nil else { return }
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        let live = phase == .listening || phase == .ready
        let frame = live ? (levelSource?() ?? .silent) : .silent
        smoother.advance(to: frame, at: now)
        redraw(time: now - startTime)
    }

    /// Bars mirrored about the centre: low frequencies in the middle (tallest), highs
    /// toward the ends, with a slow travelling shimmer so silence still breathes.
    private func redraw(time: Double) {
        let count = heights.count
        guard count > 0 else { return }
        let bandCount = smoother.bands.count
        let maxHeight = bounds.height * 0.62
        let minHeight: CGFloat = 3
        let level = CGFloat(smoother.level)
        let totalWidth = CGFloat(count) * (Self.barWidth + Self.barGap) - Self.barGap
        var x = (bounds.width - totalWidth) / 2
        let midY = bounds.midY
        let path = CGMutablePath()
        for index in 0..<count {
            let position = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0.5
            let distance = abs(position - 0.5) * 2               // 0 centre … 1 ends
            let bandPosition = distance * CGFloat(bandCount - 1)
            let lower = Int(bandPosition), upper = min(lower + 1, bandCount - 1)
            let fraction = bandPosition - CGFloat(lower)
            let band = CGFloat(smoother.bands[lower]) * (1 - fraction) + CGFloat(smoother.bands[upper]) * fraction
            let envelope = 1 - distance * distance * 0.55
            let shimmer = 0.5 + 0.5 * sin(time * 3.1 - Double(position) * 9)
            let quiet = 0.10 + 0.06 * CGFloat(shimmer)
            let target = (quiet + (band * 0.75 + level * 0.55) * CGFloat(0.85 + 0.15 * shimmer)) * envelope
            // Ease each bar on its own so the shape moves like liquid, not a meter.
            heights[index] += (target - heights[index]) * 0.35
            let height = max(minHeight, min(maxHeight, heights[index] * maxHeight))
            let rect = CGRect(x: x, y: midY - height / 2, width: Self.barWidth, height: height)
            path.addRoundedRect(in: rect, cornerWidth: Self.barWidth / 2, cornerHeight: Self.barWidth / 2)
            x += Self.barWidth + Self.barGap
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.path = path
        CATransaction.commit()
    }
}

/// CADisplayLink retains its target; the proxy keeps that from retaining the view.
private final class DisplayLinkProxy: NSObject {
    weak var view: VoiceStripIndicatorView?
    init(_ view: VoiceStripIndicatorView) { self.view = view }
    @objc func tick() { view?.tick() }
}
