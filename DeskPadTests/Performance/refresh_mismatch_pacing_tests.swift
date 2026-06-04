//
//  refresh_mismatch_pacing_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Test Strategy row
//  `testNoJudderAt60on120`: the pacer carries
//  `targetPresentationTimestamp` per tick (FR-17, AC-16) so the
//  renderer can anchor `MTLDrawable.present(at:)` to the vsync grid.
//  Drives the pacer with synthetic ticks at a fixed 1/120 cadence and
//  asserts the closure observes the supplied target timestamps in
//  monotonic order.
//

import XCTest

@testable import DeskPad

@MainActor
final class RefreshMismatchPacingTests: XCTestCase {
    func testNoJudderAt60on120() {
        var observed: [CFTimeInterval] = []
        let pacer = DisplayLinkPacer(present: { tick in
            observed.append(tick.targetPresentationTimestamp)
        })

        var t: CFTimeInterval = 1
        for _ in 0 ..< 120 {
            pacer.markDirty()
            pacer.tick(PacerTick(targetPresentationTimestamp: t, targetTimestamp: t - 0.00833))
            t += 1.0 / 120.0
        }

        XCTAssertEqual(observed.count, 120)
        for i in 1 ..< observed.count {
            XCTAssertGreaterThan(observed[i], observed[i - 1])
        }
    }
}
