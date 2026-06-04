//
//  idle_gpu_zero_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Test Strategy row
//  `testIdleProducesNoNonCompositorGPUSubmissions`: with the dirty
//  flag never set, the pacer ticks but never invokes the present
//  closure across 5 seconds-equivalent of refresh cycles (NFR-3,
//  AC-5).
//

import XCTest

@testable import DeskPad

@MainActor
final class IdleGPUZeroTests: XCTestCase {
    func testIdleProducesNoNonCompositorGPUSubmissions() {
        var presents = 0
        let pacer = DisplayLinkPacer(present: { _ in presents += 1 })

        // 5 seconds at 120 Hz = 600 ticks.
        for _ in 0 ..< 600 { pacer.tick() }

        XCTAssertEqual(presents, 0)
        XCTAssertEqual(pacer.presentCallCount, 0)
        XCTAssertEqual(pacer.tickCount, 600)
    }
}
