import CoreGraphics
import Foundation
import Testing

@testable import CmuxStripLayout

/// Invariant tests for the niri-style strip layout model. Each invariant from the task brief
/// maps to at least one `@Test` here. These run headlessly via `swift test`.
@Suite struct StripLayoutTests {

    // MARK: - Helpers

    /// Deterministic id factory so failures are reproducible (no `UUID()` in assertions).
    private func columnID(_ n: Int) -> StripColumnID {
        StripColumnID(UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!)
    }

    private func windowID(_ n: Int) -> StripWindowID {
        StripWindowID(UUID(uuidString: "11111111-0000-0000-0000-\(String(format: "%012d", n))")!)
    }

    private func column(_ n: Int, width: CGFloat = 600, windows: Int = 1) -> StripColumn {
        StripColumn(
            id: columnID(n),
            width: width,
            windows: (0..<windows).map { windowID(n * 10 + $0) }
        )
    }

    /// A 3-column strip, each 600 wide, gap 0, focused on the first column.
    private func threeColumns(viewportWidth: CGFloat = 800) -> StripLayout {
        StripLayout(
            columns: [column(1), column(2), column(3)],
            focusedColumnIndex: 0
        )
    }

    // MARK: - Invariant 1: opening a column doesn't change prior columns' widths

    @Test func insertColumnPreservesSiblingWidths() {
        var strip = StripLayout(columns: [column(1, width: 500), column(2, width: 300)], focusedColumnIndex: 0)
        let before = strip.columns.map(\.width)
        strip.insertColumn(column(9, width: 720), viewportWidth: 800)
        // The two originals keep their exact widths; only a new column was appended.
        #expect(strip.columns[0].width == before[0])
        #expect(strip.columns[2].width == before[1]) // original column 2 shifted to index 2
        #expect(strip.columns.count == 3)
    }

    @Test func insertColumnAppendsAfterFocusedAndFocusesIt() {
        var strip = threeColumns()
        strip.focusColumn(.right, viewportWidth: 800) // focus index 1
        strip.insertColumn(column(9, width: 600), viewportWidth: 800)
        // New column inserted right after the previously focused (index 1) -> now at index 2.
        #expect(strip.columns[2].id == columnID(9))
        #expect(strip.focusedColumnIndex == 2)
        #expect(strip.focusedColumn?.id == columnID(9))
    }

    /// Opening a terminal while focused on the last column reveals the new column at the
    /// trailing edge with its left-neighbor visible (column-snapped), rather than pinning it
    /// alone at the leading edge with a large trailing blank. Offset stays a column boundary so
    /// the leftmost visible column is never a sliver.
    @Test func openingAtEndRevealsNewColumnWithContext() {
        // 4 columns, 640 wide, gap 8, viewport 1380 -> ~2 columns fit.
        var strip = StripLayout(
            columns: (1...4).map { column($0, width: 640) },
            focusedColumnIndex: 3, // focused on the last column
            gap: 8
        )
        strip.insertColumn(column(9, width: 640), viewportWidth: 1380)
        let boundaries = Set(strip.columns.indices.map { strip.columnLeftEdge($0) })
        // Offset is a column boundary (leftmost visible column starts at the content origin).
        #expect(boundaries.contains(strip.scrollOffset))
        // The new column is the focused one and is fully visible (not clipped).
        #expect(strip.focusedColumnIndex == 4)
        let frames = strip.columnFrames(in: CGRect(x: 0, y: 0, width: 1380, height: 1000))
        let focusedFrame = frames[4].frame
        #expect(focusedFrame.minX >= 0)
        #expect(focusedFrame.maxX <= 1380) // fully within the viewport, no sliver
        // At least one column is visible to the LEFT of the new one (context, not alone+blank).
        #expect(frames[3].isVisible == true)
    }

    @Test func insertIntoEmptyStrip() {
        var strip = StripLayout()
        strip.insertColumn(column(1, width: 400), viewportWidth: 800)
        #expect(strip.columns.count == 1)
        #expect(strip.focusedColumnIndex == 0)
        #expect(strip.scrollOffset == 0)
    }

    // MARK: - Invariant 2: focusColumn(right) reveals target without resizing

    @Test func focusColumnRightPutsFocusInRightSlot() {
        // viewport 1200; three 600-wide columns -> exactly two fill the screen (2-fit), total 1800.
        var strip = threeColumns()
        let widthsBefore = strip.columns.map(\.width)

        #expect(strip.scrollOffset == 0)
        // Focus column 2 (index 1): it is already fully visible (the right of the first pair), so
        // the strip does NOT pan -> offset stays 0.
        strip.focusColumn(.right, viewportWidth: 1200)
        #expect(strip.focusedColumnIndex == 1)
        #expect(strip.scrollOffset == 0)
        #expect(strip.columns.map(\.width) == widthsBefore)

        // Focus column 3 (index 2): off the right edge, so it slides into the right slot with
        // column 2 (index 1) in the left slot -> offset = leftEdge(1) = 600.
        strip.focusColumn(.right, viewportWidth: 1200)
        #expect(strip.focusedColumnIndex == 2)
        #expect(strip.scrollOffset == 600)
        #expect(strip.columns.map(\.width) == widthsBefore)
    }

    /// The regression for the reported bug: with columns 2 and 3 both on screen (column 2 left,
    /// column 3 right) and focus on column 3, pressing focus-left must NOT shift the whole strip —
    /// columns 2 and 3 stay displayed and focus simply moves to the already-visible column 2.
    @Test func focusColumnLeftDoesNotPanWhenTargetAlreadyVisible() {
        var strip = threeColumns()
        strip.focusColumn(.right, viewportWidth: 1200)
        strip.focusColumn(.right, viewportWidth: 1200) // offset 600, focus index 2 (cols 1|2 shown)
        #expect(strip.scrollOffset == 600)

        strip.focusColumn(.left, viewportWidth: 1200)  // back to index 1, which is already visible
        // Column 1 is fully visible at offset 600 (the left of the visible pair), so no pan:
        // the same two columns stay on screen, focus just moves left.
        #expect(strip.focusedColumnIndex == 1)
        #expect(strip.scrollOffset == 600)
        // Both columns 1 and 2 remain visible after the focus change.
        let frames = strip.columnFrames(in: CGRect(x: 0, y: 0, width: 1200, height: 1000))
        #expect(frames[1].isVisible == true)
        #expect(frames[2].isVisible == true)

        // Pressing left again DOES pan, because column 0 is off-screen to the left.
        strip.focusColumn(.left, viewportWidth: 1200) // focus index 0
        #expect(strip.focusedColumnIndex == 0)
        #expect(strip.scrollOffset == 0) // column 0 snapped to the leading edge
    }

    /// Every focus-column press advances focus by exactly one and slides the 2-column window;
    /// the offset increases monotonically across the strip (no "dead" presses that do nothing
    /// then jump). The very first pair shares offset 0 (both already visible), as expected.
    @Test func everyFocusColumnPressAdvancesAndPans() {
        // 5 columns, 600 wide, viewport 1200 -> exactly two fit; the strip overflows so panning
        // is possible once focus moves past the initial visible pair.
        var strip = StripLayout(
            columns: (1...5).map { column($0, width: 600) },
            focusedColumnIndex: 0
        )
        var lastOffset = strip.scrollOffset
        var pannedCount = 0
        for expectedIndex in 1...4 {
            let moved = strip.focusColumn(.right, viewportWidth: 1200)
            #expect(moved == true)
            #expect(strip.focusedColumnIndex == expectedIndex) // advances by exactly one
            #expect(strip.scrollOffset >= lastOffset)          // never jumps backward
            if strip.scrollOffset > lastOffset { pannedCount += 1 }
            lastOffset = strip.scrollOffset
        }
        // Past the initial visible pair, every press pans -> at least 3 of the 4 presses panned.
        #expect(pannedCount >= 3)
        #expect(strip.scrollOffset > 0)
    }

    @Test func focusColumnAtEdgeReturnsFalseAndDoesNotMove() {
        var strip = threeColumns()
        #expect(strip.focusColumn(.left, viewportWidth: 800) == false)
        #expect(strip.focusedColumnIndex == 0)
        #expect(strip.scrollOffset == 0)
    }

    @Test func revealNoOpWhenColumnAlreadyVisible() {
        // Wide viewport: everything fits, focusing should never scroll.
        var strip = threeColumns()
        strip.focusColumn(.right, viewportWidth: 2000)
        #expect(strip.scrollOffset == 0)
        strip.focusColumn(.right, viewportWidth: 2000)
        #expect(strip.scrollOffset == 0)
    }

    // MARK: - Invariant 3: total strip width = Σ widths + gaps and can exceed viewport

    @Test func totalContentWidthSumsWidthsAndGaps() {
        let strip = StripLayout(
            columns: [column(1, width: 500), column(2, width: 300), column(3, width: 200)],
            gap: 10
        )
        // 500 + 300 + 200 + 2 gaps * 10 = 1020
        #expect(strip.totalContentWidth == 1020)
    }

    @Test func stripCanExceedViewport() {
        let strip = threeColumns(viewportWidth: 800)
        #expect(strip.totalContentWidth == 1800)
        #expect(strip.totalContentWidth > 800)
        #expect(strip.maxScrollOffset(for: 800) == 1000)
    }

    @Test func emptyStripHasZeroWidth() {
        let strip = StripLayout()
        #expect(strip.totalContentWidth == 0)
    }

    @Test func columnFramesArePositionedAtIntrinsicWidthsWithOffset() {
        var strip = threeColumns()
        strip.setScrollOffset(400, viewportWidth: 800)
        let frames = strip.columnFrames(in: CGRect(x: 0, y: 0, width: 800, height: 1000))
        #expect(frames.count == 3)
        // Column 0 at strip-x 0 -> viewport-x -400; spans [-400,200], still pokes into the
        // viewport on the left, so it is partially visible.
        #expect(frames[0].frame.minX == -400)
        #expect(frames[0].frame.width == 600)
        #expect(frames[0].isVisible == true)
        // Column 1 at strip-x 600 -> viewport-x 200, fully visible.
        #expect(frames[1].frame.minX == 200)
        #expect(frames[1].isVisible == true)
        // Column 2 at strip-x 1200 -> viewport-x 800 (its left edge sits exactly on the
        // viewport's right edge), so nothing of it shows -> not visible.
        #expect(frames[2].frame.minX == 800)
        #expect(frames[2].isVisible == false)

        // A column fully off the left (scroll past it) is not visible.
        var deep = strip
        deep.setScrollOffset(1000, viewportWidth: 800) // clamped to max 1000
        let dframes = deep.columnFrames(in: CGRect(x: 0, y: 0, width: 800, height: 1000))
        #expect(dframes[0].frame.maxX == -400) // [-1000,-400], entirely left of viewport
        #expect(dframes[0].isVisible == false)
    }

    // MARK: - Bug fix: first column starts at the content-area origin at full width

    /// The renderer passes the *content area* (window minus sidebar) as the viewport, with its
    /// own local origin. The first column must sit exactly at that origin at its full intended
    /// width — never squeezed to a sliver against the sidebar — whether the sidebar is open
    /// (narrower content area) or closed (wider). Verified by varying the viewport width.
    @Test(arguments: [
        CGFloat(900),   // sidebar open: narrower content area
        CGFloat(1400),  // sidebar closed: wider content area
    ])
    func firstColumnStartsAtContentOriginAtFullWidth(contentWidth: CGFloat) {
        let intended: CGFloat = 640
        var strip = StripLayout(
            columns: (1...4).map { column($0, width: intended) },
            focusedColumnIndex: 0,
            gap: 8
        )
        // Focus the first column (the renderer's content-area origin maps to viewport.minX).
        strip.focusColumn(.left, viewportWidth: contentWidth) // already at 0; ensures anchored
        let content = CGRect(x: 0, y: 0, width: contentWidth, height: 1000)
        let frames = strip.columnFrames(in: content)
        // First column: left edge exactly at the content-area origin, full intended width.
        #expect(frames[0].frame.minX == content.minX)
        #expect(frames[0].frame.width == intended)
        #expect(frames[0].isVisible == true)
    }

    /// The leftmost visible column always starts at the content-area origin: the scroll offset
    /// is always exactly some column's left edge (a column boundary). This is what prevents a
    /// partially-clipped left column from being reflowed into a sliver by the terminal portal.
    @Test func scrollOffsetIsAlwaysAColumnBoundaryAfterFocus() {
        var strip = StripLayout(
            columns: (1...6).map { column($0, width: 600) },
            focusedColumnIndex: 0,
            gap: 8
        )
        let boundaries = Set(strip.columns.indices.map { strip.columnLeftEdge($0) })
        // Walk right across the whole strip; after every focus change the offset is a boundary.
        for _ in 0..<5 {
            strip.focusColumn(.right, viewportWidth: 900)
            #expect(boundaries.contains(strip.scrollOffset))
        }
        // ...and back left.
        for _ in 0..<5 {
            strip.focusColumn(.left, viewportWidth: 900)
            #expect(boundaries.contains(strip.scrollOffset))
        }
    }

    // MARK: - Overview (zoom-out) geometry

    /// The overview scale shrinks the whole strip to fit the content area: the total scaled
    /// width never exceeds the content width, for both a narrow and a wide content area.
    @Test(arguments: [CGFloat(900), CGFloat(1600)])
    func overviewScaleFitsWholeStrip(contentWidth: CGFloat) {
        let strip = StripLayout(
            columns: (1...8).map { column($0, width: 640) },
            gap: 8
        )
        let scale = strip.overviewScale(forContentWidth: contentWidth)
        #expect(scale > 0)
        #expect(scale <= 1)
        #expect(strip.totalContentWidth * scale <= contentWidth)
    }

    @Test func overviewScaleNeverMagnifiesWhenStripFits() {
        // Two columns already fit a wide content area -> no zoom (scale 1).
        let strip = StripLayout(columns: [column(1, width: 400), column(2, width: 400)], gap: 8)
        #expect(strip.overviewScale(forContentWidth: 2000) == 1)
    }

    /// Overview frames live in content-area coordinates and never overlap the sidebar: every
    /// frame sits within `[0, contentWidth]`, and they preserve the columns' relative order.
    @Test func overviewFramesStayWithinContentAreaAndPreserveOrder() {
        let strip = StripLayout(
            columns: (1...6).map { column($0, width: 640) },
            gap: 8
        )
        let content = CGSize(width: 1000, height: 800)
        let frames = strip.overviewColumnFrames(in: content)
        #expect(frames.count == 6)
        for frame in frames {
            #expect(frame.frame.minX >= 0)                 // never left of the content origin (no sidebar overlap)
            #expect(frame.frame.maxX <= content.width + 0.01) // never past the content area
            #expect(frame.frame.minY >= 0)
            #expect(frame.frame.maxY <= content.height + 0.01)
        }
        // Relative order and scaled positions preserved (each column left of the next).
        for i in 1..<frames.count {
            #expect(frames[i].frame.minX > frames[i - 1].frame.minX)
        }
        // The scaled column widths are the intrinsic widths times the scale (no per-column squashing).
        let scale = strip.overviewScale(forContentWidth: content.width)
        #expect(abs(frames[0].frame.width - 640 * scale) < 0.01)
    }

    // MARK: - Invariant 4: focusWindowDown/Up stays within a column

    @Test func focusWindowDownStaysWithinColumn() {
        var strip = StripLayout(
            columns: [column(1, windows: 3), column(2, windows: 1)],
            focusedColumnIndex: 0
        )
        #expect(strip.columns[0].focusedWindowIndex == 0)
        #expect(strip.focusWindow(.down) == true)
        #expect(strip.columns[0].focusedWindowIndex == 1)
        #expect(strip.focusedColumnIndex == 0) // column focus unchanged
        #expect(strip.focusWindow(.down) == true)
        #expect(strip.columns[0].focusedWindowIndex == 2)
        // At the bottom of the stack: cannot go further, does not spill into another column.
        #expect(strip.focusWindow(.down) == false)
        #expect(strip.columns[0].focusedWindowIndex == 2)
        #expect(strip.focusedColumnIndex == 0)
    }

    @Test func focusWindowUpStopsAtTop() {
        var strip = StripLayout(columns: [column(1, windows: 2)], focusedColumnIndex: 0)
        #expect(strip.focusWindow(.up) == false) // already at top
        strip.focusWindow(.down)
        #expect(strip.focusWindow(.up) == true)
        #expect(strip.columns[0].focusedWindowIndex == 0)
    }

    @Test func focusWindowIgnoresHorizontalDirections() {
        var strip = StripLayout(columns: [column(1, windows: 2)], focusedColumnIndex: 0)
        #expect(strip.focusWindow(.left) == false)
        #expect(strip.focusWindow(.right) == false)
    }

    @Test func appendStackedWindowDoesNotResizeColumns() {
        var strip = StripLayout(columns: [column(1, width: 500), column(2, width: 300)], focusedColumnIndex: 1)
        let widthsBefore = strip.columns.map(\.width)
        strip.appendWindowToFocusedColumn(windowID(99))
        #expect(strip.columns[1].windows.count == 2)
        #expect(strip.columns[1].focusedWindowIndex == 1) // focus the new stacked window
        #expect(strip.columns.map(\.width) == widthsBefore) // no resize
    }

    // MARK: - Invariant 5: moveColumn reorders without resizing

    @Test func moveColumnReordersWithoutResizing() {
        var strip = StripLayout(
            columns: [column(1, width: 500), column(2, width: 300), column(3, width: 200)],
            focusedColumnIndex: 0
        )
        let widthsMultiset = strip.columns.map(\.width).sorted()
        #expect(strip.moveColumn(.right, viewportWidth: 2000) == true)
        // Order is now [2, 1, 3] by id; focus follows the moved column to index 1.
        #expect(strip.columns.map(\.id) == [columnID(2), columnID(1), columnID(3)])
        #expect(strip.focusedColumnIndex == 1)
        // Same set of widths, none changed.
        #expect(strip.columns.map(\.width).sorted() == widthsMultiset)
        // The moved column kept its own width (500), it just changed position.
        #expect(strip.columns[1].id == columnID(1))
        #expect(strip.columns[1].width == 500)
    }

    @Test func moveColumnAtEdgeIsNoOp() {
        var strip = threeColumns()
        #expect(strip.moveColumn(.left, viewportWidth: 800) == false)
        #expect(strip.columns.map(\.id) == [columnID(1), columnID(2), columnID(3)])
    }

    @Test func moveColumnLeftMirrorsRight() {
        var strip = StripLayout(columns: [column(1), column(2), column(3)], focusedColumnIndex: 2)
        #expect(strip.moveColumn(.left, viewportWidth: 2000) == true)
        #expect(strip.columns.map(\.id) == [columnID(1), columnID(3), columnID(2)])
        #expect(strip.focusedColumnIndex == 1)
    }

    // MARK: - Invariant 6: closing collapses positions not sizes and clamps offset

    @Test func removeColumnCollapsesPositionsNotSizes() {
        var strip = StripLayout(
            columns: [column(1, width: 500), column(2, width: 300), column(3, width: 200)],
            focusedColumnIndex: 0
        )
        // Before: column 3 (index 2) left edge = 500 + 300 = 800.
        #expect(strip.columnLeftEdge(2) == 800)
        strip.removeColumn(at: 1, viewportWidth: 2000) // remove the middle 300-wide column
        // Surviving columns keep widths; column 3 slid left to edge 500 (positions collapsed).
        #expect(strip.columns.map(\.width) == [500, 200])
        #expect(strip.columnLeftEdge(1) == 500)
    }

    @Test func removeColumnReanchorsToColumnBoundary() {
        var strip = threeColumns() // three 600-wide columns, total 1800
        strip.focusColumn(.right, viewportWidth: 1200)
        strip.focusColumn(.right, viewportWidth: 1200) // focus last (index 2), offset = leftEdge(1) = 600
        #expect(strip.scrollOffset == 600)
        strip.removeColumn(at: 2, viewportWidth: 1200) // remove focused -> focus index 1 (now last)
        #expect(strip.focusedColumnIndex == 1)
        // Only two 600-wide columns remain (total 1200 == viewport), so the content now fits and
        // the offset re-anchors to the content origin -> 0, a column boundary.
        #expect(strip.scrollOffset == strip.columnLeftEdge(0))
        #expect(strip.scrollOffset == 0)
    }

    @Test func removeLastRemainingColumnResetsStrip() {
        var strip = StripLayout(columns: [column(1)], focusedColumnIndex: 0)
        let removed = strip.removeColumn(at: 0, viewportWidth: 800)
        #expect(removed == columnID(1))
        #expect(strip.columns.isEmpty)
        #expect(strip.focusedColumnIndex == 0)
        #expect(strip.scrollOffset == 0)
    }

    @Test func removeFocusedColumnMovesFocusToNeighbor() {
        var strip = threeColumns()
        strip.focusColumn(.right, viewportWidth: 2000) // focus index 1
        strip.removeFocusedColumn(viewportWidth: 2000)
        #expect(strip.columns.count == 2)
        // Focus stayed at a valid index pointing at a surviving column.
        #expect(strip.columns.indices.contains(strip.focusedColumnIndex))
    }

    // MARK: - Continuous pan + snap (open question d)

    @Test func setScrollOffsetClampsToRange() {
        var strip = threeColumns(viewportWidth: 800)
        strip.setScrollOffset(99999, viewportWidth: 800)
        #expect(strip.scrollOffset == 1000) // clamped to max
        strip.setScrollOffset(-50, viewportWidth: 800)
        #expect(strip.scrollOffset == 0) // clamped to min
    }

    @Test func snapScrollGoesToNearestColumnEdge() {
        var strip = threeColumns(viewportWidth: 800)
        strip.setScrollOffset(560, viewportWidth: 800) // nearest column edge is 600 (col 1)
        strip.snapScrollToNearestColumn(viewportWidth: 800)
        #expect(strip.scrollOffset == 600)

        strip.setScrollOffset(100, viewportWidth: 800) // nearest edge is 0 (col 0)
        strip.snapScrollToNearestColumn(viewportWidth: 800)
        #expect(strip.scrollOffset == 0)
    }

    @Test func setColumnWidthIsTheOnlyResizePath() {
        var strip = StripLayout(columns: [column(1, width: 600), column(2, width: 600)], focusedColumnIndex: 0)
        strip.setColumnWidth(900, at: 0, viewportWidth: 800)
        #expect(strip.columns[0].width == 900)
        #expect(strip.columns[1].width == 600) // sibling untouched
        // Enforces a sane minimum.
        strip.setColumnWidth(5, at: 1, viewportWidth: 800)
        #expect(strip.columns[1].width == 80)
    }

    // MARK: - removeWindow / replaceFocusedColumn (stacked window close)

    @Test func removeWindowFromStackKeepsColumn() {
        var strip = StripLayout(
            columns: [column(1, width: 500, windows: 3), column(2, width: 300)],
            focusedColumnIndex: 0
        )
        let w = windowID(10 * 1 + 1) // second window of column 1
        #expect(strip.removeWindow(w, viewportWidth: 800) == true)
        #expect(strip.columns.count == 2) // column survives
        #expect(strip.columns[0].windows.count == 2)
        #expect(strip.columns.map(\.width) == [500, 300]) // no resize
    }

    @Test func removeLastWindowRemovesColumn() {
        var strip = StripLayout(
            columns: [column(1, width: 500, windows: 1), column(2, width: 300)],
            focusedColumnIndex: 0
        )
        let only = windowID(10) // sole window of column 1
        #expect(strip.removeWindow(only, viewportWidth: 800) == true)
        #expect(strip.columns.count == 1)
        #expect(strip.columns[0].id == columnID(2))
        #expect(strip.columns[0].width == 300)
    }

    @Test func removeUnknownWindowIsNoOp() {
        var strip = threeColumns()
        #expect(strip.removeWindow(windowID(999), viewportWidth: 800) == false)
        #expect(strip.columns.count == 3)
    }

    @Test func replaceFocusedColumnEditsInPlace() {
        var strip = StripLayout(columns: [column(1, width: 500), column(2, width: 300)], focusedColumnIndex: 1)
        var edited = strip.columns[1]
        edited.windows.append(windowID(88))
        strip.replaceFocusedColumn(with: edited)
        #expect(strip.columns[1].windows.count == 2)
        #expect(strip.columns[0].width == 500) // sibling untouched
    }

    // MARK: - Invariant 7 support: Codable round-trip (session restore)

    @Test func codableRoundTripPreservesStrip() throws {
        var strip = threeColumns(viewportWidth: 800)
        strip.focusColumn(.right, viewportWidth: 800)
        strip.appendWindowToFocusedColumn(windowID(77))
        let data = try JSONEncoder().encode(strip)
        let decoded = try JSONDecoder().decode(StripLayout.self, from: data)
        #expect(decoded == strip)
        #expect(decoded.focusedColumnIndex == strip.focusedColumnIndex)
        #expect(decoded.scrollOffset == strip.scrollOffset)
        #expect(decoded.columns.map(\.width) == strip.columns.map(\.width))
    }

    // MARK: - Sanity: a full open-three-terminals sequence never resizes the first

    @Test func openingThreeTerminalsNeverShrinksTheFirst() {
        var strip = StripLayout()
        strip.insertColumn(column(1, width: 600), viewportWidth: 800)
        let firstWidthAfterOpen = strip.columns[0].width
        strip.insertColumn(column(2, width: 600), viewportWidth: 800)
        strip.insertColumn(column(3, width: 600), viewportWidth: 800)
        // The very first terminal kept its width through two more opens — the niri invariant.
        #expect(strip.columns[0].width == firstWidthAfterOpen)
        #expect(strip.columns.allSatisfy { $0.width == 600 })
        #expect(strip.totalContentWidth == 1800)
        // And the viewport panned to the newest column (offset > 0).
        #expect(strip.scrollOffset > 0)
    }
}
