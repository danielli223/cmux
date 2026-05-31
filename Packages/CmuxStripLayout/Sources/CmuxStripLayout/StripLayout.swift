import CoreGraphics

/// A pure, value-type model of a niri-style scrollable strip for one cmux workspace.
///
/// A strip is an ordered left-to-right sequence of ``StripColumn`` whose combined width may
/// exceed the viewport. The ``scrollOffset`` defines a horizontal window onto that strip.
/// All layout math lives here as pure functions and all structural changes are pure
/// mutating methods, so the entire model is unit-testable headlessly with no AppKit/SwiftUI
/// dependency. Views render from ``columnFrames(in:)`` and contain no layout math.
///
/// The defining invariant, enforced by every mutation below: **inserting, removing,
/// focusing, or moving a column never changes any other column's ``StripColumn/width``.**
/// Columns move; they do not resize. This is the behavior cmux's Bonsplit tiling cannot
/// express (see `docs/kb/layout-engine.md`).
///
/// ```swift
/// var strip = StripLayout(columns: [a], focusedColumnIndex: 0)
/// strip.insertColumn(b, viewportWidth: 800)   // appends after a, pans to reveal b
/// // a.width is unchanged; the strip is now wider than 800 and scrolled right.
/// ```
public struct StripLayout: Equatable, Sendable, Codable {
    /// The columns, ordered left to right along the strip.
    public private(set) var columns: [StripColumn]

    /// Index into ``columns`` of the focused column. Always valid while ``columns`` is
    /// non-empty; `0` when empty.
    public private(set) var focusedColumnIndex: Int

    /// The viewport's left edge in strip coordinates. `0` shows the strip's start; larger
    /// values pan right. Always clamped to `0...maxScrollOffset(for:)` by mutations that
    /// know the viewport width.
    public private(set) var scrollOffset: CGFloat

    /// The horizontal gap in points inserted between adjacent columns.
    public var gap: CGFloat

    /// The default intrinsic width assigned to a freshly opened column when the caller does
    /// not specify one. Chosen so a couple of columns fit a typical viewport while leaving
    /// the strip free to grow wider.
    public static let defaultColumnWidth: CGFloat = 640

    /// Creates a strip.
    /// - Parameters:
    ///   - columns: The initial columns, left to right.
    ///   - focusedColumnIndex: Index of the focused column; clamped into range.
    ///   - scrollOffset: Initial scroll offset in strip coordinates (clamped to `>= 0`).
    ///   - gap: Gap between adjacent columns in points.
    public init(
        columns: [StripColumn] = [],
        focusedColumnIndex: Int = 0,
        scrollOffset: CGFloat = 0,
        gap: CGFloat = 0
    ) {
        self.columns = columns
        self.focusedColumnIndex = columns.isEmpty
            ? 0
            : min(max(focusedColumnIndex, 0), columns.count - 1)
        self.scrollOffset = max(0, scrollOffset)
        self.gap = gap
    }

    // MARK: - Geometry (pure)

    /// The total width of the strip's content in points: the sum of all column widths plus
    /// the inter-column gaps. May exceed any viewport width — that is the point of a strip.
    public var totalContentWidth: CGFloat {
        guard !columns.isEmpty else { return 0 }
        let widths = columns.reduce(0) { $0 + $1.width }
        let gaps = gap * CGFloat(columns.count - 1)
        return widths + gaps
    }

    /// The left edge of the column at `index` in strip coordinates (scroll offset *not*
    /// applied). Equals the sum of all preceding column widths and gaps.
    /// - Parameter index: A valid column index.
    /// - Returns: The column's left edge in strip space.
    public func columnLeftEdge(_ index: Int) -> CGFloat {
        var x: CGFloat = 0
        let upper = min(max(index, 0), columns.count)
        var i = 0
        while i < upper {
            x += columns[i].width + gap
            i += 1
        }
        return x
    }

    /// The largest meaningful scroll offset for a given viewport: enough to bring the strip's
    /// right edge to the viewport's right edge, never negative. `0` when the content fits.
    /// - Parameter viewportWidth: The visible width in points.
    /// - Returns: The maximum scroll offset.
    public func maxScrollOffset(for viewportWidth: CGFloat) -> CGFloat {
        max(0, totalContentWidth - viewportWidth)
    }

    /// Resolves every column to a viewport-space ``StripColumnFrame``.
    ///
    /// Columns are laid out left to right at their intrinsic widths starting at
    /// `-scrollOffset`, so the returned frames pan as a unit when the offset changes and a
    /// column's width is independent of its neighbors. A column is marked visible when its
    /// rectangle intersects the viewport.
    /// - Parameter viewport: The visible rectangle; `width`/`height` size the columns,
    ///   `origin` offsets all frames (usually `.zero`).
    /// - Returns: One ``StripColumnFrame`` per column, in strip order.
    public func columnFrames(in viewport: CGRect) -> [StripColumnFrame] {
        var frames: [StripColumnFrame] = []
        frames.reserveCapacity(columns.count)
        var x = viewport.minX - scrollOffset
        for column in columns {
            let frame = CGRect(x: x, y: viewport.minY, width: column.width, height: viewport.height)
            let isVisible = frame.maxX > viewport.minX && frame.minX < viewport.maxX
            frames.append(StripColumnFrame(id: column.id, frame: frame, isVisible: isVisible))
            x += column.width + gap
        }
        return frames
    }

    // MARK: - Focus accessors

    /// The focused column, or `nil` when the strip is empty.
    public var focusedColumn: StripColumn? {
        columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex] : nil
    }

    // MARK: - Mutations (pure)

    /// Inserts `column` immediately after the focused column (or at the end of an empty
    /// strip), focuses it, and pans the viewport just enough to reveal it.
    ///
    /// This is niri's "open a new window" behavior: the new column appends at its own
    /// intrinsic width and **no existing column changes width**. The viewport animates to
    /// the new column via ``scrollOffset``.
    /// - Parameters:
    ///   - column: The fully-formed column to insert (caller owns its id and width).
    ///   - viewportWidth: Current viewport width, used to pan the new column on-screen.
    public mutating func insertColumn(_ column: StripColumn, viewportWidth: CGFloat) {
        let insertionIndex = columns.isEmpty ? 0 : focusedColumnIndex + 1
        columns.insert(column, at: insertionIndex)
        focusedColumnIndex = insertionIndex
        revealFocusedColumnTrailing(viewportWidth: viewportWidth)
    }

    /// Removes the column at `index`, collapsing the gap it leaves: subsequent columns slide
    /// left to their new positions (their widths are untouched), focus moves to a surviving
    /// neighbor, and the scroll offset is re-clamped.
    /// - Parameters:
    ///   - index: The column to remove.
    ///   - viewportWidth: Current viewport width, used to re-clamp and re-reveal focus.
    /// - Returns: The id of the removed column, or `nil` if `index` was invalid.
    @discardableResult
    public mutating func removeColumn(at index: Int, viewportWidth: CGFloat) -> StripColumnID? {
        guard columns.indices.contains(index) else { return nil }
        let removed = columns.remove(at: index)
        if columns.isEmpty {
            focusedColumnIndex = 0
            scrollOffset = 0
            return removed.id
        }
        if focusedColumnIndex > index || focusedColumnIndex >= columns.count {
            focusedColumnIndex = max(0, min(focusedColumnIndex - 1, columns.count - 1))
        }
        revealFocusedColumnTrailing(viewportWidth: viewportWidth)
        return removed.id
    }

    /// Removes the focused column. Convenience over ``removeColumn(at:viewportWidth:)``.
    /// - Parameter viewportWidth: Current viewport width.
    /// - Returns: The id of the removed column, or `nil` if the strip was empty.
    @discardableResult
    public mutating func removeFocusedColumn(viewportWidth: CGFloat) -> StripColumnID? {
        removeColumn(at: focusedColumnIndex, viewportWidth: viewportWidth)
    }

    /// Appends a window to the bottom of the focused column's vertical stack and focuses it.
    /// No column's width changes; this is niri's "open a stacked window".
    /// - Parameter window: The window id to append.
    public mutating func appendWindowToFocusedColumn(_ window: StripWindowID) {
        guard columns.indices.contains(focusedColumnIndex) else { return }
        columns[focusedColumnIndex].windows.append(window)
        columns[focusedColumnIndex].focusedWindowIndex = columns[focusedColumnIndex].windows.count - 1
    }

    /// Moves column focus one step left or right and pans the viewport to bring the new
    /// focused column to the nearest screen edge (niri `center-focused-column "never"`).
    /// Widths are never changed. Vertical directions are ignored here.
    /// - Parameters:
    ///   - direction: ``StripAxisDirection/left`` or ``StripAxisDirection/right``.
    ///   - viewportWidth: Current viewport width, used to reveal the target.
    /// - Returns: `true` if focus moved, `false` at a strip edge or for a vertical direction.
    @discardableResult
    public mutating func focusColumn(_ direction: StripAxisDirection, viewportWidth: CGFloat) -> Bool {
        guard !columns.isEmpty else { return false }
        let target: Int
        switch direction {
        case .left:
            target = focusedColumnIndex - 1
        case .right:
            target = focusedColumnIndex + 1
        case .up, .down:
            return false
        }
        guard columns.indices.contains(target) else { return false }
        focusedColumnIndex = target
        revealFocusedColumn(viewportWidth: viewportWidth)
        return true
    }

    /// Moves window focus one step up or down *within the focused column*. Never crosses to
    /// another column and never changes the scroll offset. Horizontal directions are ignored.
    /// - Parameter direction: ``StripAxisDirection/up`` or ``StripAxisDirection/down``.
    /// - Returns: `true` if focus moved, `false` at a stack edge or for a horizontal direction.
    @discardableResult
    public mutating func focusWindow(_ direction: StripAxisDirection) -> Bool {
        guard columns.indices.contains(focusedColumnIndex) else { return false }
        let count = columns[focusedColumnIndex].windows.count
        let current = columns[focusedColumnIndex].focusedWindowIndex
        let target: Int
        switch direction {
        case .up:
            target = current - 1
        case .down:
            target = current + 1
        case .left, .right:
            return false
        }
        guard target >= 0, target < count else { return false }
        columns[focusedColumnIndex].focusedWindowIndex = target
        return true
    }

    /// Reorders the focused column one step left or right on the strip, keeping it focused
    /// and panning the viewport to follow it. Reordering swaps positions only — **no column
    /// changes width**. Vertical directions are ignored.
    /// - Parameters:
    ///   - direction: ``StripAxisDirection/left`` or ``StripAxisDirection/right``.
    ///   - viewportWidth: Current viewport width, used to keep the moved column revealed.
    /// - Returns: `true` if the column moved, `false` at a strip edge or for a vertical direction.
    @discardableResult
    public mutating func moveColumn(_ direction: StripAxisDirection, viewportWidth: CGFloat) -> Bool {
        guard !columns.isEmpty else { return false }
        let target: Int
        switch direction {
        case .left:
            target = focusedColumnIndex - 1
        case .right:
            target = focusedColumnIndex + 1
        case .up, .down:
            return false
        }
        guard columns.indices.contains(target) else { return false }
        columns.swapAt(focusedColumnIndex, target)
        focusedColumnIndex = target
        revealFocusedColumn(viewportWidth: viewportWidth)
        return true
    }

    /// Replaces the focused column with an edited copy (e.g. after removing one window from
    /// its stack). The column keeps its position; no other column changes. Re-clamps focus.
    /// - Parameter column: The replacement column.
    public mutating func replaceFocusedColumn(with column: StripColumn) {
        guard columns.indices.contains(focusedColumnIndex) else { return }
        columns[focusedColumnIndex] = column
    }

    /// Removes the window with the given id from whichever column contains it. If that empties
    /// the column, the column is removed and the gap collapses (positions, not widths). Focus
    /// and scroll are re-clamped.
    /// - Parameters:
    ///   - id: The window to remove.
    ///   - viewportWidth: Current viewport width, used to re-clamp.
    /// - Returns: `true` if a window was found and removed.
    @discardableResult
    public mutating func removeWindow(_ id: StripWindowID, viewportWidth: CGFloat) -> Bool {
        guard let columnIndex = columns.firstIndex(where: { $0.windows.contains(id) }) else {
            return false
        }
        guard let windowIndex = columns[columnIndex].windows.firstIndex(of: id) else { return false }
        if columns[columnIndex].windows.count <= 1 {
            removeColumn(at: columnIndex, viewportWidth: viewportWidth)
        } else {
            columns[columnIndex].windows.remove(at: windowIndex)
            let clamped = min(columns[columnIndex].focusedWindowIndex, columns[columnIndex].windows.count - 1)
            columns[columnIndex].focusedWindowIndex = max(0, clamped)
        }
        return true
    }

    /// Pans the viewport so the focused column is fully visible at a column boundary (the
    /// leftmost visible column starts at the content origin, never a clipped sliver). Public
    /// entry point used when seeding/restoring the strip (e.g. on mode enable).
    /// - Parameter viewportWidth: Current viewport width.
    public mutating func revealFocusedColumnForViewport(_ viewportWidth: CGFloat) {
        revealFocusedColumnTrailing(viewportWidth: viewportWidth)
    }

    /// Sets a column's intrinsic width directly (the only operation that legitimately resizes
    /// a column — an explicit user/programmatic resize), then re-clamps the scroll offset.
    /// - Parameters:
    ///   - width: The new intrinsic width in points (clamped to a small positive minimum).
    ///   - index: The column to resize.
    ///   - viewportWidth: Current viewport width, used to re-clamp scroll.
    public mutating func setColumnWidth(_ width: CGFloat, at index: Int, viewportWidth: CGFloat) {
        guard columns.indices.contains(index) else { return }
        columns[index].width = max(80, width)
        clampScroll(viewportWidth: viewportWidth)
    }

    /// Directly sets the scroll offset (e.g. from a continuous trackpad pan), clamped to the
    /// valid range for `viewportWidth`. Does not change focus.
    /// - Parameters:
    ///   - offset: The desired offset in strip coordinates.
    ///   - viewportWidth: Current viewport width.
    public mutating func setScrollOffset(_ offset: CGFloat, viewportWidth: CGFloat) {
        scrollOffset = offset
        clampScroll(viewportWidth: viewportWidth)
    }

    /// Snaps the scroll offset to the column whose left edge is nearest the current offset —
    /// the niri "snap-to-column on release" behavior after a continuous trackpad pan.
    /// - Parameter viewportWidth: Current viewport width, used to clamp the result.
    public mutating func snapScrollToNearestColumn(viewportWidth: CGFloat) {
        guard !columns.isEmpty else { scrollOffset = 0; return }
        var best = scrollOffset
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in columns.indices {
            let edge = columnLeftEdge(index)
            let distance = abs(edge - scrollOffset)
            if distance < bestDistance {
                bestDistance = distance
                best = edge
            }
        }
        scrollOffset = best
        clampScroll(viewportWidth: viewportWidth)
    }

    // MARK: - Internal scroll helpers

    /// Pans so the focused column's left edge sits at the viewport's leading edge — which the
    /// renderer maps to the content-area origin (the sidebar's right edge).
    ///
    /// This **column-snaps** the scroll offset to a column boundary, which fixes two coupled
    /// problems with the older "scroll just to the nearest edge" policy:
    ///
    /// 1. The leftmost visible column always starts exactly at the content origin, so it is
    ///    never partially clipped into a reflowed sliver crushed against the sidebar (cmux's
    ///    terminal portal resizes a partially-clipped surface, so a half-off column would
    ///    otherwise reflow to 1–2 characters wide).
    /// 2. Each focus change moves the offset by exactly one column, so `focus-column` pans the
    ///    viewport on **every** press instead of only once focus leaves the visible range.
    ///
    /// When the whole strip already fits the viewport, nothing scrolls. The offset is clamped
    /// to the last column's left edge so the focused column is always fully visible (never a
    /// sliver); the cost is that focusing the final column can leave trailing empty space,
    /// which is preferred over crushing the focused terminal.
    private mutating func revealFocusedColumn(viewportWidth: CGFloat) {
        guard columns.indices.contains(focusedColumnIndex) else { return }
        guard totalContentWidth > viewportWidth else {
            scrollOffset = 0
            return
        }
        let maxAnchor = columnLeftEdge(columns.count - 1)
        scrollOffset = max(0, min(columnLeftEdge(focusedColumnIndex), maxAnchor))
    }

    /// Reveals the focused column at the viewport's **trailing** edge, column-snapped: scrolls
    /// so the focused column's right edge sits within the viewport, then snaps the offset up to
    /// the nearest column boundary so the leftmost visible column starts at the content origin
    /// (never a clipped left sliver).
    ///
    /// Used for structural changes (open / close / restore) so a newly focused column appears
    /// with its left-neighbors for context and minimal trailing blank — unlike
    /// ``revealFocusedColumn``, which pins the focused column to the leading edge so keyboard
    /// focus navigation pans by exactly one column per press.
    private mutating func revealFocusedColumnTrailing(viewportWidth: CGFloat) {
        guard columns.indices.contains(focusedColumnIndex) else { return }
        guard totalContentWidth > viewportWidth else {
            scrollOffset = 0
            return
        }
        let focusedLeft = columnLeftEdge(focusedColumnIndex)
        let focusedRight = focusedLeft + columns[focusedColumnIndex].width
        let trailingTarget = max(0, focusedRight - viewportWidth)
        // Smallest column boundary >= the scroll-to-edge target keeps the leftmost visible
        // column whole; never scroll past the focused column's own left edge (keeps it visible).
        var snapped = focusedLeft
        for index in columns.indices {
            let edge = columnLeftEdge(index)
            if edge >= trailingTarget {
                snapped = edge
                break
            }
        }
        scrollOffset = max(0, min(snapped, focusedLeft))
    }

    /// Clamps ``scrollOffset`` into `0...maxScrollOffset(for:)`.
    private mutating func clampScroll(viewportWidth: CGFloat) {
        scrollOffset = max(0, min(scrollOffset, maxScrollOffset(for: viewportWidth)))
    }
}
