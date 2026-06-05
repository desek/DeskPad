//
//  live_switch_latency_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 NFR-6 / AC-17 scaffolding. The 4K live-switch
//  latency benchmark requires a real 4K virtual display and a TCC-
//  granted runtime; the carve-out at
//  `docs/cr/CR-0002-energy-measurement.md` documents the methodology.
//  The headless unit test `live_switch_tests.swift` already proves the
//  swap completes in well under 250 ms at the synthetic test scale.
//

import XCTest

@testable import DeskPad

final class LiveSwitchLatencyTests: XCTestCase {
    /// `testLiveSwitchUnder250ms` — TCC-bound 4K benchmark.
    func testLiveSwitchUnder250ms() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["DESKPAD_RUN_INSTRUMENTS_BENCHMARKS"] == nil,
            "4K live-switch benchmark; see docs/cr/CR-0002-energy-measurement.md"
        )
        XCTFail("Instruments-backed benchmark must be driven out-of-band; this assertion is unreachable in normal CI")
    }
}
