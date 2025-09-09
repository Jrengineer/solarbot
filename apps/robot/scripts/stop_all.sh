#!/usr/bin/env bash
set -euo pipefail

pkill -f battery_udp_node.py || true
pkill -f commcheck.py || true
pkill -f oak_streamer_node.py || true
pkill -f udp_listener_node.py || true
