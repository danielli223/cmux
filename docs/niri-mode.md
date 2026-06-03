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
| ⌃⌥H / ⌃⌥L | Focus column left / right | `shortcut.niriFocusColumnLeft` / `Right` |
| ⌃⌥K / ⌃⌥J | Focus window up / down within column | `shortcut.niriFocusWindowUp` / `Down` |
| ⌃⌥⇧H / ⌃⌥⇧L | Move column left / right on the strip | `shortcut.niriMoveColumnLeft` / `Right` |

> Focus/move use **vim letters (H/J/K/L), not arrows.** `⌃⌥`+Arrow collides with window managers
> (Rectangle/Magnet default to exactly `⌃⌥`+Arrow), macOS Mission Control, and terminal
> word-movement, which register *global* hotkeys that steal the event before cmux's app-level
> shortcut monitor — making arrow-based focus unreliable. Letters avoid all of those.
| ⌃⌥V (hold) | Hold-to-preview overview (zoom out) | `shortcut.niriToggleOverview` |
| ⌘⇧↩ | Fullscreen the focused column (pane-zoom) | `shortcut.togglePaneZoom` |

The pane-zoom shortcut (`Toggle Pane Zoom`) is **shared with tiling mode**: while the strip is
active it expands the focused column to fill the viewport instead of zooming a Bonsplit pane (the
tree is dormant in strip mode). It is a pure render state — no column changes width — and any
focus/structural change or opening the overview clears it.

These do not collide with the reserved bindings (⌘D, ⌘⇧D, ⌃Tab, ⌘⇧[ / ⌘⇧], ⌥⌘+arrows).

## Scrolling & column snapping

The scroll offset is **column-snapped**: it is always exactly some column's left edge, so the
leftmost visible column always starts at the content-area origin (the sidebar's right edge).
This matters because cmux's terminal portal resizes a partially-clipped surface — a half-off
column would otherwise reflow to 1–2 characters wide, crushed against the sidebar. Two reveal
policies share the model:

- **Focus navigation** (`focus-column left/right`) pins the focused column to the **leading**
  edge, so every key press pans the viewport by exactly one column (no "dead" presses while the
  target is still visible).
- **Structural changes** (open / close / restore) reveal the focused column at the **trailing**
  edge, snapped to a boundary — the new column appears with its left-neighbours for context and
  minimal trailing blank.

## Overview (zoom-out)

`⌃⌥V` toggles a niri-style **overview**: the whole strip is scaled down (`overviewScale` =
content width ÷ total strip width, capped at 1) so every column is visible at once as a tile,
laid out at its real relative position. The sidebar is untouched — the overview only fills the
content area to its right (frames live in content-area coordinates, same origin as normal mode).

**Hold-to-preview (⌘-Tab style):** `⌃⌥V` is *held*, not tapped. The keyDown opens the overview;
while held, `⌃⌥←/→` (or plain arrow keys) move the highlight; **releasing** the key — or
releasing Control/Option — commits: it focuses the highlighted column, closes the overview, pans
the viewport to bring it on-screen, and routes keyboard input to that terminal (a keystroke right
after release lands in it). `Return` commits early; `Escape` (or clicking the dimmed backdrop)
cancels and restores the exact prior viewport (focused column + scroll offset). A transient
`NSEvent` monitor (installed on hold-start, removed on commit/cancel) drives the release
detection. The scale transition is animated (spring); its smoothness is a manual-review item.

**Tiles — live color feed:** each tile shows the column's real terminal content, in color, for
every window (a tabbed column stacks its windows top-to-bottom as mini-screens, the active one
outlined). The presentation per window is picked by the pure `overviewTileMode(for:)`
(`CmuxStripLayout`):

- **Live** — for columns that were **on-screen (rendering)** when the overview opened. The tile is
  an `OverviewMirrorView` whose layer `contents` points at the source `GhosttyMetalLayer`'s
  presented `IOSurface` (`contentsGravity = .resizeAspectFill`), so the live frame scales down for
  free. The source is **never resized**, so it never reflows — the constraint that ruled out a
  naive scaled portal (the sliver-bug mechanism). To keep these columns rendering without bleeding
  over the overview, `StripCanvasView` parks them **full-size off-screen** while the overview is
  open (their `isVisibleInUI` stays true; the portal geometry re-sync runs during the overview so
  the portals follow the parked frames). Refreshes are driven by the refcounted
  `.ghosttyDidRenderFrame` notification and coalesced to ~12fps by the pure `FrameRefreshThrottle`.
- **Frozen** — for **off-screen** columns (already occluded, not producing frames before the
  overview). A one-time color `CGImage` is captured from the surface's current `IOSurface` at
  overview-open (`stripCaptureThumbnailImage`) and shown statically. We do **not** force off-screen
  columns to keep rendering — that bounds GPU cost and avoids the hard "render while hidden"
  question.
- **Text** — deepest fallback: the original scaled monospace `ghostty_surface_read_text` snapshot,
  used when a window has neither a live source nor a captured color frame.

Suppression mechanism: live columns are **parked off-screen** (not hidden in place). This was
chosen over hiding the host so it cannot reintroduce the portal "bleed" over the overview backdrop,
and because a full-size off-screen frame keeps the surface rendering without a reflow.

## Control socket (v1)

Raw v1 line commands on the cmux control socket (used by automation and the
`NiriStripModeUITests` UI test; not exposed as typed `cmux` CLI subcommands). They act on the
selected workspace.

| Command | Effect |
| --- | --- |
| `niri_mode <on\|off\|toggle>` | Enable/disable the strip; returns `OK <mode>` |
| `niri_status` | JSON: `mode`, `viewportWidth`, `scrollOffset`, `totalContentWidth`, `focusedColumnIndex`, `columnFullscreen`, and per-column `id`/`width`/`x`/`focused`/`windowPanelIds` |
| `niri_open` | Open a terminal in a new column after the focused one; returns `OK <panelId>` |
| `niri_open_stacked` | Open a terminal stacked below the focused window |
| `niri_focus <left\|right\|up\|down>` | Focus a column (left/right) or window in the column (up/down) |
| `niri_move <left\|right>` | Reorder the focused column |
| `niri_close` | Close the focused column's focused window |
| `niri_fullscreen <on\|off\|toggle>` | Fullscreen the focused column (pane-zoom); returns `OK <fullscreen\|strip>` |
| `niri_overview <on\|off\|toggle>` | Open/close the zoom-out overview |
| `niri_overview_move <left\|right>` | Move the overview highlight |
| `niri_overview_select` | Select the highlighted column and close the overview |

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
