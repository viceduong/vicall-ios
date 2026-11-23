import UIKit
import SwiftUI

/// Dial screen, in-call transcript, and the local recordings list.
struct DialView: View {
    @StateObject private var client = CallClient()
    @AppStorage("serverURL") private var serverURL = "wss://your-server.example/ws/call"
    @AppStorage("scenario") private var scenario = "screening"
    @AppStorage("token") private var token = ""
    @State private var showRecordings = false

    private let scenarios: [(id: String, label: String)] = [
        ("screening", "Sàng lọc cuộc gọi"),
        ("support", "Hỗ trợ khách hàng"),
        ("booking", "Đặt lịch hẹn"),
        ("sales_qual", "Sàng lọc khách tiềm năng"),
    ]

    var body: some View {
        NavigationView {
            Group {
                if client.state == .inCall || client.state == .ending {
                    inCall
                } else {
                    dialPad
                }
            }
            .navigationTitle("Vicall")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showRecordings = true } label: {
                        Image(systemName: "waveform")
                    }
                    .disabled(client.state == .inCall)
                }
            }
            .sheet(isPresented: $showRecordings) { RecordingsView() }
        }
    }

    // MARK: - dial

    private var dialPad: some View {
        Form {
            Section("Server") {
                TextField("wss://host/ws/call", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
                // Required when the server runs with VICALL_TOKEN set, which it
                // should whenever it is reachable through the tunnel.
                SecureField("access token (if required)", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
            }

            Section("Scenario") {
                Picker("Scenario", selection: $scenario) {
                    ForEach(scenarios, id: \.id) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if case .failed(let msg) = client.state {
                Section {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.footnote)
                }
            }

            if let s = client.summary {
                Section("Last call") {
                    LabeledRow("Action", s.action)
                    LabeledRow("Intent", s.intent.isEmpty ? "—" : s.intent)
                    LabeledRow("Turns", "\(s.turns)")
                    LabeledRow("Duration", String(format: "%.1fs", s.durationS))
                    LabeledRow("Barge-ins", "\(s.bargeIns)")
                    if s.responseP50 > 0 {
                        LabeledRow("Response p50", "\(s.responseP50) ms")
                        LabeledRow("Response p95", "\(s.responseP95) ms")
                    }
                }
            }

            Section {
                Button {
                    client.dial(urlString: serverURL, scenario: scenario, token: token)
                } label: {
                    HStack {
                        Spacer()
                        Label(client.state == .connecting ? "Connecting…" : "Call",
                              systemImage: "phone.fill")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(client.state == .connecting)
            }
        }
    }

    // MARK: - in call

    private var inCall: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(client.events) { ev in
                            row(ev).id(ev.id)
                        }
                        if !client.partial.isEmpty {
                            Text(client.partial)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .italic()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .id("partial")
                        }
                    }
                    .padding()
                }
                .onChange(of: client.events.count) { _ in
                    if let last = client.events.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack {
                if let ms = client.lastResponseMs {
                    Label("\(ms) ms", systemImage: "timer")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(ms < 1500 ? .green : .orange)
                }
                Spacer()
                Button(role: .destructive) {
                    client.hangUp()
                } label: {
                    Label("Hang up", systemImage: "phone.down.fill")
                        .font(.headline)
                }
                .disabled(client.state == .ending)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func row(_ ev: CallEvent) -> some View {
        switch ev.kind {
        case .caller:
            bubble(ev.text, color: .blue, align: .trailing)
        case .bot:
            bubble(ev.text, color: .gray.opacity(0.35), align: .leading)
        case .decision:
            Text(ev.text)
                .font(.caption.monospaced())
                .foregroundColor(.purple)
                .frame(maxWidth: .infinity, alignment: .center)
        case .system:
            Text(ev.text)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func bubble(_ text: String, color: Color,
                        align: HorizontalAlignment) -> some View {
        HStack {
            if align == .trailing { Spacer(minLength: 40) }
            Text(text)
                .padding(10)
                .background(color)
                .cornerRadius(12)
            if align == .leading { Spacer(minLength: 40) }
        }
    }
}

private struct LabeledRow: View {
    let k: String
    let v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundColor(.secondary).font(.body.monospacedDigit())
        }
    }
}

/// Local recordings, so a call can be replayed or exported for WER scoring.
struct RecordingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []

    var body: some View {
        NavigationView {
            List {
                if files.isEmpty {
                    Text("No recordings yet.").foregroundColor(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    // ShareLink is iOS 16+, and this app targets iOS 15, so
                    // export goes through the UIKit share sheet instead.
                    Button {
                        share(url)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .font(.footnote.monospaced())
                                    .lineLimit(1)
                                Text(sizeText(url)).font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { try? FileManager.default.removeItem(at: files[i]) }
                    load()
                }
            }
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        files = ((try? FileManager.default.contentsOfDirectory(at: dir,
                                                              includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func share(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return }
        // Walk to whatever is actually on top, or presenting fails inside a sheet.
        var top = root
        while let p = top.presentedViewController { top = p }
        top.present(vc, animated: true)
    }

    private func sizeText(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        // 16 kHz, 2 channels, 16-bit => 64000 bytes per second.
        return String(format: "%.1fs · %d KB", Double(bytes) / 64000.0, bytes / 1024)
    }
}
