import Foundation
import QuartzCore

/// Drives a short, transient animation of the niri strip's scroll offset so keyboard navigation
/// **glides** between viewport positions instead of teleporting.
///
/// This is a property animator, not a render loop: it steps a single `CGFloat` (the strip's
/// ``StripLayout/scrollOffset``) along an ease-out curve for a fixed duration, invoking `onStep` each
/// tick, then stops. It never calls into Ghostty drawing and holds no display link — the canvas
/// repositions its columns from the stepped offset through its normal reconcile path (with implicit
/// layer animations disabled, so every column moves together each frame and nothing smears).
///
/// Retargeting mid-flight is supported: calling ``animate(from:to:)`` again while a previous
/// animation is running simply restarts the curve from the new `from` toward the new `to`, so a
/// rapid sequence of navigations chases a moving target smoothly rather than queueing jumps.
@MainActor
final class StripScrollAnimator {
    private var timer: Timer?
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var startTime: CFTimeInterval = 0
    private let duration: CFTimeInterval
    private let tickInterval: TimeInterval
    private let onStep: (CGFloat) -> Void
    private let onFinished: () -> Void

    /// Whether an animation is currently in flight.
    var isAnimating: Bool { timer != nil }

    /// Creates an animator.
    /// - Parameters:
    ///   - duration: The animation length in seconds. The default `0.22` reads as a quick, deliberate
    ///     glide — long enough to perceive the motion, short enough not to feel sluggish during fast
    ///     repeated navigation.
    ///   - tickInterval: The step period in seconds (default `1/120` for smoothness on ProMotion
    ///     displays; coarser displays simply coalesce).
    ///   - onStep: Invoked each tick with the eased offset to apply.
    ///   - onFinished: Invoked once when the animation reaches its target (or is replaced/cancelled
    ///     having reached the end). Not called on an explicit ``cancel()``.
    init(
        duration: CFTimeInterval = 0.22,
        tickInterval: TimeInterval = 1.0 / 120.0,
        onStep: @escaping (CGFloat) -> Void,
        onFinished: @escaping () -> Void = {}
    ) {
        self.duration = duration
        self.tickInterval = tickInterval
        self.onStep = onStep
        self.onFinished = onFinished
    }

    /// Starts (or retargets) an animation of the offset from `from` to `to`.
    ///
    /// Equal endpoints, or a non-positive duration, apply `to` immediately. Otherwise the offset is
    /// stepped along an ease-out cubic until it reaches `to`.
    /// - Parameters:
    ///   - from: The starting offset (usually the strip's current ``StripLayout/scrollOffset``).
    ///   - to: The target offset to glide to.
    func animate(from: CGFloat, to: CGFloat) {
        timer?.invalidate()
        timer = nil
        guard duration > 0, from != to else {
            onStep(to)
            onFinished()
            return
        }
        self.from = from
        self.to = to
        startTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops any in-flight animation immediately, leaving the offset wherever the last step left it.
    /// Does not invoke `onFinished`.
    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// Ease-out cubic: fast start, gentle settle. `1 - (1 - t)^3`.
    private func eased(_ t: CGFloat) -> CGFloat {
        let inv = 1 - t
        return 1 - inv * inv * inv
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - startTime
        let t = min(1, max(0, CGFloat(elapsed / duration)))
        onStep(from + (to - from) * eased(t))
        if t >= 1 {
            timer?.invalidate()
            timer = nil
            onStep(to)
            onFinished()
        }
    }
}
