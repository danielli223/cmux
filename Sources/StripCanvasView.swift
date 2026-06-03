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
            isWorkspaceInputActive: isWorkspaceInputActive,
            isWorkspaceVisible: isWorkspaceVisible,
            buildContent: { column, isColumnFocused in
                AnyView(self.columnContent(column: column, isColumnFocused: isColumnFocused))
            }
        )
    }

    /// Builds one column's hosted SwiftUI: the **focused** window only (tabbed column), at full
    /// column height, with a tab indicator when the column stacks more than one window.
    @ViewBuilder
    private func columnContent(column: StripColumn, isColumnFocused: Bool) -> some View {
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
                    // While the overview is up, the previously-visible (on-screen) columns keep
                    // rendering so their tiles can mirror a live color feed — they are visually
                    // suppressed in `reconcile` (host hidden) so the window-level portal does not
                    // bleed over the overview. Off-screen columns stay occluded (frozen tiles).
                    // When a column is fullscreened, the non-focused columns are likewise hidden so
                    // only the expanded column's portal renders.
                    isVisibleInUI: isWorkspaceVisible
                        && (!stripController.isOverviewActive
                            || stripController.overviewLiveColumnIDs.contains(column.id))
                        && (!stripController.isColumnFullscreen || isColumnFocused),
                    portalPriority: workspacePortalPriority,
                    isSplit: stripController.layout.columns.count > 1,
                    // Dim non-focused columns clearly so the focused one is unmistakable.
                    appearance: appearance.withStrongerUnfocusedDim(opacity: 0.55),
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
        let isWorkspaceInputActive: Bool
        let isWorkspaceVisible: Bool
        let buildContent: (StripColumn, Bool) -> AnyView
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
        isWorkspaceInputActive: Bool,
        isWorkspaceVisible: Bool,
        buildContent: @escaping (StripColumn, Bool) -> AnyView
    ) {
        let inputs = SyncInputs(
            layout: layout,
            isOverviewActive: isOverviewActive,
            overviewLiveColumnIDs: overviewLiveColumnIDs,
            isColumnFullscreen: isColumnFullscreen,
            isWorkspaceInputActive: isWorkspaceInputActive,
            isWorkspaceVisible: isWorkspaceVisible,
            buildContent: buildContent
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
        let buildContent = inputs.buildContent
        let viewport = CGRect(origin: .zero, size: view.bounds.size)
        let frames = layout.columnFrames(in: viewport)
        var live: Set<StripColumnID> = []
        var didReposition = false

        // Keep the gap-filling backdrop matched to the live terminal theme.
        view.layer?.backgroundColor = GhosttyBackgroundTheme.currentColor().cgColor

        // Move every column host within one transaction with implicit animations disabled, so a
        // pan snaps all columns to their new positions in a single frame instead of letting the
        // layer-backed hosts ease independently (which reads as a smear/flicker during the pan).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (index, column) in layout.columns.enumerated() {
            guard frames.indices.contains(index) else { continue }
            let isFocused = index == layout.focusedColumnIndex
            // When a column is fullscreened, the focused column takes the whole viewport and the
            // rest are parked off-screen (their portals are also hidden via `isVisibleInUI`); a
            // strip-space x keeps them laid out but fully outside the visible canvas.
            let frame: CGRect
            // A full-size frame parked entirely outside the visible canvas. Used both for
            // fullscreen's non-focused columns and for the overview's live-mirrored columns: the
            // portal keeps rendering (the size is unchanged, so it never reflows) but sits
            // off-screen, so it cannot bleed over the overview tiles that mirror it.
            let parkedOffscreen = CGRect(x: -(viewport.width + column.width + 200), y: 0,
                                         width: column.width, height: viewport.height)
            if isColumnFullscreen {
                frame = isFocused ? viewport : parkedOffscreen
            } else if isOverviewActive, inputs.overviewLiveColumnIDs.contains(column.id) {
                frame = parkedOffscreen
            } else {
                frame = frames[index].frame
            }
            // Rebuild the hosted SwiftUI only when content identity changes — NOT on scroll
            // (which changes only the frame). Focus / input-active / visibility are included so
            // the focus ring and portal visibility stay correct; none of them change on scroll.
            let key = [
                column.focusedWindow?.raw.uuidString ?? "none",
                String(column.windows.count),
                isFocused ? "f" : "-",
                inputs.isWorkspaceInputActive ? "a" : "-",
                inputs.isWorkspaceVisible ? "v" : "-",
                isOverviewActive ? "o" : "-", // toggling overview flips isVisibleInUI -> rebuild
                // live-mirrored columns stay visible (un-occluded) during the overview, so their
                // membership in the live set must invalidate the cached content.
                inputs.overviewLiveColumnIDs.contains(column.id) ? "L" : "-",
                isColumnFullscreen ? "z" : "-", // toggling fullscreen flips isVisibleInUI -> rebuild
            ].joined(separator: "|")
            live.insert(column.id)

            if var existing = hosts[column.id] {
                if existing.contentKey != key {
                    existing.controller.rootView = buildContent(column, isFocused)
                    existing.contentKey = key
                    hosts[column.id] = existing
                }
                if existing.controller.view.frame != frame {
                    existing.controller.view.frame = frame
                    didReposition = true
                }
                // NOTE: do NOT toggle `controller.view.isHidden` for the overview. Hiding the host
                // view suppresses SwiftUI's pending update pass, so the `isVisibleInUI = false`
                // rootView change above never reaches the terminal and the GPU portal stays
                // rendered (the faint terminal "bleed" through the overview backdrop). The portal
                // is hidden purely via `isVisibleInUI` — the same path workspace-switching uses.
            } else {
                let controller = NSHostingController(rootView: buildContent(column, isFocused))
                addChild(controller) // AppKit handles the parent/child lifecycle (no did/willMove)
                view.addSubview(controller.view)
                controller.view.frame = frame
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

        // Translating a column moves the terminal's host view in window space without changing
        // its own frame, so the GPU portal's frame observer never fires. Force every portal in
        // the window to re-read its anchor frame so terminals follow the column positions. This
        // must also run while the overview is up: the live-mirrored columns are parked off-screen,
        // and their portals only follow that move once re-synced (otherwise they bleed over the
        // overview). Off-screen columns are occluded (`isVisibleInUI = false`), so re-syncing them
        // is a no-op — no terminal flashes through the dimmed overview.
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
