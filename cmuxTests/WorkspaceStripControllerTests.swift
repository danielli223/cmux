import CmuxStripLayout
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral tests for ``WorkspaceStripController`` — the glue between the pure
/// ``StripLayout`` model and cmux terminal panels — exercised through a fake
/// ``StripPanelBridge`` so they run headlessly with no `Workspace`/AppKit dependency.
///
/// These complement the model-level invariant tests in the `CmuxStripLayout` package by
/// verifying the *routing* layer: that opening creates panels without resizing siblings,
/// that focus is kept in sync with the model, that closing removes the right panel, and
/// that toggling the mode off returns to tiling (leaving the strip data intact).
@MainActor
@Suite final class WorkspaceStripControllerTests {
    /// Keeps fake bridges alive for the duration of each test. ``WorkspaceStripController``
    /// holds its bridge `weak` (the production bridge is the owning `Workspace`), so the test
    /// must retain the fake itself or it would deallocate immediately.
    private var retainedBridges: [FakeStripBridge] = []

    /// A fake panel lifecycle: records created/closed/focused panel ids deterministically.
    final class FakeStripBridge: StripPanelBridge {
        var livePanels: [UUID] = []
        var focused: UUID?
        var seed: [UUID] = []
        private var counter = 0

        var stripSeedPanelIDs: [UUID] { seed }
        var stripFocusedPanelID: UUID? { focused }

        private func mint() -> UUID {
            counter += 1
            return UUID(uuidString: "ABCDABCD-0000-0000-0000-\(String(format: "%012d", counter))")!
        }

        func stripCreateColumnTerminal(after panelID: UUID?) -> UUID? {
            let id = mint(); livePanels.append(id); focused = id; return id
        }

        func stripCreateStackedTerminal(below panelID: UUID) -> UUID? {
            let id = mint(); livePanels.append(id); focused = id; return id
        }

        func stripFocusPanel(_ panelID: UUID) { focused = panelID }

        @discardableResult
        func stripClosePanel(_ panelID: UUID) -> Bool {
            let before = livePanels.count
            livePanels.removeAll { $0 == panelID }
            return livePanels.count != before
        }

        var thumbnailText: [UUID: String] = [:]
        func stripCaptureThumbnailText(for panelID: UUID) -> String? { thumbnailText[panelID] }
        var gridColumns: [UUID: Int] = [:]
        func stripTerminalGridColumns(for panelID: UUID) -> Int? { gridColumns[panelID] }
    }

    private func makeController(seed: [UUID]) -> (WorkspaceStripController, FakeStripBridge) {
        let bridge = FakeStripBridge()
        bridge.seed = seed
        bridge.livePanels = seed
        bridge.focused = seed.first
        retainedBridges.append(bridge) // keep alive past this method (controller holds it weakly)
        let controller = WorkspaceStripController()
        controller.bridge = bridge
        controller.setViewportWidth(800)
        return (controller, bridge)
    }

    @Test func enableSeedsOneColumnPerExistingPanel() {
        let seed = [UUID(), UUID(), UUID()]
        let (controller, _) = makeController(seed: seed)
        controller.enableStripMode()
        #expect(controller.mode == .strip)
        #expect(controller.layout.columns.count == 3)
        // The seeded windows map 1:1 to the existing panels, in order.
        #expect(controller.layout.columns.map { $0.windows.first?.raw } == seed)
    }

    @Test func openColumnAppendsWithoutResizingSiblings() {
        let (controller, bridge) = makeController(seed: [UUID()])
        controller.enableStripMode()
        let widthsBefore = controller.layout.columns.map(\.width)

        let newPanel = controller.openColumn()
        #expect(newPanel != nil)
        #expect(controller.layout.columns.count == 2)
        // First column kept its exact width — no shrink.
        #expect(controller.layout.columns[0].width == widthsBefore[0])
        // The new column is focused and the bridge focused the new panel.
        #expect(controller.layout.focusedColumnIndex == 1)
        #expect(bridge.focused == newPanel)
    }

    @Test func openingThreeNeverShrinksAndPansViewport() {
        let (controller, _) = makeController(seed: [UUID()])
        controller.enableStripMode()
        controller.openColumn()
        controller.openColumn()
        let widths = controller.layout.columns.map(\.width)
        #expect(controller.layout.columns.count == 3)
        #expect(Set(widths).count == 1) // all identical — none shrank
        #expect(controller.layout.totalContentWidth > 800) // strip exceeds viewport
        #expect(controller.layout.scrollOffset > 0) // panned to the newest column
    }

    @Test func openStackedWindowAddsToColumnWithoutNewColumn() {
        let (controller, bridge) = makeController(seed: [UUID()])
        controller.enableStripMode()
        let stacked = controller.openStackedWindow()
        #expect(stacked != nil)
        #expect(controller.layout.columns.count == 1) // still one column
        #expect(controller.layout.columns[0].windows.count == 2) // stacked vertically
        #expect(bridge.focused == stacked)
    }

    @Test func focusColumnSyncsBridgeFocus() {
        let (controller, bridge) = makeController(seed: [UUID()])
        controller.enableStripMode()
        controller.openColumn() // now 2 columns, focus index 1
        controller.focusColumn(.left)
        #expect(controller.layout.focusedColumnIndex == 0)
        // Bridge focus moved to the first column's panel.
        #expect(bridge.focused == controller.layout.columns[0].windows.first?.raw)
    }

    @Test func moveColumnReordersWithoutResizing() {
        let (controller, _) = makeController(seed: [UUID()])
        controller.enableStripMode()
        controller.openColumn()
        controller.openColumn() // 3 columns, focus index 2
        let widthsBefore = controller.layout.columns.map(\.width).sorted()
        controller.moveColumn(.left)
        #expect(controller.layout.focusedColumnIndex == 1)
        #expect(controller.layout.columns.map(\.width).sorted() == widthsBefore)
    }

    @Test func closeFocusedColumnClosesPanelAndCollapses() {
        let (controller, bridge) = makeController(seed: [UUID()])
        controller.enableStripMode()
        controller.openColumn() // 2 columns
        let liveBefore = bridge.livePanels.count
        controller.closeFocusedColumn()
        #expect(controller.layout.columns.count == 1) // gap collapsed
        #expect(bridge.livePanels.count == liveBefore - 1) // panel actually closed
    }

    @Test func disableRestoresTilingButKeepsStripData() {
        let (controller, _) = makeController(seed: [UUID()])
        controller.enableStripMode()
        controller.openColumn()
        let columnCount = controller.layout.columns.count
        controller.disableStripMode()
        #expect(controller.mode == .tiling)
        // Strip structure is retained so re-enabling restores column order.
        #expect(controller.layout.columns.count == columnCount)
        #expect(controller.isStripMode == false)
    }

    @Test func actionsAreNoOpsWhenNotInStripMode() {
        let (controller, bridge) = makeController(seed: [UUID()])
        // Mode is .tiling (never enabled).
        #expect(controller.openColumn() == nil)
        #expect(controller.openStackedWindow() == nil)
        controller.focusColumn(.right)
        controller.moveColumn(.right)
        controller.closeFocusedColumn()
        #expect(bridge.livePanels.count == 1) // nothing created or closed
    }

    // MARK: - Fullscreen (zoom a column)

    @Test func toggleColumnFullscreenFlipsStateWhenInStripMode() {
        let (controller, _) = makeController(seed: [UUID()])
        controller.enableStripMode()
        controller.openColumn() // 2 columns, focus index 1
        #expect(controller.isColumnFullscreen == false)
        #expect(controller.toggleColumnFullscreen() == true)
        #expect(controller.isColumnFullscreen == true)
        #expect(controller.toggleColumnFullscreen() == true)
        #expect(controller.isColumnFullscreen == false)
    }

    @Test func fullscreenDoesNotResizeAnyColumn() {
        let (controller, _) = makeController(seed: [UUID()])
        controller.enableStripMode()
        controller.openColumn()
        controller.openColumn() // 3 columns
        let widthsBefore = controller.layout.columns.map(\.width)
        controller.toggleColumnFullscreen()
        // Fullscreen is a pure render state: the model's column widths are untouched, so toggling
        // it off restores the strip exactly (the render expands the focused column, not the model).
        #expect(controller.layout.columns.map(\.width) == widthsBefore)
        controller.toggleColumnFullscreen()
        #expect(controller.layout.columns.map(\.width) == widthsBefore)
    }

    @Test func focusMoveClearsFullscreen() {
        let (controller, _) = makeController(seed: [UUID()])
        controller.enableStripMode()
        controller.openColumn() // 2 columns, focus index 1
        controller.toggleColumnFullscreen()
        #expect(controller.isColumnFullscreen == true)
        controller.focusColumn(.left) // navigating away must drop the expansion
        #expect(controller.isColumnFullscreen == false)
    }

    @Test func enteringOverviewClearsFullscreen() {
        let (controller, _) = makeOverflowingStrip()
        controller.toggleColumnFullscreen()
        #expect(controller.isColumnFullscreen == true)
        controller.enterOverview()
        #expect(controller.isColumnFullscreen == false)
        #expect(controller.isOverviewActive == true)
    }

    @Test func fullscreenInertWhenNotInStripMode() {
        let (controller, _) = makeController(seed: [UUID()])
        // Mode is .tiling (never enabled): the toggle reports no change and stays off.
        #expect(controller.toggleColumnFullscreen() == false)
        #expect(controller.isColumnFullscreen == false)
    }

    // MARK: - Overview (zoom-out)

    /// Build an overflowing strip (several columns, narrow viewport) focused mid-strip.
    private func makeOverflowingStrip() -> (WorkspaceStripController, FakeStripBridge) {
        let (controller, bridge) = makeController(seed: [UUID()])
        controller.setViewportWidth(900)
        controller.enableStripMode()
        for _ in 0..<5 { controller.openColumn() } // 6 columns total
        controller.focusColumn(.left)
        controller.focusColumn(.left) // move focus off the end, establishing a scroll offset
        return (controller, bridge)
    }

    @Test func togglingOverviewOnThenOffRestoresExactViewport() {
        let (controller, _) = makeOverflowingStrip()
        let focusBefore = controller.layout.focusedColumnIndex
        let offsetBefore = controller.layout.scrollOffset

        controller.toggleOverview()
        #expect(controller.isOverviewActive == true)
        // Moving the highlight around must not disturb the underlying viewport.
        controller.moveOverviewSelection(.right)
        controller.moveOverviewSelection(.right)

        controller.toggleOverview() // cancel
        #expect(controller.isOverviewActive == false)
        #expect(controller.layout.focusedColumnIndex == focusBefore)
        #expect(controller.layout.scrollOffset == offsetBefore)
    }

    @Test func selectingOverviewColumnFocusesItAndBringsItOnScreen() {
        let (controller, bridge) = makeOverflowingStrip()
        controller.enterOverview()
        // Highlight the last column and select it.
        for _ in 0..<controller.layout.columns.count {
            controller.moveOverviewSelection(.right)
        }
        let target = controller.overviewSelectionIndex
        controller.selectOverviewColumn()

        #expect(controller.isOverviewActive == false)
        #expect(controller.layout.focusedColumnIndex == target)
        // The newly focused column is fully visible in the normal layout.
        let viewport = CGRect(x: 0, y: 0, width: controller.viewportWidth, height: 1000)
        let frame = controller.layout.columnFrames(in: viewport)[target].frame
        #expect(frame.minX >= 0)
        #expect(frame.maxX <= controller.viewportWidth + 0.01)
        // Focus was routed to the selected column's panel.
        #expect(bridge.focused == controller.layout.columns[target].windows.first?.raw)
    }

    @Test func overviewSelectionClampsAtEnds() {
        let (controller, _) = makeOverflowingStrip()
        controller.enterOverview()
        for _ in 0..<20 { controller.moveOverviewSelection(.left) }
        #expect(controller.overviewSelectionIndex == 0)
        for _ in 0..<20 { controller.moveOverviewSelection(.right) }
        #expect(controller.overviewSelectionIndex == controller.layout.columns.count - 1)
    }

    @Test func overviewCapturesThumbnailsAndClearsOnExit() {
        let (controller, bridge) = makeOverflowingStrip()
        for column in controller.layout.columns {
            if let panelID = column.focusedWindow?.raw {
                bridge.thumbnailText[panelID] = "screen of \(panelID.uuidString.prefix(4))"
            }
        }
        controller.enterOverview()
        // One thumbnail captured per column.
        #expect(controller.overviewThumbnails.count == controller.layout.columns.count)
        controller.cancelOverview()
        #expect(controller.overviewThumbnails.isEmpty) // cleared on exit
    }

    @Test func overviewIsInertWhenNotInStripMode() {
        let (controller, _) = makeController(seed: [UUID()])
        controller.toggleOverview() // mode is .tiling
        #expect(controller.isOverviewActive == false)
    }

    @Test func sessionRoundTripRebuildsStrip() {
        let (controller, _) = makeController(seed: [UUID()])
        controller.enableStripMode()
        controller.openColumn()
        controller.openColumn()
        let persisted = controller.sessionColumnPanelIDs()
        #expect(persisted?.count == 3)

        // Simulate restore into a fresh controller with remapped (here identical) ids.
        let (restored, _) = makeController(seed: [])
        restored.restoreFromSession(columnPanelIDs: persisted ?? [], focusedColumnIndex: 1)
        #expect(restored.mode == .strip)
        #expect(restored.layout.columns.count == 3)
        #expect(restored.layout.focusedColumnIndex == 1)
    }
}
