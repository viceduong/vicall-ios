import Foundation

/// Transcript / event line shown in the in-call view.
struct CallEvent: Identifiable, Equatable {
    enum Kind: Equatable { case caller, bot, system, decision }
    let id = UUID()
    let kind: Kind
    let text: String
    let at: Date
}

/// Server-reported metrics for one finished call.
struct CallSummary: Equatable {
    var callID: String = ""
    var action: String = ""
    var intent: String = ""
    var urgency: Int = 0
    var turns: Int = 0
    var durationS: Double = 0
    var bargeIns: Int = 0
    var responseP50: Int = 0
    var responseP95: Int = 0
}

/// Websocket transport to the vicall server.
///
/// Wire protocol: a JSON hello frame opens the call, binary frames are PCM16
/// audio in both directions, and JSON frames carry pipeline events so the app
/// can show a live transcript.
@MainActor
final class CallClient: NSObject, ObservableObject {
    @Published var state: State = .idle
    @Published var events: [CallEvent] = []
    @Published var partial: String = ""
    @Published var summary: CallSummary?
    @Published var lastResponseMs: Int?
    /// Survives a failed call so the cause is still readable afterwards.
    /// A .failed state returns the UI to the dial screen and discards `events`,
    /// which is why five rounds of audio diagnostics were never seen.
    @Published var diagnostics: [String] = []

    enum State: Equatable {
        case idle, connecting, inCall, ending
        case failed(String)
    }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    /// Keeps the tunnel from treating a quiet call as a dead connection.
    private var heartbeat: Timer?
    /// Catches a microphone that starts but never delivers audio.
    private var micWatchdog: Timer?
    private var framesSent = 0
    private let audio = CallAudio()
    private var scenario = "screening"

    /// Local copy of the call, written when the call ends.
    private(set) var lastRecordingURL: URL?

    // MARK: - dial

    func dial(urlString: String, scenario: String, token: String = "") {
        guard state == .idle || isFailed else { return }
        // Settle the microphone permission before opening the socket, so a
        // first run cannot start a call whose audio graph is dead.
        Task { [weak self] in
            let ok = await CallAudio.requestMic()
            await MainActor.run {
                guard let self else { return }
                if ok {
                    self.reallyDial(urlString: urlString, scenario: scenario, token: token)
                } else {
                    self.state = .failed(
                        "Microphone access denied. Open Settings > Vicall and "
                        + "enable Microphone.")
                }
            }
        }
    }

    private func reallyDial(urlString: String, scenario: String, token: String) {
        self.scenario = scenario
        events.removeAll()
        partial = ""
        summary = nil
        lastResponseMs = nil
        audio.resetRecording()

        guard let url = URL(string: urlString), url.scheme == "ws" || url.scheme == "wss" else {
            state = .failed("Bad server URL. Use wss://host/ws/call")
            return
        }

        state = .connecting
        let cfg = URLSessionConfiguration.default
        // On a websocket URLSession treats this as an INACTIVITY timeout, not
        // just a handshake deadline. At 15s it was tearing down calls mid-turn:
        // the socket goes quiet while the bot thinks and speaks, which is
        // routinely longer than 15s, and iOS killed it as idle. The heartbeat
        // below is also now faster than this value, so a genuinely quiet call
        // still gets traffic.
        cfg.timeoutIntervalForRequest = 300
        cfg.waitsForConnectivity = true
        // The socket must survive a long call with gaps between turns.
        cfg.timeoutIntervalForResource = 3600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        t.resume()
        receive()

        // The server requires this when it runs with VICALL_TOKEN set, since the
        // tunnel exposes the endpoint publicly.
        var hello: [String: Any] = ["scenario": scenario, "phone": "ios-app"]
        if !token.isEmpty { hello["token"] = token }
        // Start audio BEFORE the hello. The server greets the moment it sees
        // the hello frame, and play(pcm16:) drops anything that arrives while
        // the engine is not running — which is why the first greeting was
        // sometimes silent. Ordering it this way removes the race entirely.
        do {
            try audio.start()
            diag("audio.start OK — \(audio.routeInfo)")
        } catch {
            // This was invisible before: .failed swaps the view back to the
            // dial screen and the transcript goes with it.
            diag("audio.start FAILED: \(error.localizedDescription)")
            state = .failed("Audio failed: \(error.localizedDescription)")
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            return
        }

        send(json: hello)

        framesSent = 0
        audio.onFrame = { [weak self] data in
            guard let self else { return }
            self.task?.send(.data(data)) { _ in }
            Task { @MainActor in self.framesSent += 1 }
        }
        audio.onError = { [weak self] msg in
            Task { @MainActor in self?.append(.system, msg) }
        }
        // Cloudflare closes an idle websocket at roughly 100s. Audio normally
        // keeps it busy, but the gaps between turns can be long enough to trip
        // that, so send our own ping.
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self, let task = self.task else { return }
            task.sendPing { [weak self] err in
                guard let err else { return }
                // A failed ping is the earliest reliable signal that the
                // connection is gone; surface it instead of waiting for a read
                // to fail much later.
                Task { @MainActor in
                    guard let self, self.state == .inCall else { return }
                    self.heartbeat?.invalidate(); self.heartbeat = nil
                    self.micWatchdog?.invalidate(); self.micWatchdog = nil
                    self.saveRecording()
                    self.state = .failed("Connection lost: \(err.localizedDescription)")
                    self.audio.stop()
                }
            }
        }

        // A silently dead microphone used to look like a network problem: the
        // server played its greeting, received zero audio, and ended the call
        // after the no-input timeout. Detect it here and say so.
        micWatchdog?.invalidate()
        micWatchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.state == .inCall else { return }
                // Report the whole chain, so the next failure is localisable
                // without another round trip: did the tap fire, did frames
                // survive conversion, did anything play.
                let taps = self.audio.tapFireCount
                let why = self.audio.captureDropReason
                let msg = "mic: taps=\(taps) sent=\(self.framesSent)"
                    + (why.isEmpty ? "" : " dropped(\(why))")
                    + " | playback: \(self.audio.playedBufferCount) buffers"
                self.append(.system, msg)
                self.diag(msg)
                if taps == 0 {
                    let hint = "Input tap never fired — the microphone is not "
                        + "delivering audio to the app at all."
                    self.append(.system, hint); self.diag(hint)
                }
            }
        }

        state = .inCall
        append(.system, "Connected — speak when the assistant finishes.")
        if !audio.routeInfo.isEmpty { append(.system, audio.routeInfo) }

        // Report whether bot audio actually reached the player. A silent
        // greeting with a healthy server looks identical to a failed one from
        // the app, so state it explicitly.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await MainActor.run {
                guard let self, self.state == .inCall else { return }
                let n = self.audio.playedBufferCount
                let msg = n == 0
                    ? "0 playback buffers — graph dead. \(self.audio.routeInfo)"
                    : "Playback OK: \(n) buffers, \(self.framesSent) mic frames sent."
                self.append(.system, msg)
                self.diag(msg)
            }
        }
    }

    func hangUp() {
        guard state == .inCall || state == .connecting else { return }
        state = .ending
        heartbeat?.invalidate(); heartbeat = nil
        micWatchdog?.invalidate(); micWatchdog = nil
        send(json: ["type": "hangup"])
        audio.stop()
        // Persist locally even if the server summary never arrives.
        saveRecording()
        // Give the server a moment to send its summary before tearing down.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                self?.task?.cancel(with: .goingAway, reason: nil)
                self?.task = nil
                if self?.state == .ending { self?.state = .idle }
            }
        }
    }

    // MARK: - receive

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                Task { @MainActor in
                    // A cancel during hangup is expected, not a failure.
                    if self.state == .inCall || self.state == .connecting {
                        self.heartbeat?.invalidate(); self.heartbeat = nil
                        self.micWatchdog?.invalidate(); self.micWatchdog = nil
                        self.saveRecording()  // keep what we captured
                        self.state = .failed("Connection dropped: \(err.localizedDescription)")
                        self.audio.stop()
                    }
                }
            case .success(let msg):
                switch msg {
                case .data(let d):
                    self.audio.play(pcm16: d)
                case .string(let s):
                    Task { @MainActor in self.handle(json: s) }
                @unknown default:
                    break
                }
                self.receive()
            }
        }
    }

    private func handle(json: String) {
        guard let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let type = o["type"] as? String else { return }

        switch type {
        case "call_start":
            if let label = o["label"] as? String { append(.system, label) }

        case "asr.partial":
            partial = (o["text"] as? String) ?? ""

        case "asr.final":
            partial = ""
            if let t = (o["text"] as? String), !t.isEmpty { append(.caller, t) }

        case "tts.start":
            audio.setBotSpeaking(true)
            if let t = o["text"] as? String { append(.bot, t) }

        case "tts.done", "tts.cancelled":
            audio.setBotSpeaking(false)

        case "turn.barge_in":
            // The server stopped talking; drop audio we already queued or the
            // bot keeps speaking locally after being interrupted.
            audio.setBotSpeaking(false)
            audio.flushPlayback()
            append(.system, "— interrupted —")

        case "llm.decision":
            let action = (o["action"] as? String) ?? "?"
            let intent = (o["intent"] as? String) ?? ""
            let urg = (o["urgency"] as? Int) ?? 0
            append(.decision, "action=\(action)  intent=\(intent)  urgency=\(urg)")

        case "cc.handoff":
            if let r = o["reason"] as? String { append(.system, "override: \(r)") }

        case "tts.first_audio":
            if let ms = o["ms"] as? Double { lastResponseMs = Int(ms) }

        case "call_summary":
            var s = CallSummary()
            s.callID = (o["call_id"] as? String) ?? ""
            s.action = (o["action"] as? String) ?? ""
            s.intent = (o["intent"] as? String) ?? ""
            s.urgency = (o["urgency"] as? Int) ?? 0
            s.turns = (o["turns"] as? Int) ?? 0
            s.durationS = (o["duration_s"] as? Double) ?? 0
            s.bargeIns = (o["barge_ins"] as? Int) ?? 0
            if let stages = o["stages"] as? [String: Any],
               let resp = stages["response"] as? [String: Any] {
                s.responseP50 = (resp["p50_ms"] as? Int) ?? 0
                s.responseP95 = (resp["p95_ms"] as? Int) ?? 0
            }
            summary = s
            append(.system, "Call ended — \(s.action), \(s.turns) turns")

        case "error":
            if let m = o["message"] as? String { state = .failed(m) }

        default:
            break
        }
    }

    // MARK: - helpers

    private func append(_ kind: CallEvent.Kind, _ text: String) {
        events.append(CallEvent(kind: kind, text: text, at: Date()))
        if kind == .system {
            diagnostics.append(text)
            if diagnostics.count > 40 { diagnostics.removeFirst() }
        }
    }

    /// Record a line that must outlive the call, even on failure.
    private func diag(_ text: String) {
        diagnostics.append(text)
        if diagnostics.count > 40 { diagnostics.removeFirst() }
    }

    private func send(json: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: json),
              let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    private func saveRecording() {
        guard audio.capturedSeconds > 0.5 else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("vicall-\(stamp).wav")
        do {
            try audio.writeWav(to: url)
            lastRecordingURL = url
            append(.system, "Saved recording: \(url.lastPathComponent)")
        } catch {
            append(.system, "Could not save recording: \(error.localizedDescription)")
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

extension CallClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        Task { @MainActor in
            self.heartbeat?.invalidate(); self.heartbeat = nil
            self.micWatchdog?.invalidate(); self.micWatchdog = nil
            self.audio.stop()
            if self.state == .inCall {
                // Server-initiated close mid-call: surface it rather than
                // silently returning to the dial screen.
                self.saveRecording()
                self.state = .failed("Server closed the connection (code \(closeCode.rawValue)).")
            }
        }
    }
}
