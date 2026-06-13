import Foundation

/// Which layout strategy a ``Workspace`` is currently presenting its terminals with.
///
/// cmux ships two coexisting strategies. ``tiling`` is the historical Bonsplit split tree
/// (opening a terminal subdivides the focused pane, shrinking it). ``strip`` is the
/// niri-style scrollable strip (opening a terminal appends a fixed-width column and pans the
/// viewport, never resizing existing terminals). The mode is per-workspace and persisted
/// across session restore; switching back to ``tiling`` leaves the underlying Bonsplit tree
/// intact, so tiling behavior is unchanged when niri-mode is off.
enum WorkspaceLayoutMode: String, Codable, Sendable, CaseIterable {
    /// Bonsplit split-tree tiling (default).
    case tiling
    /// niri-style scrollable strip of fixed-width columns.
    case strip
}
