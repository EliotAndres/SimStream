# About SimStream

Use the iOS Simulator screen on a browser (mobile or not). Low-latency, limited dependencies.

## Demo video








https://github.com/user-attachments/assets/98e72b20-35de-4daa-b010-dc3c413a110d





## Dependencies

- Swift/Xcode
- `idb_companion` (`brew install facebook/fb/idb-companion`): send touch events to the simulator
- Python package manager (pip or uv) to run the idb Python bridge ()
- `cloudflared` (`brew install cloudflared`): needed to expose the stream to an agent like Claude. Skip with `--no-tunnel` if you only want a local URL.
- For streaming: Chrome 94+ or Safari 16.4+ (needs `VideoDecoder`)


## Permissions

Grant both to Terminal (System Settings → Privacy & Security):

- **Screen Recording** — required to capture the Simulator window via ScreenCaptureKit.
- **Accessibility** — used to locate the device-screen rect inside the Simulator window so the macOS title bar is cropped out and touches map to the right device coordinates.

When running inside a MacOS VM, you can force-enable those permissions by modifying TCC.db (integrity protection needs to be disabled, it's the case on Tart VMs) 

## Installation (with agent skill)

```sh
npx skills add EliotAndres/SimStream
```

Installs a `/stream-simulator` skill into your coding agent. From then on, ask the agent to start SimStream (or paste an error) and it will handle setup, launch, permission prompts, and troubleshooting for you.

## Installation (manual)

```sh
./install_idb.sh
```
Installs `idb-companion` via Homebrew and creates a Python venv for the touch bridge. Uses `uv` if present, otherwise falls back to `python3 -m venv` + `pip`.

## Run

```sh
./start.sh              # default: serves http://localhost:3738 AND a Cloudflare tunnel
                        # URL so an agent (Claude, etc.) can open the stream remotely.
./start.sh --no-tunnel  # local only — skip cloudflared. Use when you're viewing
                        # from a browser on the same machine or LAN.
```


## Notes (AI Generated)

- The Swift process disables `Window → Show Device Bezels` on launch (cleaner capture).
- A single Swift binary handles capture, H.264 encoding (hardware with software fallback), HTTP, and WebSocket — no separate signaling server.
- Touch events are forwarded to `idb_companion` over a persistent gRPC bridge (`idb_touch_events_bridge.py`).
- Override the port with `PORT=xxxx swift run SimulatorStream`.
- **macOS VMs / Tart guests:** VideoToolbox often creates an H.264 session but never delivers frames (`kVTVideoEncoderNotAvailableNowErr`). The encoder falls back to software H.264 after a few failed output callbacks. To skip hardware from the first frame, set `SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER=1` (e.g. `SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER=1 ./start.sh`).
