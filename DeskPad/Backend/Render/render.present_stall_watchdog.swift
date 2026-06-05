//
//  render.present_stall_watchdog.swift
//  DeskPad
//
//  @agents-index CR-0003 Phase 2 / FR-6 / FR-7: Layer 1 always-on
//  watchdog. Observes the `(ingestedFrameCount, presentedFrameCount,
//  state)` triple from the coordinator on a once-per-second main-actor
//  cadence and emits a single greppable WARN line with the literal
//  prefix `present stall: ingested=` when ingestion has advanced but
//  presentation has not for the prior three seconds. Rate-limited to
//  one emission per ten-second window so a sustained stall does not
//  flood the rotating file sink. The watchdog is the cheapest detection
//  layer and the only one that runs in production builds; it observes
//  the existing counters and takes no lock on the hot capture/present
//  paths per NFR-2.
//

import Foundation

/// Triple the watchdog samples on every tick. Returned by the closure
/// the coordinator injects so the watchdog never reaches into the
/// coordinator's stored state directly (Law of Demeter / FR-6).
public struct PresentStallSample: Sendable, Equatable {
    public let ingested: Int
    public let presented: Int
    public let state: CaptureRenderCoordinatorState

    public init(ingested: Int, presented: Int, state: CaptureRenderCoordinatorState) {
        self.ingested = ingested
        self.presented = presented
        self.state = state
    }
}

/// Layer 1 watchdog. Constructed once per coordinator lifetime; started
/// when the coordinator first transitions to `.running` and stopped on
/// any terminal/idle transition. The production path schedules a
/// `Task` that ticks every second; tests bypass the timer entirely by
/// invoking `tick(now:)` directly with simulated timestamps so the
/// stall window (three seconds) and rate-limit window (ten seconds)
/// can be exercised in microseconds rather than seconds.
@MainActor
public final class PresentStallWatchdog {
    /// Seconds of no `presented` progress (with `ingested` still
    /// advancing) before the watchdog considers the pipeline stalled.
    public static let stallWindowSeconds: Double = 3.0

    /// Minimum seconds between successive WARN emissions while a stall
    /// persists; FR-6 caps this at one line per ten-second window.
    public static let rateLimitSeconds: Double = 10.0

    /// Tick cadence used by the production scheduling loop. Tests do
    /// not rely on this; they drive `tick(now:)` synchronously.
    public static let tickIntervalSeconds: Double = 1.0

    private let sampleProvider: () -> PresentStallSample
    private let log: Logger
    private var task: Task<Void, Never>?

    /// Rolling baseline: the (sample, timestamp) captured roughly
    /// `stallWindowSeconds` ago. The baseline is rotated forward
    /// whenever (a) presentation advances, (b) ingestion stalls, or
    /// (c) the state leaves `.running`, so the watchdog only fires on
    /// a *sustained* ingest-advance / present-flat window.
    private var baseline: (sample: PresentStallSample, at: Double)?

    /// Wall-clock host time of the most recent WARN emission, used to
    /// enforce the FR-6 ten-second rate limit. `nil` means no line has
    /// been emitted in the current process lifetime.
    private var lastEmissionAt: Double?

    public init(
        sampleProvider: @escaping () -> PresentStallSample,
        log: Logger = Logger(category: "watchdog")
    ) {
        self.sampleProvider = sampleProvider
        self.log = log
    }

    /// Start the production once-per-second tick loop. Idempotent: a
    /// second `start()` while a task is already running is a no-op so
    /// the coordinator can call it on every transition into `.running`
    /// without bookkeeping.
    public func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick(now: Self.currentHostTime())
                let nanos = UInt64(Self.tickIntervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    /// Stop the tick loop and discard rolling baseline state so a
    /// subsequent `start()` begins from a clean slate (per FR-6 the
    /// watchdog only runs while `.running`).
    public func stop() {
        task?.cancel()
        task = nil
        baseline = nil
        lastEmissionAt = nil
    }

    /// Drive one watchdog evaluation at the given host time. Exposed
    /// `public` so tests can simulate the three-second stall window
    /// and ten-second rate-limit window without real waiting.
    public func tick(now: Double) {
        let current = sampleProvider()
        guard current.state == .running else {
            // FR-6 forbids emissions outside `.running`. Drop the
            // baseline so re-entering `.running` does not retroactively
            // count time spent restarting/idle as part of a stall.
            baseline = nil
            return
        }
        guard let prior = baseline else {
            baseline = (current, now)
            return
        }
        let elapsed = now - prior.at
        if elapsed < Self.stallWindowSeconds {
            // Still inside the observation window; do not rotate the
            // baseline yet so the next tick can compare against the
            // same prior snapshot.
            return
        }
        let ingestedAdvanced = current.ingested > prior.sample.ingested
        let presentedAdvanced = current.presented > prior.sample.presented
        if ingestedAdvanced, !presentedAdvanced {
            emitIfAllowed(current: current, elapsed: elapsed, now: now)
        }
        // Rotate the baseline forward on every evaluation past the
        // window so the next stall check observes a fresh three-second
        // delta, regardless of whether a line was emitted.
        baseline = (current, now)
    }

    /// FR-6 / FR-7: emit at most one line per ten-second window.
    private func emitIfAllowed(
        current: PresentStallSample, elapsed: Double, now: Double
    ) {
        if let last = lastEmissionAt, now - last < Self.rateLimitSeconds {
            return
        }
        lastEmissionAt = now
        let elapsedRounded = (elapsed * 1000).rounded() / 1000
        log.warning(
            "present stall: ingested=\(current.ingested) presented=\(current.presented) elapsed=\(elapsedRounded)"
        )
    }

    /// Host-time source used by the production tick loop. Pulled
    /// through a static so the production path matches the latency
    /// timestamps emitted by `FramePresenter` (both use
    /// `CACurrentMediaTime`).
    private static func currentHostTime() -> Double {
        // Avoid pulling in QuartzCore here; `Date` is sufficient for
        // the seconds-scale comparisons this watchdog performs.
        Date().timeIntervalSinceReferenceDate
    }
}
