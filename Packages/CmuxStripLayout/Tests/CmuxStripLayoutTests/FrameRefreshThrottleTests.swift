import Foundation
import Testing
@testable import CmuxStripLayout

@Suite struct FrameRefreshThrottleTests {
    private func id(_ n: Int) -> StripWindowID {
        StripWindowID(UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!)
    }

    @Test func drainBeforeIntervalReturnsEmpty() {
        var t = FrameRefreshThrottle(interval: 0.1, startTime: 0)
        t.markDirty(id(1))
        #expect(t.drain(now: 0.05) == [])
    }

    @Test func drainAfterIntervalReturnsAndClears() {
        var t = FrameRefreshThrottle(interval: 0.1, startTime: 0)
        t.markDirty(id(1))
        t.markDirty(id(2))
        #expect(t.drain(now: 0.1) == [id(1), id(2)])
        #expect(t.drain(now: 0.25) == [])
    }

    @Test func coalescesRepeatedMarks() {
        var t = FrameRefreshThrottle(interval: 0.1, startTime: 0)
        t.markDirty(id(1))
        t.markDirty(id(1))
        t.markDirty(id(1))
        #expect(t.drain(now: 0.2) == [id(1)])
    }

    @Test func reflectsLatestDirtySetAcrossWindows() {
        var t = FrameRefreshThrottle(interval: 0.1, startTime: 0)
        t.markDirty(id(1))
        _ = t.drain(now: 0.1)
        t.markDirty(id(2))
        #expect(t.drain(now: 0.25) == [id(2)])
    }
}
