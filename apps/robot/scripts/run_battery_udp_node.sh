#!/usr/bin/env bash
set -euo pipefail

# Optional: activate a virtualenv if available
# source .venv/bin/activate || true

# Determine workspace root (one directory up from this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Environment
export PYTHONUNBUFFERED=1
export PYTHONPATH="$WS_ROOT/src:${PYTHONPATH:-}"

# Serial port check (optional)
if [[ ! -r /dev/ttyUSB0 ]]; then
  echo "⚠️  /dev/ttyUSB0 currently not accessible (missing or permission). Continuing..."
fi

# Run application
cd "$WS_ROOT"
exec /usr/bin/python3 "$WS_ROOT/src/battery_streamer/battery_streamer/battery_udp_node.py"

