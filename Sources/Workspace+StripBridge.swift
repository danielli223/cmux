import Bonsplit
import CoreGraphics
import CoreImage
import Foundation
import IOSurface
import QuartzCore

/// ``Workspace`` conformance to ``StripPanelBridge``: it backs niri-mode's strip with the
/// existing terminal-panel lifecycle (Bonsplit + `panels`). niri-mode reuses these paths
/// rather than forking panel creation, so a strip column is an ordinary terminal panel.
extension Workspace: StripPanelBridge {
    /// Shared Core Image context for converting a surface's presented `IOSurface` into a frozen
    /// overview snapshot. Reused so the (expensive) context is built once, not per snapshot.
    fileprivate static let stripSnapshotContext = CIContext(options: nil)

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

    func stripSourceSurfaceLayer(for panelID: UUID) -> CALayer? {
        (panels[panelID] as? TerminalPanel)?.liveSurfaceLayer()
    }

    func stripCaptureThumbnailImage(for panelID: UUID) -> CGImage? {
        guard let layer = stripSourceSurfaceLayer(for: panelID),
              let contents = layer.contents,
              CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        // The presented Metal drawable is exposed as the layer's `contents` IOSurface; render it
        // to a detached CGImage so the frozen tile keeps the pixels after the source stops drawing.
        let surface = contents as! IOSurfaceRef
        let ciImage = CIImage(ioSurface: surface)
        return Workspace.stripSnapshotContext.createCGImage(ciImage, from: ciImage.extent)
    }

    func stripPanelID(forSurfaceObject object: Any?) -> UUID? {
        // `.ghosttyDidRenderFrame` posts the surface's GhosttyNSView as the object; its
        // terminalSurface.id is the panel id (TerminalPanel.id == surface.id).
        guard let surfaceView = object as? GhosttyNSView,
              let surfaceID = surfaceView.terminalSurface?.id,
              panels[surfaceID] is TerminalPanel else { return nil }
        return surfaceID
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
