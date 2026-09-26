import UIKit

@MainActor
protocol KeyboardTouchSurfaceViewDelegate: AnyObject {
    func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didBegin key: KeyboardKey)
    func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didMoveTo key: KeyboardKey)
    /// 0...1 of the way through a downward flick on `key`. Drives the animation
    /// that lifts the secondary glyph into the primary's place as the finger
    /// travels, which is the whole of what makes the gesture feel native — iPadOS
    /// does it in a private layer no extension can reach.
    func keyboardTouchSurface(
        _ view: KeyboardTouchSurfaceView,
        didUpdateFlickProgress progress: CGFloat,
        on key: KeyboardKey
    )
    /// `flickedDown` is the iPad secondary-glyph gesture: the touch was dragged
    /// downward far enough before lifting, without leaving the key.
    func keyboardTouchSurface(
        _ view: KeyboardTouchSurfaceView,
        didEnd key: KeyboardKey?,
        flickedDown: Bool
    )
    func keyboardTouchSurfaceDidCancel(_ view: KeyboardTouchSurfaceView)
}

final class KeyboardTouchSurfaceView: UIView {
    weak var delegate: KeyboardTouchSurfaceViewDelegate?
    /// Downward travel that turns a tap into a secondary-glyph insert. Zero
    /// disables the gesture entirely, which is what iPhone uses — no iPhone key
    /// has a secondary, so a flick there would be a mystery keystroke.
    var flickThreshold: CGFloat = 0
    private var touchBeganLocation: CGPoint = .zero
    /// The key the touch STARTED on. A flick must insert this key's secondary, not
    /// whatever the finger happens to be over when it lifts — dragging down far
    /// enough to count as a flick is often far enough to reach the row below.
    private var touchBeganKey: KeyboardKey?

    var keyRows: [[KeyboardTouchKeyRegion]] = [] {
        didSet {
            activeRegion = activeTouch.flatMap { resolve($0.location(in: self)) }
        }
    }

    /// Touches with y above this (the suggestion bar) are passed through so the
    /// suggestion bar beneath receives them. Below it, the surface resolves keys.
    /// Lets the surface be full-bleed (uniform, no rectangle) while only owning
    /// the key area.
    var keyAreaTop: CGFloat = 0

    private weak var activeTouch: UITouch?
    private var activeRegion: KeyboardTouchResolvedRegion?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        guard let region = resolve(touch.location(in: self)) else {
            activeRegion = nil
            return
        }
        activeRegion = region
        touchBeganLocation = touch.location(in: self)
        touchBeganKey = region.key
        delegate?.keyboardTouchSurface(self, didBegin: region.key)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touch(from: touches) else { return }
        let point = touch.location(in: self)
        if flickThreshold > 0, let began = touchBeganKey {
            delegate?.keyboardTouchSurface(
                self,
                didUpdateFlickProgress: max(0, min(1, (point.y - touchBeganLocation.y) / flickThreshold)),
                on: began
            )
        }
        let region = resolve(point)
        guard region?.key != activeRegion?.key else { return }
        activeRegion = region
        if let region {
            delegate?.keyboardTouchSurface(self, didMoveTo: region.key)
        } else {
            delegate?.keyboardTouchSurfaceDidCancel(self)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touch(from: touches) else { return }
        let end = touch.location(in: self)
        let region = resolve(end) ?? activeRegion
        // Judged against the key the touch BEGAN on, and against nothing else.
        //
        // This used to require `region?.key == activeRegion?.key`, meaning "the
        // finger never left the key" — but `touchesMoved` reassigns `activeRegion`
        // as the finger travels, so that compared the end region against itself and
        // was always true. Worse, the insert used the END key: a downward drag long
        // enough to be a flick usually reaches the row below, so flicking `q` typed
        // the secondary of `a`. Both halves are why this read as "doesn't work".
        let began = touchBeganKey
        let flicked = flickThreshold > 0
            && began != nil
            && (end.y - touchBeganLocation.y) >= flickThreshold
        activeTouch = nil
        activeRegion = nil
        touchBeganLocation = .zero
        touchBeganKey = nil
        if let began, flickThreshold > 0 {
            delegate?.keyboardTouchSurface(self, didUpdateFlickProgress: 0, on: began)
        }
        delegate?.keyboardTouchSurface(
            self,
            didEnd: flicked ? began : region?.key,
            flickedDown: flicked
        )
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch(from: touches) != nil else { return }
        cancelTracking()
    }

    /// Row replacement and keyboard dismissal invalidate the gesture, including
    /// a later touchesEnded delivered for the old row. Clearing only controller
    /// highlighting leaves that touch able to insert a key from the new layout.
    func cancelTracking() {
        if let began = touchBeganKey, flickThreshold > 0 {
            delegate?.keyboardTouchSurface(self, didUpdateFlickProgress: 0, on: began)
        }
        activeTouch = nil
        activeRegion = nil
        touchBeganLocation = .zero
        touchBeganKey = nil
        delegate?.keyboardTouchSurfaceDidCancel(self)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, !keyRows.isEmpty else {
            return false
        }
        return point.y >= keyAreaTop && bounds.contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, !keyRows.isEmpty else {
            return nil
        }
        return (point.y >= keyAreaTop && bounds.contains(point)) ? self : nil
    }

    private func configure() {
        // CRITICAL: a custom keyboard EXTENSION drops touches over regions where
        // the touch-receiving view renders fully transparent (verified on-device
        // + on-sim; the system keyboard is exempt because it isn't an extension).
        // A visual-effect glass backdrop behind does NOT count — only a plain,
        // non-transparent background on THIS view makes the inter-key gaps
        // touchable. ~1/255 alpha: the system registers the color so touches
        // land, but it is genuinely imperceptible (0.02 was ~5x too high and
        // read as a tint). Do NOT set to `.clear`.
        // Ref: https://developer.apple.com/forums/thread/702798
        //
        // The tint must follow the appearance. White at 0.004 over a DARK keyboard
        // lifts it by 0.004 * 255 = 1.02, i.e. exactly one unit per channel — the
        // key area measured [23,23,24] against [22,22,23] everywhere else on a real
        // iPad, a visible seam between the keys and the strip above them. Black at
        // the same alpha over dark takes it to 21.91, which rounds back to 22 and is
        // genuinely invisible; light mode keeps white, where +0.13 of 223 is equally
        // invisible. Either way the view still has a non-nil backgroundColor, which
        // is the whole reason for doing this.
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.004)
                : UIColor.white.withAlphaComponent(0.004)
        }
        isOpaque = false
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityViewIsModal = false
    }

    private func touch(from touches: Set<UITouch>) -> UITouch? {
        guard let activeTouch else { return nil }
        return touches.first { $0 === activeTouch }
    }

    private func resolve(_ point: CGPoint) -> KeyboardTouchResolvedRegion? {
        KeyboardTouchResolver.resolve(
            point: point,
            rows: keyRows,
            bounds: bounds
        )
    }
}
