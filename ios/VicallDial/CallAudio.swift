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

    // Rebuilt for every call. Reusing one engine across calls left the input
    // silently dead on a second dial — attaching the same player node again and
    // re-tapping a stale input produced a graph that ran but captured nothing,
    // so the server received a greeting and then zero bytes of microphone audio.
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
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
    /// Format the player node is actually connected with.
    private var connectedFormat: AVAudioFormat?
    /// 16kHz wire audio -> whatever the graph wants.
    private var playConverter: AVAudioConverter?
    private(set) var isRunning = false
    /// True when the hardware echo canceller engaged.
    private(set) var voiceProcessingActive = false

    /// One-line summary of the live audio graph, shown in-call.
    ///
    /// Three rounds were spent on a silent greeting that turned out to be a
    /// format mismatch. Surfacing the actual rates means the next audio fault
    /// is visible on the phone instead of inferred from server logs.
    private(set) var routeInfo = ""
    /// Buffers handed to the player, so "did playback happen" is answerable.
    private(set) var playedBufferCount = 0

    /// Suppress the uplink while the bot is speaking.
    ///
    /// Belt to the AEC's braces. If voice processing fails to engage — some
    /// routes and older devices — raw loudspeaker bleed would otherwise reach
    /// the server, which transcribes the bot's own words as caller speech and
    /// answers itself. Half-duplex is the honest fallback: we lose the ability
    /// to interrupt mid-sentence, but the call stays coherent.
    ///
    /// When AEC *is* active we keep streaming, because that is what makes
    /// barge-in work.
    private let gateLock = NSLock()
    private var botSpeaking = false

    /// Bot audio received before the engine was ready.
    private let preLock = NSLock()
    private var preRoll: [Data] = []
    private var preRollBytes = 0

    func setBotSpeaking(_ speaking: Bool) {
        gateLock.lock(); botSpeaking = speaking; gateLock.unlock()
    }

    private var shouldMuteUplink: Bool {
        gateLock.lock(); defer { gateLock.unlock() }
        return botSpeaking && !voiceProcessingActive
    }

    // Everything the phone hears and says is kept so a call can be replayed
    // and scored offline, which is the whole point of this app.
    private var capturedFrames: [Data] = []
    private var playedFrames: [Data] = []
    private let recLock = NSLock()

    // MARK: - lifecycle

    /// Microphone authorisation, awaited rather than fired and forgotten.
    static func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        guard !isRunning else { return }

        // Without this the whole graph comes up dead: touching inputNode
        // unauthorised leaves it misconfigured, so neither capture nor playback
        // works and nothing raises. That presented as a silent greeting AND as
        // zero microphone frames reaching the server — one fault, not two.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NSError(domain: "CallAudio", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Microphone access is not granted. Open Settings > Vicall "
                    + "and enable Microphone, then dial again.",
            ])
        }

        // Discard any previous graph before building a new one.
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        voiceProcessingActive = false
        connectedFormat = nil
        playConverter = nil
        preLock.lock(); preRoll.removeAll(); preRollBytes = 0; preLock.unlock()

        let session = AVAudioSession.sharedInstance()
        // No .defaultToSpeaker: routing playback to the loudspeaker while the
        // microphone is live is what makes echo audible in the first place.
        // The receiver (or a headset) keeps the two far apart, and .voiceChat
        // already prefers the receiver.
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.allowBluetooth])
        try session.setPreferredSampleRate(targetRate)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let output = engine.outputNode

        // The session mode alone does NOT give AVAudioEngine echo cancellation.
        // Tapping inputNode yields raw microphone audio, loudspeaker bleed
        // included, which the server then hears as caller speech — the bot ends
        // up talking to itself. Voice processing is a separate switch on the
        // nodes, and it must be set BEFORE the engine starts.
        if #available(iOS 13.0, *) {
            do {
                try input.setVoiceProcessingEnabled(true)
                try output.setVoiceProcessingEnabled(true)
                voiceProcessingActive = true
            } catch {
                // Echo cancellation is unavailable on this route. Say so rather
                // than silently streaming echo back to the server.
                voiceProcessingActive = false
                onError?("Echo cancellation unavailable — use a headset.")
            }
        }

        // Read the format AFTER enabling voice processing: turning it on can
        // change the node's channel count and sample rate.
        //
        // The route is not always ready the instant setActive returns, and a
        // 0 Hz format yields a tap that never fires. Retry briefly rather than
        // starting a call whose microphone is dead.
        var hwFormat = input.outputFormat(forBus: 0)
        var waited = 0.0
        while hwFormat.sampleRate <= 0 && waited < 1.0 {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 0.05
            hwFormat = input.outputFormat(forBus: 0)
        }
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "CallAudio", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Microphone unavailable — check the mic permission and that "
                    + "no other app is using it, then try again.",
            ])
        }
        converter = AVAudioConverter(from: hwFormat, to: wireFormat)

        engine.attach(player)
        // Connect with the MIXER's own format, not our 16kHz wire format.
        // Enabling voice processing on the output node forces the graph to the
        // hardware rate (typically 48kHz), and connecting a 16kHz format onto
        // that mismatched node produced silent playback — the greeting was
        // generated, sent and received, but never audible. Scheduling 16kHz
        // buffers onto a correctly-connected player is fine: AVAudioEngine
        // resamples them.
        let mixFormat = engine.mainMixerNode.inputFormat(forBus: 0)
        let connectFormat = mixFormat.sampleRate > 0 ? mixFormat : playFormat
        engine.connect(player, to: engine.mainMixerNode, format: connectFormat)
        connectedFormat = connectFormat
        // Convert explicitly rather than trusting the engine to resample a
        // mismatched buffer: a silent graph is far harder to notice than a
        // conversion error.
        playConverter = connectFormat.sampleRate == playFormat.sampleRate
            ? nil
            : AVAudioConverter(from: playFormat, to: connectFormat)

        let bufferSize = AVAudioFrameCount(hwFormat.sampleRate * 0.02)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buf, _ in
            self?.handleCapture(buf)
        }

        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true

        let sess = AVAudioSession.sharedInstance()
        routeInfo = String(
            format: "in %.0fkHz/%dch · out %.0fkHz · aec %@ · %@",
            hwFormat.sampleRate / 1000, Int(hwFormat.channelCount),
            connectFormat.sampleRate / 1000,
            voiceProcessingActive ? "on" : "OFF",
            sess.currentRoute.outputs.first?.portType.rawValue ?? "?")

        // Flush anything the server sent while we were still starting up.
        preLock.lock()
        let early = preRoll
        preRoll.removeAll()
        preRollBytes = 0
        preLock.unlock()
        for chunk in early {
            play(pcm16: chunk)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        setBotSpeaking(false)
        NotificationCenter.default.removeObserver(self)
        engine.inputNode.removeTap(onBus: 0)
        // Leave voice processing off for whatever uses the session next.
        if #available(iOS 13.0, *) {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            try? engine.outputNode.setVoiceProcessingEnabled(false)
        }
        voiceProcessingActive = false
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
        var data = Data(bytes: ch[0], count: bytes)

        // Without AEC, replace the bot's own bleed with silence instead of
        // dropping the frame: the server's VAD needs a continuous stream to
        // time its endpointing, and gaps read as the caller having stopped.
        if shouldMuteUplink {
            data = Data(count: bytes)
        }

        recLock.lock(); capturedFrames.append(data); recLock.unlock()
        onFrame?(data)
    }

    // MARK: - playback

    /// Enqueue PCM16 bot audio arriving from the server.
    ///
    /// Audio that arrives before the engine is running is held, not dropped.
    /// Discarding it silently is what made the opening greeting intermittently
    /// inaudible: the server starts speaking as soon as it sees the hello
    /// frame, and anything delivered in that window vanished.
    func play(pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        guard isRunning else {
            preLock.lock()
            // Bound it: if the engine never starts, this must not grow without
            // limit. ~2s at 16kHz PCM16 is plenty to cover the startup window.
            if preRollBytes < 64_000 {
                preRoll.append(pcm16)
                preRollBytes += pcm16.count
            }
            preLock.unlock()
            return
        }
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
        guard let out = convertForPlayback(buf) else { return }
        playedBufferCount += 1
        player.scheduleBuffer(out, completionHandler: nil)
    }

    /// Resample a 16kHz buffer to the connected format when they differ.
    private func convertForPlayback(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let conv = playConverter, let target = connectedFormat else {
            return buf  // formats already match
        }
        let ratio = target.sampleRate / playFormat.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else {
            return nil
        }
        var done = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true
            status.pointee = .haveData
            return buf
        }
        return err == nil && out.frameLength > 0 ? out : nil
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
