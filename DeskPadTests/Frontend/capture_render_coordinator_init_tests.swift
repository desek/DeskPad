//
//  capture_render_coordinator_init_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 1 closure for
//  `screen.capture_render_coordinator.swift`. Fires the existing init-time
//  closures directly (`evaluatePermission()`, `handleDeviceLoss(error:)`,
//  `evaluateAdaptiveMode(...)`, `applyConfiguration(...)`) so the branches
//  that don't require TCC are exercised in a unit context.
//

import AppKit
import CoreGraphics
import Metal
import XCTest

@testable import DeskPad

@MainActor
final class CaptureRenderCoordinatorInitTests: XCTestCase {
    final class FakeProbe: ScreenCapturePermissionProbe, @unchecked Sendable {
        var preflightResults: [Bool]
        var requestCalls: Int = 0
        init(_ results: [Bool]) { preflightResults = results }
        func preflight() -> Bool {
            guard !preflightResults.isEmpty else { return false }
            return preflightResults.removeFirst()
        }

        @discardableResult
        func request() -> Bool {
            requestCalls += 1
            return true
        }
    }

    /// evaluatePermission(): preflight true is a no-op; preflight false
    /// transitions to .permissionRequired and calls request().
    func testEvaluatePermissionFlipFlops() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this host")
        }
        let probe = FakeProbe([true, false])
        let coord = CaptureRenderCoordinator(permissionProbe: probe)
        _ = coord.evaluatePermission()
        XCTAssertEqual(probe.requestCalls, 0)
        _ = coord.evaluatePermission()
        XCTAssertEqual(coord.state, .permissionRequired)
        XCTAssertEqual(probe.requestCalls, 1)
    }

    /// handleDeviceLoss(error:) with a device-removed-class error must
    /// produce a `.recovered` (or `.failed`) outcome, never `.noError`.
    func testHandleDeviceLossWiresThroughRecovery() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this host")
        }
        let probe = FakeProbe([true])
        let coord = CaptureRenderCoordinator(permissionProbe: probe)
        let error = NSError(
            domain: MTLCommandBufferErrorDomain,
            code: Int(MTLCommandBufferError.deviceRemoved.rawValue)
        )
        let outcome = coord.handleDeviceLoss(error: error)
        XCTAssertNotEqual(outcome, .noError)
    }

    /// evaluateAdaptiveMode(switchThresholdSeconds:) selects power-saving
    /// when the EMA exceeds the threshold and low-latency otherwise.
    func testEvaluateAdaptiveModeRespectsEMA() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this host")
        }
        let probe = FakeProbe([true, true, true])
        let coord = CaptureRenderCoordinator(permissionProbe: probe)
        // Seed the EMA above threshold by publishing two arrivals with a
        // long synthetic gap.
        coord.streamOutput.publishForTest(syntheticIngestHostTime: 1.0)
        coord.streamOutput.publishForTest(syntheticIngestHostTime: 1.1)
        let mode = coord.evaluateAdaptiveMode(switchThresholdSeconds: 0.05)
        XCTAssertEqual(mode, .powerSaving)
    }

    /// applyConfiguration: zero resolution short-circuits; same as last
    /// short-circuits; first non-zero call records the values.
    func testApplyConfigurationGuards() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this host")
        }
        let probe = FakeProbe([true, true])
        let coord = CaptureRenderCoordinator(permissionProbe: probe)
        await coord.applyConfiguration(resolution: .zero, scaleFactor: 1)
        await coord.applyConfiguration(resolution: CGSize(width: 1920, height: 1080), scaleFactor: 1)
        // Repeat call with identical values exits via the early-return.
        await coord.applyConfiguration(resolution: CGSize(width: 1920, height: 1080), scaleFactor: 1)
    }

    /// _setStateForTest seam: directly observable mutation of state.
    func testSetStateForTestSeam() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this host")
        }
        let probe = FakeProbe([true])
        let coord = CaptureRenderCoordinator(permissionProbe: probe)
        coord._setStateForTest(.failed)
        XCTAssertEqual(coord.state, .failed)
    }
}
