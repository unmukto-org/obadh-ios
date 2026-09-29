import Accelerate
import AVFoundation
import os

/// Microphone → 16 kHz mono Float32, plus loudness and a coarse spectrum for the
/// listening visual.
///
/// The engine runs for the whole warm session because a backgrounded app may keep a
/// running recording alive but may not start a new one. Whether buffers are used is
/// decided downstream (`VoiceRecognitionPipeline` drops them unless dictating), and
/// levels are only published while `isMetering`, so an idle warm session shows
/// nothing and computes almost nothing.
final class VoiceAudioCapture: @unchecked Sendable {
    enum CaptureError: Error {
        case noInput
        case converterUnavailable
    }

    /// Called on the tap thread with 16 kHz mono samples.
    var onSamples: (@Sendable ([Float]) -> Void)?
    /// Called on the main queue when iOS reconfigured the audio hardware (a route
    /// change: AirPods, Bluetooth, a call ending) and the engine could not be brought
    /// back. The session is no longer recording.
    var onFailure: (@Sendable (Error) -> Void)?

    private let log = Logger(subsystem: "org.unmukto.obadh", category: "voice")
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let levelWriter: VoiceLevelWriter?
    private let meter = LevelMeter()
    private struct State {
        var isMetering = false
        var lastBufferAt: CFTimeInterval = 0
        var wantsRunning = false
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private var configurationObserver: NSObjectProtocol?

    /// Whether levels are written to the shared page. Toggled per dictation.
    var isMetering: Bool {
        get { lock.withLock { $0.isMetering } }
        set {
            lock.withLock { $0.isMetering = newValue }
            if !newValue { levelWriter?.writeSilence() }
        }
    }

    /// When the last converted buffer arrived (`CACurrentMediaTime`). The session's
    /// watchdog compares this with the clock: a running engine that stopped
    /// delivering is the "shows listening, hears nothing" failure.
    var lastBufferAt: CFTimeInterval { lock.withLock { $0.lastBufferAt } }

    init(levelWriter: VoiceLevelWriter?) {
        self.levelWriter = levelWriter
        // iOS stops the engine and changes the hardware format on a route change.
        // The tap and converter are built for the old format, so without this every
        // later buffer fails to convert and is silently dropped.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        lock.withLock { $0.wantsRunning = true }
        guard !engine.isRunning else { return }
        try installAndStart()
    }

    /// Rebuild the tap and converter for the current hardware format and start.
    func restart() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try installAndStart()
    }

    private func handleConfigurationChange() {
        guard lock.withLock({ $0.wantsRunning }) else { return }
        log.notice("OBADH-VOICE audio configuration changed; rebuilding capture")
        do {
            try restart()
        } catch {
            log.error("OBADH-VOICE capture restart failed: \(String(describing: error), privacy: .public)")
            lock.withLock { $0.wantsRunning = false }
            onFailure?(error)
        }
    }

    private func installAndStart() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noInput }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter
        // ~50 ms buffers: small enough that drafts and the visual feel immediate.
        let frames = AVAudioFrameCount(inputFormat.sampleRate * 0.05)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: frames, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        // A fresh start counts as alive; the watchdog measures from here.
        lock.withLock { $0.lastBufferAt = CACurrentMediaTime() }
        log.notice("OBADH-VOICE capture started at \(inputFormat.sampleRate, privacy: .public) Hz")
    }

    func stop() {
        lock.withLock { $0.wantsRunning = false }
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levelWriter?.writeSilence()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
        lock.withLock { $0.lastBufferAt = CACurrentMediaTime() }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        if isMetering, let levelWriter {
            meter.measure(samples) { level, bands in
                levelWriter.write(level: level, isSpeech: level > 0.08, bands: bands)
            }
        }
        onSamples?(samples)
    }
}

/// Loudness (perceptual 0...1 from dBFS) and a 12-band log-spaced spectrum from a
/// 512-point FFT. Allocation-free after init.
private final class LevelMeter: @unchecked Sendable {
    private let fftSize = 512
    private let log2n: vDSP_Length = 9
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    private var bands = [Float](repeating: 0, count: VoiceLevelFrame.bandCount)
    private let bandEdges: [Int]

    init() {
        setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: 512)
        vDSP_hann_window(&window, 512, Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: 512)
        real = [Float](repeating: 0, count: 256)
        imaginary = [Float](repeating: 0, count: 256)
        magnitudes = [Float](repeating: 0, count: 256)
        // Log-spaced edges from ~90 Hz to 8 kHz (bins of 31.25 Hz at 16 kHz).
        let count = VoiceLevelFrame.bandCount
        bandEdges = (0...count).map { index in
            let fraction = Double(index) / Double(count)
            return min(255, max(3, Int(3 * pow(256.0 / 3.0, fraction))))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func measure(_ samples: [Float], deliver: (Float, UnsafeBufferPointer<Float>) -> Void) {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let db = 20 * log10(max(rms, 1e-7))
        // -55 dBFS (room) ... -12 dBFS (close speech) mapped to 0...1, eased.
        let linear = min(max((db + 55) / 43, 0), 1)
        let level = linear * linear * (3 - 2 * linear)

        let count = min(samples.count, fftSize)
        windowed.withUnsafeMutableBufferPointer { buffer in
            buffer.update(repeating: 0)
            vDSP_vmul(samples, 1, window, 1, buffer.baseAddress!, 1, vDSP_Length(count))
        }
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        for band in 0..<VoiceLevelFrame.bandCount {
            let lower = bandEdges[band], upper = max(bandEdges[band + 1], lower + 1)
            var mean: Float = 0
            magnitudes.withUnsafeBufferPointer {
                vDSP_meanv($0.baseAddress! + lower, 1, &mean, vDSP_Length(upper - lower))
            }
            let bandDB = 20 * log10(max(mean / Float(fftSize), 1e-7))
            let value = min(max((bandDB + 70) / 45, 0), 1)
            bands[band] = value * level.squareRoot()
        }
        bands.withUnsafeBufferPointer { deliver(level, $0) }
    }
}
