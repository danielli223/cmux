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
                    // Hide the live terminal portals while the overview is up (the portal is a
                    // window-level layer above SwiftUI, so it would otherwise show through the
                    // dimmed overview). Terminals keep running; only rendering is gated.
                    isVisibleInUI: isWorkspaceVisible && !stripController.isOverviewActive,
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

    override func loadView() {
        let canvas = StripCanvasNSView()
        canvas.wantsLayer = true
        canvas.layer?.masksToBounds = true
        view = canvas
    }

    /// Reconciles the hosted column views with the current ``StripLayout``.
    /// - Parameters:
    ///   - layout: The current strip model.
    ///   - isOverviewActive: When true, hide the live terminals (the overview tiles cover them).
    ///   - isWorkspaceInputActive: Whether this workspace has keyboard focus.
    ///   - isWorkspaceVisible: Whether this workspace is visible.
    ///   - buildContent: Builds a column's SwiftUI content; the `Bool` is whether it is focused.
    func sync(
        layout: StripLayout,
        isOverviewActive: Bool,
        isWorkspaceInputActive: Bool,
        isWorkspaceVisible: Bool,
        buildContent: (StripColumn, Bool) -> AnyView
    ) {
        let viewport = CGRect(origin: .zero, size: view.bounds.size)
        let frames = layout.columnFrames(in: viewport)
        var live: Set<StripColumnID> = []
        var didReposition = false

        for (index, column) in layout.columns.enumerated() {
            guard frames.indices.contains(index) else { continue }
            let frame = frames[index].frame
            let isFocused = index == layout.focusedColumnIndex
            // Rebuild the hosted SwiftUI only when content identity changes — NOT on scroll
            // (which changes only the frame). Focus / input-active / visibility are included so
            // the focus ring and portal visibility stay correct; none of them change on scroll.
            let key = [
                column.focusedWindow?.raw.uuidString ?? "none",
                String(column.windows.count),
                isFocused ? "f" : "-",
                isWorkspaceInputActive ? "a" : "-",
                isWorkspaceVisible ? "v" : "-",
                isOverviewActive ? "o" : "-", // toggling overview flips isVisibleInUI -> rebuild
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
        // the window to re-read its anchor frame so terminals follow the column positions. Skip
        // while the overview is up: the live portals are hidden there, and re-syncing them can
        // briefly flash the previously-focused terminal through the dimmed overview.
        if didReposition, !isOverviewActive, let window = view.window {
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        }
    }
}

/// The flipped AppKit canvas (top-left origin) so the rectangles from
/// ``StripLayout/columnFrames(in:)`` map directly to subview frames.
final class StripCanvasNSView: NSView {
    override var isFlipped: Bool { true }
}
