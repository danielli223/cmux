import Foundation

/// Coalesces a stream of per-window "needs refresh" marks into at most one batch per ``interval``.
///
/// The niri overview mirrors live terminal frames into tiles. Terminals can emit frames far faster
/// than the overview needs to repaint, so each ``markDirty(_:)`` records intent and ``drain(now:)``
/// returns the accumulated set only when at least ``interval`` seconds have elapsed since the last
/// drain, clearing it. Pure and clock-injected so it is fully unit-testable without a timer.
///
/// ```swift
/// var throttle = FrameRefreshThrottle(interval: 1.0 / 12.0, startTime: CACurrentMediaTime())
/// throttle.markDirty(windowID)
/// let due = throttle.drain(now: CACurrentMediaTime()) // empty until the interval elapses
/// ```
public struct FrameRefreshThrottle: Sendable {
    /// Minimum seconds between non-empty drains.
    public let interval: TimeInterval
    private var dirty: Set<StripWindowID> = []
    private var lastDrain: TimeInterval

    /// Creates a throttle.
    /// - Parameters:
    ///   - interval: Minimum seconds between non-empty drains (e.g. `1.0 / 12` for ~12fps).
    ///   - startTime: The clock value treated as the last drain time.
    public init(interval: TimeInterval, startTime: TimeInterval) {
        self.interval = interval
        self.lastDrain = startTime
    }

    /// Records that `id`'s tile needs a refresh on the next due drain.
    public mutating func markDirty(_ id: StripWindowID) { dirty.insert(id) }

    /// Returns the windows to refresh if ``interval`` has elapsed since the last drain, clearing
    /// the set and resetting the clock; otherwise returns an empty set and changes nothing.
    /// - Parameter now: The current clock value (same time base as `startTime`).
    /// - Returns: The set of windows to refresh, or an empty set when not yet due / nothing dirty.
    public mutating func drain(now: TimeInterval) -> Set<StripWindowID> {
        guard now - lastDrain >= interval, !dirty.isEmpty else { return [] }
        lastDrain = now
        let out = dirty
        dirty.removeAll(keepingCapacity: true)
        return out
    }
}
