# SimStream on Leo's Mac mini

Claude and Codex share these project instructions. This is the live working copy
of the upstream Swift iOS Simulator streamer, not the whole-desktop stream.

- Read `README.md` for source architecture. Local deployment facts are canonical
  in `~/Vibe Coding Infra/docs/simstream.md`; use that document over upstream
  installation defaults when working on this mini.
- `Sources/` contains the Swift capture/encoding/HTTP/WebSocket implementation.
  `browser/` is the viewer; `idb_touch_events_bridge.py` forwards simulator input.
  Swift package: `Package.swift`, macOS 14+. The existing Python bridge uses 3.12.
- The live copy is `~/Developer/SimStream`. The separate infrastructure submodule
  at `~/Vibe Coding Infra/external/SimStream` pins upstream; do not merge the two
  trees or alter the submodule pin as part of a local fix.
- The mini runs `com.leolim.simstream` in its GUI session via `~/bin/simstream-agent`
  and `start.sh --no-tunnel`: local port 3738, private Tailscale entry port 3739.
  The Swift server can bind all interfaces; `--no-tunnel` does not make it loopback.
- Read-only status: `~/bin/simstream-probe --json`. Canonical logs are
  `/tmp/simstream.log` and `/tmp/simstream.err`. Redact any private data in reports.
- For the whole Mac desktop, keyboard/password entry or zoom/orientation, work in
  `~/Vibe Coding Infra/bin/screenstream` and its tests, not this simulator streamer.
  Read the shared `~/Vibe Coding Infra/skills/mini-streams/SKILL.md` when diagnosing either.
- Preserve the active stream, simulator and existing TCC identities. Local builds
  use an isolated worktree and separate Swift scratch path; do not rebuild/replace
  the live `.build` binary merely to validate an edit. Dependencies/venv need
  their own setup in worktrees; do not copy credentials or live runtime state.
- Screen Recording for the GUI LaunchAgent belongs to its actual SimulatorStream
  binary/context. Use normal macOS permission UI; do not edit TCC databases or
  disable system protections. Terminal instructions in upstream docs are not a
  description of this deployment.
- Starting/stopping services, installing dependencies, simulator changes, public
  tunnels and deployments require authorization for that action. No Cloudflare
  tunnel or new paid service is implied by permission to work on this repository.
- Keep `.claude/settings.local.json` local and provider-specific. Preserve its
  existing staged deletion and the user's `.gitignore` edit; neither is a request
  to restore settings or transfer Claude permissions to Codex.

This project has no separate memory index on the mini. Use the linked infrastructure
deployment document and its canonical memory index at
`~/Vibe Coding Infra/claude/memory/MEMORY.md` for relevant historical context.

## Xcode 27 / Device Hub

Xcode 27.2 uses DeviceHub.app (`com.apple.dt.Devices`) instead of Simulator.app.
Capture supports both, preferring an iOS-titled window. On stream startup, full
Device Hub windows switch once to compact mode via AXPress; capture and touch
mapping share the AX-measured top toolbar/group height. A failed switch/measurement
falls back to the whole window, where touch mapping may be inaccurate. No fixed
23-point inset or 1:1 device/window scale is assumed. Look for
`[Capture] Found Device Hub window:` plus `[Capture] AX content rect in window:`
and `[Capture] Cropping to content area:`. See README for the wide-compact fallback.
Do not exercise the mode switch during read-only validation.
