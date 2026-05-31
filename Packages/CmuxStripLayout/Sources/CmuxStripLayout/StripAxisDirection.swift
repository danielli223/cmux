/// A direction along one of the strip's two orthogonal axes.
///
/// The horizontal axis (``left`` / ``right``) selects and reorders *columns*; the vertical
/// axis (``up`` / ``down``) selects and reorders *windows within the focused column*. The
/// two axes never cross: focusing a window up/down stays inside its column, matching niri.
public enum StripAxisDirection: Sendable, Equatable {
    /// Toward the start of the strip (previous column) or top of a column (previous window).
    case left
    /// Toward the end of the strip (next column) or bottom of a column (next window).
    case right
    /// Toward the top of the focused column's window stack (previous window).
    case up
    /// Toward the bottom of the focused column's window stack (next window).
    case down
}
