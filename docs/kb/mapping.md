# niri → cmux concept mapping

Synthesis of [`niri.md`](./niri.md), [`cmux.md`](./cmux.md), and [`layout-engine.md`](./layout-engine.md).
The table maps each niri concept to its cmux counterpart and flags the behavioral gap that
"niri-mode" must close. The defining gap, restated once: **cmux's Bonsplit tiling subdivides a
fixed container (opening a pane shrinks its sibling); niri keeps every column's intrinsic width and
makes the strip wider than the viewport, panning the viewport instead of resizing.**

## Concept table

| niri concept | cmux counterpart today | Behavioral gap / decision for niri-mode |
| --- | --- | --- |
| **Monitor workspace** (one infinite horizontal strip per workspace) | `Workspace` (a sidebar project entry), owns one `BonsplitController` (`Sources/Workspace.swift`) | niri-mode adds a per-`Workspace` `StripLayout` used *instead of* the Bonsplit tree when the mode is on. The sidebar still switches workspaces — unchanged. |
| **Column** (intrinsic width, never resized on open) | A vertical slice of the Bonsplit tree (`.split(.horizontal)` branch) | **Core gap.** Bonsplit width = `parent.width * dividerPosition` — fractions of a fixed whole, so a new column shrinks siblings. niri-mode introduces `StripColumn { id, width: CGFloat }` with an *absolute* intrinsic width that does not change when columns are added/removed/focused. |
| **Window inside a column** (vertical stack) | A `PaneState`/`Tab` → `Panel` (terminal) inside a pane | Reuse: a column owns an ordered vertical stack of terminals. v1 models this as `StripColumn.windows: [WindowID]` with per-window heights summing to the viewport height (vertical axis is bounded, like niri). |
| **The strip is wider than the screen** | No equivalent — Bonsplit always fills exactly the container rect | niri-mode: `totalWidth = Σ column widths + gaps`, may exceed viewport. A `scrollOffset` defines the visible window. This is the whole point. |
| **Viewport / scroll offset** | None | New `StripLayout.scrollOffset: CGFloat`. Pure function `columnFrames(in:)` lays columns left-to-right at `x = runningX − scrollOffset`. |
| `focus-column-left` / `focus-column-right` | `focusLeft`/`focusRight` (⌥⌘←/→) → `navigateFocus` over Bonsplit bounds | niri-mode: move focus to prev/next column **and** pan `scrollOffset` just enough to bring it to the nearest screen edge (niri `center-focused-column "never"` default). No resize. |
| `focus-window-up` / `focus-window-down` | `focusUp`/`focusDown` (⌥⌘↑/↓) | niri-mode: move focus within the focused column's vertical window stack; never crosses to another column. |
| `move-column-left` / `move-column-right` | No direct analog (drag tabs only) | niri-mode: reorder the focused column in the strip array; widths unchanged; viewport follows the moved column. |
| `move-window-up` / `move-window-down` | tab reorder within a pane | niri-mode: reorder within the column's window stack. (v1: optional; focus up/down is the priority.) |
| **Open new window → new column appended after focused, pan to it** | ⌘D split right → `splitPane` halves the focused pane | **Core gap.** niri-mode: `insertColumn(after: focused)` appends a `StripColumn` at its intrinsic width; siblings keep widths; `scrollOffset` animates to reveal it. |
| **Open stacked window** (add below in column) | ⌘⇧D split down → `splitPane(.vertical)` | niri-mode: append a window to the focused column's stack; other columns untouched. |
| **Close column → gap collapses by moving neighbors** | close pane → sibling reclaims space (resize) | niri-mode: `removeColumn` drops it from the array; neighbors' x-positions recompute (they *move*, not resize); `scrollOffset` clamps. |
| **Tabbed column display mode** | Bonsplit pane with multiple tabs | Out of scope for v1 (documented as future). |
| **Vertical dynamic workspaces** (up/down workspace axis) | cmux workspaces are the sidebar list (`⌃[`/`⌃]`, `⌘1…9`) | Keep cmux's sidebar as the workspace switcher — do **not** move it into the strip. The task forbids hijacking workspace switching into the horizontal scroll. |
| **Scroll-tick bindings** (wheel → discrete focus change) | trackpad scroll handled per-view | niri-mode: discrete wheel ticks = focus-column left/right (snap). Continuous two-finger pan = pixel-pan `scrollOffset` with snap-to-column on release. |
| **`center-focused-column`** option | None | niri-mode v1 default = scroll-to-edge (niri `"never"`). Centering is a documented later config option. |
| **IPC socket** (`NIRI_SOCKET`, `niri msg action …`) | cmux Unix socket v1/v2 (`Sources/TerminalController.swift`) | Decision (open question c): expose niri-mode over the existing socket for test/automation — a `niri_layout` query (debug) + reuse existing split/focus commands routed through the strip when the mode is on. |

## Decisions on the open questions

- **(a) New strategy vs extend engine:** a *parallel* pure-model `StripLayout` strategy alongside
  Bonsplit. Bonsplit's geometry is irreducibly ratio-based; teaching it intrinsic widths + a scroll
  offset would touch the whole vendored submodule and its tests. The strip owns the horizontal axis;
  the vertical-within-column axis reuses ordinary terminal panels. See `layout-engine.md` §"Recommended seam".
- **(b) Off-screen column lifecycle:** keep all columns *live* in v1 (terminals keep running) — that
  is niri's behavior and what users expect (a build running off-screen must not pause). Documented
  cost: N live GPU-backed terminals. Mitigation knob left for later: throttle/suspend rendering of
  columns fully outside the viewport (the model already knows each column's visible range, so a
  later change can gate `forceRefresh`/draw on `isVisible` without touching the model). v1 keeps it
  simple and correct: live.
- **(c) Socket exposure:** yes — expose a read-only `niri_layout` debug query (column ids, intrinsic
  widths, x-positions, scrollOffset, focused index) so automation/UITests can assert invariants, and
  route the existing focus/split/close commands through the strip when the mode is on. Mutation stays
  on the one shared action path (CLAUDE.md shared-behavior policy).
- **(d) Continuous vs ticked scrolling:** both, matching niri — continuous pixel-pan for two-finger
  trackpad drag (snap-to-column on release), discrete ticks for wheel/keyboard focus changes.

## Where it plugs in (one-line pointers)

- Model: new leaf package `Packages/CmuxStripLayout` — pure value types + mutations, fully unit-tested.
- Mode flag + ownership: per-`Workspace` (`Sources/Workspace.swift`).
- Mutation routing: branch in `Workspace.newTerminalSplit` / close / focus to the strip when on.
- Rendering: a `StripView` chosen at the `BonsplitView` mount point in `Sources/WorkspaceContentView.swift`.
- Keybinds: new `Action` cases in `Sources/KeyboardShortcutSettings.swift` (avoid the reserved set).
- Socket: `niri_layout` query + mode toggle in `Sources/TerminalController.swift`.
