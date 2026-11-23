# VicallDial

iOS dialer for [vicall](https://github.com/viceduong), an offline Vietnamese
AI call-screening pipeline (streaming ASR + local LLM + TTS).

The app exists to measure the thing synthetic audio cannot: real-speech word
error rate. Benchmark WER on text-to-speech sentences came out around 1.5%,
while conversational speech through the same pipeline measured 31-56%, so the
benchmark was not predictive. This dials the server with a real human voice
over a real network path and records both legs for scoring.

## What it does

- Captures 16 kHz mono PCM16 and streams it over a websocket
- Plays the assistant's audio back as it arrives
- `.playAndRecord` + `.voiceChat` mode, so the hardware echo canceller is on —
  that is what makes barge-in detection trustworthy on a phone
- Shows a live transcript, the per-turn decision, and response latency
- Saves each call locally as stereo WAV (left = caller, right = bot) for export

## Build

No signing. GitHub Actions generates the project with XcodeGen, builds
unsigned for device and uploads `VicallDial.ipa` as an artifact. Install it
with AltStore or Sideloadly.

Locally, with Xcode and XcodeGen:

```bash
cd ios && xcodegen generate --spec project.yml && open VicallDial.xcodeproj
```

## Configuration

Set the server URL and access token on the dial screen; both persist. The URL
is a websocket endpoint (`wss://host/ws/call`), and the token must match the
server's `VICALL_TOKEN`. Plain `ws://` to a LAN address works because
`Info.plist` sets `NSAllowsLocalNetworking`.

This repo is a mirror of the `ios/` directory of a private monorepo; the server
is not included.
