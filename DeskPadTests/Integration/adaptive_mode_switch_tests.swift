//
//  adaptive_mode_switch_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Test Strategy row
//  `testAdaptiveModeSwitchOnArrivalRate`: when the sustained arrival
//  rate falls below the configured threshold the coordinator switches
//  from `.lowLatency` to `.powerSaving` (FR-18, AC-15).
//

import XCTest

@testable import DeskPad

@MainActor
final class AdaptiveModeSwitchTests: XCTestCase {
    func testAdaptiveModeSwitchOnArrivalRate() {
        let coordinator = CaptureRenderCoordinator()

        // Seed the EMA with a slow inter-arrival cadence (~10 Hz).
        var t: CFTimeInterval = 1
        for _ in 0 ..< 32 {
            coordinator.streamOutput.publishForTest(syntheticIngestHostTime: t)
            t += 0.1
        }
        let modeAfterSlow = coordinator.evaluateAdaptiveMode()

        switch modeAfterSlow {
        case .powerSaving:
            break
        default:
            XCTFail("expected powerSaving after sustained slow arrivals; got \(modeAfterSlow)")
        }
    }
}
