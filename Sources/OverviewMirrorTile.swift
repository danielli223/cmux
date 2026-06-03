import AppKit
import CmuxStripLayout
import QuartzCore
import SwiftUI

/// SwiftUI host for one window's overview tile content: a live `IOSurface` mirror (on-screen
/// columns), a frozen color snapshot (off-screen columns), or nothing (`.text`, where
/// ``StripWorkspaceView`` shows the scaled-text fallback instead).
///
/// The ``pendingRefresh`` set is published by ``WorkspaceStripController`` at ~12fps; passing it
/// as a stored property makes SwiftUI re-run ``updateNSView(_:context:)`` on each throttled tick,
/// which is where a live tile re-reads its source `IOSurface`. Do not wrap this view in `.id(...)`
/// keyed on the refresh — that would tear down and recreate the `NSView` every frame.
struct OverviewMirrorTile: NSViewRepresentable {
    /// The panel whose terminal this tile mirrors.
    let panelID: UUID
    /// The strip window id, used to test membership in ``pendingRefresh``.
    let windowID: StripWindowID
    /// How this tile should present (``OverviewTileMode/live`` / ``OverviewTileMode/frozen``).
    let mode: OverviewTileMode
    /// The live source layer to mirror, when ``mode`` is ``OverviewTileMode/live``.
    let sourceLayer: CALayer?
    /// The frozen snapshot to show, when ``mode`` is ``OverviewTileMode/frozen``.
    let frozenImage: CGImage?
    /// Windows the controller flagged for a throttled refresh this tick (drives re-evaluation).
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
