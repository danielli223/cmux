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
        // Composite the (non-opaque) terminal surface over the same background color the live terminal
        // uses, so a translucent terminal background blends to the same result as the real portal.
        layer?.backgroundColor = GhosttyBackgroundTheme.currentColor().cgColor
        // `.resize` (not aspectFill) maps the surface exactly to the layer with no extra resampling —
        // the mirror frame already matches the column's aspect, so this is a 1:1 copy.
        mirrorLayer.contentsGravity = .resize
        mirrorLayer.masksToBounds = true
        mirrorLayer.backgroundColor = NSColor.clear.cgColor
        // The presented terminal `IOSurface` is at the display's backing scale (2× on Retina). Without
        // a matching `contentsScale` the mirror downsamples it to 1×, so the glide shows a softer,
        // slightly-shifted copy that visibly snaps to crisp when the live portal takes over at settle.
        // Default to 2× until the real window scale is known in `viewDidMoveToWindow`.
        mirrorLayer.contentsScale = 2
        layer?.contentsScale = 2
        layer?.addSublayer(mirrorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        mirrorLayer.contentsScale = scale
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirrorLayer.frame = bounds
        CATransaction.commit()
    }

    /// Non-interactive: a mirror is a pure visual overlay (e.g. covering the portal re-sync gap at a
    /// glide's settle), so it must never intercept clicks meant for the terminal beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

    /// Prefers a live `IOSurface` mirror; falls back to a frozen snapshot when the source has no
    /// presented surface yet (e.g. a column that has not rendered this session). If neither is
    /// available, leaves whatever was last shown in place.
    /// - Parameters:
    ///   - liveSource: The live `GhosttyMetalLayer` to mirror, if any.
    ///   - frozenFallback: A cached snapshot to show when no live surface exists.
    func refresh(liveSource: CALayer?, frozenFallback: CGImage?) {
        if let liveSource,
           let contents = liveSource.contents,
           CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            refreshLive(from: liveSource)
        } else if let frozenFallback {
            showFrozen(frozenFallback)
        }
    }
}
