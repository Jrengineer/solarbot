#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export PYTHONUNBUFFERED=1
export PYTHONPATH="$WS_ROOT/src:${PYTHONPATH:-}"

pids=()

start_node() {
  local module_path="$1"
  /usr/bin/python3 "$module_path" &
  pids+=("$!")
}

start_node "$WS_ROOT/src/battery_streamer/battery_streamer/battery_udp_node.py"
start_node "$WS_ROOT/src/commcheck/commcheck/commcheck.py"
start_node "$WS_ROOT/src/oak_streamer/oak_streamer/oak_streamer_node.py"
start_node "$WS_ROOT/src/plc_comm/plc_comm/udp_listener_node.py"

trap 'echo "Stopping nodes..."; kill ${pids[*]} 2>/dev/null' SIGINT SIGTERM

wait
