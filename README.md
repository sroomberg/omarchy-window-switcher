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
o.bind("Alt_L", "End window-switcher session", "hypr-cycle-window-end", { release = true })
o.bind("Alt_R", "End window-switcher session (right alt)", "hypr-cycle-window-end", { release = true })
```

`repeating = true` matters: without it, holding Tab down (rather than
tapping repeatedly) never re-fires the binding, `state.json` goes stale, and
the HUD's watchdog (see below) will hide it mid-hold. Lua's `repeat` is a
reserved keyword (the `repeat...until` loop), so the option the `o.bind`
wrapper exposes is `repeating`, not `repeat` — `{ repeat = true }` is a
syntax error.

**4. Reset stale state at login** — add to `~/.config/hypr/autostart.lua`:

```lua
o.launch_on_start("hypr-cycle-window-end")
```

See "Known limitations" below for why.

## How it works

- `hypr-cycle-window.sh [next|prev]` does the actual cycling: snapshots the
  window order once per Alt-held "session" (using Hyprland's own
  `focusHistoryID`, so it starts from a real most-recently-used order), then
  walks that stable list on each Tab press instead of re-sorting every time
  (which would just bounce between the two most recent windows). It writes
  the whole HUD state to `~/.local/state/omarchy/window-switcher/state.json`
  on every press.
- `WindowSwitcher.qml` is a passive Quickshell overlay (`kinds: ["overlay"]`)
  that watches that file via `FileView` and renders it — no keyboard focus,
  no click handling. All the actual switching logic lives in the bash
  script.
- `hypr-cycle-window-end.sh`, bound to the bare *release* of `Alt_L`/`Alt_R`,
  clears the session and tells the HUD to hide. Hyprland's Lua binding API
  supports binding a modifier key's release on its own, which is what makes
  a real hold-Alt-tap-Tab-release-to-commit interaction possible at all.

## Known limitations

- Window order is snapshotted fresh at the start of each Alt-held session.
  This matches real Alt+Tab UX, but the order can differ slightly from a
  naive most-recently-used sort if you cycle back and forth a lot within one
  hold.
- Icon resolution (`resolve_icon()` in the script) looks up each window's
  `.desktop` file by `StartupWMClass` or filename match; apps without a
  matching desktop entry fall back to the raw window class as the icon
  name, which the HUD further falls back from (via `Quickshell.iconPath`) to
  a generic executable icon if that name isn't in the icon theme either.
- **The Alt-release keybind can be missed.** A Hyprland config reload
  (`hyprctl reload`) while Alt is physically held resets the compositor's
  internal press-tracking, so the release event that should fire the unbind
  script sometimes never arrives — which would otherwise leave the HUD stuck
  on screen indefinitely (observed firsthand while developing this). The
  state file also survives a full reboot on its own (it's a plain file
  under `~/.local/state`), so a stale session can resurface after a restart
  too. Three defenses against this, all in the install steps above:
  - The script validates every address in a leftover session file against
    the *current* window list before trusting it; any mismatch (e.g. from
    before a reboot) discards it and takes a fresh snapshot instead of
    rendering broken/blank icons.
  - The plugin runs a 2.5s watchdog timer (reset on every Tab press) that
    force-hides the HUD if the state file goes stale for any reason — a
    backstop independent of whether the release keybind ever fires.
  - Running `hypr-cycle-window-end` once at login (step 4 above) means a
    stuck-visible state file left over from a crash or reboot can't
    resurrect the HUD on the next session either.

## License

MIT
