//
//  device_loss_recovery_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Phase 3 Test Strategy row
//  `testRebuildsPipelineOnDeviceLost`: a synthetic
//  `MTLCommandBufferErrorDomain` error with one of the device-loss class
//  codes drives the recovery utility to acquire a new device and invoke
//  the `swapIn` closure so dependents can rebuild against it.
//

import Metal
import XCTest

@testable import DeskPad

final class DeviceLossRecoveryTests: XCTestCase {
    /// Build an `NSError` in the `MTLCommandBufferErrorDomain` for `code`,
    /// converting the `UInt`-typed `MTLCommandBufferError.Code.rawValue` to
    /// the `Int` that `NSError(domain:code:)` requires.
    private func makeMTLError(_ code: MTLCommandBufferError.Code) -> NSError {
        return NSError(domain: MTLCommandBufferErrorDomain, code: Int(code.rawValue))
    }

    /// `testRebuildsPipelineOnDeviceLost`: feed a synthetic error in the
    /// `MTLCommandBufferErrorDomain` with code `.deviceRemoved`; assert
    /// the recovery utility invokes `swapIn` with the fresh device and
    /// returns `.recovered`.
    func testRebuildsPipelineOnDeviceLost() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host")
        }
        let recovery = DeviceLossRecovery(deviceFactory: { device })
        var swapInCalls = 0
        let outcome = recovery.handle(error: makeMTLError(.deviceRemoved)) { newDevice in
            swapInCalls += 1
            XCTAssertTrue(newDevice === device)
        }
        XCTAssertEqual(outcome, .recovered)
        XCTAssertEqual(swapInCalls, 1)
    }

    /// `.accessRevoked` is also in the device-loss class per FR-9.
    func testAccessRevokedTriggersRecovery() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host")
        }
        let recovery = DeviceLossRecovery(deviceFactory: { device })
        let outcome = recovery.handle(error: makeMTLError(.accessRevoked)) { _ in }
        XCTAssertEqual(outcome, .recovered)
    }

    /// A non-device-loss error code must be ignored.
    func testUnrelatedErrorIgnored() {
        let recovery = DeviceLossRecovery(deviceFactory: { nil })
        let outcome = recovery.handle(error: makeMTLError(.timeout)) { _ in
            XCTFail("swapIn must not run for non-device-loss errors")
        }
        XCTAssertEqual(outcome, .noError)
    }

    /// When the device factory returns nil, the outcome is `.failed`.
    func testFailedWhenNoReplacementDevice() {
        let recovery = DeviceLossRecovery(deviceFactory: { nil })
        let outcome = recovery.handle(error: makeMTLError(.deviceRemoved)) { _ in
            XCTFail("swapIn must not run when no device is available")
        }
        XCTAssertEqual(outcome, .failed)
    }
}
