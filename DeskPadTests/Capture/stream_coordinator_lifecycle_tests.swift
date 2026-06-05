//
//  stream_coordinator_lifecycle_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 1 closure for `capture.stream_coordinator.swift`.
//  Drives start/stop/reconfigure/restart-mid-cycle/nil-handle branches via
//  a mock `StreamHandle`. Sibling of `stream_coordinator_restart_tests.swift`,
//  which already covers the budget-exhaustion and backoff-math paths.
//

import XCTest

@testable import DeskPad

final class StreamCoordinatorLifecycleTests: XCTestCase {
    /// Mock that records each call and surfaces a script of injected
    /// errors followed by successes.
    final class MockHandle: StreamHandle, @unchecked Sendable {
        var startCalls: Int = 0
        var stopCalls: Int = 0
        var updateCalls: Int = 0
        var lastUpdate: (Int, Int) = (0, 0)
        var startErrors: [Error?] = []
        var updateError: Error?

        func startStream() async throws {
            startCalls += 1
            if !startErrors.isEmpty {
                let next = startErrors.removeFirst()
                if let next { throw next }
            }
        }

        func stopStream() async throws { stopCalls += 1 }
        func updateConfiguration(width: Int, height: Int) async throws {
            updateCalls += 1
            lastUpdate = (width, height)
            if let err = updateError { throw err }
        }
    }

    struct FakeClock: StreamClock {
        func sleep(seconds _: Double) async throws {}
    }

    func testStartTransitionsToRunning() async throws {
        let coord = StreamCoordinator(clock: FakeClock())
        let handle = MockHandle()
        await coord.install(handle: handle)
        try await coord.start()
        let state = await coord.state
        XCTAssertEqual(state, .running)
        XCTAssertEqual(handle.startCalls, 1)
    }

    func testStopTransitionsToIdle() async throws {
        let coord = StreamCoordinator(clock: FakeClock())
        let handle = MockHandle()
        await coord.install(handle: handle)
        try await coord.start()
        try await coord.stop()
        let state = await coord.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(handle.stopCalls, 1)
    }

    func testUpdateConfigurationPropagatesDimensions() async throws {
        let coord = StreamCoordinator(clock: FakeClock())
        let handle = MockHandle()
        await coord.install(handle: handle)
        try await coord.updateConfiguration(width: 1280, height: 720)
        XCTAssertEqual(handle.updateCalls, 1)
        XCTAssertEqual(handle.lastUpdate.0, 1280)
        XCTAssertEqual(handle.lastUpdate.1, 720)
    }

    func testRestartScheduleMidCycleSuccess() async throws {
        let coord = StreamCoordinator(clock: FakeClock())
        let handle = MockHandle()
        // Two errors, then success on third attempt.
        handle.startErrors = [
            NSError(domain: "test", code: 1),
            NSError(domain: "test", code: 2),
        ]
        await coord.install(handle: handle)
        await coord.runRestartSchedule()
        let state = await coord.state
        XCTAssertEqual(state, .running)
        XCTAssertEqual(handle.startCalls, 3)
    }

    func testStartWithoutInstalledHandleIsNoOp() async throws {
        let coord = StreamCoordinator(clock: FakeClock())
        try await coord.start()
        let state = await coord.state
        XCTAssertEqual(state, .idle)
    }

    /// Stop without an installed handle still transitions to .idle (the
    /// guard-let-else branch sets the state explicitly).
    func testStopWithoutHandleStillIdle() async throws {
        let coord = StreamCoordinator(clock: FakeClock())
        try await coord.stop()
        let state = await coord.state
        XCTAssertEqual(state, .idle)
    }

    /// runRestartSchedule with no handle transitions to .failed.
    func testRestartScheduleWithoutHandleFails() async {
        let coord = StreamCoordinator(clock: FakeClock())
        await coord.runRestartSchedule()
        let state = await coord.state
        XCTAssertEqual(state, .failed)
    }
}
