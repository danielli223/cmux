import CmuxStripLayout
import CoreGraphics
import Foundation

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

    /// The last viewport width reported by the view, used by pure model ops that pan/clamp.
    /// Seeded with a reasonable default so socket-driven ops before first layout still work.
    private(set) var viewportWidth: CGFloat = 1200

    /// The intrinsic width assigned to columns: **half the content area minus the inter-column
    /// gap**, derived from the live viewport so exactly two columns + the gap fill the screen
    /// (the third begins the horizontal scroll). Never a hardcoded constant.
    var newColumnWidth: CGFloat { max(200, ((viewportWidth - layout.gap) / 2).rounded()) }

    /// Whether niri-mode is currently active.
    var isStripMode: Bool { mode == .strip }

    // MARK: - Overview (zoom-out) state

    /// Whether the niri-style overview (zoom-out) is currently showing. A render + input mode
    /// over the same ``layout`` — it does not fork the column data.
    @Published private(set) var isOverviewActive = false

    /// The column the overview highlight is on. Becomes the focused column when selected.
    @Published private(set) var overviewSelectionIndex = 0

    /// Per-column text thumbnails captured when the overview opens (a snapshot of each focused
    /// terminal's viewport, keyed by ``StripColumnID``). Rendered as scaled text in the tiles —
    /// see `docs/niri-mode.md` for why text rather than live/snapshot pixels.
    @Published private(set) var overviewThumbnails: [StripColumnID: String] = [:]

    /// Saved viewport (focused column + scroll offset) captured when the overview opens, so
    /// cancelling returns to the exact prior state.
    private var savedFocusBeforeOverview = 0
    private var savedOffsetBeforeOverview: CGFloat = 0

    // MARK: - Viewport

    /// Records the current viewport width (from the rendering `GeometryReader`) and re-clamps
    /// the scroll offset to it. Called from an action/`onChange`, never from `body` math.
    /// - Parameter width: The viewport width in points.
    func setViewportWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        let old = viewportWidth
        guard width != old else { return }
        viewportWidth = width
        // Columns track the content area: recompute every column to the new half-width so two
        // exactly fill the screen across window/sidebar resizes, then re-pan the focused column.
        if old > 0, isStripMode {
            layout.setAllColumnWidths(newColumnWidth)
            layout.revealFocusedColumnForViewport(width)
        } else {
            layout.setScrollOffset(layout.scrollOffset, viewportWidth: width)
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
        isOverviewActive = false
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
        let afterPanel = layout.focusedColumn?.focusedWindow?.raw
        guard let newPanelID = bridge.stripCreateColumnTerminal(after: afterPanel) else { return nil }
        let column = StripColumn(
            id: StripColumnID(UUID()),
            width: newColumnWidth,
            windows: [StripWindowID(newPanelID)]
        )
        layout.insertColumn(column, viewportWidth: viewportWidth)
        bridge.stripFocusPanel(newPanelID)
        return newPanelID
    }

    /// Opens a new terminal stacked below the focused column's focused window. Other columns
    /// are untouched. niri "open a stacked window".
    /// - Returns: The new panel's id, or `nil` if creation failed.
    @discardableResult
    func openStackedWindow() -> UUID? {
        guard mode == .strip, let bridge,
              let belowPanel = layout.focusedColumn?.focusedWindow?.raw else { return nil }
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
    }

    // MARK: - Focus & movement

    /// Moves column focus left/right, pans to reveal, and focuses the landing panel.
    func focusColumn(_ direction: StripAxisDirection) {
        guard mode == .strip else { return }
        if layout.focusColumn(direction, viewportWidth: viewportWidth) {
            syncFocusToModel()
        }
    }

    /// Moves window focus up/down within the focused column and focuses the landing panel.
    func focusWindow(_ direction: StripAxisDirection) {
        guard mode == .strip else { return }
        if layout.focusWindow(direction) {
            syncFocusToModel()
        }
    }

    /// Reorders the focused column left/right on the strip; widths unchanged; viewport follows.
    func moveColumn(_ direction: StripAxisDirection) {
        guard mode == .strip else { return }
        layout.moveColumn(direction, viewportWidth: viewportWidth)
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
        savedFocusBeforeOverview = layout.focusedColumnIndex
        savedOffsetBeforeOverview = layout.scrollOffset
        overviewSelectionIndex = layout.focusedColumnIndex
        captureOverviewThumbnails()
        isOverviewActive = true
    }

    /// Snapshots each column's focused-window terminal text for the overview tiles.
    private func captureOverviewThumbnails() {
        guard let bridge else { return }
        var thumbnails: [StripColumnID: String] = [:]
        for column in layout.columns {
            guard let panelID = column.focusedWindow?.raw else { continue }
            if let text = bridge.stripCaptureThumbnailText(for: panelID), !text.isEmpty {
                thumbnails[column.id] = text
            }
        }
        overviewThumbnails = thumbnails
    }

    /// Cancels the overview without changing the selection, restoring the exact viewport
    /// (focused column + scroll offset) from when it opened.
    func cancelOverview() {
        guard isOverviewActive else { return }
        isOverviewActive = false
        overviewThumbnails = [:]
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
    }

    /// Sets the overview highlight to a specific column (e.g. a click).
    func setOverviewSelection(_ index: Int) {
        guard isOverviewActive, layout.columns.indices.contains(index) else { return }
        overviewSelectionIndex = index
    }

    /// Selects the highlighted column: makes it the focused column, closes the overview, and
    /// pans the viewport to bring it on-screen (the leading-edge focus pan).
    func selectOverviewColumn() {
        guard isOverviewActive else { return }
        let target = overviewSelectionIndex
        isOverviewActive = false
        overviewThumbnails = [:]
        layout.setFocusedColumn(target, viewportWidth: viewportWidth)
        if let panelID = layout.focusedColumn?.focusedWindow?.raw {
            bridge?.stripFocusPanel(panelID)
        }
    }

    // MARK: - Scrolling (trackpad)

    /// Pans the strip by a pixel delta (continuous two-finger trackpad pan). Does not change
    /// focus. Positive `dx` reveals columns to the right.
    /// - Parameter dx: Pixels to pan by.
    func panBy(_ dx: CGFloat) {
        guard mode == .strip else { return }
        layout.setScrollOffset(layout.scrollOffset + dx, viewportWidth: viewportWidth)
    }

    /// Snaps the scroll offset to the nearest column edge (on trackpad gesture release).
    func snapScroll() {
        guard mode == .strip else { return }
        layout.snapScrollToNearestColumn(viewportWidth: viewportWidth)
    }

    // MARK: - External panel events

    /// Reconciles the strip when a panel disappears out-of-band (closed via another surface,
    /// crash, etc.): drops any window/column referencing it so the model never points at a
    /// dead panel.
    /// - Parameter panelID: The panel that no longer exists.
    func handlePanelRemoved(_ panelID: UUID) {
        guard mode == .strip else { return }
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
