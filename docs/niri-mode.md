# niri-mode: scrollable strip layout

niri-mode is a per-workspace alternative to cmux's Bonsplit tiling, modeled on the
[niri](https://github.com/YaLTeR/niri) scrollable-tiling Wayland compositor. Instead of
subdividing the viewport when you open a terminal (which shrinks the existing one), niri-mode
arranges terminals as an **infinite horizontal strip of fixed-width columns** and pans the
viewport. Opening a terminal appends a column and scrolls to it; existing terminals never
resize.

It coexists with tiling: each workspace is independently in `tiling` (default) or `strip`
mode, and switching back to tiling leaves the Bonsplit tree untouched.

See `docs/kb/niri.md`, `docs/kb/cmux.md`, `docs/kb/layout-engine.md`, and `docs/kb/mapping.md`
for the research and the niri→cmux concept mapping behind this.

## Model

- A **strip** is an ordered left-to-right sequence of columns in one workspace; its total
  width may exceed the screen.
- A **column** has an intrinsic width that does not change when columns are added/removed/
  focused, and holds a vertical stack of one or more terminal **windows**.
- The **viewport** is a horizontal window onto the strip defined by a scroll offset.

The geometry and all mutations live in the pure, fully unit-tested `CmuxStripLayout` package
(`Packages/CmuxStripLayout`). The app layer (`WorkspaceStripController`, `StripWorkspaceView`)
renders from that model and contains no layout math.

## Keyboard shortcuts

niri-mode uses the otherwise-unused **Control+Option** layer (all editable in
Settings → Keyboard Shortcuts and overridable in `~/.config/cmux/cmux.json`). The toggle works
in any mode; the rest act only while the strip is active.

| Shortcut | Action | Config key |
| --- | --- | --- |
| ⌃⌥S | Toggle scrollable strip layout | `shortcut.niriToggleMode` |
| ⌃⌥N | New column (open terminal, append + pan) | `shortcut.niriNewColumn` |
| ⌃⌥⇧N | New stacked window (add below in column) | `shortcut.niriNewStackedWindow` |
| ⌃⌥W | Close column / focused stacked window | `shortcut.niriCloseColumn` |
| ⌃⌥← / ⌃⌥→ | Focus column left / right (pans to edge) | `shortcut.niriFocusColumnLeft` / `Right` |
| ⌃⌥↑ / ⌃⌥↓ | Focus window up / down within column | `shortcut.niriFocusWindowUp` / `Down` |
| ⌃⌥⇧← / ⌃⌥⇧→ | Move column left / right on the strip | `shortcut.niriMoveColumnLeft` / `Right` |

These do not collide with the reserved bindings (⌘D, ⌘⇧D, ⌃Tab, ⌘⇧[ / ⌘⇧], ⌥⌘+arrows).

## Trackpad

A horizontal two-finger scroll pans the strip continuously (pixel-for-pixel) and snaps to the
nearest column edge on release. Vertical scroll falls through to the focused terminal.

## Control socket (v1)

Raw v1 line commands on the cmux control socket (used by automation and the
`NiriStripModeUITests` UI test; not exposed as typed `cmux` CLI subcommands). They act on the
selected workspace.

| Command | Effect |
| --- | --- |
| `niri_mode <on\|off\|toggle>` | Enable/disable the strip; returns `OK <mode>` |
| `niri_status` | JSON: `mode`, `viewportWidth`, `scrollOffset`, `totalContentWidth`, `focusedColumnIndex`, and per-column `id`/`width`/`x`/`focused`/`windowPanelIds` |
| `niri_open` | Open a terminal in a new column after the focused one; returns `OK <panelId>` |
| `niri_open_stacked` | Open a terminal stacked below the focused window |
| `niri_focus <left\|right\|up\|down>` | Focus a column (left/right) or window in the column (up/down) |
| `niri_move <left\|right>` | Reorder the focused column |
| `niri_close` | Close the focused column's focused window |

## Design decisions (open questions resolved)

- **(a) New strategy, not an engine change.** Bonsplit's geometry is ratio-based (a new pane
  takes a fraction of its sibling). A fixed-width strip is inexpressible there, so the strip is
  a parallel pure-model layout. The vertical-within-column axis reuses ordinary terminal panels.
- **(b) Off-screen columns stay live.** Terminal processes keep running off-screen (niri
  behavior — a build off-screen must not pause). To bound GPU/CPU cost, `StripWorkspaceView`
  gates a column's **portal rendering** on visibility (`isVisibleInUI`) while keeping the
  process alive. The model exposes each column's visible range, so a future change can throttle
  further without touching the model.
- **(c) Socket-exposed.** A read-only `niri_status` query plus the structural commands above let
  automation/tests assert the invariants. All mutation flows through the one shared
  `WorkspaceStripController` path (keybind, socket, future menu) per the shared-behavior policy.
- **(d) Both scroll modes.** Continuous pixel-pan for trackpad (snap-to-column on release) and
  discrete focus changes for keyboard — matching niri.

## Session restore

When a workspace is in strip mode, the session snapshot records `layoutMode: "strip"`, the
per-column window panel ids, and the focused column. On restore, panel ids are remapped to the
freshly-created panels and the strip is rebuilt; tiling sessions are unaffected.

## Tests

- `Packages/CmuxStripLayout/Tests` — 31 pure-model invariant tests (`swift test`).
- `cmuxTests/WorkspaceStripControllerTests.swift` — controller routing via a fake bridge.
- `cmuxUITests/NiriStripModeUITests.swift` — drives the running app over the socket and asserts
  no-shrink / pan / reorder against `niri_status`.

## Not in scope (v1)

Tabbed column display mode, browser/editor columns, centering-focused-column config, and any
"future vision" beyond terminals. Smoothness/momentum/edge-feel is left to manual review.
