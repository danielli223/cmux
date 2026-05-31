import Bonsplit
import CmuxStripLayout
import SwiftUI

/// Renders a ``Workspace`` as a niri-style scrollable strip when its
/// ``WorkspaceStripController`` is in ``WorkspaceLayoutMode/strip``.
///
/// Columns are positioned at the absolute frames produced by the pure
/// ``StripLayout/columnFrames(in:)`` — laid out left-to-right at their intrinsic widths and
/// panned by the scroll offset. Each column renders its vertically-stacked terminal windows
/// with the same ``PanelContentView`` the Bonsplit renderer uses, so terminal hosting,
/// portals, and focus all work unchanged. Off-screen columns stay alive (their terminal
/// processes keep running) but their portal rendering is gated via `isVisibleInUI`, the
/// documented "live but throttle off-screen rendering" default (see `docs/kb/mapping.md`).
///
/// The view contains **no layout math** — all geometry comes from the model — and the
/// `ForEach` is eager (inside a `ZStack`, not a `Lazy*` container), avoiding the
/// `LazyLayoutViewCache` thrash that the snapshot-boundary rule guards against.
struct StripWorkspaceView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var stripController: WorkspaceStripController
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let workspacePortalPriority: Int
    let appearance: PanelAppearance

    var body: some View {
        GeometryReader { geo in
            let viewport = CGRect(origin: .zero, size: geo.size)
            let frames = stripController.layout.columnFrames(in: viewport)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(frames.enumerated()), id: \.element.id) { entry in
                    let columnFrame = entry.element
                    let columnIndex = entry.offset
                    if stripController.layout.columns.indices.contains(columnIndex) {
                        columnView(
                            column: stripController.layout.columns[columnIndex],
                            isColumnFocused: columnIndex == stripController.layout.focusedColumnIndex,
                            frame: columnFrame.frame,
                            isVisible: columnFrame.isVisible
                        )
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .overlay {
                if stripController.isOverviewActive {
                    overviewLayer(in: geo.size)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: stripController.isOverviewActive)
            .onAppear { stripController.setViewportWidth(geo.size.width) }
            .onChange(of: geo.size.width) { _, newWidth in
                stripController.setViewportWidth(newWidth)
            }
            .background(StripScrollCatcher(stripController: stripController))
        }
    }

    // MARK: - Overview (zoom-out) rendering

    /// The niri-style overview: the whole strip scaled down to fit the content area, with one
    /// tile per column and a highlight on the selected one. Tiles are lightweight (background
    /// + title + tab-count indicator), not live or snapshot terminal pixels — see the type doc
    /// and `docs/niri-mode.md` for the rationale. Clicking a tile selects that column.
    @ViewBuilder
    private func overviewLayer(in size: CGSize) -> some View {
        let frames = stripController.layout.overviewColumnFrames(in: size)
        ZStack(alignment: .topLeading) {
            // Dimmed backdrop so the zoomed-out tiles read as a distinct mode.
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { stripController.cancelOverview() }
            ForEach(Array(frames.enumerated()), id: \.element.id) { entry in
                let index = entry.offset
                if stripController.layout.columns.indices.contains(index) {
                    overviewTile(
                        column: stripController.layout.columns[index],
                        index: index,
                        isSelected: index == stripController.overviewSelectionIndex,
                        frame: entry.element.frame
                    )
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// A single column tile in the overview.
    @ViewBuilder
    private func overviewTile(column: StripColumn, index: Int, isSelected: Bool, frame: CGRect) -> some View {
        let title = overviewColumnTitle(column: column, index: index)
        let accent = Color.accentColor
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: GhosttyBackgroundTheme.currentColor()))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? accent : Color.white.opacity(0.18),
                                  lineWidth: isSelected ? 3 : 1)
            )
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.92))
                    if column.windows.count > 1 {
                        // Tabbed/stacked column: show the window count + active index.
                        Text(String(
                            localized: "niri.overview.tabIndicator",
                            defaultValue: "\(column.focusedWindowIndex + 1)/\(column.windows.count)"
                        ))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.16)))
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 6)
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .contentShape(Rectangle())
            .onTapGesture {
                stripController.setOverviewSelection(index)
                stripController.selectOverviewColumn()
            }
    }

    private func overviewColumnTitle(column: StripColumn, index: Int) -> String {
        if let panelID = column.windows.first?.raw,
           let panel = workspace.panels[panelID] {
            let title = panel.displayTitle
            if !title.isEmpty { return title }
        }
        return String(localized: "niri.overview.columnFallback", defaultValue: "Column \(index + 1)")
    }

    /// Renders one column: its vertically-stacked terminal windows at the column's frame.
    @ViewBuilder
    private func columnView(
        column: StripColumn,
        isColumnFocused: Bool,
        frame: CGRect,
        isVisible: Bool
    ) -> some View {
        let windowCount = max(column.windows.count, 1)
        let windowHeight = frame.height / CGFloat(windowCount)
        VStack(spacing: 0) {
            ForEach(Array(column.windows.enumerated()), id: \.element.raw) { windowEntry in
                let windowIndex = windowEntry.offset
                let panelID = windowEntry.element.raw
                let isWindowFocused = isColumnFocused && windowIndex == column.focusedWindowIndex
                windowView(panelID: panelID, isFocused: isWindowFocused, isVisible: isVisible)
                    .frame(height: windowHeight)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
    }

    /// Renders a single terminal window (one panel) inside a column.
    @ViewBuilder
    private func windowView(panelID: UUID, isFocused: Bool, isVisible: Bool) -> some View {
        if let panel = workspace.panels[panelID],
           let paneId = workspace.stripPaneId(forPanel: panelID) {
            PanelContentView(
                panel: panel,
                workspaceId: workspace.id,
                paneId: paneId,
                isFocused: isWorkspaceInputActive && isFocused,
                isSelectedInPane: true,
                // Hide the live terminal portals while the overview is up so its tiles aren't
                // covered by the GPU portal layer (terminals keep running; only rendering is gated).
                isVisibleInUI: isWorkspaceVisible && isVisible && !stripController.isOverviewActive,
                portalPriority: workspacePortalPriority,
                isSplit: stripController.layout.columns.count > 1,
                appearance: appearance,
                hasUnreadNotification: false,
                terminalAgentContext: "",
                onFocus: {
                    guard isWorkspaceInputActive else { return }
                    guard workspace.panels[panelID] != nil else { return }
                    workspace.focusPanel(panelID, trigger: .terminalFirstResponder)
                },
                onRequestPanelFocus: {
                    guard isWorkspaceInputActive else { return }
                    guard workspace.panels[panelID] != nil else { return }
                    workspace.focusPanel(panelID)
                },
                onResumeAgentHibernation: {
                    guard isWorkspaceInputActive else { return }
                    guard workspace.panels[panelID] != nil else { return }
                    workspace.resumeAgentHibernation(panelId: panelID, focus: true)
                },
                onAutoResumeAgentHibernation: {
                    guard isWorkspaceInputActive else { return }
                    guard workspace.panels[panelID] != nil else { return }
                    workspace.resumeAgentHibernation(panelId: panelID, focus: false)
                },
                onTriggerFlash: { workspace.triggerDebugFlash(panelId: panelID) }
            )
        } else {
            Color.clear
        }
    }
}

/// An AppKit-backed transparent overlay that turns continuous two-finger trackpad scrolling
/// into strip panning (with snap-to-column on gesture end), matching niri's touchpad gesture.
/// Discrete wheel ticks and keyboard navigation drive focus changes elsewhere; this view owns
/// only the continuous pixel-pan.
private struct StripScrollCatcher: NSViewRepresentable {
    let stripController: WorkspaceStripController

    func makeNSView(context: Context) -> StripScrollCatcherView {
        let view = StripScrollCatcherView()
        view.stripController = stripController
        return view
    }

    func updateNSView(_ nsView: StripScrollCatcherView, context: Context) {
        nsView.stripController = stripController
    }
}

/// The `NSView` that receives `scrollWheel:` events for ``StripScrollCatcher``.
final class StripScrollCatcherView: NSView {
    weak var stripController: WorkspaceStripController?

    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard let stripController, stripController.isStripMode else {
            super.scrollWheel(with: event)
            return
        }
        // Only treat predominantly-horizontal scrolls as strip pans; vertical scroll falls
        // through to the focused terminal.
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard abs(dx) > abs(dy) else {
            super.scrollWheel(with: event)
            return
        }
        // Natural scrolling: swiping content left (negative dx) reveals columns to the right.
        stripController.panBy(-dx)
        if event.phase == .ended || event.momentumPhase == .ended {
            stripController.snapScroll()
        }
    }
}
