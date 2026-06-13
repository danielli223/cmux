import Foundation

/// A stable identity for a column on a niri-style strip.
///
/// Columns keep their identity across reorders, focus changes, and scroll, so the
/// renderer can diff the strip without reusing the wrong terminal view for a column.
/// The wrapped `UUID` is supplied by the caller (typically derived from the cmux pane
/// or panel id) — ``StripLayout`` mutations never mint ids themselves, which keeps every
/// mutation a pure, deterministic function of its inputs.
public struct StripColumnID: Hashable, Sendable, Codable {
    /// The underlying unique value.
    public let raw: UUID

    /// Creates a column id wrapping the given `UUID`.
    /// - Parameter raw: The unique value, usually sourced from a cmux pane/panel id.
    public init(_ raw: UUID) {
        self.raw = raw
    }
}
