# cmux layout engine (Bonsplit)

How cmux models split/pane layout, how it computes geometry, how a keybind like ⌘D
becomes a layout mutation, and where a new "niri-mode" infinite-strip layout strategy
should plug in.

This doc is written for someone about to add a parallel layout strategy. The crux finding
up front: **Bonsplit's geometry is purely ratio-based — every split node divides its
parent's rectangle by a fraction, so adding a column necessarily SHRINKS its siblings.**
There is no notion of an intrinsic/absolute column width, and no scroll/viewport offset.
A fixed-width horizontal strip is not expressible in the existing model and needs a
parallel layout strategy rather than a tweak to the divider math.

---

## Engine location & API

The layout engine is the **Bonsplit** library, a git submodule vendored at
`vendor/bonsplit` (submodule SHA in `git submodule status`: `vendor/bonsplit (1.1.1-359-...)`).
It is a Swift package (`vendor/bonsplit/Package.swift`) consumed by the app target as
`import Bonsplit`.

Public API surface (`vendor/bonsplit/Sources/Bonsplit/Public/`):

- **`BonsplitController`** (`BonsplitController.swift`) — the `@MainActor @Observable`
  facade. One controller instance per cmux workspace (`workspace.bonsplitController`).
  Public mutation API:
  - Tabs: `createTab`, `closeTab`, `selectTab`, `moveTab`, `reorderTab`,
    `selectNextTab` / `selectPreviousTab`.
  - Splits: `splitPane(_:orientation:withTab:initialDividerPosition:)` and overloads
    (`insertFirst:`, `movingTab:`) — `BonsplitController.swift:402` / `:467` / `:529`.
  - `closePane(_:)` — `:586`.
  - Focus: `focusPane`, `navigateFocus(direction:)`, `adjacentPane(to:direction:)` — `:616`–`:632`.
  - Zoom: `togglePaneZoom`, `clearPaneZoom`, `zoomedPaneId` — `:637`–`:657`.
  - Geometry: `layoutSnapshot()` (`:717`), `treeSnapshot()` (`:746`),
    `setDividerPosition(_:forSplit:fromExternal:)` (`:812`), `setContainerFrame(_:)` (`:834`).
- **`BonsplitView`** (`BonsplitView.swift`) — the SwiftUI entry point. Takes a controller
  plus a per-tab content builder closure.
- **`BonsplitDelegate`** / **`BonsplitConfiguration`** — host callbacks (veto/notify) and
  appearance/behavior config.
- Public value types in `Public/Types/`: `SplitOrientation` (`.horizontal | .vertical`),
  `PaneID`, `TabID`, `Tab`, `NavigationDirection`, and the read-only geometry export
  `LayoutSnapshot` / `ExternalTreeNode` (`Public/Types/LayoutSnapshot.swift`).

Internal model (`vendor/bonsplit/Sources/Bonsplit/Internal/Models/`):

- **`SplitNode`** (`SplitNode.swift:12`) — `indirect enum` that *is* the split tree.
  Two cases: `.pane(PaneState)` (a leaf holding tabs) and `.split(SplitState)` (a binary
  branch). It is a strict **binary tree** — every split has exactly `first` and `second`.
- **`SplitState`** (`SplitState.swift:12`) — a branch: `orientation`, `first`, `second`,
  and **`dividerPosition: CGFloat // 0.0 to 1.0`** (`SplitState.swift:17`). This single
  fraction is the *entire* geometry parameter for the node.
- **`PaneState`** (`Internal/Models/PaneState.swift`) — a leaf: ordered `tabs`, `selectedTabId`.
- **`SplitViewController`** (`Internal/Controllers/SplitViewController.swift:7`) — the
  `@Observable @MainActor` engine that owns `rootNode: SplitNode` and performs the tree
  rewrites (`splitPane`, `closePane`, `navigateFocus`). `BonsplitController` wraps it.

There is no `weight`, no `minWidth`/`maxWidth`, and no absolute pixel size stored in the
model. The only stored geometry is one `dividerPosition` ratio per branch.

---

## Geometry computation (the crux)

Geometry is computed by a single recursive pass that **subdivides the parent rect by the
divider fraction**. The canonical function is `SplitNode.computePaneBounds`
(`vendor/bonsplit/Sources/Bonsplit/Internal/Models/SplitNode.swift:85`):

```swift
func computePaneBounds(in availableRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [PaneBounds] {
    switch self {
    case .pane(let paneState):
        return [PaneBounds(paneId: paneState.id, bounds: availableRect)]

    case .split(let splitState):
        let dividerPos = splitState.dividerPosition
        let firstRect: CGRect
        let secondRect: CGRect

        switch splitState.orientation {
        case .horizontal:  // Side-by-side: first=LEFT, second=RIGHT
            firstRect = CGRect(x: availableRect.minX, y: availableRect.minY,
                               width: availableRect.width * dividerPos, height: availableRect.height)
            secondRect = CGRect(x: availableRect.minX + availableRect.width * dividerPos, y: availableRect.minY,
                                width: availableRect.width * (1 - dividerPos), height: availableRect.height)
        case .vertical:    // Stacked: first=TOP, second=BOTTOM
            firstRect = CGRect(x: availableRect.minX, y: availableRect.minY,
                               width: availableRect.width, height: availableRect.height * dividerPos)
            secondRect = CGRect(x: availableRect.minX, y: availableRect.minY + availableRect.height * dividerPos,
                                width: availableRect.width, height: availableRect.height * (1 - dividerPos))
        }

        return splitState.first.computePaneBounds(in: firstRect)
             + splitState.second.computePaneBounds(in: secondRect)
    }
}
```

Key properties:

- It starts from the **unit rect** `(0,0,1,1)` and produces *normalized* bounds. Pixels
  only appear when `BonsplitController.layoutSnapshot()` multiplies by `containerFrame`
  (`BonsplitController.swift:721`–`735`). So the model is resolution-independent: the same
  tree fills whatever container it is given.
- A child's width is `parent.width * dividerPos` (or `* (1 - dividerPos)`). Width is
  **always a fraction of the parent**, never an absolute value.
- The exact same fraction-based subdivision is duplicated in
  `BonsplitController.buildExternalTree` (`BonsplitController.swift:751`–`796`) for the
  `treeSnapshot()` export, and the runtime AppKit layout is driven by `NSSplitView` whose
  divider pixel position is `availableSize * dividerPosition`
  (`SplitContainerView.swift:298`, `:671`).

This is a **ratio-based recursive split tree** (option 1 in the brief), not fixed-size.

---

## Why splitting shrinks siblings

When you split pane *P*, the engine rewrites the tree in
`SplitViewController.splitNodeRecursively` (`SplitViewController.swift:141`): the leaf
`.pane(P)` is replaced by a `.split` whose children are `.pane(P)` and `.pane(new)`, with

```swift
dividerPosition: normalizedInitialDividerPosition(initialDividerPosition)  // default 0.5
```

(`SplitViewController.swift:167`, default `0.5` at `:281`).

Because geometry is `parent.width * dividerPos`, inserting that 0.5 split means *P* now
occupies half of the rectangle it used to fill — its sibling appears by **taking half of
P's space**. Add a third pane and you get a nested split inside one half, so that half is
again subdivided. There is no way for the new pane to claim *new* horizontal space beyond
the container: the container rect is fixed at `(0,0,1,1)` and every pane is a fraction of
it. `SplitEqualizer` (`Sources/SplitEqualizer.swift:64`) even computes
`firstSpanCount / totalSpanCount` to rebalance — confirming the model thinks purely in
shares-of-a-fixed-whole, never in intrinsic widths.

Consequently, an "infinite strip of fixed-width columns that don't resize when a column is
added" cannot be represented by mutating `dividerPosition`. It needs a different layout
strategy.

---

## View integration

Rendering is a SwiftUI tree that mirrors `SplitNode`, terminating in AppKit `NSSplitView`s:

- `BonsplitView` (`BonsplitView.swift:40`) injects both controllers into the environment
  and renders `SplitViewContainer`.
- `SplitViewContainer` (`Internal/Views/SplitViewContainer.swift`) wraps everything in a
  `GeometryReader`, pushes `geometry.frame(in: .global)` into `controller.containerFrame`
  (`:33`–`:38` — this is the pixel basis for `layoutSnapshot()`), and renders
  `controller.zoomedNode ?? controller.rootNode` via `SplitNodeView` (`:42`).
- `SplitNodeView` (`Internal/Views/SplitNodeView.swift:19`) switches on the node: `.pane`
  → `SinglePaneWrapper` (an `NSHostingController`-backed pane); `.split` →
  `SplitContainerView`.
- `SplitContainerView` (`Internal/Views/SplitContainerView.swift:90`) is an
  `NSViewRepresentable` over a custom `ThemedSplitView: NSSplitView`. It owns two
  arranged subviews (kept stable at count 2 to avoid collapse flashes) and recurses:
  each child is either a pane host or another nested `SplitContainerView`
  (`makeView(for:)`, `:438`). Divider position is applied as pixels
  (`availableSize * dividerPosition`, `:298`).

**Divider drag** and **equalize** both live here:

- Interactive drag: the `Coordinator` (an `NSSplitViewDelegate`) detects a real
  pointer-on-divider drag in `splitViewWillResizeSubviews` (`:676`) and writes the new
  fraction back to the model in `splitViewDidResizeSubviews` (`:879`:
  `self.splitState.dividerPosition = normalizedPosition`). Non-drag resizes (window
  resize, structural updates) deliberately do *not* mutate the model; they re-assert the
  stored ratio via `syncPosition` (`:630`).
- Equalize ("equalize split span weighting", recent commit `0bd42abd`): host-side pure
  logic in `Sources/SplitEqualizer.swift` walks `treeSnapshot()` and calls
  `controller.setDividerPosition(position, forSplit:fromExternal:true)` per split. It is a
  good template for a model-only layout operation (see seam below).

---

## Keybind → mutation flow

Tracing ⌘D ("Split Right", default `StoredShortcut(key: "d", command: true, ...)` —
`Sources/KeyboardShortcutSettings.swift:339`; `splitDown` is ⇧⌘D at `:341`):

1. **Key event** → `AppDelegate.performKeyEquivalent` matches the configured shortcut:
   `matchConfiguredShortcut(event:, action: .splitRight)` → `performSplitShortcut(direction: .right, ...)`
   (`Sources/AppDelegate.swift:12720`–`12731`). The command-palette / menu entrypoints
   land on the same `performSplitShortcut` (`AppDelegate.swift:14114`,
   `Sources/cmuxApp+...`), per the shared-action policy.
2. **`AppDelegate.performSplitShortcut`** (`AppDelegate.swift:13620`) resolves the focused
   terminal context and calls `tabManager.createSplit(tabId:surfaceId:direction:)`
   (`:13660`).
3. **`TabManager.createSplit`** (`Sources/TabManager.swift:7428`) → `newSplit(...)`
   (`:7433` / def `:7865`) → `Workspace.newTerminalSplit(from:orientation:insertFirst:...)`
   (`TabManager.swift:7878`). `SplitDirection.orientation` maps `.right` → `.horizontal`,
   `.down` → `.vertical`.
4. **`Workspace.newTerminalSplit`** creates the new terminal panel and calls the engine:
   `bonsplitController.splitPane(paneId, orientation:, withTab:, insertFirst:)`
   (`Sources/Workspace.swift:13073`).
5. **`BonsplitController.splitPane`** (`BonsplitController.swift:467`) →
   `SplitViewController.splitPaneWithTab` → `splitNodeRecursively` rewrites `rootNode`
   (the tree mutation described above), focuses the new pane, then
   `notifyGeometryChange()` pushes a fresh `LayoutSnapshot` to the delegate.
6. `@Observable` propagation re-renders `SplitContainerView`, which inserts the new
   `NSSplitView` arranged subview and animates the divider in.

**Where a viewport / scroll-offset would be injected:** the natural seam is between the
model and `computePaneBounds` / `SplitViewContainer`. Today `SplitViewContainer`
(`SplitViewContainer.swift:18`) hands the full container rect to the renderer and the tree
fills it exactly. A strip layout would compute *absolute* column rects and apply a
horizontal scroll offset *before* handing rects to the pane hosts — i.e. the offset lives
at the container level, parallel to `computePaneBounds`, not inside the existing divider
math.

---

## Recommended seam for niri-mode

Goal: an infinite horizontal strip of columns with **intrinsic widths that don't change
when a column is added**, plus a horizontal **scroll offset** that brings columns into
view (niri-style). This is fundamentally incompatible with `dividerPosition` (ratios of a
fixed whole), so add it as a **parallel, pure-model layout strategy**, not as a Bonsplit
divider hack.

Concrete recommendation:

1. **New pure model package / type, no views.** Mirror the `SplitEqualizer` precedent
   (`Sources/SplitEqualizer.swift`): a `@MainActor enum`/`struct` of pure functions over a
   value-type column model, fully unit-testable with Swift Testing and zero AppKit/SwiftUI
   dependency. Model shape:
   - `StripColumn { id, width: CGFloat /* intrinsic px */, content }`
   - `StripLayout { columns: [StripColumn], scrollOffset: CGFloat }`
   - A pure `func columnRects(in container: CGRect) -> [(id, CGRect)]` that lays columns
     left-to-right at their intrinsic widths starting at `-scrollOffset` (the strip can be
     wider than the container; that's the point). Adding a column appends to `columns` and
     does **not** touch any sibling's `width` — the exact property the ratio engine can't
     provide. This is the analog of `computePaneBounds`, but absolute instead of fractional.
   - Pure mutation ops `insertColumn`, `removeColumn`, `focusColumn(_:)` that also update
     `scrollOffset` to keep the focused column visible (niri "scroll-into-view"). Put the
     viewport math here so it is testable without a window.

2. **Keep the existing Bonsplit tree for *within-column* splits.** A niri "column" can
   itself hold a vertical Bonsplit stack. So the strip model owns the horizontal axis and
   the scroll offset; each column can embed a `BonsplitController` (or just a `PaneState`)
   for vertical splits. This avoids reimplementing tabs/panes and reuses all the pane
   hosting, drag, and zoom machinery.

3. **A strategy switch above `SplitViewContainer`.** Introduce a layout-mode enum on the
   workspace (`tiling` vs `strip`). The host's content view
   (`Sources/WorkspaceContentView.swift:219`, where `BonsplitView` is mounted) chooses
   either the current `BonsplitView` or a new `StripView` that consumes `StripLayout`.
   The strip's `GeometryReader` plays the role `SplitViewContainer` plays today
   (`SplitViewContainer.swift:18`–`38`): it owns the container rect and applies the scroll
   offset, then positions each column's pane host at the absolute rect from
   `columnRects(in:)`.

4. **Reuse the keybind plumbing unchanged.** ⌘D etc. already funnel through the single
   shared `performSplitShortcut` → `createSplit` → `newTerminalSplit` chain
   (`AppDelegate.swift:13620`, `TabManager.swift:7428`, `Workspace.swift:13073`). Branch at
   `Workspace.newTerminalSplit`: in strip mode, route a horizontal "split" to
   `StripLayout.insertColumn` instead of `bonsplitController.splitPane`. One model path,
   every entrypoint (shortcut, palette, menu, CLI) inherits it — satisfying the
   shared-behavior policy in CLAUDE.md.

### Constraints from CLAUDE.md to respect

- **Typing-latency-sensitive paths.** `StripView`'s container will sit in the same
  hosting chain as terminals. Do not add per-keystroke work to any `hitTest`/render hot
  path; keep the `isPointerEvent`-style gating used in `TerminalWindowPortal.swift`. Pane
  hosts must keep `mouseDownCanMoveWindow = false` like Bonsplit's
  `NonDraggableHostingView` (`SplitNodeView.swift:61`) so tab/strip clicks aren't eaten by
  window-drag detection in minimal mode.
- **Snapshot boundary.** If the strip renders columns via `ForEach`/`LazyHStack`, rows
  below that boundary must receive **immutable value snapshots + closure action bundles
  only** — no `@ObservedObject`/`@EnvironmentObject`/`@Bindable`/`let store:` references in
  the row subtree (the `IndexSectionActions` pattern in
  `Sources/SessionIndexView.swift`). The pure `StripLayout` value type makes this natural:
  hand each column its `(id, CGRect, contentSnapshot)`, never the store.
- **No state mutation in view-body computations.** Scroll-offset / focus reconciliation
  must run in a `reload()` completion, `didSet`, or an explicit action callback — never
  inside the projection that feeds `ForEach`. Keep all `scrollOffset` math in the pure
  model ops and invoke them from action handlers, not from `body`.
- **One type per file / docs.** New public types under a `Packages/` strip package each
  get their own file and a DocC `///` doc comment per the package policy.

### Why not extend Bonsplit instead

Adding fixed widths to `SplitState` would mean teaching `computePaneBounds`
(`SplitNode.swift:85`), `buildExternalTree` (`BonsplitController.swift:751`), the
`NSSplitView` coordinator (`SplitContainerView.swift`), `SplitEqualizer`, divider drag,
and the resize-clamp logic to understand a second geometry mode — and Bonsplit is a shared
vendored submodule with its own test suite. A parallel strip strategy that *reuses* panes
for the vertical axis but owns the horizontal axis + scroll offset is a smaller, isolated,
fully-testable change that leaves the proven tiling engine untouched.
