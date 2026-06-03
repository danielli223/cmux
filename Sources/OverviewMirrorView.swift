import AppKit
import QuartzCore

/// A layer-backed view that mirrors a terminal surface's presented `IOSurface` into a scaled tile
/// for the niri overview.
///
/// Setting the mirror layer's `contents` to the source surface layer's `IOSurface` and using
/// `contentsGravity = .resizeAspectFill` scales the live frame down for free — the source surface
/// is never resized, so it never reflows (the "1-character sliver" failure mode the strip canvas
/// hosting was built to avoid). Off-screen columns that are no longer rendering show a one-time
/// frozen `CGImage` instead.
final class OverviewMirrorView: NSView {
    private let mirrorLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        mirrorLayer.contentsGravity = .resizeAspectFill
        mirrorLayer.masksToBounds = true
        mirrorLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(mirrorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirrorLayer.frame = bounds
        CATransaction.commit()
    }

    /// Mirrors `sourceLayer`'s current presented `IOSurface`. Call on each throttled refresh.
    /// Does nothing if the source has no `IOSurface`-backed contents yet (e.g. before its first
    /// frame), leaving whatever was last shown in place.
    /// - Parameter sourceLayer: The live `GhosttyMetalLayer` whose presented surface to mirror.
    func refreshLive(from sourceLayer: CALayer) {
        guard let contents = sourceLayer.contents,
              CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirrorLayer.contents = contents
        CATransaction.commit()
    }

    /// Shows a one-time frozen color snapshot, used for off-screen columns that are not rendering.
    /// - Parameter image: The captured `CGImage` to display.
    func showFrozen(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirrorLayer.contents = image
        CATransaction.commit()
    }
}
