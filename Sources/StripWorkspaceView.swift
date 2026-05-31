import AppKit
import Bonsplit
import CmuxStripLayout
import SwiftUI

/// Renders a ``Workspace`` as a niri-style scrollable strip when its
/// ``WorkspaceStripController`` is in ``WorkspaceLayoutMode/strip``.
///
/// Columns are laid out at the absolute frames produced by the pure
/// ``StripLayout/columnFrames(in:)``. **Crucially, the terminals are hosted in an AppKit
/// canvas (``StripCanvasNSView``) — one `NSHostingController` per column positioned by frame,
/// the same hosting shape Bonsplit uses.** An earlier SwiftUI `.position()` layout made cmux's
/// terminal portal clamp every surface to a tiny ancestor's bounds, rendering terminals as
/// one-character slivers (the portal walks the superview chain intersecting bounds, and
/// `.position()` containers size to the position point, not the column). Hosting each column as
/// a full-frame AppKit subview gives the portal the real column rectangle.
///
/// Tabbed columns: a column shows only its **focused** window at full height; the others stay
/// alive but hidden, switched with `focus-window up/down`, with a tab indicator. Column widths
/// derive from the live content area (see ``WorkspaceStripController/newColumnWidth``).
struct StripWorkspaceView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var stripController: WorkspaceStripController
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let workspacePortalPriority: Int
    let appearance: PanelAppearance

    var body: some View {
        GeometryReader { geo in
            ZStack {
                StripCanvasView(
                    workspace: workspace,
                    stripController: stripController,
                    isWorkspaceVisible: isWorkspaceVisible,
                    isWorkspaceInputActive: isWorkspaceInputActive,
                    workspacePortalPriority: workspacePortalPriority,
                    appearance: appearance
                )
                if stripController.isOverviewActive {
                    overviewLayer(in: geo.size)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
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
    /// tile per column and a highlight on the selected one. Tiles show each column's background,
    /// title, and (for tabbed columns) a tab-count indicator — see `docs/niri-mode.md` for why
    /// these are tiles rather than live/snapshot terminal pixels. Clicking a tile selects it.
    @ViewBuilder
    private func overviewLayer(in size: CGSize) -> some View {
        let frames = stripController.layout.overviewColumnFrames(in: size)
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.32)
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
                        Text("\(column.focusedWindowIndex + 1)/\(column.windows.count)")
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
        if let panelID = column.focusedWindow?.raw ?? column.windows.first?.raw,
           let panel = workspace.panels[panelID] {
            let title = panel.displayTitle
            if !title.isEmpty { return title }
        }
        return String(localized: "niri.overview.columnFallback", defaultValue: "Column \(index + 1)")
    }
}

/// An AppKit-backed transparent overlay that turns continuous two-finger trackpad scrolling
/// into strip panning (with snap-to-column on gesture end), matching niri's touchpad gesture.
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
        guard let stripController, stripController.isStripMode, !stripController.isOverviewActive else {
            super.scrollWheel(with: event)
            return
        }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard abs(dx) > abs(dy) else {
            super.scrollWheel(with: event)
            return
        }
        stripController.panBy(-dx)
        if event.phase == .ended || event.momentumPhase == .ended {
            stripController.snapScroll()
        }
    }
}
