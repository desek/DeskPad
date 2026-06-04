//
//  display_link_pacer_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Phase 3 Test Strategy row
//  `testSkipsPresentWhenNotDirty`: a pacer driven by a fake tick source
//  with the dirty flag never set invokes `present` zero times across 60
//  ticks, enforcing FR-5 (idle frames are skipped).
//

import XCTest

@testable import DeskPad

@MainActor
final class DisplayLinkPacerTests: XCTestCase {
    /// `testSkipsPresentWhenNotDirty`: drive the pacer's `tick()` 60
    /// times with the dirty flag never set; assert `present` was never
    /// invoked.
    func testSkipsPresentWhenNotDirty() {
        var presentCalls = 0
        let pacer = DisplayLinkPacer(present: { presentCalls += 1 })

        for _ in 0 ..< 60 { pacer.tick() }

        XCTAssertEqual(presentCalls, 0)
        XCTAssertEqual(pacer.presentCallCount, 0)
        XCTAssertEqual(pacer.tickCount, 60)
    }

    /// Companion assertion: when the dirty flag is set ahead of a tick,
    /// `present` runs once and the flag is cleared so the next tick
    /// without a fresh `markDirty()` is suppressed.
    func testPresentsOncePerDirtyTransition() {
        var presentCalls = 0
        let pacer = DisplayLinkPacer(present: { presentCalls += 1 })

        pacer.markDirty()
        pacer.tick()
        pacer.tick()

        XCTAssertEqual(presentCalls, 1)
        XCTAssertEqual(pacer.tickCount, 2)
    }
}
