#!/bin/bash
# Bound to Alt's own key-release. Ends the current Alt+Tab session: clears
# the snapshotted window order (so the next Tab press takes a fresh one) and
# tells the HUD overlay to hide.
set -euo pipefail

state_dir="$HOME/.local/state/omarchy/window-switcher"
rm -f "$state_dir/session.json"

if [[ -f "$state_dir/state.json" ]]; then
  jq '.visible = false' "$state_dir/state.json" > "$state_dir/state.json.tmp" 2>/dev/null \
    && mv "$state_dir/state.json.tmp" "$state_dir/state.json" \
    || echo '{"visible": false, "apps": [], "selected": 0}' > "$state_dir/state.json"
fi
