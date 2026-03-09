# recall

`recall` is an iOS lifelogging app that records continuously, keeps voice segments, and uploads audio chunks to a configurable HTTP ingest endpoint.

## What it does

- Always-on background recording with `AVAudioEngine`
- 2-stage voice activity detection (RMS gate + Silero VAD via FluidAudio)
- AAC-LC chunking for efficient upload and storage
- Optional telemetry upload for location and HealthKit summaries
- Optional `openclaw-plugin/` helper for OpenClaw telemetry ingestion

## Repository layout

- `recall/`: iOS app source
- `RecordingControl/`: Control Center extension
- `openclaw-plugin/`: optional OpenClaw plugin for telemetry ingestion
- `project.yml`: XcodeGen project spec

## Setup

### iOS app

1. Generate the Xcode project from `project.yml` with XcodeGen.
2. Build and run on iOS 17+.
3. Configure your upload server in the app's Settings screen.
4. If you use telemetry, configure the telemetry server URL and bearer token in Settings.

No private server URLs, tokens, or local infrastructure defaults are included in this repository.

### OpenClaw plugin

The OpenClaw plugin is optional. See [openclaw-plugin/README.md](openclaw-plugin/README.md) for installation and local configuration.

## Build

```bash
xcodegen generate
xcodebuild -project recall.xcodeproj -scheme recall -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' build
```

## Notes

- `recall` starts recording on launch and is designed for always-on background capture.
- Upload and telemetry endpoints are runtime configuration, not baked into source control.
- HealthKit and location permissions are requested by iOS when those features are enabled.

## License

MIT. See [LICENSE](LICENSE).
