import Testing
@testable import CmuxStripLayout

@Suite struct OverviewTileModeTests {
    @Test func renderingSourceIsLive() {
        let s = OverviewTileSource(isRendering: true, hasFrozenImage: true, hasText: true)
        #expect(overviewTileMode(for: s) == .live)
    }

    @Test func notRenderingWithFrozenImageIsFrozen() {
        let s = OverviewTileSource(isRendering: false, hasFrozenImage: true, hasText: true)
        #expect(overviewTileMode(for: s) == .frozen)
    }

    @Test func notRenderingNoImageFallsBackToText() {
        let s = OverviewTileSource(isRendering: false, hasFrozenImage: false, hasText: true)
        #expect(overviewTileMode(for: s) == .text)
    }

    @Test func nothingAvailableStillText() {
        let s = OverviewTileSource(isRendering: false, hasFrozenImage: false, hasText: false)
        #expect(overviewTileMode(for: s) == .text)
    }
}
