#!/bin/bash
# Alt+Tab replacement for Hyprland/Omarchy: cycles windows across ALL
# workspaces (stock Alt+Tab only cycles within the current one), follows to
# whichever workspace the target window lives on, and drives a macOS-style
# HUD overlay (see ../WindowSwitcher.qml) that shows the app list and
# highlights the current selection while Alt is held.
#
# Usage: hypr-cycle-window.sh [next|prev]
#
# There is no reliable way to detect Alt being released on this Hyprland
# build: binding `{ release = true }` on a bare modifier key (Alt_L/Alt_R)
# registers without error but never actually fires on physical hardware —
# confirmed by live-testing with logging on both the bind and Hyprland's own
# IPC event socket; zero release events across multiple bare Alt taps and
# multiple full Alt+Tab cycles. (The one working `release = true` example
# elsewhere in Omarchy's own config binds a regular key, F9 — modifiers
# apparently take a different internal path that never reaches bind-matching
# for their own release.)
#
# So sessions are purely time-based instead: a session (the frozen window
# order + cached icons from SESSION_TIMEOUT_S ago) is considered "ended" if
# this script hasn't been called in that long, matching the HUD's own
# watchdog timer (see WindowSwitcher.qml) so both independently agree on
# when a hold has ended. This also fixes a real behavioral bug that existed
# under the old release-based design: since release never fired, the window
# order snapshot never actually refreshed between separate uses either — it
# silently kept reusing the very first snapshot for as long as those windows
# stayed open.
set -euo pipefail

direction="${1:-next}"
state_dir="$HOME/.local/state/omarchy/window-switcher"
session_file="$state_dir/session.json"
hud_file="$state_dir/state.json"
session_timeout_s=3
mkdir -p "$state_dir"

resolve_icon() {
  local class="$1"
  local desktop_file
  desktop_file=$(grep -ril "StartupWMClass=${class}$" /usr/share/applications "$HOME/.local/share/applications" 2>/dev/null | head -1)
  if [[ -z "$desktop_file" ]]; then
    desktop_file=$(find /usr/share/applications "$HOME/.local/share/applications" -iname "${class}.desktop" 2>/dev/null | head -1)
  fi
  if [[ -n "$desktop_file" ]]; then
    grep -m1 "^Icon=" "$desktop_file" | cut -d= -f2-
  else
    echo "$class"
  fi
}

clients_json="$(hyprctl clients -j)"

session_valid=false
if [[ -f "$session_file" ]]; then
  session_age=$(( $(date +%s) - $(stat -c %Y "$session_file" 2>/dev/null || echo 0) ))
  if (( session_age < session_timeout_s )); then
    apps_json="$(jq -c '.apps' "$session_file" 2>/dev/null || echo '[]')"
    index="$(jq -r '.index' "$session_file" 2>/dev/null || echo 0)"
    if [[ -n "$apps_json" && "$apps_json" != "null" ]]; then
      # Even within the timeout window, a leftover session can reference
      # windows that no longer exist (one just got closed). Trust it only
      # if every address it lists is still an actual open window right now.
      stale_count="$(echo "$clients_json" | jq --argjson apps "$apps_json" '
        [$apps[] as $a | select(([.[]|.address] | index($a.address)) == null)] | length
      ' 2>/dev/null || echo 1)"
      [[ "$stale_count" == "0" ]] && session_valid=true
    fi
  fi
fi

if [[ "$session_valid" != "true" ]]; then
  # New session: snapshot the window order (Hyprland's own focusHistoryID,
  # 0 = current focus) and resolve each app's icon/title once, up front.
  mapfile -t new_addresses < <(echo "$clients_json" | jq -r 'sort_by(.focusHistoryID) | .[].address')
  apps_json="[]"
  for addr in "${new_addresses[@]}"; do
    class="$(echo "$clients_json" | jq -r --arg addr "$addr" '.[] | select(.address == $addr) | .class')"
    title="$(echo "$clients_json" | jq -r --arg addr "$addr" '.[] | select(.address == $addr) | .title')"
    icon="$(resolve_icon "$class")"
    apps_json="$(echo "$apps_json" | jq -c --arg class "$class" --arg title "$title" --arg icon "$icon" --arg addr "$addr" '. + [{class: $class, title: $title, icon: $icon, address: $addr}]')"
  done
  index=0
fi

count="$(echo "$apps_json" | jq 'length')"
if (( count < 2 )); then
  exit 0
fi

if [[ "$direction" == "prev" ]]; then
  index=$(( (index - 1 + count) % count ))
else
  index=$(( (index + 1) % count ))
fi

target_address="$(echo "$apps_json" | jq -r ".[$index].address")"
target_workspace="$(echo "$clients_json" | jq -r --arg addr "$target_address" '.[] | select(.address == $addr) | .workspace.id')"
current_workspace="$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id')"

# Persist + tell the HUD immediately — before touching focus at all. All the
# heavy lifting (icons, class/title) is already cached in $apps_json from
# session setup, so this is just two fast file writes, and the HUD updates
# in parallel with the switch below rather than only after it finishes.
# The session file's mtime (just now) is what session_valid above measures
# next time this script runs — that's the whole "session" mechanism.
echo "{\"apps\": $apps_json, \"index\": $index}" > "$session_file"
echo "{\"visible\": true, \"selected\": $index, \"apps\": $apps_json}" > "$hud_file"

if [[ "$target_workspace" != "$current_workspace" ]]; then
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$target_workspace\" })" >/dev/null
  sleep 0.08
fi

# No dispatcher on this Hyprland fork focuses an arbitrary window by address
# or class directly (every hl.dsp.* dispatcher acts on the current focus, or
# targets by direction/workspace/monitor only). Once on the right workspace,
# nudge focus in-workspace until it lands on the exact target; bounded so a
# workspace full of windows can't spin forever.
for _ in $(seq 1 8); do
  now="$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')"
  [[ "$now" == "$target_address" ]] && break
  hyprctl dispatch 'hl.dsp.window.cycle_next()' >/dev/null
  sleep 0.03
done
hyprctl dispatch 'hl.dsp.window.bring_to_top()' >/dev/null 2>&1 || true
