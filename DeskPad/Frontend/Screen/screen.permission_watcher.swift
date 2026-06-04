//
//  screen.permission_watcher.swift
//  DeskPad
//
//  @agents-index Permission watcher that owns the FR-8 / AC-7 2 Hz
//  `CGPreflightScreenCaptureAccess` poll. Started when the coordinator
//  enters its restart / failed window and stopped on recovery so the
//  watcher is silent on the happy path. Extracted from the coordinator
//  to keep the coordinator file under the NFR-4 / AC-17 200-LOC cap.
//

import Foundation

/// Drives a periodic permission probe (default 2 Hz per FR-8) while
/// the coordinator is in a restart / failed window. The watcher is
/// `@MainActor`-isolated because it dispatches its `onResult` callback
/// to the coordinator, which is itself `@MainActor`.
@MainActor
public final class PermissionWatcher {
    private let probe: any ScreenCapturePermissionProbe
    private let intervalSeconds: Double
    private let onResult: (Bool) -> Void
    private var task: Task<Void, Never>?
    private let log = Logger(category: "screen")

    /// Build a watcher.
    ///
    /// - Parameters:
    ///   - probe: Permission probe seam, typically the same instance the
    ///     coordinator uses.
    ///   - intervalSeconds: Poll interval; defaults to 0.5 (FR-8 2 Hz).
    ///   - onResult: Invoked on each poll with the current `preflight()`
    ///     value. The coordinator drives state transitions from here.
    public init(
        probe: any ScreenCapturePermissionProbe,
        intervalSeconds: Double = 0.5,
        onResult: @escaping (Bool) -> Void
    ) {
        self.probe = probe
        self.intervalSeconds = intervalSeconds
        self.onResult = onResult
    }

    /// Start polling. Idempotent: a second call while already running is
    /// a no-op so the coordinator can call `start()` from multiple state
    /// transitions without double-scheduling.
    public func start() {
        guard task == nil else { return }
        log.notice("permission watcher polling at \(intervalSeconds)s")
        let probe = self.probe
        let interval = intervalSeconds
        let onResult = self.onResult
        task = Task { @MainActor in
            while !Task.isCancelled {
                let granted = probe.preflight()
                onResult(granted)
                let ns = UInt64(max(0, interval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    /// Stop polling. Safe to call when not started.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Whether the watcher is currently running. Exposed for tests.
    public var isRunning: Bool { task != nil }

    deinit {
        task?.cancel()
    }
}
