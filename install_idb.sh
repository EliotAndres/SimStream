#!/bin/bash
set -e

cd "$(dirname "$0")"

# ─── idb_companion via Homebrew ──────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  echo "Error: Homebrew is not installed. Install it from https://brew.sh"
  exit 1
fi

if brew list --formula idb-companion &>/dev/null; then
  echo "[install] idb-companion already installed."
else
  echo "[install] Installing idb-companion via Homebrew..."
  brew install facebook/fb/idb-companion
fi

# ─── Python environment for touch bridge ─────────────────────────────────────
echo "[install] Setting up Python environment for touch bridge..."

if command -v uv &>/dev/null; then
  echo "[install] Using uv."
  uv venv .venv --python 3.12
  uv pip install --python .venv/bin/python grpclib fb-idb
elif command -v python3 &>/dev/null; then
  echo "[install] uv not found, falling back to python3 + pip."
  python3 -m venv .venv
  .venv/bin/python -m pip install --upgrade pip
  .venv/bin/python -m pip install grpclib fb-idb
else
  echo "Error: neither uv nor python3 is available."
  echo "  Install uv:     curl -LsSf https://astral.sh/uv/install.sh | sh"
  echo "  Or install python3 (e.g. brew install python@3.12)"
  exit 1
fi

echo ""
echo "Done. Run './start.sh' to start streaming."
