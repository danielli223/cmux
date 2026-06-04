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
                    // No fade-in transition: the opaque backdrop must cover the content area
                    // immediately, otherwise the previously-focused live terminal can flash
                    // through during the animation while its portal is still being hidden.
                    overviewLayer(in: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if stripController.isStripMode, !stripController.isOverviewActive {
                    StripModeIndicator()
                        .padding(.top, 6)
                        .padding(.trailing, 8)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onAppear { stripController.setViewportWidth(geo.size.width) }
            .onChange(of: geo.size.width) { _, newWidth in
                stripController.setViewportWidth(newWidth)
            }
        }
    }

    // MARK: - Overview (zoom-out) rendering

    /// The niri-style overview: the whole strip scaled down to fit the content area, with one
    /// tile per column and a highlight on the selected one. Tiles show each column's background,
    /// title, and (for tabbed columns) a tab-count indicator — see `docs/niri-mode.md` for why
    /// these are tiles rather than live/snapshot terminal pixels. Clicking a tile selects it.
    @ViewBuilder
    private func overviewLayer(in size: CGSize) -> some View {
        let frames = stripController.layout.overviewStripFrames(
            in: size,
            visibleColumns: stripController.overviewVisibleColumns,
            scrollOffset: stripController.overviewScrollOffset
        )
        ZStack(alignment: .topLeading) {
            // Fully opaque: a solid backdrop so no terminal content (or a briefly-lingering canvas
            // mirror) can bleed through behind the overview tiles.
            Color(red: 0.11, green: 0.12, blue: 0.14)
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

    /// A single column tile in the overview: a dark "screen" showing a scaled text snapshot of
    /// the column's focused terminal, a title bar, an optional tab indicator, and a highlight
    /// border on the selection.
    @ViewBuilder
    private func overviewTile(column: StripColumn, index: Int, isSelected: Bool, frame: CGRect) -> some View {
        let title = overviewColumnTitle(column: column, index: index)
        let windowTexts = stripController.overviewThumbnails[column.id] ?? []
        let accent = Color.accentColor
        // Fixed dark "terminal screen" so the light snapshot text is always readable regardless
        // of the live terminal theme (which previously rendered white-on-white).
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(red: 0.07, green: 0.08, blue: 0.10))
            .overlay(alignment: .top) {
                // Stacked windows render as a vertical column of mini-screens (top to bottom,
                // matching the real column), with the active window emphasized.
                VStack(spacing: 2) {
                    ForEach(Array(column.windows.enumerated()), id: \.element.raw) { entry in
                        windowMiniScreen(
                            text: entry.offset < windowTexts.count ? windowTexts[entry.offset] : "",
                            panelID: entry.element.raw,
                            windowID: entry.element,
                            columnID: column.id,
                            isActiveWindow: entry.offset == column.focusedWindowIndex,
                            isStacked: column.windows.count > 1,
                            accent: accent
                        )
                    }
                }
                .padding(.top, 18)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.95))
                    if column.windows.count > 1 {
                        Text("\(column.focusedWindowIndex + 1)/\(column.windows.count)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(accent.opacity(0.8)))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.55))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? accent : Color.white.opacity(0.16),
                                  lineWidth: isSelected ? 3 : 1)
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .contentShape(Rectangle())
            .onTapGesture {
                stripController.setOverviewSelection(index)
                stripController.selectOverviewColumn()
            }
    }

    /// One window's content inside an overview tile: a live color mirror when its column is still
    /// rendering (on-screen), a frozen color snapshot when it is off-screen, or the scaled-text
    /// fallback when no frame is available. When a column is stacked (tabbed), each window gets an
    /// equal vertical slice and the active one is outlined.
    @ViewBuilder
    private func windowMiniScreen(text: String, panelID: UUID, windowID: StripWindowID,
                                  columnID: StripColumnID, isActiveWindow: Bool,
                                  isStacked: Bool, accent: Color) -> some View {
        let isLive = stripController.overviewLiveColumnIDs.contains(columnID)
        let frozen = stripController.overviewFrozenImages[panelID]
        let mode = overviewTileMode(for: OverviewTileSource(
            isRendering: isLive, hasFrozenImage: frozen != nil, hasText: !text.isEmpty))
        ZStack {
            if mode == .text {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 5.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(isActiveWindow ? 0.82 : 0.5))
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
            } else {
                OverviewMirrorTile(
                    panelID: panelID,
                    windowID: windowID,
                    mode: mode,
                    sourceLayer: isLive ? stripController.bridge?.stripSourceSurfaceLayer(for: panelID) : nil,
                    frozenImage: frozen,
                    pendingRefresh: stripController.pendingMirrorRefresh
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(isStacked ? 0.30 : 0.0))
        )
        .overlay(
            isStacked
                ? RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isActiveWindow ? accent.opacity(0.9) : Color.white.opacity(0.12),
                                  lineWidth: isActiveWindow ? 1.5 : 0.5)
                : nil
        )
        .clipped()
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

/// A small persistent badge shown in the content area's top-right corner while niri-mode is on,
/// so the mode is unambiguous (there is no other visible cue when a single terminal is open).
private struct StripModeIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 9, weight: .bold))
            Text(String(localized: "niri.indicator.label", defaultValue: "STRIP"))
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.92))
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .allowsHitTesting(false)
        .accessibilityLabel(Text("niri strip mode active"))
    }
}
