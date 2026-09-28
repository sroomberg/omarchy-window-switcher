# omarchy-window-switcher

An Alt+Tab replacement for [Omarchy](https://omarchy.org/)/Hyprland that:

- cycles windows across **all** workspaces (stock Alt+Tab only cycles the
  current one), following focus to whichever workspace the target window
  lives on
- shows a macOS Cmd+Tab-style HUD in the center of the screen while Alt is
  held, highlighting the current selection

## Why this needs a workaround

Omarchy runs a patched/forked Hyprland with a Lua dispatch layer. Every
`hl.dsp.*` dispatcher acts on the *currently focused* window, or targets by
direction/workspace/monitor — there's no dispatcher to focus an arbitrary
window by address or class directly. (`nwg-dock-hyprland`'s click-to-focus
has the same problem, for the same reason — it assumes vanilla Hyprland's
classic `hyprctl dispatch focuswindow address:...` syntax, which this fork's
daemon rejects even over the raw IPC socket.)

So `hypr-cycle-window.sh`, once it's switched to the right workspace, nudges
focus in-workspace with `cycle_next()` (bounded to 8 attempts) until it lands
on the exact target window.

## Install

**1. The plugin (HUD overlay):**

```bash
omarchy plugin add https://github.com/sroomberg/omarchy-window-switcher.git --enable --yes
```

Omarchy clones this repo into `~/.config/omarchy/plugins/sroomberg.window-switcher/`
and enables it — the shell won't render anything from a disabled plugin, so
`--enable` (or `omarchy plugin enable sroomberg.window-switcher` afterward)
is required, not optional.

**2. The scripts** — `omarchy plugin add` only installs the plugin bundle
(`manifest.json` + `WindowSwitcher.qml`); it doesn't touch `~/.local/bin` or
your Hyprland config, so this part is manual. Step 1 already cloned this
whole repo (scripts included) into the plugin directory, so copy from there:

```bash
cp ~/.config/omarchy/plugins/sroomberg.window-switcher/scripts/hypr-cycle-window.sh ~/.local/bin/hypr-cycle-window
cp ~/.config/omarchy/plugins/sroomberg.window-switcher/scripts/hypr-cycle-window-end.sh ~/.local/bin/hypr-cycle-window-end
chmod +x ~/.local/bin/hypr-cycle-window ~/.local/bin/hypr-cycle-window-end
```

**3. Keybindings** — add to `~/.config/hypr/bindings.lua`:

```lua
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
o.bind("ALT + TAB", "Cycle window (all workspaces)", "hypr-cycle-window next", { repeating = true })
o.bind("ALT + SHIFT + TAB", "Cycle window backward (all workspaces)", "hypr-cycle-window prev", { repeating = true })
```

`repeating = true` matters: without it, holding Tab down (rather than
tapping repeatedly) never re-fires the binding, so the session goes idle and
the HUD hides itself mid-hold (see "How it works" — there's no Alt-release
binding at all here; timing is what governs everything). Lua's `repeat` is
a reserved keyword (the `repeat...until` loop), so the option the `o.bind`
wrapper exposes is `repeating`, not `repeat` — `{ repeat = true }` is a
syntax error.

**4. Clear stale state at login** (optional, but recommended) — add to
`~/.config/hypr/autostart.lua`:

```lua
o.launch_on_start("hypr-cycle-window-end")
```

Not required for correctness (session expiry already self-heals a stale
state file — see below), but avoids a brief up-to-3s flash of the HUD if it
was left visible from before a crash or reboot.

## How it works

- `hypr-cycle-window.sh [next|prev]` does the actual cycling: snapshots the
  window order once per session (using Hyprland's own `focusHistoryID`, so
  it starts from a real most-recently-used order, plus each window's
  resolved icon/title), then walks that stable list on each Tab press
  instead of re-sorting every time (which would just bounce between the two
  most recent windows). It writes the whole HUD state to
  `~/.local/state/omarchy/window-switcher/state.json` on every press.
- `WindowSwitcher.qml` is a passive Quickshell overlay (`kinds: ["overlay"]`)
  that watches that file via `FileView` and renders it — no keyboard focus,
  no click handling. All the actual switching logic lives in the bash
  script.
- **Sessions are purely time-based — there is no Alt-release detection at
  all.** A session is "over" once `hypr-cycle-window.sh` hasn't been called
  in `session_timeout_s` (3s); the next Tab press after that starts a fresh
  snapshot instead of continuing the old one. The plugin runs a matching
  3s watchdog timer (reset on every Tab press) that hides the HUD the same
  way. `hypr-cycle-window-end.sh` still exists as a manual "reset now"
  utility (used by the optional login cleanup above) but isn't relied on
  for anything during normal use.

## Why no Alt-release binding

An earlier version of this bound `hl.unbind`-style release detection on
`Alt_L`/`Alt_R` (`{ release = true }`), matching real Alt+Tab UX (commit on
release). **This does not work in practice.** Hyprland's Lua binding API
accepts and registers `{ release = true }` on a bare modifier key without
any error, but it never actually fires on physical hardware — confirmed by
live-testing with logging added to both the bound script and Hyprland's own
IPC event socket (`.socket2.sock`): zero release events across multiple bare
Alt taps and multiple full Alt+Tab cycles, tested with a real human at the
keyboard, not simulated input. The one working `release = true` example
elsewhere in Omarchy's own default config binds a regular key (`F9`), not a
modifier — modifiers apparently take a different internal path that never
reaches bind-matching for their own release. The IPC event socket only
exposes high-level semantic events (`workspace`, `fullscreen`, `submap`),
not raw key press/release, so there's no lower-level primitive to fall back
to either. If a future Hyprland/Omarchy release fixes this, re-adding a
release binding as a faster-than-3s commit path would be a reasonable
follow-up.

## Disabling just the HUD

The overlay and the cycling logic are fully independent — the plugin is
just a passive file-watcher, so disabling it doesn't touch the actual
Alt+Tab behavior:

```bash
omarchy plugin disable sroomberg.window-switcher   # HUD off, cycling still works
omarchy plugin enable sroomberg.window-switcher    # HUD back on
```

## Known limitations

- Window order (and icons) are snapshotted once per session and reused for
  3 seconds of continued use; a gap longer than that starts a fresh
  snapshot. This matches real Alt+Tab UX reasonably well, but the order can
  differ slightly from a naive most-recently-used sort if you cycle back and
  forth a lot within one session.
- Icon resolution (`resolve_icon()` in the script) looks up each window's
  `.desktop` file by `StartupWMClass` or filename match; apps without a
  matching desktop entry fall back to the raw window class as the icon
  name, which the HUD further falls back from (via `Quickshell.iconPath`) to
  a generic executable icon if that name isn't in the icon theme either.
- There's a small, inherent floor on how fast the HUD can respond to each
  press — the script makes several `hyprctl` calls per invocation (each a
  separate subprocess spawn + IPC round-trip), typically totaling somewhere
  in the low hundreds of milliseconds. The HUD state file is written first,
  before the actual focus/workspace switch runs, so the HUD shouldn't
  visibly lag behind the switch — but neither is instantaneous.

## License

MIT
