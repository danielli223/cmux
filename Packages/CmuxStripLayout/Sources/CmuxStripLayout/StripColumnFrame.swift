import CoreGraphics

/// The resolved on-screen rectangle for one column, produced by
/// ``StripLayout/columnFrames(in:)``.
///
/// `frame.origin.x` is in **viewport coordinates**: it already accounts for the strip's
/// scroll offset, so a column scrolled off the left has a negative `minX` and a column
/// scrolled off the right has a `minX` greater than the viewport width. The renderer
/// positions each column's terminal host at exactly this frame.
public struct StripColumnFrame: Equatable, Sendable {
    /// The column this frame belongs to.
    public let id: StripColumnID

    /// The column's rectangle in viewport coordinates (scroll offset already applied).
    public let frame: CGRect

    /// Whether any part of ``frame`` intersects the viewport and is therefore visible.
    public let isVisible: Bool

    /// Creates a resolved column frame.
    /// - Parameters:
    ///   - id: The column's identity.
    ///   - frame: The viewport-space rectangle.
    ///   - isVisible: Whether the frame intersects the viewport.
    public init(id: StripColumnID, frame: CGRect, isVisible: Bool) {
        self.id = id
        self.frame = frame
        self.isVisible = isVisible
    }
}
