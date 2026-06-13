# niri Overview Live Color Feed — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the niri overview's monochrome, frozen text-snapshot tiles with live full-color tiles — a throttled IOSurface mirror of each currently-rendering (on-screen) column, and a frozen color snapshot (text fallback) for off-screen columns.

**Architecture:** Each terminal is a window-level `CAMetalLayer` (`GhosttyMetalLayer`) whose presented drawable is reachable as `layer.contents` (an `IOSurfaceRef`). A small mirror `CALayer` points its own `contents` at that IOSurface and scales it down for free — the source never resizes, so it never reflows. A refcounted `.ghosttyDidRenderFrame` notification drives refreshes, coalesced by a pure throttle (~12fps). Off-screen columns (already not rendering before the overview) get a one-time frozen snapshot.

**Tech Stack:** Swift / AppKit / SwiftUI / Core Animation (CALayer, IOSurface), Ghostty Metal portal, Swift Testing. Pure niri logic lives in the `CmuxStripLayout` package.

---

## Spike-determined branch

Task 1 is a manual spike that decides the **suppression mechanism** for keeping previously-visible columns rendering while not bleeding over the overview:
- **Branch A (preferred): hidden-in-place** — keep occlusion on, set the host view `isHidden` / alpha 0. Use if frames keep coming.
- **Branch B (fallback): parked off-screen** — keep the host full-size but moved outside the viewport (like the fullscreen parked-column trick at `StripCanvasView.swift:232`).
- **Branch C (degrade): no live tiles** — if even on-screen columns stall while suppressed, capture frozen color snapshots of every column at open and skip live mirroring. Still strictly better than today.

Tasks 5–7 contain the code for **Branch A**; each notes the one-line change for Branch B and the degrade path for C. Do not start Task 5 until Task 1 records an outcome.

## File Structure

**New (pure, in `CmuxStripLayout` package — niri strip domain, tested via `swift test`):**
- `Packages/CmuxStripLayout/Sources/CmuxStripLayout/FrameRefreshThrottle.swift` — coalescing throttle (dirty set + interval clock).
- `Packages/CmuxStripLayout/Sources/CmuxStripLayout/OverviewTileMode.swift` — `OverviewTileMode` enum + `OverviewTileSource` + `overviewTileMode(for:)` pure selector.
- `Packages/CmuxStripLayout/Tests/CmuxStripLayoutTests/FrameRefreshThrottleTests.swift`
- `Packages/CmuxStripLayout/Tests/CmuxStripLayoutTests/OverviewTileModeTests.swift`

**New (AppKit, in app target):**
- `Sources/OverviewMirrorView.swift` — layer-backed `NSView` that mirrors a source surface layer's IOSurface (live) or shows a frozen `CGImage` / nothing.
- `Sources/OverviewMirrorTile.swift` — `NSViewRepresentable` SwiftUI wrapper that resolves a window's tile mode and drives the mirror.

**Modified:**
- `Sources/StripPanelBridge.swift` — add `stripSourceSurfaceLayer(for:)` and `stripCaptureThumbnailImage(for:)` to the protocol.
- The bridge implementation file (whatever conforms to `StripPanelBridge`; find with grep in Task 4).
- `Sources/WorkspaceStripController.swift` — overview-session lifecycle: render-frame token, per-column render-visibility set, frozen-baseline capture, throttle ownership.
- `Sources/StripCanvasView.swift` — overview visibility gate: previously-visible columns render-but-suppressed; off-screen occluded.
- `Sources/StripWorkspaceView.swift` — `overviewTile` hosts `OverviewMirrorTile` instead of `windowMiniScreen` `Text`.
- `docs/niri-mode.md` — update the "Thumbnails — decision" section.

---

## Task 1: Spike — does a suppressed-but-unoccluded column keep rendering?

**Files:**
- Temporary probe edits in `Sources/StripCanvasView.swift` and a `cmuxDebugLog` call. **Reverted at the end of this task** — no production code lands here.

- [ ] **Step 1: Add a frame-counter probe.** In `Sources/GhosttyTerminalView.swift`, the `.ghosttyDidRenderFrame` notification already fires per surface while demand is held. Add a temporary `#if DEBUG` observer in `StripCanvasViewController.reconcile` (or `viewDidLayout`) that, while `isOverviewActive`, retains rendered-frame notifications (`GhosttyNSView.retainRenderedFrameNotifications()`, store the closure) and logs each `.ghosttyDidRenderFrame`:

```swift
#if DEBUG
// TEMP SPIKE — remove in Task 1 cleanup.
private var spikeToken: (() -> Void)?
private var spikeObs: NSObjectProtocol?
func spikeStart() {
    spikeToken = GhosttyNSView.retainRenderedFrameNotifications()
    spikeObs = NotificationCenter.default.addObserver(
        forName: .ghosttyDidRenderFrame, object: nil, queue: .main
    ) { note in
        let v = note.object as AnyObject
        let seed = ((v as? NSView)?.layer?.contents).map { c -> UInt32 in
            CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID()
                ? IOSurfaceGetSeed(c as! IOSurfaceRef) : 0
        } ?? 0
        cmuxDebugLog("spike.frame obj=\(ObjectIdentifier(v)) seed=\(seed)")
    }
}
#endif
```

- [ ] **Step 2: Suppress one previously-visible column without occluding it.** In `reconcile`, when `isOverviewActive`, for the focused column set `existing.controller.view.isHidden = true` but DO NOT let `isVisibleInUI` go false for it (temporarily hardcode that one column's `buildContent` visibility argument to `true` via a probe flag). Leave the others as-is.

- [ ] **Step 3: Build and run the tagged debug app.**

Run: `./scripts/reload.sh --tag niri-overview-spike --launch`
Then in the app: enable niri mode, open ≥2 columns, start `while true; do date; sleep 1; done` in the focused column, open the overview (`⌃⌥V`), and watch the log:
`tail -f /tmp/cmux-debug-niri-overview-spike.log | grep spike.frame`

- [ ] **Step 4: Record the outcome.** Append a short result to the spec under a new "## Spike result" heading in `docs/superpowers/specs/2026-06-02-niri-overview-live-color-design.md`:
  - If `spike.frame` keeps logging with an **advancing `seed`** for the hidden column → **Branch A** (hidden-in-place). 
  - If frames stop when hidden but continue when the host is parked off-screen (move its frame to `CGRect(x: -100000, ...)` instead of `isHidden`) → **Branch B**.
  - If neither keeps frames flowing → **Branch C** (degrade to frozen-only).

- [ ] **Step 5: Revert all probe edits.** Remove the `#if DEBUG` spike code. `git diff` must show no changes to `StripCanvasView.swift` / `GhosttyTerminalView.swift` except (none).

Run: `git status` → only the spec file modified.

- [ ] **Step 6: Commit the spike result.**

```bash
git add docs/superpowers/specs/2026-06-02-niri-overview-live-color-design.md
git commit -m "niri overview: record live-feed spike result (branch X)"
```

---

## Task 2: Pure frame-refresh throttle (TDD)

**Files:**
- Create: `Packages/CmuxStripLayout/Sources/CmuxStripLayout/FrameRefreshThrottle.swift`
- Test: `Packages/CmuxStripLayout/Tests/CmuxStripLayoutTests/FrameRefreshThrottleTests.swift`

- [ ] **Step 1: Write the failing test.**

```swift
import Testing
@testable import CmuxStripLayout

@Suite struct FrameRefreshThrottleTests {
    private func id(_ n: Int) -> StripWindowID { StripWindowID(UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!) }

    @Test func drainBeforeIntervalReturnsEmpty() {
        var t = FrameRefreshThrottle(interval: 0.1, startTime: 0)
        t.markDirty(id(1))
        #expect(t.drain(now: 0.05) == [])
    }

    @Test func drainAfterIntervalReturnsAndClears() {
        var t = FrameRefreshThrottle(interval: 0.1, startTime: 0)
        t.markDirty(id(1)); t.markDirty(id(2))
        #expect(t.drain(now: 0.1) == [id(1), id(2)])
        #expect(t.drain(now: 0.25) == [])          // nothing dirty after a drain
    }

    @Test func coalescesRepeatedMarks() {
        var t = FrameRefreshThrottle(interval: 0.1, startTime: 0)
        t.markDirty(id(1)); t.markDirty(id(1)); t.markDirty(id(1))
        #expect(t.drain(now: 0.2) == [id(1)])
    }

    @Test func reflectsLatestDirtySetAcrossWindows() {
        var t = FrameRefreshThrottle(interval: 0.1, startTime: 0)
        t.markDirty(id(1))
        _ = t.drain(now: 0.1)
        t.markDirty(id(2))
        #expect(t.drain(now: 0.25) == [id(2)])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `cd Packages/CmuxStripLayout && swift test --filter FrameRefreshThrottleTests`
Expected: FAIL — "cannot find 'FrameRefreshThrottle' in scope".

- [ ] **Step 3: Write the minimal implementation.**

```swift
import Foundation

/// Coalesces a stream of per-window "needs refresh" marks into at most one batch per ``interval``.
///
/// The niri overview mirrors live terminal frames into tiles. Terminals can emit frames far faster
/// than the overview needs to repaint, so each ``markDirty(_:)`` records intent and ``drain(now:)``
/// returns the accumulated set only when at least ``interval`` seconds have elapsed since the last
/// drain, clearing it. Pure and clock-injected so it is fully unit-testable without a timer.
public struct FrameRefreshThrottle: Sendable {
    /// Minimum seconds between drains.
    public let interval: TimeInterval
    private var dirty: Set<StripWindowID> = []
    private var lastDrain: TimeInterval

    /// Creates a throttle.
    /// - Parameters:
    ///   - interval: Minimum seconds between non-empty drains (e.g. `1.0 / 12` for ~12fps).
    ///   - startTime: The clock value treated as the last drain time.
    public init(interval: TimeInterval, startTime: TimeInterval) {
        self.interval = interval
        self.lastDrain = startTime
    }

    /// Records that `id`'s tile needs a refresh on the next due drain.
    public mutating func markDirty(_ id: StripWindowID) { dirty.insert(id) }

    /// Returns the windows to refresh if ``interval`` has elapsed since the last drain, clearing
    /// the set and resetting the clock; otherwise returns an empty set and changes nothing.
    /// - Parameter now: The current clock value (same time base as `startTime`).
    public mutating func drain(now: TimeInterval) -> Set<StripWindowID> {
        guard now - lastDrain >= interval, !dirty.isEmpty else { return [] }
        lastDrain = now
        let out = dirty
        dirty.removeAll(keepingCapacity: true)
        return out
    }
}
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `cd Packages/CmuxStripLayout && swift test --filter FrameRefreshThrottleTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit.**

```bash
git add Packages/CmuxStripLayout/Sources/CmuxStripLayout/FrameRefreshThrottle.swift \
        Packages/CmuxStripLayout/Tests/CmuxStripLayoutTests/FrameRefreshThrottleTests.swift
git commit -m "niri overview: pure FrameRefreshThrottle (~12fps coalescer)"
```

---

## Task 3: Pure tile-mode selector (TDD)

**Files:**
- Create: `Packages/CmuxStripLayout/Sources/CmuxStripLayout/OverviewTileMode.swift`
- Test: `Packages/CmuxStripLayout/Tests/CmuxStripLayoutTests/OverviewTileModeTests.swift`

- [ ] **Step 1: Write the failing test.**

```swift
import Testing
@testable import CmuxStripLayout

@Suite struct OverviewTileModeTests {
    @Test func renderingSourceIsLive() {
        let s = OverviewTileSource(isRendering: true, hasFrozenImage: true, hasText: true)
        #expect(overviewTileMode(for: s) == .live)
    }
    @Test func notRenderingWithFrozenImageIsFrozen() {
        let s = OverviewTileSource(isRendering: false, hasFrozenImage: true, hasText: true)
        #expect(overviewTileMode(for: s) == .frozen)
    }
    @Test func notRenderingNoImageFallsBackToText() {
        let s = OverviewTileSource(isRendering: false, hasFrozenImage: false, hasText: true)
        #expect(overviewTileMode(for: s) == .text)
    }
    @Test func nothingAvailableStillText() {
        let s = OverviewTileSource(isRendering: false, hasFrozenImage: false, hasText: false)
        #expect(overviewTileMode(for: s) == .text)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `cd Packages/CmuxStripLayout && swift test --filter OverviewTileModeTests`
Expected: FAIL — "cannot find 'overviewTileMode' in scope".

- [ ] **Step 3: Write the minimal implementation.**

```swift
/// How a single niri-overview tile should present one window's content.
public enum OverviewTileMode: Equatable, Sendable {
    /// Mirror the source surface's live IOSurface, refreshed while the overview is open.
    case live
    /// Show a one-time color snapshot captured when the overview opened.
    case frozen
    /// Show the monochrome scaled-text snapshot (deepest fallback).
    case text
}

/// The inputs that decide a tile's ``OverviewTileMode``.
public struct OverviewTileSource: Equatable, Sendable {
    /// Whether the source surface is actively producing Metal frames right now.
    public var isRendering: Bool
    /// Whether a frozen color snapshot was captured for this window.
    public var hasFrozenImage: Bool
    /// Whether a text snapshot is available.
    public var hasText: Bool

    /// Creates a tile source descriptor.
    public init(isRendering: Bool, hasFrozenImage: Bool, hasText: Bool) {
        self.isRendering = isRendering
        self.hasFrozenImage = hasFrozenImage
        self.hasText = hasText
    }
}

/// Picks the tile presentation: ``OverviewTileMode/live`` when the source renders, else the best
/// available frozen fallback (``OverviewTileMode/frozen`` then ``OverviewTileMode/text``).
public func overviewTileMode(for source: OverviewTileSource) -> OverviewTileMode {
    if source.isRendering { return .live }
    if source.hasFrozenImage { return .frozen }
    return .text
}
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `cd Packages/CmuxStripLayout && swift test --filter OverviewTileModeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit.**

```bash
git add Packages/CmuxStripLayout/Sources/CmuxStripLayout/OverviewTileMode.swift \
        Packages/CmuxStripLayout/Tests/CmuxStripLayoutTests/OverviewTileModeTests.swift
git commit -m "niri overview: pure OverviewTileMode selector (live/frozen/text)"
```

---

## Task 4: Bridge API — source surface layer + color snapshot

**Files:**
- Modify: `Sources/StripPanelBridge.swift` (protocol)
- Modify: the conforming type (find first)

- [ ] **Step 1: Find the bridge implementation.**

Run: `grep -rln "StripPanelBridge" Sources/ | grep -v StripPanelBridge.swift`
Then within those, find the one with `func stripCaptureThumbnailText(for`:
Run: `grep -rln "func stripCaptureThumbnailText" Sources/`

- [ ] **Step 2: Extend the protocol.** In `Sources/StripPanelBridge.swift`, after `stripCaptureThumbnailText`:

```swift
    /// The live Core Animation layer backing the panel's focused terminal surface (the
    /// `GhosttyMetalLayer`), or `nil` for non-terminal/headless panels. Used by the niri overview
    /// to mirror the surface's presented `IOSurface` into a scaled tile without resizing (and thus
    /// without reflowing) the source.
    func stripSourceSurfaceLayer(for panelID: UUID) -> CALayer?

    /// A one-time color snapshot of the panel's terminal as a `CGImage`, captured from the current
    /// presented `IOSurface`. Returns `nil` if the surface has no recent frame. Used to freeze
    /// off-screen overview tiles in color.
    func stripCaptureThumbnailImage(for panelID: UUID) -> CGImage?
```

Add `import QuartzCore` / `import CoreGraphics` to the file if not present.

- [ ] **Step 3: Implement in the conforming type.** Mirror the existing `stripCaptureThumbnailText` path (panelID → terminal surface → surface `NSView`). Return `surfaceView.layer` for the layer method. For the image method, read the layer's IOSurface contents and convert:

```swift
    func stripSourceSurfaceLayer(for panelID: UUID) -> CALayer? {
        // Reuse the same panelID -> GhosttyNSView resolution as stripCaptureThumbnailText.
        guard let surfaceView = ghosttySurfaceView(forPanel: panelID) else { return nil }
        return surfaceView.layer
    }

    func stripCaptureThumbnailImage(for panelID: UUID) -> CGImage? {
        guard let layer = stripSourceSurfaceLayer(for: panelID),
              let contents = layer.contents,
              CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        let surface = contents as! IOSurfaceRef
        let ci = CIImage(ioSurface: surface)
        let ctx = CIContext(options: nil)
        return ctx.createCGImage(ci, from: ci.extent)
    }
```

If no existing `ghosttySurfaceView(forPanel:)` helper exists, factor the surface lookup that `stripCaptureThumbnailText` already does into one and reuse it (DRY). Add `import CoreImage`.

- [ ] **Step 4: Verify it compiles.**

Run: `xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-niri-overview build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit.**

```bash
git add Sources/StripPanelBridge.swift <conforming-file>
git commit -m "niri overview: bridge access to live surface layer + color snapshot"
```

---

## Task 5: OverviewMirrorView (AppKit) — Branch A

**Files:**
- Create: `Sources/OverviewMirrorView.swift`

> Branch B: identical view; the source stays full-size off-screen, so no view change is needed — only Task 7 differs. Branch C: this view is still used, but only ever in `.frozen` mode.

- [ ] **Step 1: Write the view.**

```swift
import AppKit
import QuartzCore

/// A layer-backed view that mirrors a terminal surface's presented `IOSurface` into a scaled tile
/// for the niri overview. Setting ``mirrorLayer``'s `contents` to the source's `IOSurface` and
/// using `contentsGravity = .resizeAspectFill` scales the live frame down for free — the source
/// surface is never resized, so it never reflows. Supports a frozen `CGImage` for off-screen
/// columns that are no longer rendering.
final class OverviewMirrorView: NSView {
    private let mirrorLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        mirrorLayer.contentsGravity = .resizeAspectFill
        mirrorLayer.masksToBounds = true
        mirrorLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(mirrorLayer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mirrorLayer.frame = bounds
        CATransaction.commit()
    }

    /// Mirrors `sourceLayer`'s current presented `IOSurface`. Call on each throttled refresh.
    /// Does nothing if the source has no IOSurface-backed contents yet.
    func refreshLive(from sourceLayer: CALayer) {
        guard let contents = sourceLayer.contents,
              CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mirrorLayer.contents = contents
        CATransaction.commit()
    }

    /// Shows a one-time frozen color snapshot (off-screen columns).
    func showFrozen(_ image: CGImage) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mirrorLayer.contents = image
        CATransaction.commit()
    }
}
```

- [ ] **Step 2: Verify it compiles.**

Run: `xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-niri-overview build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit.**

```bash
git add Sources/OverviewMirrorView.swift
git commit -m "niri overview: OverviewMirrorView (scaled IOSurface mirror)"
```

---

## Task 6: Controller lifecycle — token, render-visibility set, frozen baselines, throttle

**Files:**
- Modify: `Sources/WorkspaceStripController.swift`

- [ ] **Step 1: Add overview live-session state.** Below the `overviewThumbnails` property (line ~59):

```swift
    /// Per-window frozen color snapshots captured when the overview opens (off-screen columns).
    /// Keyed by panel id (``StripWindowID/raw``). Published so tiles can read them.
    @Published private(set) var overviewFrozenImages: [UUID: CGImage] = [:]

    /// The set of column ids that were on-screen (rendering) when the overview opened, and are
    /// therefore mirrored live. Drives both the canvas render-but-suppress gate and tile mode.
    @Published private(set) var overviewLiveColumnIDs: Set<StripColumnID> = []

    /// Held for the whole overview session so `.ghosttyDidRenderFrame` keeps firing.
    private var renderFrameToken: (() -> Void)?
    /// Coalesces frame notifications into ~12fps mirror refreshes.
    private var refreshThrottle = FrameRefreshThrottle(interval: 1.0 / 12.0, startTime: 0)
    /// Window ids needing a mirror refresh, observed by the view layer.
    @Published private(set) var pendingMirrorRefresh: Set<StripWindowID> = []
```

- [ ] **Step 2: Compute the live set + capture frozen baselines in `enterOverview()`.** Replace the body of `enterOverview()`:

```swift
    func enterOverview() {
        guard mode == .strip, !isOverviewActive, !layout.columns.isEmpty else { return }
        clearColumnFullscreen()
        savedFocusBeforeOverview = layout.focusedColumnIndex
        savedOffsetBeforeOverview = layout.scrollOffset
        overviewSelectionIndex = layout.focusedColumnIndex

        // On-screen columns (rendering now) -> live; the rest -> frozen.
        let viewport = CGRect(x: 0, y: 0, width: viewportWidth, height: 1)
        let visibleIDs = Set(layout.columnFrames(in: viewport).filter(\.isVisible).map(\.id))
        overviewLiveColumnIDs = visibleIDs

        captureOverviewThumbnails()          // text fallback (all columns)
        captureFrozenImages(excluding: visibleIDs)   // color freeze for off-screen columns

        renderFrameToken = GhosttyNSView.retainRenderedFrameNotifications()
        isOverviewActive = true
    }

    /// Captures a one-time color snapshot for every column NOT in `live` (off-screen, not
    /// rendering live).
    private func captureFrozenImages(excluding live: Set<StripColumnID>) {
        guard let bridge else { return }
        var images: [UUID: CGImage] = [:]
        for column in layout.columns where !live.contains(column.id) {
            for window in column.windows {
                if let img = bridge.stripCaptureThumbnailImage(for: window.raw) {
                    images[window.raw] = img
                }
            }
        }
        overviewFrozenImages = images
    }
```

- [ ] **Step 3: Add the frame-notification observer + throttle drain.** Add a method and call it from `enterOverview()` (after `isOverviewActive = true`) to start observing, and stop in cleanup:

```swift
    private var frameObserver: NSObjectProtocol?
    private var refreshTimer: Timer?

    private func startMirrorRefresh() {
        frameObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let panelID = self.bridge?.stripPanelID(forSurfaceObject: note.object) else { return }
            self.refreshThrottle.markDirty(StripWindowID(panelID))
        }
        // ~12fps drain; CACurrentMediaTime base matches FrameRefreshThrottle expectations.
        refreshThrottle = FrameRefreshThrottle(interval: 1.0 / 12.0, startTime: CACurrentMediaTime())
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let due = self.refreshThrottle.drain(now: CACurrentMediaTime())
            if !due.isEmpty { self.pendingMirrorRefresh = due }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopMirrorRefresh() {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        renderFrameToken?(); renderFrameToken = nil
        pendingMirrorRefresh = []
        overviewFrozenImages = [:]
        overviewLiveColumnIDs = []
    }
```

Add `import QuartzCore` for `CACurrentMediaTime`. This needs a new bridge method `stripPanelID(forSurfaceObject:)` mapping a `.ghosttyDidRenderFrame` object (the `GhosttyNSView`) back to a panel id — add it to `StripPanelBridge` and implement it via the same surface registry used in Task 4 (reverse lookup). Call `startMirrorRefresh()` at the end of `enterOverview()`.

- [ ] **Step 4: Tear down in both exits.** In `cancelOverview()` and `selectOverviewColumn()`, after setting `isOverviewActive = false`, call `stopMirrorRefresh()`. Replace the existing `overviewThumbnails = [:]` lines (keep them; just add the call).

- [ ] **Step 5: Verify it compiles.**

Run: `xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-niri-overview build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit.**

```bash
git add Sources/WorkspaceStripController.swift Sources/StripPanelBridge.swift <conforming-file>
git commit -m "niri overview: controller live-session (token, live set, frozen, throttle)"
```

---

## Task 7: Canvas gate — render previously-visible columns while suppressing them — Branch A

**Files:**
- Modify: `Sources/StripCanvasView.swift`

- [ ] **Step 1: Pass the live set into the canvas.** In `StripCanvasView.updateNSViewController`, the `sync(...)` call and `SyncInputs` need `overviewLiveColumnIDs`. Thread `stripController.overviewLiveColumnIDs` through `sync` into `SyncInputs`.

- [ ] **Step 2: Change the per-column visibility argument.** In `columnContent`, the `isVisibleInUI` currently goes false for all columns when overview is active. Change it so live columns stay un-occluded:

```swift
                    isVisibleInUI: isWorkspaceVisible
                        && (!stripController.isOverviewActive
                            || stripController.overviewLiveColumnIDs.contains(column.id))
                        && (!stripController.isColumnFullscreen || isColumnFocused),
```

- [ ] **Step 3: Suppress live columns visually (Branch A).** In `reconcile`, after positioning, when `isOverviewActive`, hide live columns' host views so the portal doesn't bleed over the overview backdrop while still rendering. Add to the per-column loop:

```swift
            // Overview: live-mirrored columns keep rendering (un-occluded) but their host view is
            // hidden so the portal doesn't bleed over the overview tiles. (Branch A.)
            if isOverviewActive {
                existing.controller.view.isHidden = inputs.overviewLiveColumnIDs.contains(column.id)
            } else if existing.controller.view.isHidden {
                existing.controller.view.isHidden = false
            }
```

> **Branch B instead:** do NOT set `isHidden`; instead set `frame = CGRect(x: -(viewport.width + column.width + 200), y: 0, width: column.width, height: viewport.height)` for live columns while `isOverviewActive`, matching the fullscreen parked-column trick. **Branch C:** skip Tasks 7's render-keep-alive entirely; leave the original blanket `isVisibleInUI = false` and rely only on frozen images (Task 6 then captures frozen images for ALL columns).

- [ ] **Step 4: Include the live set in the content-rebuild key.** In the `key` array (line ~240), add `inputs.overviewLiveColumnIDs.contains(column.id) ? "L" : "-"` so toggling live-ness rebuilds.

- [ ] **Step 5: Verify it compiles.**

Run: `xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-niri-overview build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit.**

```bash
git add Sources/StripCanvasView.swift
git commit -m "niri overview: keep on-screen columns rendering while suppressed (branch A)"
```

---

## Task 8: OverviewMirrorTile + wire into StripWorkspaceView

**Files:**
- Create: `Sources/OverviewMirrorTile.swift`
- Modify: `Sources/StripWorkspaceView.swift`

- [ ] **Step 1: Write the SwiftUI wrapper.**

```swift
import AppKit
import CmuxStripLayout
import SwiftUI

/// SwiftUI host for one window's overview tile content: a live IOSurface mirror, a frozen color
/// snapshot, or (fallback) nothing — `StripWorkspaceView` overlays the text snapshot beneath it.
struct OverviewMirrorTile: NSViewRepresentable {
    let panelID: UUID
    let windowID: StripWindowID
    let mode: OverviewTileMode
    let sourceLayer: CALayer?
    let frozenImage: CGImage?
    /// Set of windows the controller flagged for a throttled refresh this tick.
    let pendingRefresh: Set<StripWindowID>

    func makeNSView(context: Context) -> OverviewMirrorView { OverviewMirrorView() }

    func updateNSView(_ view: OverviewMirrorView, context: Context) {
        switch mode {
        case .live:
            if let sourceLayer { view.refreshLive(from: sourceLayer) }
        case .frozen:
            if let frozenImage { view.showFrozen(frozenImage) }
        case .text:
            break
        }
    }
}
```

- [ ] **Step 2: Replace `windowMiniScreen`'s `Text` with the mirror, text underneath.** In `Sources/StripWorkspaceView.swift`, change `windowMiniScreen` to overlay the mirror over the text fallback. The tile mode comes from the controller's published state:

```swift
    @ViewBuilder
    private func windowMiniScreen(text: String, panelID: UUID, windowID: StripWindowID,
                                  columnID: StripColumnID, isActiveWindow: Bool,
                                  isStacked: Bool, accent: Color) -> some View {
        let isLive = stripController.overviewLiveColumnIDs.contains(columnID)
        let frozen = stripController.overviewFrozenImages[panelID]
        let mode = overviewTileMode(for: OverviewTileSource(
            isRendering: isLive, hasFrozenImage: frozen != nil, hasText: !text.isEmpty))
        ZStack {
            if mode == .text {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 5.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(isActiveWindow ? 0.82 : 0.5))
                    .lineLimit(nil).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 3).padding(.vertical, 2)
            } else {
                // Passing `pendingRefresh` as a property makes SwiftUI re-run updateNSView
                // whenever the controller publishes a new throttled refresh set, which is where
                // the live mirror re-reads its IOSurface. Do NOT add `.id(...)` here — that would
                // tear down and recreate the NSView every refresh.
                OverviewMirrorTile(
                    panelID: panelID, windowID: windowID, mode: mode,
                    sourceLayer: isLive ? stripController.bridge?.stripSourceSurfaceLayer(for: panelID) : nil,
                    frozenImage: frozen,
                    pendingRefresh: stripController.pendingMirrorRefresh)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(isStacked ? 0.30 : 0.0)))
        .overlay(isStacked ? RoundedRectangle(cornerRadius: 3)
            .strokeBorder(isActiveWindow ? accent.opacity(0.9) : Color.white.opacity(0.12),
                          lineWidth: isActiveWindow ? 1.5 : 0.5) : nil)
        .clipped()
    }
```

Update the call site in `overviewTile` to pass `panelID`, `windowID`, and `column.id`. The `windowTexts` loop currently maps over strings only — change `stripController.overviewThumbnails[column.id]` use to iterate `column.windows` (so each entry has its `windowID`/`panelID`), pairing with the text array by index. Keep `bridge` access off the row body where possible; here `stripController` is already an `@ObservedObject` on `StripWorkspaceView`, consistent with existing code.

- [ ] **Step 3: Build the tagged app and verify it launches.**

Run: `./scripts/reload.sh --tag niri-overview --launch`
Expected: `BUILD SUCCEEDED`, app launches. Provide the `file://` App-path link to the user.

- [ ] **Step 4: Commit.**

```bash
git add Sources/OverviewMirrorTile.swift Sources/StripWorkspaceView.swift
git commit -m "niri overview: live/frozen color tiles in StripWorkspaceView"
```

---

## Task 9: Manual verification + docs

**Files:**
- Modify: `docs/niri-mode.md`

- [ ] **Step 1: Dogfood the live feed.** In the tagged app: niri mode, ≥3 columns, run `while true; do date; done` in two on-screen columns, scroll a third off-screen, open the overview (`⌃⌥V`). Verify:
  - On-screen columns' tiles show **live, color, updating** terminal content (~12fps).
  - The off-screen column's tile shows a **color frozen** snapshot (or text if it never rendered).
  - No terminal "bleed" over the overview backdrop; closing the overview restores the prior viewport and focus.
  - Typing latency in normal mode is unaffected (open/close overview a few times, type in a terminal).

- [ ] **Step 2: Update the doc.** In `docs/niri-mode.md`, rewrite the "**Thumbnails — decision:**" paragraph to describe the new behavior: live IOSurface mirror for on-screen columns (no reflow — the source renders full-size, the tile scales its IOSurface), throttled ~12fps; frozen color snapshot for off-screen columns; text snapshot as the deepest fallback. Note the spike outcome (Branch A/B/C) and why.

- [ ] **Step 3: Run the pure test suite.**

Run: `cd Packages/CmuxStripLayout && swift test`
Expected: PASS (existing + the two new suites).

- [ ] **Step 4: Commit.**

```bash
git add docs/niri-mode.md
git commit -m "niri overview: document live color feed tiles"
```

- [ ] **Step 5: Request code review** via the superpowers:requesting-code-review skill before finishing the branch.

---

## Self-Review notes

- **Spec coverage:** live mirror (Tasks 5,7,8), frozen off-screen (Task 6), text fallback (Task 8), ~12fps throttle (Task 2,6), IOSurface mirror without reflow (Task 5), tile-mode selection (Task 3), session lifecycle token/visibility (Task 6,7), spike (Task 1), docs (Task 9), behavioral tests for the pure pieces (Tasks 2,3). The spec's "session lifecycle test seam" is partially covered by the pure tests; a controller-level token-count test is **optional** and noted here rather than forced, because `WorkspaceStripController` is `@MainActor` app-target code requiring pbxproj test wiring — add only if the executor wants it.
- **Type consistency:** `FrameRefreshThrottle(interval:startTime:)`, `markDirty(_:)`, `drain(now:)`, `overviewTileMode(for:)`, `OverviewTileSource(isRendering:hasFrozenImage:hasText:)`, `OverviewMirrorView.refreshLive(from:)`/`showFrozen(_:)`, `overviewLiveColumnIDs`, `overviewFrozenImages`, `pendingMirrorRefresh`, `stripSourceSurfaceLayer(for:)`, `stripCaptureThumbnailImage(for:)`, `stripPanelID(forSurfaceObject:)` — used consistently across Tasks 2–8.
- **Spike gate:** Tasks 5–7 code is Branch A; Branch B/C deltas are inline. Do not start Task 5 before Task 1 records an outcome.
