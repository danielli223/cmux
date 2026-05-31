# cmux Architecture Reference (for a niri-style scrollable layout mode)

Reference material distilled from the cmux source tree. **The source is authoritative**; this
doc cites concrete file paths and line numbers so you can re-verify before building on it.

cmux is a native macOS app (SwiftUI + AppKit) that embeds Ghostty terminals and WKWebView browsers.
The split/tiling engine is a vendored Swift package, **Bonsplit** (`vendor/bonsplit/`).

---

## 1. Object hierarchy

The hierarchy the task brief assumed is **mostly right, but the in-code names differ** from the
user-facing API names because of historical drift. Here is the verified model:

```
Window  (NSWindow, one MainWindowContext per window)
  └─ TabManager            // one per window; owns the sidebar list of "workspaces"
       └─ Workspace        // a project / sidebar entry. (In code: TabManager.tabs : [Workspace])
            ├─ bonsplitController : BonsplitController   // the split tree for this workspace
            │     └─ SplitNode tree  (binary: .pane | .split)
            │           └─ PaneState (a leaf pane = a split region)
            │                 └─ [Tab]   // bonsplit "tabs" inside the pane == "Surfaces" in the API
            └─ panels : [UUID: Panel]    // the actual content objects, keyed by panel/surface id
                  └─ Panel  (terminal | browser | markdown | filePreview | rightSidebarTool)
```

### Name mapping (this trips people up — read carefully)

| Conceptual layer | Public API / CLI name | In-code type / property |
| --- | --- | --- |
| OS window | `window` | `NSWindow` + `AppDelegate.MainWindowContext` (`Sources/AppDelegate.swift:579`) |
| Sidebar project entry | `workspace` | `Workspace` (`Sources/Workspace.swift:9396`), stored as `TabManager.tabs: [Workspace]` (`Sources/TabManager.swift:1134`) |
| Split region | `pane` | bonsplit `PaneState` / `PaneID` (`vendor/bonsplit/.../Models/PaneState.swift`) |
| A tab within a pane | `surface` | bonsplit `Tab` / `TabID` (`vendor/bonsplit/.../Public/Types/Tab.swift`); cmux maps `Tab.id` → `Panel.id` |
| Content of a surface | `surface` content / `panel` | `Panel` subclass, `Workspace.panels: [UUID: Panel]` (`Sources/Workspace.swift:13035` etc.) |

Key consequences for a niri-style mode:

- **`TabManager.tabs` is `[Workspace]`, not terminal tabs.** `selectedTabId` is the *selected
  workspace* id. The legacy "tab" vocabulary in `TabManager`/`Workspace` everywhere means *workspace*.
  See `Sources/TabManager.swift:927` (`class TabManager: ObservableObject`), `:1134`, `:2354`
  (`var selectedTab: Workspace { selectedWorkspace }`).
- **Each `Workspace` owns exactly one `BonsplitController`** (`Sources/Workspace.swift:9441`,
  `let bonsplitController: BonsplitController`). The split tree is per-workspace, so a niri-style
  scrollable column layout would live *inside* one workspace's bonsplit tree (or replace it).
- **A bonsplit `Tab` is a "Surface"; its id maps to a `Panel`.** `Workspace` keeps a "Mapping from
  bonsplit TabID to our Panel instances" (`Sources/Workspace.swift:9453`). The `Panel` is where the
  terminal/browser/etc. actually lives (`Sources/Panels/Panel.swift:6`, `enum PanelType`).
- `PanelType` cases: `terminal`, `browser`, `markdown`, `filePreview`, `rightSidebarTool`
  (`Sources/Panels/Panel.swift:6-38`).

---

## 2. Tiling / split model — and exactly how splitting steals space

The entire tiling model is a **binary split tree** in Bonsplit. There is **no notion of a scrollable
infinite strip today** — this is the gap a niri-style mode must fill.

### The tree

`SplitNode` (`vendor/bonsplit/Sources/Bonsplit/Internal/Models/SplitNode.swift:12`):

```swift
indirect enum SplitNode: Identifiable, Equatable {
    case pane(PaneState)     // leaf: one split region, holds [Tab]
    case split(SplitState)   // branch: exactly TWO children + a divider
}
```

`SplitState` (`.../Models/SplitState.swift:12`) is a branch with:
- `orientation: SplitOrientation` — `.horizontal` (side-by-side, first=LEFT/second=RIGHT) or
  `.vertical` (stacked, first=TOP/second=BOTTOM) (`.../Public/Types/SplitOrientation.swift:4`).
- `first: SplitNode`, `second: SplitNode` — the two children (always exactly two).
- `dividerPosition: CGFloat` in `[0,1]` — fraction given to `first`.

### Bounds are computed top-down in normalized [0,1] coordinates

`SplitNode.computePaneBounds(in:)` (`.../Models/SplitNode.swift:85`) recursively subdivides a unit
rect. For a horizontal split: `first` gets `width * dividerPosition`, `second` gets
`width * (1 - dividerPosition)`; vertical does the same on height. There is no per-pane fixed/min
pixel size in the model — every pane is a fraction of its parent's rect.

### How a split STEALS SPACE (the critical behavior)

`SplitViewController.splitPane(...)` → `splitNodeRecursively(...)`
(`.../Internal/Controllers/SplitViewController.swift:125-195`):

1. Walk the tree to the **target leaf pane** (the focused pane).
2. **Replace that leaf** `.pane(P)` with a new `.split(S)` whose `first = .pane(P)` (the original)
   and `second = .pane(newPane)`.
3. `dividerPosition` defaults to **0.5** (`normalizedInitialDividerPosition` clamps to `[0.1,0.9]`,
   default `0.5`, `:280-283`).

**Therefore splitting only subdivides the focused pane's own rectangle, 50/50.** Sibling panes
elsewhere in the tree are untouched — their bounds don't change because only the target leaf's
sub-rect is repartitioned. There is **no global "shift everything over" or space redistribution**;
space is "stolen" purely from the pane you split, halving it. The visual entry animation slides the
new pane in from the right/bottom (`animationOrigin: .fromSecond`, `:168`) but the steady-state model
is always the 0.5 ratio.

This is the opposite of niri's model (where opening a new column pushes the strip and other columns
keep their width). A niri-style mode would need either a new container type or a flat list of
columns with independent widths + a horizontal scroll offset, rather than recursively halving.

### Closing a pane gives space back to its sibling

`closePane` → `closePaneRecursively` (`SplitViewController.swift:286-347`): removing a leaf collapses
its parent split, and the **sibling subtree replaces the parent**, reclaiming the full parent rect.
Focus moves to the sibling. The last pane can't be closed.

### Resizing dividers

Dragging a divider just mutates `SplitState.dividerPosition`. Programmatic: `BonsplitController`'s
`setDividerPosition(_:forSplit:fromExternal:)` (used by the equalizer at
`Sources/SplitEqualizer.swift:65`).

### Equalize splits (⌃=)

`SplitEqualizer.equalize` (`Sources/SplitEqualizer.swift:15-65`) walks the tree and resets each
`SplitState.dividerPosition` to an even share so all leaf panes get equal area.

### Zoom

`togglePaneZoom` (`SplitViewController.swift:107`) renders only one pane fullscreen; requires >1 pane.
Bound to ⌘⇧Return (`toggleSplitZoom`).

### Spatial focus navigation (already directional, niri-relevant)

`navigateFocus(direction:)` / `findBestNeighbor` (`SplitViewController.swift:403-474`) picks the best
neighbor pane in a direction by perpendicular-axis overlap then distance, using the computed
normalized bounds. This is the existing "focus left/right/up/down" primitive.

### cmux-side split entry points

`Workspace.newTerminalSplit(from:orientation:insertFirst:focus:)`
(`Sources/Workspace.swift:12941`) and siblings `newBrowserSplit`, `newMarkdownSplit`
(`:13477`), etc. all funnel into `bonsplitController.splitPane(paneId, orientation:, withTab:,
insertFirst:)` (e.g. `Sources/Workspace.swift:13073`). `insertFirst` chooses left/top vs right/bottom
placement of the new pane. Direction → orientation mapping: left/right → `.horizontal`,
up/down → `.vertical`; left/up set `insertFirst = true` (`Sources/TerminalController.swift:11611-11612`,
`:18996`).

---

## 3. Keybinds

All cmux-owned shortcuts are defined as the `Action` enum + `defaultShortcut` in
**`Sources/KeyboardShortcutSettings.swift`** (enum cases `:60-147`, defaults `:247-405`). They are
user-editable in Settings and overridable via `~/.config/cmux/cmux.json`. Per the repo CLAUDE.md
shortcut policy, **every new cmux shortcut must be registered here.**

Dispatch / interception happens in `Sources/AppDelegate.swift` (`performKeyEquivalent`, key monitor)
and through SwiftUI command menus in `Sources/cmuxApp.swift`.

### Existing shortcuts the niri task MUST NOT collide with

| Shortcut | Action | Source (defaultShortcut) |
| --- | --- | --- |
| ⌘D | Split Right (`splitRight`) | `KeyboardShortcutSettings.swift:339` |
| ⌘⇧D | Split Down (`splitDown`) | `:341` |
| ⌥⌘D | Split Browser Right (`splitBrowserRight`) | `:344` |
| ⌥⌘⇧D | Split Browser Down (`splitBrowserDown`) | `:346` |
| ⌥⌘← / → / ↑ / ↓ | Focus Pane Left/Right/Up/Down (`focusLeft/Right/Up/Down`) | `:331-338` |
| ⌃⇧] / ⌃⇧[ → see note | — | (the brief's `⌘⇧[` / `⌘⇧]` are **surface** nav, below) |
| ⌘⇧] / ⌘⇧[ | Next / Previous **Surface** (`nextSurface`/`prevSurface`) | `:348-351` |
| ⌃] / ⌃[ | Next / Previous **Workspace** (`nextSidebarTab`/`prevSidebarTab`) | `:309-312` |
| ⌘⇧Return | Toggle Pane Zoom (`toggleSplitZoom`) | `:342` |
| ⌃= | Equalize Splits (`equalizeSplits`) | `:343` |

Note: the brief mentioned `⌃Tab` — there is **no `⌃Tab` binding** in `defaultShortcut`; cross-surface
cycling is `⌘⇧[` / `⌘⇧]`. Verify against `KeyboardShortcutSettings.swift` before assuming Tab is free.

### Other notable existing shortcuts (non-exhaustive — full list at `:247-405`)

| Shortcut | Action |
| --- | --- |
| ⌘N / ⌘⇧N | New Workspace / New Window |
| ⌘T | New Surface (`newSurface`) |
| ⌘W / ⌘⇧W / ⌃W | Close Tab / Close Workspace / Close Window |
| ⌘[ / ⌘] | Focus History Back / Forward |
| ⌘1…9 | Select Workspace by number; ⌃1…9 = Select Surface by number / right-sidebar modes |
| ⌘B / ⌥⌘B | Toggle Left / Right Sidebar |
| ⌘P / ⌘⇧P | Go to Workspace / Command Palette |
| ⌘L / ⌘⇧L | Focus Browser Address Bar / Open Browser |
| ⌘F, ⌘G, ⌘⇧F | Find / Find Next / Find in Directory |

Free modifier space for a new niri layer is tight. ⌃-based and ⌥⌘⇧ combos are the least crowded;
check `conflictingAction` (`:451`) which rejects any new binding that collides with an existing one.

---

## 4. Socket / CLI API

### Transport

cmux runs a **Unix-domain socket server** inside the app, implemented in
**`Sources/TerminalController.swift`** (the big controller; ~21k lines). It listens on a stable
socket path (`SocketControlSettings.stableDefaultSocketPath`, `Sources/TerminalController.swift:109`)
using a custom `accept` loop on a dedicated `DispatchQueue` (`com.cmux.socket.listener`, `:122`).
Threading policy: telemetry/`report_*` commands run off-main; only focus/UI commands hop to the main
actor (see CLAUDE.md "Socket command threading policy" and `v2MainSync` usage).

The **CLI** (`CLI/cmux.swift` + `CLI/CMUXCLI+*.swift`, built as the `cmux` binary) connects to that
socket and speaks the protocol. Socket path resolution: `CLI/CLISocketPathResolver.swift`.

### Two protocols coexist

1. **v1 line protocol** — space-delimited text commands, one per line. Dispatch switch at
   `Sources/TerminalController.swift:2951` onward (`case "ping"`, `"list_workspaces"`, `"new_split"`,
   `"send"`, `"focus_surface"`, …). Output is plain text (`OK <uuid>`, `ERROR: …`).
2. **v2 JSON protocol** — newline-delimited JSON envelopes `{"id","method","params"}`, handle-based
   (`window_id`/`workspace_id`/`pane_id`/`surface_id`), dotted method names. Parsed by
   `parseV2SocketRequest` (`:2293`); two dispatch tables: a socket-worker (off-main) switch at `:2325`
   and a main-actor switch at `:3348`. Responses use `v2Ok` / `v2Result` / `v2Err`. See
   `docs/v2-api-migration.md` and `docs/cli-contract.md`.

### v2 methods most relevant to a layout mode

(method strings from the dispatch switch, `Sources/TerminalController.swift:3348-3520`)

| Method | Purpose |
| --- | --- |
| `window.list` / `window.current` / `window.focus` / `window.create` / `window.close` | Window management |
| `workspace.list` / `workspace.create` / `workspace.select` / `workspace.current` / `workspace.close` | Workspace (sidebar entry) CRUD + selection |
| `workspace.next` / `workspace.previous` / `workspace.last` | Cycle workspaces |
| `workspace.move_to_window` / `workspace.reorder` / `workspace.reorder_many` | Reposition workspaces |
| `workspace.equalize_splits` | Equalize all dividers in the workspace |
| `surface.list` / `surface.current` / `surface.focus` | Enumerate / focus surfaces (bonsplit tabs) |
| `surface.split` | Split focused/target surface; `params.direction` = left/right/up/down (`:3456`, handler maps to orientation + insertFirst) |
| `surface.split_off` / `surface.drag_to_split` | Pull a surface out into its own pane |
| `surface.create` / `surface.close` / `surface.move` / `surface.reorder` | Surface lifecycle |
| `surface.send_text` / `surface.send_key` | Inject text / keystrokes into a surface |
| `surface.trigger_flash` | Agent-visible highlight |
| `surface.report_tty` / `surface.report_shell_state` / `surface.clear_history` | Surface telemetry/state |
| `pane.list` / `pane.focus` / `pane.surfaces` / `pane.create` / `pane.resize` | **Pane (split region) ops — incl. programmatic resize** (`:3502-3510`) |

`pane.resize` and `surface.split` are the levers a niri-style mode would most want; `pane.resize`
ultimately drives `setDividerPosition` on the relevant `SplitState`.

### v1 equivalents (legacy, still live)

`list_workspaces`, `new_workspace`, `select_workspace`, `current_workspace`, `list_surfaces`,
`focus_surface`, `new_split` (`<direction> [panel]`, `:2981` / handler `:18996`), `new_pane`,
`new_surface`, `close_surface`, `list_panes`, `focus_pane`, `drag_surface_to_split`, `send`,
`send_surface`, `send_key`, plus a large set of `report_*` telemetry and debug/test commands
(`screenshot`, `read_screen`, `simulate_shortcut`, `layout_debug`, …). Full list: switch at
`Sources/TerminalController.swift:2951-3300`.

### CLI usage (tagged dev build)

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

Handles accept UUIDs, refs (`workspace:2`, `surface:1`), or indexes (`docs/cli-contract.md`).
Per the socket-focus policy (CLAUDE.md): only explicit focus-intent commands
(`window.focus`, `workspace.select/next/previous/last`, `surface.focus`, `pane.focus`, browser focus)
may move in-app focus; everything else must preserve the user's current focus.

---

## 5. Environment variables

Socket / control plane (consumed by the app and CLI; defined across
`Sources/TerminalController.swift`, `Sources/SocketControlSettings.swift`, `CLI/CLISocketPathResolver.swift`):

| Var | Meaning |
| --- | --- |
| `CMUX_SOCKET_PATH` | Canonical control-socket path override |
| `CMUX_SOCKET` | Deprecated alias for `CMUX_SOCKET_PATH` (CLI errors if both set and differ) |
| `CMUX_SOCKET_PASSWORD` | Socket auth password (fallback when `--password` absent) |
| `CMUX_SOCKET_ENABLE` / `CMUX_SOCKET_MODE` | Enable / mode flags for the listener |
| `CMUX_ALLOW_SOCKET_OVERRIDE` | Permits overriding the default socket path |
| `CMUX_BUNDLE_ID` | Target app bundle id (used to scope a tagged build) |
| `CMUX_BUNDLED_CLI_PATH` | Path to the CLI binary bundled with a specific app |
| `CMUX_APP_PATH` | Path to the `.app` |
| `CMUX_TAG` | Selects a tagged dev build (drives socket path `/tmp/cmux-debug-<tag>.sock`, bundle id, CLI) — see `scripts/cmux-debug-cli.sh` |
| `CMUX_DEBUG_LOG` | Debug log file path (`/tmp/cmux-debug[-<tag>].log`) |
| `CMUX_DEBUG_SOCKET_COMMAND_LOG` | Logs every socket command for debugging |

Ambient context injected into terminals (so a process inside a surface knows where it is — these are
the handles the CLI defaults to):

| Var | Meaning |
| --- | --- |
| `CMUX_WORKSPACE_ID` | Current workspace (sidebar entry) id |
| `CMUX_SURFACE_ID` | Current surface (bonsplit tab) id |
| `CMUX_PANE_ID` | Current pane (split region) id |
| `CMUX_PANEL_ID` | Current panel (content) id |
| `CMUX_TAB_ID` | Legacy/default tab context for tab commands |

(Full enumerated list lives across `Sources/`, `CLI/`, `scripts/`; the table above is the
layout-relevant subset.)

---

## 6. Sources (authoritative file paths)

Split / tiling engine (Bonsplit, vendored):
- `vendor/bonsplit/Sources/Bonsplit/Internal/Models/SplitNode.swift` — tree enum + `computePaneBounds`
- `vendor/bonsplit/Sources/Bonsplit/Internal/Models/SplitState.swift` — branch node (orientation, divider)
- `vendor/bonsplit/Sources/Bonsplit/Internal/Models/PaneState.swift` — leaf pane + its tabs
- `vendor/bonsplit/Sources/Bonsplit/Internal/Controllers/SplitViewController.swift` — split/close/focus/zoom logic (**how space is stolen**)
- `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift` — public split/tab API
- `vendor/bonsplit/Sources/Bonsplit/Public/Types/SplitOrientation.swift`, `Tab.swift`, `PaneID.swift`, `TabID.swift`, `NavigationDirection.swift`

cmux object hierarchy:
- `Sources/Workspace.swift` — `Workspace` (per-sidebar-entry), owns `bonsplitController` + `panels`; split entry points (`newTerminalSplit` `:12941`, `newMarkdownSplit` `:13477`)
- `Sources/TabManager.swift` — `TabManager` (per-window), `tabs: [Workspace]` (`:1134`), selection/focus history
- `Sources/Panels/Panel.swift` — `Panel` base + `PanelType` (terminal/browser/markdown/filePreview/rightSidebarTool)
- `Sources/Panels/TerminalPanel.swift`, `BrowserPanel.swift`, `MarkdownPanel.swift`, `FilePreviewPanel.swift` — content
- `Sources/ContentView.swift`, `Sources/WorkspaceContentView.swift` — SwiftUI hosting of the bonsplit tree
- `Sources/AppDelegate.swift` — `MainWindowContext` (`:579`), window↔TabManager wiring, key dispatch
- `Sources/cmuxApp.swift` — app entry, command menus, debug windows
- `Sources/SplitEqualizer.swift` — equalize dividers

Keybinds:
- `Sources/KeyboardShortcutSettings.swift` — `Action` enum, defaults, conflict detection
- `Sources/AppDelegate.swift` — `performKeyEquivalent` / key monitor dispatch
- `Sources/KeyboardShortcutSettingsFileStore.swift`, `Sources/CmuxConfig.swift` — `~/.config/cmux/cmux.json` overrides

Socket / CLI:
- `Sources/TerminalController.swift` — socket server + v1 (`:2951`) and v2 (`:2325`, `:3348`) dispatch
- `Sources/SocketControlSettings.swift` — socket path / mode settings
- `CLI/cmux.swift`, `CLI/CMUXCLI+*.swift`, `CLI/CLISocketPathResolver.swift` — the `cmux` CLI
- `docs/cli-contract.md`, `docs/v2-api-migration.md`, `docs/events.md`, `docs/configuration.md` — contracts

Repo conventions:
- `CLAUDE.md` / `AGENTS.md` (symlink) — shortcut policy, socket threading/focus policy, package architecture, build via `scripts/reload.sh --tag <tag>`
