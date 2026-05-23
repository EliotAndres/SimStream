#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

tunnel=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tunnel|-t) tunnel=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--tunnel]

Starts the Swift streamer (which also serves the browser page and
WebSocket on port 3738). Ctrl-C stops it.

  --tunnel, -t   Also expose the running port via cloudflared.
EOF
      exit 0
      ;;
    *) echo "[start] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

# ─── Preflight: hard-fail on any missing dependency ──────────────────────────
errors=0
fail() { echo "[start] ERROR: $*" >&2; errors=$((errors + 1)); }

# Swift toolchain
if ! command -v swift >/dev/null 2>&1; then
  fail "'swift' not found. Install Xcode or run: xcode-select --install"
fi

# idb_companion (brew package; native binary, not the Python CLI)
if ! command -v idb_companion >/dev/null 2>&1; then
  fail "'idb_companion' not found. Run ./install_idb.sh (or: brew install facebook/fb/idb-companion)"
fi

# Python venv created by install_idb.sh
if [[ ! -x .venv/bin/python ]]; then
  fail "Python venv missing (.venv/bin/python). Run ./install_idb.sh."
fi

# fb-idb CLI inside the venv (used by Swift to query screen size + send touches)
if [[ ! -x .venv/bin/idb ]]; then
  fail "'.venv/bin/idb' missing (fb-idb Python pkg not installed). Run ./install_idb.sh."
fi

# Touch bridge script
if [[ ! -f idb_touch_events_bridge.py ]]; then
  fail "idb_touch_events_bridge.py not found in $(pwd). Re-clone the repo."
fi

# Tunnel-specific
if [[ $tunnel -eq 1 ]] && ! command -v cloudflared >/dev/null 2>&1; then
  fail "--tunnel requested but 'cloudflared' is not installed. Run: brew install cloudflared"
fi

if [[ $errors -gt 0 ]]; then
  echo "[start] $errors dependency check(s) failed. Aborting." >&2
  exit 1
fi

# ─── Soft warnings (don't abort) ─────────────────────────────────────────────
if ! xcrun simctl list devices booted 2>/dev/null | grep -q "(Booted)"; then
  echo "[start] WARNING: no booted iOS Simulator detected. Boot one in Xcode → Simulator before connecting a viewer."
fi

# ─── Port ────────────────────────────────────────────────────────────────────
PORT=3738
if lsof -i :$PORT -P -n >/dev/null 2>&1; then
  echo "[start] ERROR: port $PORT is busy. Free it first:" >&2
  lsof -i :$PORT -P -n >&2
  exit 1
fi

# ─── Run ─────────────────────────────────────────────────────────────────────
# Optional: SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER=1 — prefer software H.264 in VMs where HW VT fails.
# Inherited by `swift run` (see README).

pids=()
cleanup() {
  echo
  echo "[start] Stopping…"
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

echo "[start] Swift streamer on http://localhost:$PORT"
PORT=$PORT swift run SimulatorStream &
pids+=($!)

if [[ $tunnel -eq 1 ]]; then
  echo "[start] Cloudflare tunnel → http://localhost:$PORT"
  cloudflared tunnel --url "http://localhost:$PORT" &
  pids+=($!)
fi

echo "[start] Running (pids: ${pids[*]}). Ctrl-C to stop."
wait
