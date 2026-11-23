import AVFoundation
import Foundation

/// Microphone capture and bot-audio playback for a live call.
///
/// Capture is 16 kHz mono PCM16, which is exactly what the server's ASR wants,
/// so no resampling happens on either side of the wire.
///
/// The session uses `.playAndRecord` with mode `.voiceChat`, which turns on the
/// hardware echo canceller. That is what makes barge-in trustworthy here and
/// not on a desktop mic: the bot's own voice is removed from the uplink, so
/// speech detected during playback is really the caller interrupting.
final class CallAudio {
    /// Called with each captured PCM16 frame, ready to send.
    var onFrame: ((Data) -> Void)?
    /// Raised when audio cannot continue (route loss, interruption).
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let targetRate: Double = 16_000

    /// Capture format: PCM16, mono, 16 kHz — matched to the server.
    private lazy var wireFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: targetRate,
                      channels: 1,
                      interleaved: true)!
    }()

    /// Playback format: Float32 at the same rate; AVAudioPlayerNode wants float.
    private lazy var playFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: targetRate,
                      channels: 1,
                      interleaved: false)!
    }()

    private var converter: AVAudioConverter?
    private(set) var isRunning = false

    // Everything the phone hears and says is kept so a call can be replayed
    // and scored offline, which is the whole point of this app.
    private var capturedFrames: [Data] = []
    private var playedFrames: [Data] = []
    private let recLock = NSLock()

    // MARK: - lifecycle

    func start() throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.allowBluetooth, .defaultToSpeaker])
        try session.setPreferredSampleRate(targetRate)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        // The hardware rate is whatever the route gives us (often 48 kHz), so
        // convert from the node's own format rather than assuming.
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "CallAudio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Microphone unavailable. Check permissions.",
            ])
        }
        converter = AVAudioConverter(from: hwFormat, to: wireFormat)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let bufferSize = AVAudioFrameCount(hwFormat.sampleRate * 0.02)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buf, _ in
            self?.handleCapture(buf)
        }

        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        NotificationCenter.default.removeObserver(self)
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - capture

    private func handleCapture(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        if err != nil { return }

        guard let ch = out.int16ChannelData, out.frameLength > 0 else { return }
        let bytes = Int(out.frameLength) * 2
        let data = Data(bytes: ch[0], count: bytes)

        recLock.lock(); capturedFrames.append(data); recLock.unlock()
        onFrame?(data)
    }

    // MARK: - playback

    /// Enqueue PCM16 bot audio arriving from the server.
    func play(pcm16: Data) {
        guard isRunning, !pcm16.isEmpty else { return }
        recLock.lock(); playedFrames.append(pcm16); recLock.unlock()

        let count = pcm16.count / 2
        guard let buf = AVAudioPCMBuffer(pcmFormat: playFormat,
                                         frameCapacity: AVAudioFrameCount(count)),
              let dst = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(count)

        pcm16.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                dst[0][i] = Float(src[i]) / 32768.0
            }
        }
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    /// Drop anything still queued — used when the caller interrupts the bot.
    func flushPlayback() {
        guard isRunning else { return }
        player.stop()
        player.play()
    }

    // MARK: - recordings

    /// Write the call to a 16-bit stereo WAV: left = caller, right = bot.
    ///
    /// Each leg is laid down as a continuous track. That mirrors the server's
    /// own mixdown closely enough for review, without trying to reconstruct
    /// exact interleaving from the client side.
    func writeWav(to url: URL) throws {
        recLock.lock()
        let mine = capturedFrames
        let theirs = playedFrames
        recLock.unlock()

        let left = mine.flatMap { samples(from: $0) }
        let right = theirs.flatMap { samples(from: $0) }
        let n = max(left.count, right.count)
        guard n > 0 else { return }

        var body = Data(capacity: n * 4)
        for i in 0..<n {
            var l = i < left.count ? left[i] : 0
            var r = i < right.count ? right[i] : 0
            withUnsafeBytes(of: &l) { body.append(contentsOf: $0) }
            withUnsafeBytes(of: &r) { body.append(contentsOf: $0) }
        }
        try (wavHeader(dataBytes: body.count, channels: 2, rate: Int(targetRate)) + body)
            .write(to: url)
    }

    func resetRecording() {
        recLock.lock(); capturedFrames.removeAll(); playedFrames.removeAll(); recLock.unlock()
    }

    var capturedSeconds: Double {
        recLock.lock(); defer { recLock.unlock() }
        return Double(capturedFrames.reduce(0) { $0 + $1.count / 2 }) / targetRate
    }

    private func samples(from d: Data) -> [Int16] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    private func wavHeader(dataBytes: Int, channels: Int, rate: Int) -> Data {
        var h = Data()
        func str(_ s: String) { h.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        let byteRate = rate * channels * 2
        str("RIFF"); u32(UInt32(36 + dataBytes)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(rate)); u32(UInt32(byteRate)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(dataBytes))
        return h
    }

    // MARK: - interruptions

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            onError?("Audio interrupted (another app took the microphone).")
        }
    }
}
