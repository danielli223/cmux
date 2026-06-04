import AppKit
import CmuxStripLayout
import CoreGraphics
import Foundation
import QuartzCore

/// Per-workspace controller that owns the niri-style strip and bridges it to real cmux
/// terminal panels.
///
/// The pure geometry/structure lives in ``StripLayout`` (a value type, fully unit-tested in
/// the `CmuxStripLayout` package). This controller is the thin, `@MainActor` glue that:
/// turns user/socket actions into ``StripLayout`` mutations, creates/closes real panels via
/// a ``StripPanelBridge``, and keeps cmux keyboard focus in sync with the focused column.
///
/// Identity: each strip window id wraps a panel UUID 1:1 (``StripWindowID/raw`` *is* the
/// panel id); column ids are synthetic. All structural decisions (insert-after-focused,
/// reveal-to-edge, no-resize) are delegated to ``StripLayout`` so this type stays small.
@MainActor
final class WorkspaceStripController: ObservableObject {
    /// The active layout mode. `.tiling` means the strip is dormant and Bonsplit renders.
    @Published private(set) var mode: WorkspaceLayoutMode = .tiling

    /// The strip model. Published so the view re-renders on structural/scroll changes.
    @Published private(set) var layout = StripLayout(gap: 8)

    /// The bridge to panel lifecycle/focus. Weak to avoid a retain cycle with ``Workspace``.
    weak var bridge: StripPanelBridge?

    /// The width (points) of a peeking sliver shown on each side of the strip: a snapshot of the
    /// adjacent column so the layout always reveals "there is more over here," the niri spatial cue.
    /// The live columns are inset by this on each side; the slivers fill the margins.
    static let columnPeekWidth: CGFloat = 44

    /// The **effective** viewport width the pure model lays columns out in: the actual content width
    /// minus a ``columnPeekWidth`` margin on each side. Two live columns fill this inset region, and
    /// the peek slivers occupy the margins. Pure model ops that pan/clamp use this.
    /// Seeded with a reasonable default so socket-driven ops before first layout still work.
    private(set) var viewportWidth: CGFloat = 1200 - 2 * columnPeekWidth

    /// The full content-area width (no peek inset). Used for the overview's own horizontal scroll,
    /// which spans the whole width.
    private(set) var actualViewportWidth: CGFloat = 1200

    /// The intrinsic width assigned to columns: **half the content area minus the inter-column
    /// gap**, derived from the live viewport so exactly two columns + the gap fill the screen
    /// (the third begins the horizontal scroll). Never a hardcoded constant.
    var newColumnWidth: CGFloat { max(200, ((viewportWidth - layout.gap) / 2).rounded()) }

    /// Whether niri-mode is currently active.
    var isStripMode: Bool { mode == .strip }

    /// Whether the focused column is temporarily expanded to fill the whole viewport — the
    /// niri-mode equivalent of "fullscreen / zoom a pane". A pure render state: it does not
    /// change any column ``StripColumn/width`` in the model, so toggling it off restores the
    /// strip exactly. Cleared by any focus/structural change (and by the overview), so it never
    /// outlives the column it was opened on.
    @Published private(set) var isColumnFullscreen = false

    // MARK: - Overview (zoom-out) state

    /// Whether the niri-style overview (zoom-out) is currently showing. A render + input mode
    /// over the same ``layout`` — it does not fork the column data.
    @Published private(set) var isOverviewActive = false

    /// The column the overview highlight is on. Becomes the focused column when selected.
    @Published private(set) var overviewSelectionIndex = 0

    /// How many tiles the readable, scrollable overview shows across at once.
    let overviewVisibleColumns = 4

    /// Horizontal scroll offset (points) of the overview's tile strip. The overview shows a few
    /// readable tiles and scrolls — the selection glides this to keep itself centred — rather than
    /// cramming every column to fit.
    @Published private(set) var overviewScrollOffset: CGFloat = 0

    /// Glides ``overviewScrollOffset`` so moving the overview highlight scrolls the tiles smoothly.
    private lazy var overviewAnimator = StripScrollAnimator(
        onStep: { [weak self] value in self?.overviewScrollOffset = value }
    )

    /// Per-column text thumbnails captured when the overview opens, keyed by ``StripColumnID``.
    /// Each value is one viewport-text snapshot **per stacked window** in the column (top to
    /// bottom), so a tabbed column shows all its terminals in the overview. Rendered as scaled
    /// text in the tiles — see `docs/niri-mode.md` for why text rather than live/snapshot pixels.
    @Published private(set) var overviewThumbnails: [StripColumnID: [String]] = [:]

    /// Per-window frozen color snapshots captured when the overview opens, keyed by panel id
    /// (``StripWindowID/raw``). Used for off-screen columns that are no longer rendering: their
    /// tiles show this color image rather than a live mirror or monochrome text.
    @Published private(set) var overviewFrozenImages: [UUID: CGImage] = [:]

    /// The column ids that were on-screen (actively rendering) when the overview opened, and are
    /// therefore mirrored **live**. Drives both the canvas render-but-suppress gate and the tile
    /// mode. Off-screen columns are absent and show a frozen snapshot.
    @Published private(set) var overviewLiveColumnIDs: Set<StripColumnID> = []

    /// Window ids whose live mirror should refresh this tick (published so the tile views observe
    /// it). Produced by draining ``refreshThrottle`` at ~12fps.
    @Published private(set) var pendingMirrorRefresh: Set<StripWindowID> = []

    /// Held for the whole overview session so `.ghosttyDidRenderFrame` keeps firing for the live
    /// columns. Released on overview exit.
    private var renderFrameToken: (() -> Void)?

    /// Coalesces per-surface frame notifications into ~12fps mirror refreshes.
    private var refreshThrottle = FrameRefreshThrottle(interval: 1.0 / 12.0, startTime: 0)

    /// Observes `.ghosttyDidRenderFrame` while the overview is open; marks the matching tile dirty.
    private var frameObserver: NSObjectProtocol?

    /// Drains ``refreshThrottle`` on a repeating timer while the overview is open.
    private var refreshTimer: Timer?

    /// Saved viewport (focused column + scroll offset) captured when the overview opens, so
    /// cancelling returns to the exact prior state.
    private var savedFocusBeforeOverview = 0
    private var savedOffsetBeforeOverview: CGFloat = 0

    /// Color snapshots of columns captured **while they were on-screen** (and therefore rendering),
    /// keyed by panel id. Because a terminal stops rendering once it scrolls off-screen (its surface
    /// goes to 0×0, with no IOSurface to mirror or freeze), the overview cannot snapshot an
    /// off-screen column on demand. Instead we cache each column's last on-screen frame here, refresh
    /// it as the user navigates past, and show it in the overview tile when the column is off-screen.
    private var snapshotCache: [UUID: CGImage] = [:]

    /// Timestamp of the last ``snapshotVisibleColumns(force:)`` so rapid (held-key) navigation does
    /// not run an image conversion on every keystroke.
    private var lastSnapshotTime: CFTimeInterval = 0

    // MARK: - Animated reveal (smooth keyboard navigation)

    /// True while a navigation glide is in flight. The canvas hides the live terminal portals and
    /// shows solid panels during the glide, so the moving columns cannot smear (the GPU portal
    /// re-reads its frame a runloop tick late, flashing the old position). Live content snaps back
    /// when the glide settles.
    @Published private(set) var isAnimatingScroll = false

    /// Animates the strip's ``StripLayout/scrollOffset`` so a focus or structural change glides the
    /// viewport instead of teleporting — the "scrolling window manager" feel. Steps the offset only;
    /// the canvas repositions its columns from it through the normal reconcile path.
    private lazy var scrollAnimator = StripScrollAnimator(
        onStep: { [weak self] offset in
            guard let self else { return }
            self.layout.setScrollOffset(offset, viewportWidth: self.viewportWidth)
        },
        onFinished: { [weak self] in
            self?.isAnimatingScroll = false
        }
    )

    /// Whether the user has asked macOS to minimize motion; when true, viewport changes jump.
    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Glides the viewport from `from` to the offset the model **just** jumped to. Call immediately
    /// after a layout mutation that changed ``StripLayout/scrollOffset``, passing the offset captured
    /// *before* the mutation. A no-op when the offset did not move or when reduce-motion is on (the
    /// model already sits at the destination).
    /// - Parameter from: The scroll offset captured before the mutation.
    private func animateViewport(from: CGFloat) {
        let to = layout.scrollOffset
        guard from != to else { return }
        guard !prefersReducedMotion else { return }
        layout.setScrollOffset(from, viewportWidth: viewportWidth) // rewind, then glide to `to`
        isAnimatingScroll = true
        scrollAnimator.animate(from: from, to: to)
    }

    /// Stops any in-flight glide immediately and restores the live terminals. Used by transitions
    /// (overview, mode toggle, viewport resize) that must not be fought by a stale animation.
    private func stopGlide() {
        scrollAnimator.cancel()
        if isAnimatingScroll { isAnimatingScroll = false }
    }

    // MARK: - Viewport

    /// Records the current viewport width (from the rendering `GeometryReader`) and re-clamps
    /// the scroll offset to it. Called from an action/`onChange`, never from `body` math.
    /// - Parameter width: The viewport width in points.
    func setViewportWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        let effective = max(1, width - 2 * Self.columnPeekWidth)
        let old = viewportWidth
        guard effective != old else { actualViewportWidth = width; return }
        stopGlide() // a width change re-pans; a stale glide would fight it
        actualViewportWidth = width
        viewportWidth = effective
        // Columns track the inset content area: recompute every column to the new half-width so two
        // fill the inset region (peek slivers in the margins), then re-pan the focused column.
        if old > 0, isStripMode {
            layout.setAllColumnWidths(newColumnWidth)
            layout.revealFocusedColumnForViewport(effective)
        } else {
            layout.setScrollOffset(layout.scrollOffset, viewportWidth: effective)
        }
    }

    // MARK: - Mode toggle

    /// Enables niri-mode, seeding the strip with one column per existing terminal panel (in
    /// visual order) and focusing the previously focused panel's column. No panels are
    /// created or destroyed; the Bonsplit tree is left intact for when the mode is disabled.
    func enableStripMode() {
        guard mode != .strip else { return }
        let seedIDs = bridge?.stripSeedPanelIDs ?? []
        let columns: [StripColumn] = seedIDs.map { panelID in
            StripColumn(
                id: StripColumnID(UUID()),
                width: newColumnWidth,
                windows: [StripWindowID(panelID)]
            )
        }
        if columns.isEmpty {
            // Degenerate: no terminals yet. Leave an empty strip; the next open seeds it.
            layout = StripLayout(gap: layout.gap)
        } else {
            let focusedPanel = bridge?.stripFocusedPanelID
            let focusedIndex = focusedPanel.flatMap { panelID in
                columns.firstIndex { $0.windows.first?.raw == panelID }
            } ?? 0
            layout = StripLayout(columns: columns, focusedColumnIndex: focusedIndex, gap: layout.gap)
            layout.revealFocusedColumnForViewport(viewportWidth)
        }
        mode = .strip
    }

    /// Disables niri-mode and returns to Bonsplit tiling. The strip model is retained (so
    /// re-enabling restores column order) but no longer drives rendering.
    func disableStripMode() {
        guard mode != .tiling else { return }
        stopGlide()
        isOverviewActive = false
        isColumnFullscreen = false
        mode = .tiling
    }

    /// Toggles between ``WorkspaceLayoutMode/tiling`` and ``WorkspaceLayoutMode/strip``.
    func toggleStripMode() {
        if mode == .strip { disableStripMode() } else { enableStripMode() }
    }

    // MARK: - Structural actions (niri verbs)

    /// Opens a new terminal in a brand-new column after the focused column, then pans to it.
    /// Sibling columns keep their exact widths (the core niri invariant).
    /// - Returns: The new panel's id, or `nil` if creation failed.
    @discardableResult
    func openColumn() -> UUID? {
        guard mode == .strip, let bridge else { return nil }
        clearColumnFullscreen()
        let afterPanel = layout.focusedColumn?.focusedWindow?.raw
        guard let newPanelID = bridge.stripCreateColumnTerminal(after: afterPanel) else { return nil }
        let column = StripColumn(
            id: StripColumnID(UUID()),
            width: newColumnWidth,
            windows: [StripWindowID(newPanelID)]
        )
        let from = layout.scrollOffset
        layout.insertColumn(column, viewportWidth: viewportWidth)
        bridge.stripFocusPanel(newPanelID)
        animateViewport(from: from)
        return newPanelID
    }

    /// Opens a new terminal stacked below the focused column's focused window. Other columns
    /// are untouched. niri "open a stacked window".
    /// - Returns: The new panel's id, or `nil` if creation failed.
    @discardableResult
    func openStackedWindow() -> UUID? {
        guard mode == .strip, let bridge,
              let belowPanel = layout.focusedColumn?.focusedWindow?.raw else { return nil }
        clearColumnFullscreen()
        guard let newPanelID = bridge.stripCreateStackedTerminal(below: belowPanel) else { return nil }
        layout.appendWindowToFocusedColumn(StripWindowID(newPanelID))
        bridge.stripFocusPanel(newPanelID)
        return newPanelID
    }

    /// Closes the focused column's focused window. If that empties the column, the column is
    /// removed and the gap collapses; otherwise focus moves within the remaining stack.
    func closeFocusedColumn() {
        guard mode == .strip, let bridge,
              var column = layout.focusedColumn,
              let panelID = column.focusedWindow?.raw else { return }
        clearColumnFullscreen()
        let from = layout.scrollOffset
        bridge.stripClosePanel(panelID)
        if column.windows.count <= 1 {
            layout.removeFocusedColumn(viewportWidth: viewportWidth)
        } else {
            // Remove just this window from the column's stack, keep the column.
            let idx = column.focusedWindowIndex
            column.windows.remove(at: idx)
            column.focusedWindowIndex = min(idx, column.windows.count - 1)
            layout.replaceFocusedColumn(with: column)
        }
        if let nextPanel = layout.focusedColumn?.focusedWindow?.raw {
            bridge.stripFocusPanel(nextPanel)
        }
        animateViewport(from: from)
    }

    // MARK: - Fullscreen (zoom a column)

    /// Toggles "fullscreen the focused column": the focused column renders at the full viewport,
    /// covering its neighbours, until toggled off or any other action clears it. This is the
    /// niri-mode answer to cmux's pane-zoom (`toggleSplitZoom`) — in strip mode the Bonsplit
    /// tree is dormant, so the shared zoom action routes here instead of resizing a dead pane.
    /// - Returns: `true` if the state changed (always, while a focused column exists).
    @discardableResult
    func toggleColumnFullscreen() -> Bool {
        guard mode == .strip, !isOverviewActive, layout.focusedColumn != nil else { return false }
        isColumnFullscreen.toggle()
        return true
    }

    /// Clears the fullscreen-column state if set. Called by every focus/structural action so the
    /// expansion never lingers on a column the user has navigated away from.
    private func clearColumnFullscreen() {
        if isColumnFullscreen { isColumnFullscreen = false }
    }

    // MARK: - Focus & movement

    /// Captures color snapshots of the columns currently on-screen (and rendering) into
    /// ``snapshotCache``, so the overview can show their color later when they are off-screen and no
    /// longer rendering. Throttled to ~0.4s so held-key navigation does not convert an image on every
    /// keystroke; pass `force` to bypass the throttle (e.g. when the overview is about to open).
    /// - Parameter force: When true, snapshot immediately regardless of the throttle.
    private func snapshotVisibleColumns(force: Bool = false) {
        guard mode == .strip, let bridge else { return }
        let now = CACurrentMediaTime()
        guard force || now - lastSnapshotTime > 0.4 else { return }
        lastSnapshotTime = now
        let viewport = CGRect(x: 0, y: 0, width: viewportWidth, height: 1)
        let visible = Set(layout.columnFrames(in: viewport).filter(\.isVisible).map(\.id))
        for column in layout.columns where visible.contains(column.id) {
            for window in column.windows {
                if let image = bridge.stripCaptureThumbnailImage(for: window.raw) {
                    snapshotCache[window.raw] = image
                }
            }
        }
    }

    /// The cached on-screen color snapshot for a panel, shown in place of the live terminal while the
    /// viewport glides (the live portal is hidden during motion so it cannot smear). The snapshot
    /// slides perfectly with the column; live content snaps back when the glide settles.
    /// - Parameter panelID: The panel whose last on-screen snapshot to show, if any.
    /// - Returns: The cached image, or `nil` if the column has not been on-screen yet this session.
    func glideSnapshot(for panelID: UUID?) -> CGImage? {
        guard let panelID else { return nil }
        return snapshotCache[panelID]
    }

    /// Moves column focus left/right, glides the viewport to reveal it, and focuses the landing panel.
    func focusColumn(_ direction: StripAxisDirection) {
        guard mode == .strip else { return }
        clearColumnFullscreen()
        snapshotVisibleColumns() // cache the columns we're leaving while they still have pixels
        let from = layout.scrollOffset
        if layout.focusColumn(direction, viewportWidth: viewportWidth) {
            syncFocusToModel()
            animateViewport(from: from)
        }
    }

    /// Moves window focus up/down within the focused column and focuses the landing panel.
    func focusWindow(_ direction: StripAxisDirection) {
        guard mode == .strip else { return }
        clearColumnFullscreen()
        if layout.focusWindow(direction) {
            syncFocusToModel()
        }
    }

    /// Reorders the focused column left/right on the strip; widths unchanged; viewport glides to follow.
    func moveColumn(_ direction: StripAxisDirection) {
        guard mode == .strip else { return }
        clearColumnFullscreen()
        snapshotVisibleColumns()
        let from = layout.scrollOffset
        if layout.moveColumn(direction, viewportWidth: viewportWidth) {
            animateViewport(from: from)
        }
    }

    // MARK: - Overview (zoom-out)

    /// Toggles the overview: opens it (saving the current viewport) or, if already open,
    /// cancels it (restoring the saved viewport).
    func toggleOverview() {
        guard mode == .strip else { return }
        if isOverviewActive { cancelOverview() } else { enterOverview() }
    }

    /// Opens the overview, capturing the current focused column and scroll offset so a later
    /// cancel restores them exactly. The highlight starts on the focused column.
    func enterOverview() {
        guard mode == .strip, !isOverviewActive, !layout.columns.isEmpty else { return }
        stopGlide()
        clearColumnFullscreen()
        savedFocusBeforeOverview = layout.focusedColumnIndex
        savedOffsetBeforeOverview = layout.scrollOffset
        overviewSelectionIndex = layout.focusedColumnIndex
        revealOverviewSelection(animated: false) // open already scrolled to the focused tile

        // Columns rendering now (on-screen in the pre-overview viewport) are mirrored live; the
        // rest show their last cached on-screen color snapshot. `isVisible` comes from the same pure
        // frame math the canvas uses.
        let viewport = CGRect(x: 0, y: 0, width: viewportWidth, height: 1)
        let visibleIDs = Set(layout.columnFrames(in: viewport).filter(\.isVisible).map(\.id))
        overviewLiveColumnIDs = visibleIDs

        snapshotVisibleColumns(force: true)         // freshen the cache for columns rendering now
        captureOverviewThumbnails()                 // text fallback when a column has no cached frame
        overviewFrozenImages = snapshotCache        // off-screen tiles show their last on-screen color
#if DEBUG
        let offscreen = layout.columns.filter { !visibleIDs.contains($0.id) }
        let withSnap = offscreen.filter { col in col.windows.contains { snapshotCache[$0.raw] != nil } }.count
        cmuxDebugLog("niri.overview.open cols=\(layout.columns.count) visible=\(visibleIDs.count) cached=\(snapshotCache.count) offscreenWithSnapshot=\(withSnap)/\(offscreen.count)")
#endif

        isOverviewActive = true
        startMirrorRefresh()
    }

    /// Scrolls the overview's tile strip so the highlighted tile is centred (clamped to the ends).
    /// Mirrors the live-strip glide: moving the highlight scrolls the overview, it does not jump.
    /// - Parameter animated: Glide to the target (selection moves) or set it instantly (overview open).
    private func revealOverviewSelection(animated: Bool) {
        guard !layout.columns.isEmpty else { return }
        let gap: CGFloat = 16
        let n = CGFloat(max(1, overviewVisibleColumns))
        let tileWidth = (actualViewportWidth - gap * (n + 1)) / n
        let stride = tileWidth + gap
        let selectedX = gap + CGFloat(overviewSelectionIndex) * stride
        let centered = selectedX - (actualViewportWidth - tileWidth) / 2
        let total = gap + CGFloat(layout.columns.count) * stride
        let maxScroll = max(0, total - actualViewportWidth)
        let target = min(max(centered, 0), maxScroll)
        if animated {
            overviewAnimator.animate(from: overviewScrollOffset, to: target)
        } else {
            overviewAnimator.cancel()
            overviewScrollOffset = target
        }
    }

    /// Snapshots every stacked window's terminal text per column, for the overview tiles.
    private func captureOverviewThumbnails() {
        guard let bridge else { return }
        var thumbnails: [StripColumnID: [String]] = [:]
        for column in layout.columns {
            let texts = column.windows.map { bridge.stripCaptureThumbnailText(for: $0.raw) ?? "" }
            if texts.contains(where: { !$0.isEmpty }) {
                thumbnails[column.id] = texts
            }
        }
        overviewThumbnails = thumbnails
    }

    /// Starts the live-mirror pump: retains the rendered-frame notification demand, observes
    /// per-surface frame notifications (marking the matching tile dirty), and drains the throttle
    /// on a repeating timer so live tiles refresh at ~12fps regardless of terminal output rate.
    private func startMirrorRefresh() {
        renderFrameToken = GhosttyNSView.retainRenderedFrameNotifications()
        refreshThrottle = FrameRefreshThrottle(interval: 1.0 / 12.0, startTime: CACurrentMediaTime())
        frameObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let panelID = self.bridge?.stripPanelID(forSurfaceObject: note.object) else { return }
                self.refreshThrottle.markDirty(StripWindowID(panelID))
            }
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let due = self.refreshThrottle.drain(now: CACurrentMediaTime())
                if !due.isEmpty { self.pendingMirrorRefresh = due }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Stops the live-mirror pump and clears all overview render state. Idempotent.
    private func stopMirrorRefresh() {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        renderFrameToken?()
        renderFrameToken = nil
        pendingMirrorRefresh = []
        overviewFrozenImages = [:]
        overviewLiveColumnIDs = []
    }

    /// Cancels the overview without changing the selection, restoring the exact viewport
    /// (focused column + scroll offset) from when it opened.
    func cancelOverview() {
        guard isOverviewActive else { return }
        isOverviewActive = false
        overviewThumbnails = [:]
        overviewAnimator.cancel()
        overviewScrollOffset = 0
        stopMirrorRefresh()
        layout.restoreViewport(
            focusedColumnIndex: savedFocusBeforeOverview,
            scrollOffset: savedOffsetBeforeOverview
        )
        if let panelID = layout.focusedColumn?.focusedWindow?.raw {
            bridge?.stripFocusPanel(panelID)
        }
    }

    /// Moves the overview highlight one column left/right. Vertical directions are ignored
    /// (the overview is a horizontal row of columns).
    func moveOverviewSelection(_ direction: StripAxisDirection) {
        guard isOverviewActive, !layout.columns.isEmpty else { return }
        switch direction {
        case .left:
            overviewSelectionIndex = max(0, overviewSelectionIndex - 1)
        case .right:
            overviewSelectionIndex = min(layout.columns.count - 1, overviewSelectionIndex + 1)
        case .up, .down:
            break
        }
        revealOverviewSelection(animated: true) // glide the overview to follow the highlight
    }

    /// Sets the overview highlight to a specific column (e.g. a click).
    func setOverviewSelection(_ index: Int) {
        guard isOverviewActive, layout.columns.indices.contains(index) else { return }
        overviewSelectionIndex = index
        revealOverviewSelection(animated: true)
    }

    /// Selects the highlighted column: makes it the focused column, closes the overview, and
    /// pans the viewport to bring it on-screen (the leading-edge focus pan).
    func selectOverviewColumn() {
        guard isOverviewActive else { return }
        let target = overviewSelectionIndex
        isOverviewActive = false
        overviewThumbnails = [:]
        overviewAnimator.cancel()
        overviewScrollOffset = 0
        stopMirrorRefresh()
        layout.setFocusedColumn(target, viewportWidth: viewportWidth)
        if let panelID = layout.focusedColumn?.focusedWindow?.raw {
            bridge?.stripFocusPanel(panelID)
        }
    }

    // MARK: - External panel events

    /// Reconciles the strip when a panel disappears out-of-band (closed via another surface,
    /// crash, etc.): drops any window/column referencing it so the model never points at a
    /// dead panel.
    /// - Parameter panelID: The panel that no longer exists.
    func handlePanelRemoved(_ panelID: UUID) {
        guard mode == .strip else { return }
        snapshotCache.removeValue(forKey: panelID)
        layout.removeWindow(StripWindowID(panelID), viewportWidth: viewportWidth)
    }

    // MARK: - Session restore

    /// Rebuilds the strip from a persisted session and enters ``WorkspaceLayoutMode/strip``.
    /// Each inner array is one column's window panel ids (already remapped to live panels);
    /// empty columns are dropped. Used by `Workspace.restoreSessionSnapshot`.
    /// - Parameters:
    ///   - columnPanelIDs: Per-column ordered window panel ids.
    ///   - focusedColumnIndex: The column to focus after restore.
    func restoreFromSession(columnPanelIDs: [[UUID]], focusedColumnIndex: Int) {
        let columns: [StripColumn] = columnPanelIDs.compactMap { panelIDs in
            let windows = panelIDs.map { StripWindowID($0) }
            guard !windows.isEmpty else { return nil }
            return StripColumn(id: StripColumnID(UUID()), width: newColumnWidth, windows: windows)
        }
        guard !columns.isEmpty else { return }
        layout = StripLayout(columns: columns, focusedColumnIndex: focusedColumnIndex, gap: layout.gap)
        layout.revealFocusedColumnForViewport(viewportWidth)
        mode = .strip
    }

    /// The persisted strip structure for a session snapshot: each column's window panel ids in
    /// order. Returns `nil` when niri-mode is not active (so tiling sessions stay unchanged).
    func sessionColumnPanelIDs() -> [[UUID]]? {
        guard mode == .strip else { return nil }
        return layout.columns.map { column in column.windows.map { $0.raw } }
    }

    // MARK: - Introspection (socket / tests)

    /// A JSON-encodable snapshot of the strip for the `niri_status` socket command and for
    /// UITest assertions. Includes per-column intrinsic widths and strip-space x positions so
    /// callers can verify the no-resize and pan invariants.
    func statusSnapshot() -> [String: Any] {
        var columns: [[String: Any]] = []
        for (index, column) in layout.columns.enumerated() {
            var entry: [String: Any] = [
                "id": column.id.raw.uuidString,
                "width": Double(column.width),
                "x": Double(layout.columnLeftEdge(index)),
                "focused": index == layout.focusedColumnIndex,
                "windowPanelIds": column.windows.map { $0.raw.uuidString },
                "focusedWindowIndex": column.focusedWindowIndex,
            ]
            // Render-level signal: the focused window terminal's actual grid column count.
            if let panelID = column.focusedWindow?.raw,
               let gridCols = bridge?.stripTerminalGridColumns(for: panelID) {
                entry["gridCols"] = gridCols
            }
            columns.append(entry)
        }
        return [
            "mode": mode.rawValue,
            "viewportWidth": Double(viewportWidth),
            "scrollOffset": Double(layout.scrollOffset),
            "totalContentWidth": Double(layout.totalContentWidth),
            "focusedColumnIndex": layout.focusedColumnIndex,
            "overviewActive": isOverviewActive,
            "columnFullscreen": isColumnFullscreen,
            "overviewSelectionIndex": overviewSelectionIndex,
            "overviewThumbnailCount": overviewThumbnails.count,
            "columns": columns,
        ]
    }

    // MARK: - Private

    private func syncFocusToModel() {
        if let panelID = layout.focusedColumn?.focusedWindow?.raw {
            bridge?.stripFocusPanel(panelID)
        }
    }
}
