#!/bin/bash
# Manual "reset now" utility — not bound to anything by default. Session
# expiry is purely time-based (see hypr-cycle-window.sh), so this isn't
# needed for normal use, but running it once at login clears any state left
# over from a crash/reboot immediately instead of waiting out the timeout.
# Clears the snapshotted window order (so the next Tab press takes a fresh
# one) and tells the HUD overlay to hide right away.
set -euo pipefail

state_dir="$HOME/.local/state/omarchy/window-switcher"
rm -f "$state_dir/session.json"

if [[ -f "$state_dir/state.json" ]]; then
  jq '.visible = false' "$state_dir/state.json" > "$state_dir/state.json.tmp" 2>/dev/null \
    && mv "$state_dir/state.json.tmp" "$state_dir/state.json" \
    || echo '{"visible": false, "apps": [], "selected": 0}' > "$state_dir/state.json"
fi
