---
name: stream-simulator
description: Install, launch, and troubleshoot SimStream — a low-latency iOS Simulator → browser streamer (macOS only). Default launch exposes a Cloudflare tunnel URL so an off-device viewer like Claude can open the stream; falls back to local-only if cloudflared isn't installed. Use when the user wants to share their running Simulator with Claude (or any remote viewer), mirror the Simulator to a phone/laptop browser, or fix SimStream startup errors (idb_companion missing, TCC permissions, port 3738 busy, VideoToolbox failures in VMs).
---

# stream-simulator

Help the user get SimStream running. SimStream captures the macOS iOS Simulator window with ScreenCaptureKit, encodes H.264, and serves an HTTP + WebSocket page so any modern browser can view it with low latency. Touches in the browser are forwarded to the simulator via `idb_companion`.

Source: https://github.com/EliotAndres/SimStream

## Platform check

SimStream is **macOS only** (ScreenCaptureKit + iOS Simulator). If the user is on Linux/Windows, stop and tell them.

## 1. Locate or clone the repo

Check if the current working directory is the SimStream repo (look for `Package.swift` with a `SimulatorStream` target and `start.sh`). If not:

```sh
git clone https://github.com/EliotAndres/SimStream.git
cd SimStream
```

All further commands assume the SimStream working directory.

## 2. Install dependencies

```sh
./install_idb.sh
```

This script:
- Installs `idb-companion` via Homebrew (`brew install facebook/fb/idb-companion`)
- Creates `.venv/` with `grpclib` and `fb-idb` (uses `uv` if present, else `python3 -m venv` + `pip`)

Prerequisites the script will refuse to proceed without:
- **Homebrew** — install from https://brew.sh
- **Xcode / Swift toolchain** — `xcode-select --install` (or full Xcode for the Simulator itself)
- Either **`uv`** (`curl -LsSf https://astral.sh/uv/install.sh | sh`) or **`python3`** (`brew install python@3.12`)

Recommended (used by default, needed to expose the stream to an off-device viewer like Claude):
```sh
brew install cloudflared
```
If cloudflared isn't installed, the skill falls back to a local-only run (`--no-tunnel`) and tells the user how to enable remote viewing — see step 5.

## 3. Grant macOS permissions (one-time, easy to miss)

In **System Settings → Privacy & Security**, grant the user's terminal app (Terminal.app, iTerm, Ghostty, etc.) **both**:

- **Screen Recording** — required for ScreenCaptureKit to capture the Simulator window. Without it, capture returns black frames or fails silently.
- **Accessibility** — used to read the Simulator window's device-screen rect so the macOS title bar is cropped out and browser touches map to the correct simulator coordinates.

After toggling either permission the terminal must be **fully quit and relaunched** (macOS caches the TCC decision per-process).

**macOS VMs (Tart, etc.):** TCC prompts don't appear. If System Integrity Protection is disabled (default on Tart guests), the user can force-grant by editing `/Library/Application Support/com.apple.TCC/TCC.db` directly. Don't attempt this on a normal Mac.

## 4. Boot a simulator — REQUIRED BEFORE LAUNCH

SimStream's touch pipeline aborts with `[ERROR][Touch] No booted iOS Simulator found` if no simulator is running when `swift run SimulatorStream` starts. `start.sh` only prints a soft warning — do not rely on it. **You must verify a simulator is booted before step 5.**

Check:

```sh
xcrun simctl list devices booted | grep -q "(Booted)" && echo "ok" || echo "NONE BOOTED"
```

If none is booted, boot one and wait for it to come up (Simulator.app launch is async):

```sh
open -a Simulator
until xcrun simctl list devices booted | grep -q "(Booted)"; do sleep 1; done
```

`open -a Simulator` boots the last-used device. To pick a specific one: `xcrun simctl list devices available` to find a UDID, then `xcrun simctl boot <UDID>`.

Only proceed to step 5 once a simulator is confirmed Booted.

## 5. Launch

`./start.sh` defaults to **tunnel mode** (serves `http://localhost:3738` *and* a Cloudflare public URL via `cloudflared`) so a remote viewer like Claude can open the stream. For a local-only run, pass `--no-tunnel`.

**Before launching, check for `cloudflared`:**

```sh
command -v cloudflared
```

- **If present** → run `./start.sh` (default). Watch the cloudflared output for the public `https://*.trycloudflare.com` URL and hand it to the user.
- **If absent** → run `./start.sh --no-tunnel` so the launch succeeds. Then tell the user, in one short line, that remote viewing (e.g. sharing with Claude) needs cloudflared and `brew install cloudflared` only takes a moment — they can install it and re-run for a public URL.

`start.sh` runs preflight checks and aborts on the first failure with a clear message. Read the script's stderr — it tells you exactly which dep is missing.

Override port: `PORT=4000 swift run SimulatorStream` (bypasses `start.sh`).

Force software encoder (needed in some VMs): `SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER=1 ./start.sh`.

Viewer requirements: **Chrome 94+ or Safari 16.4+** (needs `VideoDecoder`).

## Troubleshooting

Map the user's error to a fix:

| Symptom | Cause | Fix |
|---|---|---|
| `'idb_companion' not found` | Homebrew formula missing | `./install_idb.sh` or `brew install facebook/fb/idb-companion` |
| `Python venv missing (.venv/bin/python)` | `install_idb.sh` never ran | `./install_idb.sh` |
| `'.venv/bin/idb' missing` | venv exists but `fb-idb` not installed | Delete `.venv` and re-run `./install_idb.sh` |
| `port 3738 is busy` | Prior SimStream still running or another service on the port | `lsof -i :3738 -P -n` then `kill <pid>`, or run with `PORT=xxxx swift run SimulatorStream` |
| `[ERROR][Touch] No booted iOS Simulator found` | SimStream was launched before any simulator was Booted | Stop SimStream, boot a simulator (`open -a Simulator` then wait for `xcrun simctl list devices booted` to show `(Booted)`), then re-run `./start.sh` |
| Black frames in browser, no error | Screen Recording permission not granted to terminal | Grant in System Settings, then **fully quit and relaunch the terminal** |
| Touches in browser don't reach simulator | Accessibility permission not granted, or no simulator booted | Grant Accessibility (relaunch terminal); boot a simulator |
| `kVTVideoEncoderNotAvailableNowErr` in logs, stream never starts | VideoToolbox HW encoder unavailable (common in macOS VMs) | The encoder auto-falls back to SW after a few failed callbacks. To skip HW from frame 1: `SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER=1 ./start.sh` |
| `'cloudflared' is not installed (needed for the default tunnel mode)` | cloudflared missing and user wants a tunnel | `brew install cloudflared` — or relaunch with `./start.sh --no-tunnel` for a local-only run |
| `'swift' not found` | No Xcode/CLT | `xcode-select --install` (or install Xcode) |
| Browser loads page but video never appears | Browser too old, or no booted simulator | Use Chrome 94+ / Safari 16.4+; boot a simulator |
| WebSocket disconnects, "viewer reconnect" loop | Network/tunnel hiccup | Refresh viewer tab; the server auto-recovers |

## What this skill is NOT

- Not a debugger for the Swift code itself — if the user reports a crash inside `Sources/`, treat it as a normal bug-fix task.
- Not for changing encoding quality at runtime — the README documents the live FPS / bitrate / max-height sliders in the browser UI; point the user there.
