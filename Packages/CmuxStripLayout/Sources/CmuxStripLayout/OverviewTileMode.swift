/// How a single niri-overview tile should present one window's content.
public enum OverviewTileMode: Equatable, Sendable {
    /// Mirror the source surface's live `IOSurface`, refreshed while the overview is open.
    case live
    /// Show a one-time color snapshot captured when the overview opened.
    case frozen
    /// Show the monochrome scaled-text snapshot (deepest fallback).
    case text
}

/// The inputs that decide a tile's ``OverviewTileMode``.
public struct OverviewTileSource: Equatable, Sendable {
    /// Whether the source surface is actively producing Metal frames right now.
    public var isRendering: Bool
    /// Whether a frozen color snapshot was captured for this window.
    public var hasFrozenImage: Bool
    /// Whether a text snapshot is available.
    public var hasText: Bool

    /// Creates a tile source descriptor.
    /// - Parameters:
    ///   - isRendering: Whether the source surface is producing frames now.
    ///   - hasFrozenImage: Whether a frozen color snapshot exists for this window.
    ///   - hasText: Whether a text snapshot is available.
    public init(isRendering: Bool, hasFrozenImage: Bool, hasText: Bool) {
        self.isRendering = isRendering
        self.hasFrozenImage = hasFrozenImage
        self.hasText = hasText
    }
}

/// Picks a tile's presentation: ``OverviewTileMode/live`` when the source renders, else the best
/// available frozen fallback (``OverviewTileMode/frozen`` then ``OverviewTileMode/text``).
///
/// - Parameter source: The window's render/snapshot availability.
/// - Returns: The mode the overview tile should use.
public func overviewTileMode(for source: OverviewTileSource) -> OverviewTileMode {
    if source.isRendering { return .live }
    if source.hasFrozenImage { return .frozen }
    return .text
}
