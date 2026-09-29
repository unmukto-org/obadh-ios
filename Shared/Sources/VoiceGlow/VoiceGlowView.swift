import UIKit

/// The one visual for voice typing, in the keyboard's suggestion strip and on the
/// app's session screen: soft fields of light in the Siri palette drifting inside a
/// glow that swells with the voice. No lines and no edges: everything falls off
/// softly in every direction, so it reads as light rather than a shape.
///
/// Why it stays smooth: the drifting is Core Animation keyframe animation, which the
/// render server runs on its own, so it keeps full frame rate even if the keyboard's
/// main thread is busy. The voice only modulates a handful of layer properties per
/// frame (height, brightness, bloom). If the main thread hiccups, the light keeps
/// flowing and only its reaction to the voice pauses for that moment.
///
/// No SwiftUI, Metal, or textures: it fits comfortably in a keyboard extension.
final class VoiceGlowView: UIView {
    enum Mode: Equatable {
        /// Voice-reactive: armed or hearing speech.
        case live
        /// Waiting on the app (opening it, or recovering audio): dim, slow.
        case waiting
        /// Finishing the last phrase: collapses to a shimmering line.
        case finishing
        /// Nothing to animate (a problem message is shown instead).
        case hidden
    }

    /// Called once per displayed frame while live.
    var levelSource: (() -> VoiceLevelFrame)?

    private let field = CALayer()          // the glow; scaled by the voice
    private let fieldMask = CAGradientLayer()
    /// The whole Siri spectrum as one continuous sweep, so the light never has gaps.
    private let spectrum = CAGradientLayer()
    private var blobs: [CAGradientLayer] = []
    /// A soft luminous centre that brightens with the voice.
    private let core = CAGradientLayer()
    private var displayLink: CADisplayLink?
    private var smoother = VoiceLevelSmoother()
    private var mode: Mode = .live
    private var lastCounter: UInt32 = 0
    private var lastCounterChange: CFTimeInterval = 0
    private var startTime = CACurrentMediaTime()
    private var needsAnimations = true

    /// Siri / Apple Intelligence palette.
    static let palette: [UIColor] = [
        UIColor(red: 1.00, green: 0.62, blue: 0.04, alpha: 1),  // orange
        UIColor(red: 1.00, green: 0.22, blue: 0.37, alpha: 1),  // pink
        UIColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1),  // purple
        UIColor(red: 0.37, green: 0.36, blue: 0.90, alpha: 1),  // indigo
        UIColor(red: 0.04, green: 0.52, blue: 1.00, alpha: 1),  // blue
        UIColor(red: 0.39, green: 0.82, blue: 1.00, alpha: 1)   // cyan
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = false

        // An elliptical falloff: the light fades out toward every edge, so there is
        // never a visible boundary, only glow.
        fieldMask.type = .radial
        fieldMask.startPoint = CGPoint(x: 0.5, y: 0.5)
        fieldMask.endPoint = CGPoint(x: 1, y: 1)
        fieldMask.colors = [UIColor.black, UIColor.black.withAlphaComponent(0.9), .clear].map(\.cgColor)
        fieldMask.locations = [0, 0.62, 1]
        field.mask = fieldMask
        layer.addSublayer(field)

        spectrum.startPoint = CGPoint(x: 0, y: 0.5)
        spectrum.endPoint = CGPoint(x: 1, y: 0.5)
        spectrum.colors = Self.spectrumColors(offset: 0)
        spectrum.opacity = 0.85
        field.addSublayer(spectrum)

        let fieldColors = [0, 1, 2, 4, 5].map { Self.palette[$0] }
        for color in fieldColors {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.colors = [color.cgColor, color.withAlphaComponent(0.6).cgColor, color.withAlphaComponent(0).cgColor]
            blob.locations = [0, 0.5, 1]
            field.addSublayer(blob)
            blobs.append(blob)
        }

        core.type = .radial
        core.startPoint = CGPoint(x: 0.5, y: 0.5)
        core.endPoint = CGPoint(x: 1, y: 1)
        core.colors = [UIColor.white.withAlphaComponent(0.9), UIColor.white.withAlphaComponent(0.25), UIColor.white.withAlphaComponent(0)].map(\.cgColor)
        core.locations = [0, 0.4, 1]
        core.opacity = 0
        field.addSublayer(core)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        let visible = mode != .hidden
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = visible ? 1 : 0
        }
        updateTicking()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.frame = bounds
        fieldMask.frame = field.bounds
        spectrum.frame = field.bounds
        core.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.42, height: bounds.height * 1.3)
        core.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        needsAnimations = true
        installDriftAnimations()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateTicking()
        if window != nil { needsAnimations = true; installDriftAnimations() }
    }

    override var isHidden: Bool {
        didSet { updateTicking() }
    }

    /// Each field drifts on its own looping path at its own pace, so the light never
    /// visibly repeats. Render-server animations: they survive main-thread stalls.
    private func installDriftAnimations() {
        guard needsAnimations, window != nil, bounds.width > 1 else { return }
        needsAnimations = false
        let width = bounds.width, height = bounds.height
        installSpectrumFlow()
        let durations: [CFTimeInterval] = [7.3, 5.9, 8.7, 6.4, 9.6]
        let anchors: [CGFloat] = [0.22, 0.40, 0.55, 0.70, 0.84]
        for (index, blob) in blobs.enumerated() {
            let size = CGSize(width: width * 0.62, height: height * 2.4)
            blob.bounds = CGRect(origin: .zero, size: size)
            blob.removeAllAnimations()
            let path = UIBezierPath()
            let cx = width * anchors[index], cy = height / 2
            let rx = width * 0.16, ry = height * 0.12
            let phase = CGFloat(index) * 1.3
            for step in 0...24 {
                let t = CGFloat(step) / 24 * 2 * .pi
                let point = CGPoint(x: cx + rx * sin(t + phase), y: cy + ry * sin(2 * t + phase))
                step == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            blob.position = CGPoint(x: cx, y: cy)
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.path = path.cgPath
            drift.duration = durations[index]
            drift.calculationMode = .cubicPaced
            drift.repeatCount = .infinity
            blob.add(drift, forKey: "drift")

            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.88
            breathe.toValue = 1.12
            breathe.duration = durations[index] * 0.61
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            blob.add(breathe, forKey: "breathe")
        }
    }

    /// The spectrum rotated by `offset` steps, closed into a loop so the flow is seamless.
    private static func spectrumColors(offset: Int) -> [CGColor] {
        let loop = palette + [palette[0]]
        return (0..<loop.count).map { loop[(($0 + offset) % (loop.count - 1) + (loop.count - 1)) % (loop.count - 1)].cgColor }
    }

    private func installSpectrumFlow() {
        let flow = CAKeyframeAnimation(keyPath: "colors")
        flow.values = (0..<Self.palette.count).map { Self.spectrumColors(offset: $0) } + [Self.spectrumColors(offset: 0)]
        flow.duration = 9
        flow.calculationMode = .linear
        flow.repeatCount = .infinity
        spectrum.add(flow, forKey: "flow")
    }

    private func updateTicking() {
        let shouldTick = window != nil && !isHidden && mode != .hidden
        if shouldTick, displayLink == nil {
            startTime = CACurrentMediaTime()
            let link = CADisplayLink(target: GlowDisplayLinkProxy(self), selector: #selector(GlowDisplayLinkProxy.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !shouldTick {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        var frame = VoiceLevelFrame.silent
        if mode == .live, let source = levelSource?() {
            // A page that stopped updating means audio stopped arriving: calm down
            // rather than keep "listening" on stale numbers.
            if source.counter != lastCounter {
                lastCounter = source.counter
                lastCounterChange = now
            }
            if now - lastCounterChange < 0.5 { frame = source }
        }
        smoother.advance(to: frame, at: now)
        apply(time: now - startTime)
    }

    private func apply(time: Double) {
        let level = CGFloat(smoother.level)
        let presence = CGFloat(smoother.energy)
        let breath = CGFloat(0.5 + 0.5 * sin(time * 1.7))
        let scaleX: CGFloat
        let scaleY: CGFloat
        let opacity: Float
        switch mode {
        case .live:
            // Resting: a soft, low breath of light. Speaking: it swells in height
            // first (the eye reads that as loudness) and widens a little.
            scaleX = 0.78 + 0.04 * breath + 0.22 * level
            scaleY = 0.42 + 0.10 * breath + 0.70 * level
            opacity = Float(0.60 + 0.22 * presence + 0.18 * level)
        case .waiting:
            scaleX = 0.70 + 0.04 * breath
            scaleY = 0.34 + 0.08 * breath
            opacity = Float(0.32 + 0.12 * breath)
        case .finishing:
            // Gathering in: narrow and bright, pulsing while the last phrase settles.
            scaleX = 0.46 + 0.06 * breath
            scaleY = 0.30 + 0.06 * breath
            opacity = Float(0.55 + 0.25 * breath)
        case .hidden:
            return
        }
        let isDark = traitCollection.userInterfaceStyle == .dark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.transform = CATransform3DMakeScale(scaleX, scaleY, 1)
        field.opacity = opacity
        // The hot centre is what makes it read as light: it brightens with the voice.
        core.opacity = mode == .live ? Float((isDark ? 0.18 : 0.10) + (isDark ? 0.55 : 0.35) * level) : 0
        core.transform = CATransform3DMakeScale(0.8 + 0.5 * level, 1, 1)
        CATransaction.commit()
    }
}

/// CADisplayLink retains its target; the proxy keeps that from retaining the view.
private final class GlowDisplayLinkProxy: NSObject {
    weak var view: VoiceGlowView?
    init(_ view: VoiceGlowView) { self.view = view }
    @objc func tick() { view?.tick() }
}
