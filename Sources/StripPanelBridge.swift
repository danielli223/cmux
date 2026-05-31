import Foundation

/// The seam between ``WorkspaceStripController`` (pure-ish niri strip logic) and the cmux
/// ``Workspace`` (terminal panel lifecycle, focus, Bonsplit backing store).
///
/// The strip controller never touches Bonsplit or `Panel` objects directly; it expresses
/// everything it needs as the small set of operations below. ``Workspace`` provides the
/// production implementation; tests provide a fake. This keeps the controller decoupled
/// (no dependency cycle, unit-testable headlessly) while panel creation continues to flow
/// through the existing, well-tested `newTerminalSplit` path — niri-mode reuses the backing
/// store rather than forking panel lifecycle.
///
/// Identity contract: a strip window's id wraps the cmux **panel UUID** 1:1, so the renderer
/// can resolve a window straight back to its `Panel`. Column ids are synthetic.
@MainActor
protocol StripPanelBridge: AnyObject {
    /// Terminal panel ids currently in the workspace, in visual order, used to seed the strip
    /// when niri-mode is first enabled (one column per existing panel).
    var stripSeedPanelIDs: [UUID] { get }

    /// The panel that currently holds keyboard focus, if any.
    var stripFocusedPanelID: UUID? { get }

    /// Creates a new terminal panel to occupy a brand-new column, splitting off `panelID`
    /// (or any existing panel when `nil`). Returns the new panel's id, or `nil` on failure.
    /// - Parameter panelID: The panel the new column is opened next to (the focused one).
    func stripCreateColumnTerminal(after panelID: UUID?) -> UUID?

    /// Creates a new terminal panel stacked vertically below `panelID` inside the same column.
    /// Returns the new panel's id, or `nil` on failure.
    /// - Parameter panelID: The panel to stack the new window beneath.
    func stripCreateStackedTerminal(below panelID: UUID) -> UUID?

    /// Moves keyboard focus to the panel with the given id.
    /// - Parameter panelID: The panel to focus.
    func stripFocusPanel(_ panelID: UUID)

    /// Closes the panel with the given id. Returns whether it was closed.
    /// - Parameter panelID: The panel to close.
    @discardableResult
    func stripClosePanel(_ panelID: UUID) -> Bool

    /// Captures the panel's terminal viewport as plain text, for the overview's text thumbnail.
    /// Returns `nil` for non-terminal panels or a missing surface.
    /// - Parameter panelID: The panel to capture.
    func stripCaptureThumbnailText(for panelID: UUID) -> String?

    /// The panel's terminal grid column count (from the live rendered frame). A render-level
    /// signal: full-width columns report tens; a sliver reports ~1. `nil` for non-terminals.
    /// - Parameter panelID: The panel to measure.
    func stripTerminalGridColumns(for panelID: UUID) -> Int?
}
