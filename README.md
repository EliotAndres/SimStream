# About SimStream

For Leo's existing Mac mini deployment, start with [AGENTS.md](AGENTS.md).
It documents the private Tailscale setup and the actual capture-permission context.
The upstream installation guide below is preserved for reference.

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


## Xcode 27 / Device Hub

Xcode 27.2 replaces Simulator.app with Device Hub (`com.apple.dt.Devices`).
Show a booted device with `open "devices://device/open?id=<udid>"`.
SimStream prefers an iOS-titled device window and still supports legacy Simulator.
Full Device Hub windows are switched to compact mode once at capture startup,
because the full-mode AX tree does not expose the phone screen. Compact capture
removes the top toolbar/group height measured through Accessibility; zoomed
window points are scaled to the logical device size reported by idb for touches.
If the compact switch or geometry is unavailable (including a switch timeout),
the whole window is captured and precise touch mapping is not guaranteed.
An already-compact window wider than 400 points is conservatively left uncropped
when its mode cannot be confirmed; start with a narrower compact window in that case.

Look for `[Capture] Found Device Hub window:`, followed by
`[Capture] AX content rect in window:` and `[Capture] Cropping to content area:`.
A full-mode startup also logs `[Capture] Switching Device Hub to compact mode`
and `[Capture] Device Hub compact mode ready`. The legacy path retains
`[Capture] Found Simulator window:`. The `ShowDeviceBezels` preference is written
only when legacy Simulator.app is installed.

**Picture size.** The compact window opens small (about 188x410 points for an
iPhone 17 Pro) and Device Hub disables its zoom commands in compact mode. Drag
the window's corner to enlarge it; SimStream crops to the phone element at
whatever size it finds, so a larger window is a sharper stream.

**Permissions and rebuilds.** macOS ties Screen Recording and Accessibility to
the binary's code signature. An ad-hoc build gets a new signature on every
rebuild, and the existing entries in System Settings then look enabled but no
longer match (remove them with "-" and add the binary again). Put a signing
identity in `SIMSTREAM_CODESIGN_IDENTITY` or a `.codesign-identity` file and
`start.sh` signs the build so the grants persist.

## Notes (AI Generated)

- When legacy Simulator.app is installed, the Swift process disables `Window → Show Device Bezels` on launch (cleaner capture).
- A single Swift binary handles capture, H.264 encoding (hardware with software fallback), HTTP, and WebSocket — no separate signaling server.
- Touch events are forwarded to `idb_companion` over a persistent gRPC bridge (`idb_touch_events_bridge.py`).
- Override the port with `PORT=xxxx swift run SimulatorStream`.
- **macOS VMs / Tart guests:** VideoToolbox often creates an H.264 session but never delivers frames (`kVTVideoEncoderNotAvailableNowErr`). The encoder falls back to software H.264 after a few failed output callbacks. To skip hardware from the first frame, set `SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER=1` (e.g. `SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER=1 ./start.sh`).
