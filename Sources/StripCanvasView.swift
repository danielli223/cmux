import AppKit
import CmuxStripLayout
import SwiftUI

/// SwiftUI bridge that hosts the niri strip's terminal columns in an AppKit canvas.
///
/// Each column is an `NSHostingController` added as a **child view controller** and a
/// frame-positioned subview of ``StripCanvasNSView``. This is the fix for the "1-character
/// sliver" rendering: cmux's terminal portal sizes each Ghostty surface to its host view's
/// frame intersected with every ancestor's bounds, and a SwiftUI `.position()` layout
/// interposes tiny-bounds containers that clamp the surface to nothing. Hosting each column as
/// a full-frame AppKit subview (as Bonsplit does, via a child hosting controller) gives the
/// portal the real column rectangle.
struct StripCanvasView: NSViewControllerRepresentable {
    @ObservedObject var workspace: Workspace
    @ObservedObject var stripController: WorkspaceStripController
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let workspacePortalPriority: Int
    let appearance: PanelAppearance

    func makeNSViewController(context: Context) -> StripCanvasViewController {
        StripCanvasViewController()
    }

    func updateNSViewController(_ controller: StripCanvasViewController, context: Context) {
        controller.sync(
            layout: stripController.layout,
            isOverviewActive: stripController.isOverviewActive,
            overviewLiveColumnIDs: stripController.overviewLiveColumnIDs,
            isColumnFullscreen: stripController.isColumnFullscreen,
            isAnimatingScroll: stripController.isAnimatingScroll,
            isWorkspaceInputActive: isWorkspaceInputActive,
            isWorkspaceVisible: isWorkspaceVisible,
            buildContent: { column, isColumnFocused, shouldRender in
                AnyView(self.columnContent(column: column, isColumnFocused: isColumnFocused, shouldRender: shouldRender))
            },
            sourceLayer: { panelID in self.workspace.stripSourceSurfaceLayer(for: panelID) },
            snapshot: { panelID in self.stripController.glideSnapshot(for: panelID) }
        )
        // `updateNSViewController` re-runs on every `stripController` change (it is an
        // `@ObservedObject`), including the ~12fps `pendingMirrorRefresh`, so reconcile refreshes the
        // mirrors on each tick.
    }

    /// Builds one column's hosted SwiftUI: the **focused** window only (tabbed column), at full
    /// column height, with a tab indicator when the column stacks more than one window.
    /// - Parameter shouldRender: Whether the live terminal portal should render. Decided in
    ///   ``StripCanvasViewController/reconcile(_:)``: visible/focused columns render on-screen; peek
    ///   and off-screen-buffer columns render *parked off-screen* (so a mirror can show them without
    ///   reflowing); far/occluded columns do not render. The column is never partially clipped while
    ///   rendering, so the terminal grid never reflows to a sliver.
    @ViewBuilder
    private func columnContent(column: StripColumn, isColumnFocused: Bool, shouldRender: Bool) -> some View {
        ZStack(alignment: .top) {
            if let panelID = column.focusedWindow?.raw,
               let panel = workspace.panels[panelID],
               let paneId = workspace.stripPaneId(forPanel: panelID) {
                PanelContentView(
                    panel: panel,
                    workspaceId: workspace.id,
                    paneId: paneId,
                    isFocused: isWorkspaceInputActive && isColumnFocused,
                    isSelectedInPane: true,
                    isVisibleInUI: isWorkspaceVisible && shouldRender,
                    portalPriority: workspacePortalPriority,
                    isSplit: stripController.layout.columns.count > 1,
                    // No unfocused dimming — all columns render at full brightness.
                    appearance: appearance.withStrongerUnfocusedDim(opacity: 0),
                    hasUnreadNotification: false,
                    terminalAgentContext: "",
                    onFocus: {
                        guard isWorkspaceInputActive, workspace.panels[panelID] != nil else { return }
                        workspace.focusPanel(panelID, trigger: .terminalFirstResponder)
                    },
                    onRequestPanelFocus: {
                        guard isWorkspaceInputActive, workspace.panels[panelID] != nil else { return }
                        workspace.focusPanel(panelID)
                    },
                    onResumeAgentHibernation: {
                        guard isWorkspaceInputActive, workspace.panels[panelID] != nil else { return }
                        workspace.resumeAgentHibernation(panelId: panelID, focus: true)
                    },
                    onAutoResumeAgentHibernation: {
                        guard isWorkspaceInputActive, workspace.panels[panelID] != nil else { return }
                        workspace.resumeAgentHibernation(panelId: panelID, focus: false)
                    },
                    onTriggerFlash: { workspace.triggerDebugFlash(panelId: panelID) }
                )
            } else {
                Color(nsColor: GhosttyBackgroundTheme.currentColor())
            }
            if column.windows.count > 1 {
                StripTabIndicator(active: column.focusedWindowIndex, count: column.windows.count)
                    .padding(.top, 6)
            }
        }
    }
}

/// A compact "tab" indicator for a stacked (tabbed) column: a row of pips, the focused one
/// filled, plus a count. Switch tabs with `focus-window up/down`.
private struct StripTabIndicator: View {
    let active: Int
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == active ? Color.accentColor : Color.white.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
            Text("\(active + 1)/\(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.6)))
        .allowsHitTesting(false)
    }
}

/// View controller that positions one child `NSHostingController` per strip column by frame.
///
/// Using a view controller (not a bare view) gives each column hosting controller a proper
/// parent via `addChild`, so the responder chain, focus, and SwiftUI lifecycle behave like
/// Bonsplit's panes. Columns are reused per column id across syncs, so panning only moves
/// frames and never remounts the terminal portal.
final class StripCanvasViewController: NSViewController {
    private struct Hosted {
        let controller: NSHostingController<AnyView>
        var contentKey: String
    }

    private var hosts: [StripColumnID: Hosted] = [:]

    /// On-screen IOSurface mirrors keyed by column id: used both for the sliding columns during a
    /// nav glide and for the resting edge "peek" slivers. The real portal renders parked off-screen
    /// (full size, no reflow); the mirror shows it on-screen.
    private var motionMirrors: [StripColumnID: OverviewMirrorView] = [:]

    /// The most recent ``sync(layout:...)`` inputs, retained so ``viewDidLayout()`` can re-run the
    /// layout against the canvas's *current* bounds. Without this, a bounds change that does not
    /// originate from a SwiftUI update — most importantly the macOS full-screen enter/exit, where
    /// AppKit reparents and resizes the content view — would never re-flow the columns, leaving
    /// them sized to the pre-transition viewport (the "dimensions bug out on full screen" report).
    private var lastSync: SyncInputs?

    private struct SyncInputs {
        let layout: StripLayout
        let isOverviewActive: Bool
        let overviewLiveColumnIDs: Set<StripColumnID>
        let isColumnFullscreen: Bool
        let isAnimatingScroll: Bool
        let isWorkspaceInputActive: Bool
        let isWorkspaceVisible: Bool
        let buildContent: (StripColumn, Bool, Bool) -> AnyView
        let sourceLayer: (UUID) -> CALayer?
        let snapshot: (UUID) -> CGImage?
    }

    override func loadView() {
        let canvas = StripCanvasNSView()
        canvas.wantsLayer = true
        canvas.layer?.masksToBounds = true
        // Paint the canvas the terminal background color. A column pan moves the host views
        // immediately but the GPU terminal portals re-read their frames one runloop tick later;
        // for that single frame the canvas shows through behind/beside a column. With no backing
        // color that gap flashes whatever SwiftUI sits underneath (often light) — the "flash that
        // hurts" on every scroll. A dark terminal-matched fill makes the transient gap invisible.
        canvas.layer?.backgroundColor = GhosttyBackgroundTheme.currentColor().cgColor
        view = canvas
    }

    /// Re-flows the columns against the canvas's current bounds whenever AppKit lays the view out
    /// (window resize, sidebar toggle, full-screen enter/exit). Reuses the last ``sync`` inputs so
    /// the render never lags behind a bounds change that did not come through SwiftUI.
    override func viewDidLayout() {
        super.viewDidLayout()
        if let lastSync { reconcile(lastSync) }
    }

    /// Reconciles the hosted column views with the current ``StripLayout``.
    /// - Parameters:
    ///   - layout: The current strip model.
    ///   - isOverviewActive: When true, the overview tiles cover the canvas. Columns in
    ///     `overviewLiveColumnIDs` keep rendering (for live tiles) but are hidden in place; the
    ///     rest are occluded.
    ///   - overviewLiveColumnIDs: Column ids that stay rendering-but-suppressed during the overview
    ///     so their tiles can mirror a live color feed.
    ///   - isColumnFullscreen: When true, the focused column fills the viewport and the others are
    ///     parked off-screen with their portals hidden.
    ///   - isWorkspaceInputActive: Whether this workspace has keyboard focus.
    ///   - isWorkspaceVisible: Whether this workspace is visible.
    ///   - buildContent: Builds a column's SwiftUI content; the `Bool` is whether it is focused.
    func sync(
        layout: StripLayout,
        isOverviewActive: Bool,
        overviewLiveColumnIDs: Set<StripColumnID>,
        isColumnFullscreen: Bool,
        isAnimatingScroll: Bool,
        isWorkspaceInputActive: Bool,
        isWorkspaceVisible: Bool,
        buildContent: @escaping (StripColumn, Bool, Bool) -> AnyView,
        sourceLayer: @escaping (UUID) -> CALayer?,
        snapshot: @escaping (UUID) -> CGImage?
    ) {
        let inputs = SyncInputs(
            layout: layout,
            isOverviewActive: isOverviewActive,
            overviewLiveColumnIDs: overviewLiveColumnIDs,
            isColumnFullscreen: isColumnFullscreen,
            isAnimatingScroll: isAnimatingScroll,
            isWorkspaceInputActive: isWorkspaceInputActive,
            isWorkspaceVisible: isWorkspaceVisible,
            buildContent: buildContent,
            sourceLayer: sourceLayer,
            snapshot: snapshot
        )
        lastSync = inputs
        reconcile(inputs)
    }

    /// Positions every column host from `inputs` against the canvas's live `view.bounds`, rebuilds
    /// content whose identity changed, and re-syncs the terminal portals. Idempotent: safe to call
    /// from both ``sync`` and ``viewDidLayout()``.
    private func reconcile(_ inputs: SyncInputs) {
        let layout = inputs.layout
        let isOverviewActive = inputs.isOverviewActive
        let isColumnFullscreen = inputs.isColumnFullscreen
        let isAnimating = inputs.isAnimatingScroll
        let buildContent = inputs.buildContent
        // Two live columns fill an inset region; a `peek`-wide margin on each side shows a mirror of
        // the neighbours. The model lays columns out in the inset (effective) width; we render them
        // shifted right by `peek` so the margins are free for the slivers.
        let peek = WorkspaceStripController.columnPeekWidth
        let canvasSize = view.bounds.size
        let canvasW = canvasSize.width
        let effective = CGRect(x: 0, y: 0, width: max(1, canvasW - 2 * peek), height: canvasSize.height)
        let frames = layout.columnFrames(in: effective)
        var live: Set<StripColumnID> = []
        var didReposition = false
        // On-screen mirror placements (sliding columns during a glide; resting peek slivers).
        var mirrorPlacements: [(id: StripColumnID, panel: UUID?, frame: CGRect)] = []

        view.layer?.backgroundColor = GhosttyBackgroundTheme.currentColor().cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (index, column) in layout.columns.enumerated() {
            guard frames.indices.contains(index) else { continue }
            let isFocused = index == layout.focusedColumnIndex
            let insetFrame = frames[index].frame.offsetBy(dx: peek, dy: 0)
            // A full-size frame parked entirely off-screen: the portal keeps its size (never reflows).
            let parked = CGRect(x: -(canvasW + column.width + 200), y: 0,
                                width: column.width, height: canvasSize.height)
            let intersectsCanvas = insetFrame.maxX > 0 && insetFrame.minX < canvasW
            let fullyInLive = insetFrame.minX >= peek - 0.5 && insetFrame.maxX <= canvasW - peek + 0.5
            // "Near" = within one column of the canvas. Near columns render continuously (parked when
            // off-screen) so the visible<->peek<->motion transitions never tear a surface down — the
            // root cause of the compress/disappear bugs.
            let near = insetFrame.maxX > -column.width && insetFrame.minX < canvasW + column.width

            // Mirror-during-motion: the real portal is NEVER on-screen during motion and NEVER hidden
            // while near; everything seen is a mirror. Only a settled, fully-visible column promotes
            // to an on-screen portal.
            let portalFrame: CGRect
            let shouldRender: Bool
            var mirror: CGRect?
            if isColumnFullscreen {
                portalFrame = isFocused ? CGRect(origin: .zero, size: canvasSize) : parked
                shouldRender = isFocused
            } else if isOverviewActive {
                // EVERY column parks off-screen during the overview. Terminal portals are window-level
                // GPU surfaces that draw above the SwiftUI backdrop, so any column left at an on-screen
                // position (e.g. a peek sliver in the margin) bleeds over it — which is why only the
                // sides bled. Live columns keep rendering (parked) so their overview tiles mirror them;
                // the rest are occluded.
                portalFrame = parked
                shouldRender = inputs.overviewLiveColumnIDs.contains(column.id)
            } else if isAnimating {
                portalFrame = parked
                shouldRender = true // keep every column warm (see below); mirror only the visible ones
                if near, intersectsCanvas { mirror = insetFrame }
            } else if fullyInLive {
                portalFrame = insetFrame // settled & fully visible -> real on-screen portal
                shouldRender = true
            } else if intersectsCanvas {
                portalFrame = parked // settled peek sliver -> parked + rendering, mirror shows the edge
                shouldRender = true
                mirror = insetFrame
            } else {
                // Keep EVERY off-screen column warm: render it parked at full size so scrolling back
                // never has to reload it. (A column still has to be on-screen once to establish its
                // surface — a never-rendered terminal can't start while parked off-screen.) Higher
                // steady GPU/memory cost, accepted for instant scrolling.
                portalFrame = parked
                shouldRender = true
            }
            if let mirror {
                mirrorPlacements.append((id: column.id, panel: column.focusedWindow?.raw, frame: mirror))
            }

            // Rebuild content only when identity / render-gate changes (NOT on scroll, which only
            // moves the frame).
            let key = [
                column.focusedWindow?.raw.uuidString ?? "none",
                String(column.windows.count),
                isFocused ? "f" : "-",
                inputs.isWorkspaceInputActive ? "a" : "-",
                inputs.isWorkspaceVisible ? "v" : "-",
                shouldRender ? "r" : "-",
            ].joined(separator: "|")
            live.insert(column.id)

            if var existing = hosts[column.id] {
                if existing.contentKey != key {
                    existing.controller.rootView = buildContent(column, isFocused, shouldRender)
                    existing.contentKey = key
                    hosts[column.id] = existing
                }
                if existing.controller.view.frame != portalFrame {
                    existing.controller.view.frame = portalFrame
                    didReposition = true
                }
            } else {
                let controller = NSHostingController(rootView: buildContent(column, isFocused, shouldRender))
                addChild(controller)
                view.addSubview(controller.view)
                controller.view.frame = portalFrame
                hosts[column.id] = Hosted(controller: controller, contentKey: key)
                didReposition = true
            }
        }

        // Remove hosts for columns that no longer exist.
        for (id, hosted) in hosts where !live.contains(id) {
            hosted.controller.view.removeFromSuperview()
            hosted.controller.removeFromParent()
            hosts.removeValue(forKey: id)
            didReposition = true
        }

        // Place / refresh / remove on-screen mirrors. A mirror reflects the parked-but-rendering
        // column's live IOSurface (falling back to its cached snapshot before its first frame).
        var mirrorIDs: Set<StripColumnID> = []
        for entry in mirrorPlacements {
            mirrorIDs.insert(entry.id)
            let mirrorView: OverviewMirrorView
            if let existing = motionMirrors[entry.id] {
                mirrorView = existing
            } else {
                mirrorView = OverviewMirrorView()
                view.addSubview(mirrorView) // above the (off-screen) hosts; margins never overlap live portals
                motionMirrors[entry.id] = mirrorView
            }
            if mirrorView.frame != entry.frame { mirrorView.frame = entry.frame }
            mirrorView.refresh(
                liveSource: entry.panel.flatMap { inputs.sourceLayer($0) },
                frozenFallback: entry.panel.flatMap { inputs.snapshot($0) }
            )
        }
        for (id, mirrorView) in motionMirrors where !mirrorIDs.contains(id) {
            motionMirrors.removeValue(forKey: id)
            if !isOverviewActive && !isColumnFullscreen && !isAnimating {
                // SETTLED: a column just promoted to an on-screen portal. Retire after a short delay
                // so its real portal re-syncs (async, one tick late) and renders on top first — no
                // 1-frame settle gap. The closure holds the view strongly until removal.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    mirrorView.removeFromSuperview()
                }
            } else {
                // During motion (or overview/fullscreen): remove at once. A delayed removal here
                // leaves a mirror hanging at the edge as a column slides off — the "lingering text".
                mirrorView.removeFromSuperview()
            }
        }

        // Moving a host in window space doesn't fire the GPU portal's frame observer; force the
        // portals to re-read their anchor frames so terminals follow the column positions.
        if didReposition, let window = view.window {
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        }
    }
}

/// The flipped AppKit canvas (top-left origin) so the rectangles from
/// ``StripLayout/columnFrames(in:)`` map directly to subview frames.
final class StripCanvasNSView: NSView {
    override var isFlipped: Bool { true }
}
