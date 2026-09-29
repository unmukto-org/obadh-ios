import Metal
import QuartzCore
import UIKit

/// The voice lens (see VoiceSiriLens.metal): a dark glass capsule whose lobes of
/// light follow the voice, after the iOS 27 Siri language. Used in the keyboard's
/// suggestion strip and on the app's session screen.
///
/// Rendering runs on its own thread with its own display link, so nothing the
/// keyboard does on the main thread can make it stutter. It draws at the display's
/// refresh rate while visible and stops entirely when hidden or off screen. If Metal
/// is unavailable, the view shows a static dark lens instead.
final class VoiceLensView: UIView {
    enum Mode: Equatable {
        case live       // following the voice
        case waiting    // the app is starting or recovering audio
        case finishing  // settling the last phrase
    }

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let renderer: VoiceLensRenderer?
    private var isVisibleForRendering = false

    /// Levels source, read on the render thread.
    var levelFeed: VoiceLevelFeed? {
        get { renderer?.levelFeed }
        set { renderer?.levelFeed = newValue }
    }

    override init(frame: CGRect) {
        renderer = VoiceLensRenderer.make()
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        metalLayer.isOpaque = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = false
        if let renderer {
            metalLayer.device = renderer.device
            renderer.layer = metalLayer
        } else {
            // No Metal: a still lens so the state is still visible.
            layer.backgroundColor = UIColor(white: 0.04, alpha: 0.92).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        renderer?.stop()
    }

    func setMode(_ mode: Mode) {
        renderer?.setMode(mode)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if renderer == nil { layer.cornerRadius = bounds.height / 2 }
        renderer?.setGeometry(size: metalLayer.drawableSize, scale: Float(scale))
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRendering()
    }

    override var isHidden: Bool {
        didSet { updateRendering() }
    }

    override var alpha: CGFloat {
        didSet { updateRendering() }
    }

    private func updateRendering() {
        let visible = window != nil && !isHidden && alpha > 0.01
        guard visible != isVisibleForRendering else { return }
        isVisibleForRendering = visible
        if visible {
            let maxRate = Float(window?.screen.maximumFramesPerSecond ?? 60)
            renderer?.start(maxFrameRate: maxRate)
        } else {
            renderer?.stop()
        }
    }
}

/// Owns the Metal objects and the render thread. All mutable state it shares with
/// the main thread sits behind `lock`.
private final class VoiceLensRenderer: NSObject, @unchecked Sendable {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    weak var layer: CAMetalLayer?
    var levelFeed: VoiceLevelFeed? {
        get { lock.withLock { _levelFeed } }
        set { lock.withLock { _levelFeed = newValue } }
    }

    private let lock = NSLock()
    private var _levelFeed: VoiceLevelFeed?
    private var mode: VoiceLensView.Mode = .live
    private var size = CGSize.zero
    private var scale: Float = 3
    private var thread: Thread?
    private var displayLink: CADisplayLink?
    private var smoother = VoiceLevelSmoother()
    private var startTime = CACurrentMediaTime()
    private var appear: Float = 0
    private var lastCounter: UInt32 = 0
    private var lastCounterChange: CFTimeInterval = 0

    static func make() -> VoiceLensRenderer? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle(for: VoiceLensRenderer.self)),
              let vertex = library.makeFunction(name: "lensVertex"),
              let fragment = library.makeFunction(name: "lensFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // The shader outputs premultiplied colour.
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        return VoiceLensRenderer(device: device, queue: queue, pipeline: pipeline)
    }

    private init(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        super.init()
    }

    func setMode(_ mode: VoiceLensView.Mode) {
        lock.withLock { self.mode = mode }
    }

    func setGeometry(size: CGSize, scale: Float) {
        lock.withLock {
            self.size = size
            self.scale = scale
        }
    }

    func start(maxFrameRate: Float) {
        guard thread == nil else { return }
        startTime = CACurrentMediaTime()
        appear = 0
        let thread = Thread { [weak self] in
            guard let self else { return }
            let link = CADisplayLink(target: self, selector: #selector(self.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxFrameRate, preferred: maxFrameRate)
            link.add(to: .current, forMode: .default)
            self.lock.withLock { self.displayLink = link }
            // Runs until the display link is invalidated in stop().
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "org.unmukto.obadh.voice-lens"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        let link = lock.withLock { () -> CADisplayLink? in
            let link = displayLink
            displayLink = nil
            return link
        }
        thread?.cancel()
        thread = nil
        // Invalidating removes the only run-loop source, which lets the thread exit.
        link?.invalidate()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let layer, let drawable = layer.nextDrawable() else { return }
        let (mode, size, scale, feed) = lock.withLock { (self.mode, self.size, self.scale, _levelFeed) }
        guard size.width > 1, size.height > 1 else { return }

        let now = CACurrentMediaTime()
        var frame = VoiceLevelFrame.silent
        if mode == .live, let feed {
            let read = feed.read()
            // A page that stopped updating means audio stopped arriving: settle to
            // the resting shimmer rather than keep "listening" on stale numbers.
            if read.counter != lastCounter {
                lastCounter = read.counter
                lastCounterChange = now
            }
            if now - lastCounterChange < 0.5 { frame = read }
        }
        smoother.advance(to: frame, at: now)
        appear = min(1, appear + Float(link.targetTimestamp - link.timestamp) * 4)

        var uniforms = LensUniforms(
            size: SIMD2(Float(size.width), Float(size.height)),
            scale: scale,
            time: Float((now - startTime).truncatingRemainder(dividingBy: 3600)),
            level: smoother.level,
            energy: smoother.energy,
            mode: mode == .live ? 0 : (mode == .waiting ? 1 : 2),
            appear: appear * appear * (3 - 2 * appear),
            bandsA: SIMD4(smoother.bands[0], smoother.bands[1], smoother.bands[2], smoother.bands[3]),
            bandsB: SIMD4(smoother.bands[4], smoother.bands[5], smoother.bands[6], smoother.bands[7]),
            bandsC: SIMD4(smoother.bands[8], smoother.bands[9], smoother.bands[10], smoother.bands[11])
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LensUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// Mirrors `LensUniforms` in VoiceSiriLens.metal (same order, same alignment).
private struct LensUniforms {
    var size: SIMD2<Float>
    var scale: Float
    var time: Float
    var level: Float
    var energy: Float
    var mode: Float
    var appear: Float
    var bandsA: SIMD4<Float>
    var bandsB: SIMD4<Float>
    var bandsC: SIMD4<Float>
}
