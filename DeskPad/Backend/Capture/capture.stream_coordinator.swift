//
//  capture.stream_coordinator.swift
//  DeskPad
//
//  @agents-index Actor that owns the `SCStream` lifecycle: start, stop,
//  reconfigure on resolution/scale-factor changes, and restart with bounded
//  exponential backoff on delegate errors. All SCK calls funnel through this
//  actor so concurrency safety is by construction under Swift 6 strict
//  concurrency.
//
//  Restart schedule (per Phase 2 step 4 and the matching Test Strategy row):
//  100 ms, 200 ms, 400 ms, 800 ms, 1.6 s, 3.2 s, then capped at 5 s for the
//  remaining attempts, up to a hard ceiling of 10 attempts. After the tenth
//  failure the coordinator transitions to a permanent error state and stops
//  scheduling further attempts; permission revocation handling in Phase 4
//  uses that terminal state to surface a permission-needed UI.
//

import Foundation
import ScreenCaptureKit

/// Coordinator state observable from the outside. The terminal `.failed`
/// state is reached after the restart budget is exhausted; Phase 4 maps it
/// to a permission-needed UI when `CGPreflightScreenCaptureAccess` also
/// returns false.
public enum StreamCoordinatorState: Sendable, Equatable {
    case idle
    case running
    case restarting(attempt: Int)
    case failed
}

/// A clock abstraction so tests can drive the backoff schedule without
/// real-time sleeps. Production uses `RealStreamClock` which forwards to
/// `Task.sleep`; tests inject a fake clock that records the requested
/// intervals and resumes immediately.
public protocol StreamClock: Sendable {
    /// Sleep for `seconds` seconds, suspending the current task. Tests
    /// implement this as a no-op that records the requested interval.
    func sleep(seconds: Double) async throws
}

/// Production `StreamClock` backed by `Task.sleep(nanoseconds:)`. The seam
/// exists purely so the coordinator's backoff schedule is assertable.
public struct RealStreamClock: StreamClock {
    public init() {}
    public func sleep(seconds: Double) async throws {
        let ns = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: ns)
    }
}

/// Stream-handle abstraction: lets tests stand in for a real `SCStream`
/// without constructing one. Production wraps a live `SCStream`; tests
/// inject a stub that records the calls so reconfigure-vs-restart is
/// asserted directly (CR-0001 Phase 4 Test Strategy row
/// `testReconfigureOnResolutionChange`).
public protocol StreamHandle: AnyObject, Sendable {
    /// Start the stream. Throws to signal an unrecoverable start error
    /// (typically permission missing).
    func startStream() async throws
    /// Stop the stream. Idempotent.
    func stopStream() async throws
    /// Apply a new configuration without tearing the stream down.
    func updateConfiguration(width: Int, height: Int) async throws
}

/// Owns the `SCStream` lifecycle. The actor isolates all SCK mutating calls;
/// the rest of the app interacts with it via `start()`, `stop()`, and
/// `updateConfiguration(...)`.
public actor StreamCoordinator {
    /// Bounded backoff schedule for restart attempts, in seconds. The
    /// schedule starts at 100 ms and doubles, capped at 5 s, for up to
    /// `maxRestartAttempts` total attempts.
    public static let maxRestartAttempts: Int = 10

    private let log = Logger(category: "capture")
    private let clock: any StreamClock
    private(set) var state: StreamCoordinatorState = .idle
    private var handle: (any StreamHandle)?
    public private(set) var startCount: Int = 0
    public private(set) var stopCount: Int = 0
    public private(set) var updateConfigurationCount: Int = 0

    /// Build a coordinator with an injectable clock. Production sites pass
    /// `RealStreamClock()`; tests pass a fake that records the intervals.
    public init(clock: any StreamClock = RealStreamClock()) {
        self.clock = clock
    }

    /// Install a stream handle. Production calls this after building the
    /// real `SCStream`; tests inject a stub.
    public func install(handle: any StreamHandle) {
        self.handle = handle
    }

    /// Start the installed stream handle. Transitions state to `.running`
    /// on success; surfaces the error otherwise.
    public func start() async throws {
        guard let handle else { return }
        startCount += 1
        try await handle.startStream()
        state = .running
    }

    /// Stop the installed stream handle and transition to `.idle`.
    public func stop() async throws {
        guard let handle else {
            state = .idle
            return
        }
        stopCount += 1
        try await handle.stopStream()
        state = .idle
    }

    /// Reconfigure the live stream to a new pixel size. Used on virtual-
    /// display resolution / scale-factor changes. Calls
    /// `SCStream.updateConfiguration(_:)` under the hood via the handle, so
    /// no stop/start pair is observed (FR-6, AC-9).
    public func updateConfiguration(width: Int, height: Int) async throws {
        guard let handle else { return }
        updateConfigurationCount += 1
        try await handle.updateConfiguration(width: width, height: height)
    }

    /// Compute the delay (seconds) for restart attempt `attempt` (1-indexed)
    /// under the bounded exponential schedule documented in Phase 2 step 4
    /// and asserted by `testRestartBackoffSchedule`.
    ///
    /// - Parameter attempt: 1-based attempt index. Out-of-range values
    ///   return the cap (5.0) for high indices and 0 for non-positive.
    public static func backoffDelay(forAttempt attempt: Int) -> Double {
        guard attempt >= 1 else { return 0 }
        let raw = 0.1 * pow(2.0, Double(attempt - 1))
        return min(raw, 5.0)
    }

    /// Drive the backoff schedule for tests. Walks attempts 1...maxAttempts,
    /// awaiting the clock between each, transitioning to `.failed` after
    /// the budget is exhausted. Production restart logic (which actually
    /// rebuilds the SCStream) is layered on top of this primitive in
    /// Phase 4 once the full coordinator wiring lands.
    public func runRestartScheduleForTest() async throws {
        for attempt in 1 ... Self.maxRestartAttempts {
            state = .restarting(attempt: attempt)
            let delay = Self.backoffDelay(forAttempt: attempt)
            try await clock.sleep(seconds: delay)
        }
        state = .failed
    }

    /// Drive the restart schedule against the installed handle. Walks
    /// attempts 1...maxAttempts, sleeping per `backoffDelay(forAttempt:)`
    /// between attempts and calling `handle.startStream()` each time.
    /// Transitions to `.running` on first success and `.failed` after
    /// the budget is exhausted. Called from the coordinator's
    /// `onStopError` hook so a delegate error in production drives the
    /// FR-7 / AC-6 backoff at runtime.
    public func runRestartSchedule() async {
        guard let handle else {
            state = .failed
            return
        }
        for attempt in 1 ... Self.maxRestartAttempts {
            state = .restarting(attempt: attempt)
            let delay = Self.backoffDelay(forAttempt: attempt)
            try? await clock.sleep(seconds: delay)
            do {
                try await handle.startStream()
                state = .running
                return
            } catch {
                continue
            }
        }
        state = .failed
    }

    /// Trigger a restart externally. Public so the coordinator's
    /// `onStopError` closure can hop into the actor and kick off the
    /// schedule without leaking the underlying state machine.
    public func triggerRestart() async {
        await runRestartSchedule()
    }
}
