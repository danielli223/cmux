import Foundation

/// A stable identity for one terminal window stacked vertically inside a ``StripColumn``.
///
/// A niri column is a vertical stack of one or more windows; this id identifies a single
/// stacked window so focus and reordering within a column can address it without depending
/// on array position. Like ``StripColumnID`` the wrapped `UUID` is caller-supplied.
public struct StripWindowID: Hashable, Sendable, Codable {
    /// The underlying unique value.
    public let raw: UUID

    /// Creates a window id wrapping the given `UUID`.
    /// - Parameter raw: The unique value, usually sourced from a cmux panel id.
    public init(_ raw: UUID) {
        self.raw = raw
    }
}
