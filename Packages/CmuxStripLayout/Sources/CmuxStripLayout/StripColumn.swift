import CoreGraphics

/// One column on a niri-style strip: a vertical stack of terminal windows with an
/// **intrinsic width** that does not change when other columns are added or removed.
///
/// This intrinsic width is the whole point of niri-mode. cmux's Bonsplit tiling stores
/// only divider *ratios* of a fixed container, so opening a sibling shrinks you. A
/// ``StripColumn`` instead owns an absolute ``width`` in points that ``StripLayout`` never
/// mutates as a side effect of inserting, removing, focusing, or moving columns.
///
/// The vertical axis (``windows``) is bounded by the viewport height, mirroring niri's
/// columns: windows share the column's height the way niri stacks windows in a column.
public struct StripColumn: Identifiable, Equatable, Sendable, Codable {
    /// The column's stable identity.
    public let id: StripColumnID

    /// The column's intrinsic width in points. Invariant: only an explicit user resize
    /// changes this — never insertion, removal, focus, move, or scroll of other columns.
    public var width: CGFloat

    /// The vertically-stacked windows in this column, top to bottom. Always non-empty.
    public var windows: [StripWindowID]

    /// Index into ``windows`` of the focused window. Always a valid index.
    public var focusedWindowIndex: Int

    /// Creates a column.
    /// - Parameters:
    ///   - id: The column's stable identity.
    ///   - width: Intrinsic width in points (must be > 0 to be meaningful).
    ///   - windows: The vertical window stack, top to bottom; must be non-empty.
    ///   - focusedWindowIndex: Index of the focused window; clamped into range.
    public init(
        id: StripColumnID,
        width: CGFloat,
        windows: [StripWindowID],
        focusedWindowIndex: Int = 0
    ) {
        self.id = id
        self.width = width
        self.windows = windows
        self.focusedWindowIndex = windows.isEmpty
            ? 0
            : min(max(focusedWindowIndex, 0), windows.count - 1)
    }

    /// The id of the currently focused window, or `nil` if the stack is somehow empty.
    public var focusedWindow: StripWindowID? {
        guard windows.indices.contains(focusedWindowIndex) else { return windows.first }
        return windows[focusedWindowIndex]
    }
}
