//
//  capture.stream_output.swift
//  DeskPad
//
//  @agents-index `SCStreamOutput` + `SCStreamDelegate` implementation that
//  extracts the zero-copy `IOSurface` from each delivered `CMSampleBuffer` via
//  `CVPixelBufferGetIOSurface` and atomically publishes it for the renderer
//  to consume on the next display-link tick. Also stamps the host-time at
//  ingest (FR-15 latency budget) and tracks an arrival-rate EMA (FR-18
//  adaptive mode switching).
//

import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import IOSurface
import os
import QuartzCore
import ScreenCaptureKit

/// Most-recent surface plus its ingest timestamp, used by the renderer
/// to compute capture-to-present latency (FR-15 / AC-13). CR-0002
/// Phase 1 widens this value to also carry the source `CMSampleBuffer`
/// so the `PresentationBackend.enqueue(_:)` hand-off introduced by
/// CR-0002 FR-2 can be a `CMSampleBuffer` instead of a raw `IOSurface`.
/// The buffer is optional because the test-only `publishForTest`
/// entry points start from a bare `CVPixelBuffer` / `IOSurface` and
/// have no `CMSampleBuffer` to publish; the production
/// `SCStreamOutput` callback always populates it.
public struct CapturedSurface: @unchecked Sendable {
    public let surface: IOSurface
    /// `CACurrentMediaTime()` recorded the moment the SCK delivery
    /// callback ran. Subtracting from the present time gives the
    /// end-to-end capture-to-present latency.
    public let ingestHostTime: CFTimeInterval
    /// Source `CMSampleBuffer` retained alongside the unwrapped
    /// `IOSurface`. CR-0002 Phase 1 carries this so the
    /// `PresentationBackend.enqueue(_:)` interface can be a
    /// `CMSampleBuffer` per CR-0002 FR-2 without a second extraction
    /// hop. `nil` only on the test-only `publishForTest` paths that
    /// start from a bare `CVPixelBuffer` or `IOSurface`.
    public let sampleBuffer: CMSampleBuffer?

    public init(surface: IOSurface, ingestHostTime: CFTimeInterval, sampleBuffer: CMSampleBuffer? = nil) {
        self.surface = surface
        self.ingestHostTime = ingestHostTime
        self.sampleBuffer = sampleBuffer
    }
}

/// Stream output that captures the most recent `IOSurface` delivered by an
/// `SCStream` and exposes it via `latestSurface`. Also reports delegate
/// errors (`SCStreamDelegate.stream(_:didStopWithError:)`) by invoking
/// `onStopError` so the coordinator can drive backoff/restart.
public final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Closure invoked when the stream stops with an error. Captured by the
    /// coordinator to drive exponential-backoff restart.
    public typealias StopErrorHandler = @Sendable (any Error) -> Void

    private let log = Logger(category: "capture")
    private let lock = OSAllocatedUnfairLock<CapturedSurface?>(initialState: nil)
    private let metricsLock = OSAllocatedUnfairLock<ArrivalMetrics>(initialState: ArrivalMetrics())
    private let handlerLock = OSAllocatedUnfairLock<Handlers>(initialState: Handlers())

    /// Mutable handler bundle so the coordinator can wire stop-error
    /// and per-arrival callbacks after `StreamOutput` is constructed.
    /// Held under `handlerLock` so the SCK delivery queue and the main
    /// actor's writer side cannot race.
    private struct Handlers: Sendable {
        var stopErrorHandler: StopErrorHandler?
        var onArrival: (@Sendable () -> Void)?
        /// CR-0002 FR-2 / AC-1 / AC-2: per-buffer push hand-off. Invoked
        /// on the SCK delivery thread with the source `CMSampleBuffer`.
        /// The coordinator wires this to a closure that hops to the main
        /// actor and calls `currentBackend.enqueue(buffer)`. The buffer
        /// crosses the actor hop inside a `@unchecked Sendable` wrapper
        /// since `CMSampleBuffer` is not `Sendable` under Swift 6 strict
        /// concurrency; ownership is held until the hop completes.
        var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?
    }

    private let initialStopErrorHandler: StopErrorHandler?

    /// Monotonic counter of successful surface extractions. Incremented
    /// exactly once per `ingest(_:)` (or test-only publish) call that
    /// extracts an `IOSurface`. Observed by the CR-0003 Layer 1 watchdog
    /// (`render.present_stall_watchdog.swift`) to detect the white-window
    /// failure class (ingestion advancing without presentation).
    private let ingestedCounterLock = OSAllocatedUnfairLock<Int>(initialState: 0)
    public var ingestedFrameCount: Int { ingestedCounterLock.withLock { $0 } }

    /// Snapshot of the EMA of inter-arrival intervals (seconds) plus the
    /// last-seen ingest timestamp. The coordinator's adaptive-mode logic
    /// (FR-18) reads `intervalEMA` to decide whether to switch modes.
    public struct ArrivalMetrics: Sendable {
        public var intervalEMA: Double = 0
        public var lastIngestHostTime: CFTimeInterval = 0
        public var sampleCount: Int = 0
    }

    public init(onStopError: StopErrorHandler? = nil) {
        initialStopErrorHandler = onStopError
        super.init()
        handlerLock.withLock { $0.stopErrorHandler = onStopError }
    }

    /// Replace the stop-error handler post-construction. Used by the
    /// coordinator to wire the FR-7 / AC-6 restart trigger after the
    /// output has been built.
    public func setStopErrorHandler(_ handler: StopErrorHandler?) {
        handlerLock.withLock { $0.stopErrorHandler = handler }
    }

    /// Install a per-arrival callback. The renderer wires this to
    /// `pacer.markDirty()` so a freshly-arrived `IOSurface` lifts the
    /// FR-5 dirty bit and the next display-link tick presents.
    public func setOnArrival(_ handler: (@Sendable () -> Void)?) {
        handlerLock.withLock { $0.onArrival = handler }
    }

    /// CR-0002 FR-2: register a per-buffer push callback. Invoked once
    /// per delivered `CMSampleBuffer` on the SCK delivery thread, before
    /// the dirty-bit `onArrival` callback fires. The coordinator wires
    /// this to `currentBackend.enqueue(buffer)`.
    public func setOnSampleBuffer(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) {
        handlerLock.withLock { $0.onSampleBuffer = handler }
    }

    /// Latest captured surface bundle (`IOSurface` + ingest timestamp).
    public var latestCapturedSurface: CapturedSurface? {
        lock.withLock { $0 }
    }

    /// Backwards-compatible accessor: returns just the surface for
    /// existing callers that do not need the ingest timestamp.
    public var latestSurface: IOSurface? {
        lock.withLock { $0?.surface }
    }

    /// Snapshot the arrival-rate metrics under the metrics lock.
    public var arrivalMetrics: ArrivalMetrics {
        metricsLock.withLock { $0 }
    }

    /// Test-only entry point: synthesise the delivery path with a caller-
    /// provided `CMSampleBuffer`. Production traffic arrives via the
    /// `SCStreamOutput` protocol method below.
    public func publishForTest(sampleBuffer: CMSampleBuffer) {
        ingest(sampleBuffer)
    }

    /// Test-only entry point: exercise the same surface-extraction path as
    /// `ingest(_:)` starting from a bare `CVPixelBuffer`, skipping the
    /// `CMSampleBuffer` wrapping which has a SDK-fragile Swift signature.
    public func publishForTest(pixelBuffer: CVPixelBuffer) {
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
        let surface = surfaceRef.takeUnretainedValue()
        publish(surface: surface)
    }

    /// Test-only: drive the arrival-rate EMA from an explicit timestamp
    /// stream so `adaptive_mode_switch_tests.swift` can assert mode
    /// transitions deterministically without scheduling real frames.
    public func publishForTest(syntheticIngestHostTime: CFTimeInterval) {
        updateArrival(at: syntheticIngestHostTime)
    }

    // MARK: - SCStreamOutput

    public func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        // Dirty gate (CR-0002 energy fix, docs/cr/CR-0002-repl.md):
        // ScreenCaptureKit stamps every delivered buffer with an
        // `SCStreamFrameInfo.status` attachment. Only `.complete`
        // frames carry new pixel content; `.idle` frames repeat the
        // previous surface on a timer. Publishing idle frames made the
        // AVSBDL backend decode-and-present unchanged 4K content at
        // the full capture rate (~19 percent of a core on a static
        // workload) and made the Metal pacer re-present identical
        // frames. Skipping them is the capture-side equivalent of the
        // Metal pacer's dirty-bit gate.
        guard frameStatus(of: sampleBuffer) == .complete else { return }
        ingest(sampleBuffer)
    }

    /// Read the `SCStreamFrameInfo.status` attachment SCK stamps on every
    /// delivered buffer. Returns `nil` when the attachment is missing
    /// (synthetic/test buffers), which callers treat as not-complete.
    private func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: rawStatus)
    }

    // MARK: - SCStreamDelegate

    public func stream(_: SCStream, didStopWithError error: any Error) {
        log.error("SCStream stopped: \(error.localizedDescription)")
        let handler = handlerLock.withLock { $0.stopErrorHandler }
        handler?(error)
    }

    // MARK: - Private

    private func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
        let surface = surfaceRef.takeUnretainedValue()
        publish(surface: surface, sampleBuffer: sampleBuffer)
    }

    private func publish(surface: IOSurface, sampleBuffer: CMSampleBuffer? = nil) {
        ingestedCounterLock.withLock { $0 += 1 }
        let now = CACurrentMediaTime()
        // `OSAllocatedUnfairLock.withLock`'s closure is `@Sendable`, but
        // `CMSampleBuffer` is not `Sendable` in the Swift 6 strict-
        // concurrency model. The buffer is owned by this synchronous
        // call (the SCK delivery callback retains it for the duration
        // of `ingest`), so it is safe to carry across the lock; the
        // `@unchecked Sendable` `Captured` wrapper documents that.
        let captured = CapturedSurface(surface: surface, ingestHostTime: now, sampleBuffer: sampleBuffer)
        let isFirst = lock.withLock { state in
            let wasEmpty = state == nil
            state = captured
            return wasEmpty
        }
        // One-shot arrival marker: proves capture-side frame flow in the
        // log without per-frame log volume.
        if isFirst {
            log.notice("first frame ingested (\(IOSurfaceGetWidth(surface))x\(IOSurfaceGetHeight(surface)))")
        }
        updateArrival(at: now)
        let handlers = handlerLock.withLock { ($0.onArrival, $0.onSampleBuffer) }
        if let sb = sampleBuffer, let onSampleBuffer = handlers.1 {
            onSampleBuffer(sb)
        }
        handlers.0?()
    }

    /// EMA update for inter-arrival intervals. Alpha 0.1 trades some
    /// reactivity for less jitter; the adaptive-mode logic only acts on
    /// sustained changes so a slow EMA is preferred.
    private func updateArrival(at hostTime: CFTimeInterval) {
        metricsLock.withLock { metrics in
            defer {
                metrics.lastIngestHostTime = hostTime
                metrics.sampleCount += 1
            }
            guard metrics.lastIngestHostTime > 0 else { return }
            let delta = hostTime - metrics.lastIngestHostTime
            guard delta > 0 else { return }
            if metrics.intervalEMA == 0 {
                metrics.intervalEMA = delta
            } else {
                let alpha = 0.1
                metrics.intervalEMA = alpha * delta + (1 - alpha) * metrics.intervalEMA
            }
        }
    }
}
