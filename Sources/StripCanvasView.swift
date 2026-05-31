import AppKit
import CmuxStripLayout
import SwiftUI

/// SwiftUI bridge that hosts the niri strip's terminal columns in an AppKit canvas.
///
/// Each column is an `NSHostingController` added as a direct, frame-positioned subview of
/// ``StripCanvasNSView``. This is the fix for the "1-character sliver" rendering: cmux's
/// terminal portal sizes each Ghostty surface to its host view's frame intersected with every
/// ancestor's bounds, and a SwiftUI `.position()` layout interposes tiny-bounds containers that
/// clamp the surface to nothing. Hosting each column as a full-frame AppKit subview (like
/// Bonsplit does) gives the portal the real column rectangle.
struct StripCanvasView: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    @ObservedObject var stripController: WorkspaceStripController
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let workspacePortalPriority: Int
    let appearance: PanelAppearance

    func makeNSView(context: Context) -> StripCanvasNSView {
        StripCanvasNSView()
    }

    func updateNSView(_ canvas: StripCanvasNSView, context: Context) {
        canvas.sync(
            layout: stripController.layout,
            isOverviewActive: stripController.isOverviewActive,
            contentKey: { column in
                // Rebuild a column's hosted SwiftUI only when its visible (focused) window or
                // tab count changes — not on every scroll — to avoid remounting the portal.
                "\(column.focusedWindow?.raw.uuidString ?? "none")|\(column.windows.count)|\(isWorkspaceInputActive)|\(isWorkspaceVisible)"
            },
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
                    isVisibleInUI: isWorkspaceVisible,
                    portalPriority: workspacePortalPriority,
                    isSplit: stripController.layout.columns.count > 1,
                    appearance: appearance,
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
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.55)))
        .allowsHitTesting(false)
    }
}

/// The AppKit canvas that positions one `NSHostingController` per strip column by frame.
///
/// Flipped (top-left origin) so the rectangles from ``StripLayout/columnFrames(in:)`` map
/// directly. Reuses a controller per column id across syncs so panning only moves frames and
/// never remounts the terminal portal.
final class StripCanvasNSView: NSView {
    private struct Hosted {
        let controller: NSHostingController<AnyView>
        var contentKey: String
    }

    private var hosts: [StripColumnID: Hosted] = [:]

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reconciles the hosted column views with the current ``StripLayout``.
    /// - Parameters:
    ///   - layout: The current strip model.
    ///   - isOverviewActive: When true, hide the live terminals (the overview tiles cover them).
    ///   - contentKey: Identity of a column's *content* — its hosted SwiftUI is rebuilt only when
    ///     this changes, so scrolling (frame-only changes) never remounts the portal.
    ///   - buildContent: Builds a column's SwiftUI content; the `Bool` is whether it's focused.
    func sync(
        layout: StripLayout,
        isOverviewActive: Bool,
        contentKey: (StripColumn) -> String,
        buildContent: (StripColumn, Bool) -> AnyView
    ) {
        let viewport = CGRect(origin: .zero, size: bounds.size)
        let frames = layout.columnFrames(in: viewport)
        var live: Set<StripColumnID> = []

        for (index, column) in layout.columns.enumerated() {
            guard frames.indices.contains(index) else { continue }
            let frame = frames[index].frame
            let isFocused = index == layout.focusedColumnIndex
            let key = contentKey(column)
            live.insert(column.id)

            if var existing = hosts[column.id] {
                if existing.contentKey != key {
                    existing.controller.rootView = buildContent(column, isFocused)
                    existing.contentKey = key
                    hosts[column.id] = existing
                }
                existing.controller.view.frame = frame
                existing.controller.view.isHidden = isOverviewActive
            } else {
                let controller = NSHostingController(rootView: buildContent(column, isFocused))
                controller.view.frame = frame
                controller.view.isHidden = isOverviewActive
                addSubview(controller.view)
                hosts[column.id] = Hosted(controller: controller, contentKey: key)
            }
        }

        // Remove hosts for columns that no longer exist.
        for (id, hosted) in hosts where !live.contains(id) {
            hosted.controller.view.removeFromSuperview()
            hosts.removeValue(forKey: id)
        }
    }
}
