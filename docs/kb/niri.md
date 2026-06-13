# niri scrollable-tiling layout model

Reference material for implementing a "niri-style" scrollable layout mode in a macOS
terminal app. niri is a scrollable-tiling Wayland compositor. This doc captures its
layout model, navigation actions, default keybinds, gestures, scrolling behavior, and
IPC, with exact action/option names. See the [Sources](#sources) section for every URL
consulted.

## 1. Core model: columns on an infinite horizontal strip

The fundamental data structure is a per-workspace **infinite horizontal strip of
columns**, with the screen acting as a **viewport** that pans over the strip.

- "Windows are arranged in columns on an infinite strip going to the right." (README)
- Each column occupies a horizontal slot; the strip extends rightward without bound.
- The monitor/screen is a fixed-size **viewport** onto this strip. Navigating columns
  scrolls the viewport horizontally rather than rearranging windows.
- "Every monitor has its own separate window strip. Windows can never 'overflow' onto an
  adjacent monitor." Each monitor is an independent strip + viewport. (README / Overview)

Mental model for the terminal app: one workspace = an array of columns laid out on a
number line; the visible window is `[scrollX, scrollX + screenWidth]`; focus changes pan
`scrollX`.

## 2. No-resize-on-open invariant

This is niri's defining property and the most important invariant to replicate:

- "**Opening a new window never causes existing windows to resize.**" (README)
- A new window is appended as a **new column to the right** (or inserted next to the
  focused column). Existing columns keep their exact widths and positions.
- Because columns are not packed-to-fit, the **strip simply grows wider than the screen**.
  There is no "tile everything to fill the screen" reflow step. Width is a per-column
  property (`default-column-width`, preset widths), never a function of column count.
- Contrast with traditional dynamic tilers (i3/sway master-stack, bsp) where each new
  window shrinks its siblings. niri never does this.

## 3. Vertical stacking inside a column; tabbed columns / display modes

A column is itself a vertical stack of one or more windows:

- Windows within a column **stack vertically**, sharing the column's width. Adding a
  second window to a column splits the column's height between them (it does not affect
  other columns).
- Move windows in/out of columns with `consume-window-into-column` /
  `expel-window-from-column`, or the combined `consume-or-expel-window-left` /
  `consume-or-expel-window-right`.
- **Column display modes**: a column is either `normal` (windows stacked and all visible)
  or `tabbed` (windows overlaid as tabs, only the focused one shown, with a tab
  indicator). Toggle with the `toggle-column-tabbed-display` action; set explicitly with
  `SetColumnDisplay`. Config: `default-column-display "normal"` | `"tabbed"` sets the
  mode for new columns. (README: "Group windows into tabs".)

## 4. Vertical dynamic workspaces (the up/down axis)

Orthogonal to the horizontal column strip is a **vertical axis of workspaces**:

- "Workspaces are dynamic and arranged vertically. Every monitor has an independent set of
  workspaces, and there's always one empty workspace present all the way down." (README)
- Workspaces are not fixed/numbered slots; they are created/destroyed dynamically. There
  is always a trailing empty workspace at the bottom. Config
  `empty-workspace-above-first` additionally keeps an empty workspace at the top.
- So the full 2D model: **horizontal = columns within a workspace; vertical = workspaces
  within a monitor.** Plus an **Overview** that zooms out to show all workspaces/windows.

## 5. Focus / move action names and default keybinds

Default modifier is `Mod` (Super/logo key). From `resources/default-config.kdl`:

### Focus (pans the viewport, does not move windows)

| Action | Default binds |
| --- | --- |
| `focus-column-left` | `Mod+Left`, `Mod+H` |
| `focus-column-right` | `Mod+Right`, `Mod+L` |
| `focus-window-down` | `Mod+Down`, `Mod+J` |
| `focus-window-up` | `Mod+Up`, `Mod+K` |
| `focus-column-first` | `Mod+Home` |
| `focus-column-last` | `Mod+End` |
| `focus-workspace-down` | `Mod+Page_Down`, `Mod+U` |
| `focus-workspace-up` | `Mod+Page_Up`, `Mod+I` |

### Move (relocates the focused window/column/workspace)

| Action | Default binds |
| --- | --- |
| `move-column-left` | `Mod+Ctrl+Left` |
| `move-column-right` | `Mod+Ctrl+Right` |
| `move-window-down` | `Mod+Ctrl+Down` |
| `move-window-up` | `Mod+Ctrl+Up` |
| `move-column-to-workspace-down` | `Mod+Ctrl+Page_Down` |
| `move-column-to-workspace-up` | `Mod+Ctrl+Page_Up` |
| `move-workspace-down` | `Mod+Shift+Page_Down` |
| `move-workspace-up` | `Mod+Shift+Page_Up` |

### Column / window structure & sizing

| Action | Default binds |
| --- | --- |
| `consume-or-expel-window-left` | `Mod+BracketLeft` |
| `consume-or-expel-window-right` | `Mod+BracketRight` |
| `consume-window-into-column` | `Mod+Comma` |
| `expel-window-from-column` | `Mod+Period` |
| `switch-preset-column-width` | `Mod+R` |
| `maximize-column` | `Mod+F` |
| `center-column` | `Mod+C` |
| `expand-column-to-available-width` | `Mod+Ctrl+F` |
| `toggle-column-tabbed-display` | `Mod+W` |
| `fullscreen-window` | `Mod+Shift+F` |
| `set-column-width "-10%"` / `"+10%"` | `Mod+Minus` / `Mod+Equal` |
| `set-window-height "-10%"` / `"+10%"` | `Mod+Shift+Minus` / `Mod+Shift+Equal` |

### Full Action enum (niri-ipc)

The `niri_ipc::Action` enum exposes more variants than the default config binds. Notable
focus/move/scroll variants (CamelCase in the Rust enum; kebab-case in KDL config):

- Focus columns: `FocusColumnLeft`, `FocusColumnRight`, `FocusColumnFirst`,
  `FocusColumnLast`, `FocusColumnRightOrFirst`, `FocusColumnLeftOrLast`, `FocusColumn`
  (by index).
- Focus windows in column: `FocusWindowDown`, `FocusWindowUp`, `FocusWindowTop`,
  `FocusWindowBottom`, `FocusWindowDownOrTop`, `FocusWindowUpOrBottom`,
  `FocusWindowInColumn` (by index), `FocusWindowPrevious`, `FocusWindow` (by id).
- Combined edge wraps: `FocusWindowDownOrColumnLeft/Right`,
  `FocusWindowUpOrColumnLeft/Right`, `FocusColumnOrMonitorLeft/Right`,
  `FocusWindowOrWorkspaceDown/Up`, `FocusWindowOrMonitorUp/Down`.
- Workspaces: `FocusWorkspaceDown`, `FocusWorkspaceUp`, `FocusWorkspacePrevious`,
  `FocusWorkspace`.
- Move columns: `MoveColumnLeft`, `MoveColumnRight`, `MoveColumnToFirst`,
  `MoveColumnToLast`, `MoveColumnToIndex`, `MoveColumnLeftOrToMonitorLeft`,
  `MoveColumnRightOrToMonitorRight`.
- Move windows: `MoveWindowDown`, `MoveWindowUp`, `MoveWindowDownOrToWorkspaceDown`,
  `MoveWindowUpOrToWorkspaceUp`, `SwapWindowLeft`, `SwapWindowRight`.
- Move workspaces: `MoveWorkspaceDown`, `MoveWorkspaceUp`, `MoveWorkspaceToIndex`.
- Consume/expel: `ConsumeOrExpelWindowLeft/Right`, `ConsumeWindowIntoColumn`,
  `ExpelWindowFromColumn`.
- Display/centering/sizing: `ToggleColumnTabbedDisplay`, `SetColumnDisplay`,
  `CenterColumn`, `CenterVisibleColumns`, `CenterWindow`, `MaximizeColumn`,
  `ExpandColumnToAvailableWidth`, `SwitchPresetColumnWidth`, `SwitchPresetWindowWidth`,
  `SwitchPresetWindowHeight`, `SetWindowWidth`, `SetWindowHeight`, `ResetWindowHeight`.

## 6. Scroll-tick bindings and touchpad gestures

### Mouse-wheel "scroll tick" binds (discrete)

niri binds the mouse wheel to discrete focus/move actions. These are **not auto-filled**
with defaults — the binds section must be copied from the default config. From the
default config:

```kdl
binds {
    Mod+WheelScrollDown      cooldown-ms=150 { focus-workspace-down; }
    Mod+WheelScrollUp        cooldown-ms=150 { focus-workspace-up; }
    Mod+WheelScrollRight     { focus-column-right; }
    Mod+WheelScrollLeft      { focus-column-left; }
    Mod+Ctrl+WheelScrollDown  cooldown-ms=150 { move-column-to-workspace-down; }
    Mod+Ctrl+WheelScrollUp    cooldown-ms=150 { move-column-to-workspace-up; }
    Mod+Ctrl+WheelScrollRight { move-column-right; }
    Mod+Ctrl+WheelScrollLeft  { move-column-left; }
}
```

- `WheelScrollDown/Up` (vertical wheel) → workspaces; `WheelScrollRight/Left` (horizontal
  wheel / shift-wheel) → columns. `cooldown-ms` rate-limits repeated ticks.

### Touchpad / pointer gestures (continuous)

- **Three-finger horizontal swipe**: pans the view (the column strip) horizontally —
  continuous scrolling of the viewport over the strip.
- **Three-finger vertical swipe**: switches workspaces (vertical axis).
- **Four-finger vertical swipe** (since 25.05): opens/closes the **Overview**.
- **Mod + middle mouse drag**: horizontal drag pans the view; vertical drag switches
  workspaces.
- **Mod + left mouse**: interactive move; **Mod + right mouse**: interactive resize.
- Other pointer features: "Drag-and-Drop Edge View Scroll" and a "Hot Corner to Toggle
  the Overview".

The horizontal swipe panning the strip continuously is the key gesture for a niri-style
mode: it is free-scroll of `scrollX`, distinct from the discrete column-snapping focus
actions.

## 7. Centering and scroll-to-edge default behavior

How far the viewport scrolls when focus changes is controlled by `center-focused-column`
in the layout config:

- `center-focused-column "never"` (**default**): scroll **just enough** to bring the
  newly focused column fully into view at the nearest screen edge. If the focused column
  is already fully visible, the viewport does not move. This is the signature
  "scroll-the-minimum" behavior — focus walks across the strip and the viewport only
  nudges when a column would otherwise be clipped.
- `center-focused-column "always"`: always re-center the viewport on the focused column.
- `center-focused-column "on-overflow"`: center only when the focused column would not
  otherwise fit on screen.
- `always-center-single-column` (bool): when a workspace has a single column, keep it
  centered.
- `center-column` action (`Mod+C`) manually centers the focused column on demand,
  independent of the `center-focused-column` mode.

Related layout config keys:

- `default-column-width { proportion 0.5; }` — new columns default to half the output
  width (or `fixed <px>`, or omitted to let the window choose).
- `preset-column-widths { ... }` — the widths cycled by `switch-preset-column-width`
  (each a `proportion` or `fixed`).
- `default-column-display "normal" | "tabbed"` — display mode for new columns.
- `gaps <px>` (inside + outside windows), `struts { left/right/top/bottom <px>; }` (outer
  viewport margins, may be negative).
- `empty-workspace-above-first` (bool) — keep an empty workspace above the first as well
  as the always-present empty one at the bottom.

## 8. IPC: NIRI_SOCKET, `niri msg`, request/response model

niri exposes a socket-based control plane:

- The socket path is in the **`$NIRI_SOCKET`** environment variable.
- The CLI **`niri msg`** is "a thin wrapper over writing and reading to a socket". Add
  `--json` for machine-readable output.
- **Protocol**: line-delimited JSON. The client writes one JSON request object on a single
  line, then a newline (or shuts down the write half). The server replies with one
  single-line JSON object wrapped as `Ok` or `Err`.
- Direct access without the CLI: `socat STDIO "$NIRI_SOCKET"` (or any socket client) and
  speak the JSON protocol yourself.

Request types include:

- `Action` — execute a compositor action. Example payload:
  `{"Action":{"FocusWorkspace":{"reference":{"Index":2}}}}`. Every `Action` enum variant
  from section 5 is invokable this way.
- `FocusedWindow` — info about the currently focused window.
- `Windows`, `Workspaces` — query window/workspace state.
- `EventStream` — long-lived subscription: sends "the complete current state up-front,
  then follow[s] up with updates to that state," so a consumer can mirror compositor state
  without desync. This is the model to mirror if the terminal app wants an observable
  layout state feed.

For the terminal app, the takeaways are: (1) a single typed `Action` request channel maps
cleanly to a keybind/command dispatcher, and (2) the event-stream "full snapshot then
deltas" pattern is the right shape for keeping any UI/state mirror in sync.

## Sources

- niri README — https://github.com/YaLTeR/niri
- niri-ipc `Action` enum — https://docs.rs/niri-ipc/latest/niri_ipc/enum.Action.html
- Wiki: Configuration: Layout — https://github.com/YaLTeR/niri/wiki/Configuration:-Layout
- Wiki: Configuration: Key Bindings — https://github.com/YaLTeR/niri/wiki/Configuration:-Key-Bindings
- Wiki: Gestures — https://github.com/YaLTeR/niri/wiki/Gestures
- Wiki: IPC — https://github.com/YaLTeR/niri/wiki/IPC
- Default config (keybinds + layout defaults) — https://raw.githubusercontent.com/YaLTeR/niri/main/resources/default-config.kdl

Notes on fetch failures: the `yalter.github.io/niri/*.html` doc pages
(`Overview.html`, `Layout.html`, `Configuration%3A-Layout.html`) all returned HTTP 404 —
the canonical docs now live in the GitHub repo wiki (`/YaLTeR/niri/wiki/...`) and the
in-repo `resources/default-config.kdl`, which were used instead. The wiki `Key-Bindings`
and `Movement` pages rendered with load errors, so default keybinds were sourced directly
from `resources/default-config.kdl`.
