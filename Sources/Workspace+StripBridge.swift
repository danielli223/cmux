import Bonsplit
import Foundation

/// ``Workspace`` conformance to ``StripPanelBridge``: it backs niri-mode's strip with the
/// existing terminal-panel lifecycle (Bonsplit + `panels`). niri-mode reuses these paths
/// rather than forking panel creation, so a strip column is an ordinary terminal panel.
extension Workspace: StripPanelBridge {
    /// Terminal panel ids in Bonsplit pane order, used to seed the strip on mode enable.
    var stripSeedPanelIDs: [UUID] {
        var ids: [UUID] = []
        for paneId in bonsplitController.allPaneIds {
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id),
                      panels[panelId] is TerminalPanel else { continue }
                ids.append(panelId)
            }
        }
        return ids
    }

    var stripFocusedPanelID: UUID? { focusedPanelId }

    func stripCreateColumnTerminal(after panelID: UUID?) -> UUID? {
        guard let source = panelID ?? focusedPanelId ?? stripSeedPanelIDs.first else { return nil }
        return newTerminalSplit(from: source, orientation: .horizontal, focus: true)?.id
    }

    func stripCreateStackedTerminal(below panelID: UUID) -> UUID? {
        return newTerminalSplit(from: panelID, orientation: .vertical, focus: true)?.id
    }

    func stripFocusPanel(_ panelID: UUID) {
        focusPanel(panelID)
    }

    @discardableResult
    func stripClosePanel(_ panelID: UUID) -> Bool {
        closePanel(panelID)
    }

    func stripCaptureThumbnailText(for panelID: UUID) -> String? {
        (panels[panelID] as? TerminalPanel)?.captureViewportText()
    }

    func stripTerminalGridColumns(for panelID: UUID) -> Int? {
        (panels[panelID] as? TerminalPanel)?.terminalGridColumns()
    }

    /// The Bonsplit pane currently hosting the given panel, if any. Used by the strip renderer
    /// to satisfy ``PanelContentView``'s `paneId` requirement (panels stay Bonsplit-backed even
    /// in niri-mode).
    /// - Parameter panelID: The panel to locate.
    /// - Returns: The owning `PaneID`, or `nil` if the panel is not in the tree.
    func stripPaneId(forPanel panelID: UUID) -> PaneID? {
        guard let surfaceId = surfaceIdFromPanelId(panelID) else { return nil }
        for paneId in bonsplitController.allPaneIds {
            if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == surfaceId }) {
                return paneId
            }
        }
        return nil
    }
}
