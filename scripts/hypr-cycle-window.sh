#!/bin/bash
# Alt+Tab replacement for Hyprland/Omarchy: cycles windows across ALL
# workspaces (stock Alt+Tab only cycles within the current one), follows to
# whichever workspace the target window lives on, and drives a macOS-style
# HUD overlay (see ../plugins/window-switcher) that shows the app list and
# highlights the current selection while Alt is held.
#
# Usage: hypr-cycle-window.sh [next|prev]
#
# The window order is snapshotted once per "session" (the stretch between
# the first Tab press and Alt being released — see hypr-cycle-window-end.sh)
# so repeated Tab presses walk a stable list instead of re-sorting by
# most-recently-used on every press, which would just bounce between the
# two most recent windows.
set -euo pipefail

direction="${1:-next}"
state_dir="$HOME/.local/state/omarchy/window-switcher"
session_file="$state_dir/session.json"
hud_file="$state_dir/state.json"
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
current_address="$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')"

session_valid=false
if [[ -f "$session_file" ]]; then
  addresses_json="$(jq -c '.addresses' "$session_file" 2>/dev/null || echo '[]')"
  index="$(jq -r '.index' "$session_file" 2>/dev/null || echo 0)"
  # A leftover session file (crash, missed release event, or — since this is
  # a plain file in ~/.local/state — simply surviving a reboot) can reference
  # windows that no longer exist. Trust it only if every address it lists is
  # still an actual open window right now; otherwise treat it as absent and
  # take a fresh snapshot.
  if [[ -n "$addresses_json" && "$addresses_json" != "null" ]]; then
    stale_count="$(echo "$clients_json" | jq --argjson addrs "$addresses_json" '
      [$addrs[] as $a | select(([.[]|.address] | index($a)) == null)] | length
    ' 2>/dev/null || echo 1)"
    [[ "$stale_count" == "0" ]] && session_valid=true
  fi
fi

if [[ "$session_valid" != "true" ]]; then
  addresses_json="$(echo "$clients_json" | jq -c 'sort_by(.focusHistoryID) | [.[].address]')"
  index=0
fi

mapfile -t addresses < <(echo "$addresses_json" | jq -r '.[]')
count=${#addresses[@]}
if (( count < 2 )); then
  exit 0
fi

if [[ "$direction" == "prev" ]]; then
  index=$(( (index - 1 + count) % count ))
else
  index=$(( (index + 1) % count ))
fi

target_address="${addresses[$index]}"
target_workspace="$(echo "$clients_json" | jq -r --arg addr "$target_address" '.[] | select(.address == $addr) | .workspace.id')"
current_workspace="$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id')"

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

echo "{\"addresses\": $addresses_json, \"index\": $index}" > "$session_file"

# Resolve an icon per app (bash loop — simplest way to reuse resolve_icon()).
apps_with_icons="[]"
while IFS= read -r addr; do
  class="$(echo "$clients_json" | jq -r --arg addr "$addr" '.[] | select(.address == $addr) | .class')"
  title="$(echo "$clients_json" | jq -r --arg addr "$addr" '.[] | select(.address == $addr) | .title')"
  icon="$(resolve_icon "$class")"
  apps_with_icons="$(echo "$apps_with_icons" | jq -c --arg class "$class" --arg title "$title" --arg icon "$icon" --arg addr "$addr" '. + [{class: $class, title: $title, icon: $icon, address: $addr}]')"
done < <(echo "$addresses_json" | jq -r '.[]')

echo "{\"visible\": true, \"selected\": $index, \"apps\": $apps_with_icons}" > "$hud_file"
