//
//  render.avsbdl_backend.swift
//  DeskPad
//
//  @agents-index CR-0002 Phase 2: the `AVSampleBufferDisplayLayer`-based
//  `PresentationBackend`. Drives every enqueue, flush, status read, and
//  notification observation through the layer's modern
//  `sampleBufferRenderer` (`AVSampleBufferVideoRenderer`), declared at
//  `AVSampleBufferDisplayLayer.h:303` and `API_AVAILABLE(macos(14.0))`
//  which is satisfied unconditionally by CR-0001's macOS 15.0
//  deployment target. The deprecated direct-on-layer methods
//  (`enqueueSampleBuffer:`, `flush`, `flushAndRemoveImage`, `status`,
//  `error`, `readyForMoreMediaData`, `requiresFlushToResumeDecoding`,
//  `timebase`) per `AVSampleBufferDisplayLayer.h` lines 94..226 are
//  **never** referenced (CR-0002 FR-7, AC-8).
//
//  Each enqueued `CMSampleBuffer` is stamped with
//  `kCMSampleAttachmentKey_DisplayImmediately = kCFBooleanTrue`
//  (CR-0002 FR-8); the renderer is **not** combined with a control
//  timebase or `AVSampleBufferRenderSynchronizer` (CR-0002 FR-9).
//  Readiness is gated on `readyForMoreMediaData`; not-ready buffers are
//  dropped with rate-limited logging (CR-0002 FR-13). KVO of `status`
//  and the `DidFailToDecode` / `RequiresFlushToResumeDecoding`
//  notifications all trigger the same flush-and-resume recovery
//  (CR-0002 FR-10, FR-11). `presentedFrameCount` increments on every
//  readiness-gated successful enqueue so the CR-0003
//  `PresentStallWatchdog` works backend-agnostically (CR-0002 FR-18).
//
//  Phase 2 wires this backend behind a not-yet-exposed entry point;
//  tests reach it via the test-only `init(renderer:hostView:)`
//  constructor. The toggle and live-switch come in Phase 3.
//

import AppKit
import AVFoundation
import CoreMedia
import Foundation

/// Abstraction over the subset of `AVSampleBufferVideoRenderer` the
/// backend uses, so tests can substitute a spy without instantiating a
/// real `AVSampleBufferDisplayLayer`. The production conformance is the
/// host layer's `sampleBufferRenderer`; the spy in
/// `DeskPadTests/Render/avsbdl_backend_*` records calls and stubs
/// readiness.
@MainActor
public protocol AVSBDLSampleBufferRendering: AnyObject {
    /// Mirrors `AVQueuedSampleBufferRendering.readyForMoreMediaData`
    /// (`AVQueuedSampleBufferRendering.h:96`). Checked before every
    /// enqueue per CR-0002 FR-13.
    var isReadyForMoreMediaData: Bool { get }

    /// Mirrors
    /// `AVSampleBufferVideoRenderer.enqueueSampleBuffer:`
    /// (`AVSampleBufferVideoRenderer.h:55`), the modern replacement for
    /// the deprecated layer-level method.
    func enqueueSampleBuffer(_ buffer: CMSampleBuffer)

    /// Mirrors
    /// `AVSampleBufferVideoRenderer.flushWithRemovalOfDisplayedImage:completionHandler:`
    /// (`AVSampleBufferVideoRenderer.h:67`).
    func flushWithRemovalOfDisplayedImage(_ removeImage: Bool, completion: @escaping @Sendable () -> Void)
}

/// `AVSampleBufferDisplayLayer`-based presentation backend.
@MainActor
public final class AVSBDLBackend: NSObject, PresentationBackend {
    private let hostViewImpl: NSView
    private let renderer: AVSBDLSampleBufferRendering
    private let log = Logger(category: "render")

    /// CR-0002 FR-18: monotonic count of successful, readiness-gated
    /// enqueues. Read by the coordinator and surfaced to the CR-0003
    /// `PresentStallWatchdog`. Dropped frames are excluded.
    public private(set) var presentedFrameCount: Int = 0

    private var droppedFrameCount: Int = 0
    private var lastDropLogTime: Date?
    private var lastErrorDescription: String?
    private var hasBeenConfigured: Bool = false
    private var statusObservation: NSKeyValueObservation?

    private var notificationObservers: [NSObjectProtocol] = []

    /// Production constructor. Builds an `AVSBDLHostView`, reads its
    /// `sampleBufferRenderer`, and wires KVO + notification recovery.
    override public convenience init() {
        let host = AVSBDLHostView(frame: .zero)
        // Force layer instantiation so `sampleBufferRenderer` is available.
        _ = host.layer
        let layerRenderer = host.sampleBufferDisplayLayer.sampleBufferRenderer
        self.init(
            renderer: AVSBDLSystemRendererAdapter(renderer: layerRenderer),
            hostView: host,
            systemRenderer: layerRenderer
        )
    }

    /// Test-only constructor that accepts an injected renderer and host
    /// view. The Phase 2 tests use this entry point because the CR
    /// keeps the toggle and the production wiring behind Phase 3.
    public init(
        renderer: AVSBDLSampleBufferRendering,
        hostView: NSView,
        systemRenderer: AVSampleBufferVideoRenderer? = nil
    ) {
        self.renderer = renderer
        hostViewImpl = hostView
        super.init()
        if let systemRenderer {
            installKVO(on: systemRenderer)
            installNotificationObservers(for: systemRenderer)
        }
    }

    // Cleanup runs through `teardown()`; deinit is intentionally a
    // no-op so it stays nonisolated-Sendable-safe under Swift 6 strict
    // concurrency. Callers (the coordinator) drive `teardown()` on the
    // main actor before releasing the backend (CR-0002 FR-6).

    public var hostView: NSView { hostViewImpl }

    public var diagnostics: PresentationBackendDiagnostics {
        PresentationBackendDiagnostics(
            identifier: "avsbdl",
            latencyModeApplicable: false,
            lastErrorDescription: lastErrorDescription,
            droppedFrameCount: droppedFrameCount
        )
    }

    /// CR-0002 FR-12: on every reconfigure after the first, flush the
    /// renderer with `removeDisplayedImage = true`, await completion,
    /// then resize the layer's bounds before the next enqueue.
    public func configure(displaySize: CGSize, scaleFactor _: CGFloat) throws {
        if hasBeenConfigured {
            let semaphore = DispatchSemaphore(value: 0)
            renderer.flushWithRemovalOfDisplayedImage(true) {
                semaphore.signal()
            }
            // CR-0002 Risk 5: bounded wait so a stuck completion does
            // not stall the reconfigure path. The next enqueue carries
            // `kCMSampleAttachmentKey_DisplayImmediately` and replaces
            // whatever survived per `AVSampleBufferDisplayLayer.h:117`.
            _ = semaphore.wait(timeout: .now() + .seconds(1))
            log.notice("AVSBDLBackend reconfigure flush completed (or timed out)")
        }
        let newRect = CGRect(origin: .zero, size: displaySize)
        hostViewImpl.frame = newRect
        hostViewImpl.bounds = newRect
        if let avHost = hostViewImpl as? AVSBDLHostView {
            avHost.sampleBufferDisplayLayer.bounds = newRect
        }
        hasBeenConfigured = true
    }

    /// CR-0002 FR-7, FR-8, FR-13: readiness-gate, stamp
    /// display-immediately, enqueue, increment counter. Drops are
    /// counted and logged at most once per second.
    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard renderer.isReadyForMoreMediaData else {
            droppedFrameCount += 1
            rateLimitedLogDrop()
            return
        }
        guard applyDisplayImmediatelyAttachment(sampleBuffer) else {
            droppedFrameCount += 1
            log.warning("AVSBDLBackend dropped buffer: could not set DisplayImmediately attachment")
            return
        }
        renderer.enqueueSampleBuffer(sampleBuffer)
        presentedFrameCount += 1
    }

    public func teardown() {
        for token in notificationObservers {
            NotificationCenter.default.removeObserver(token)
        }
        notificationObservers.removeAll()
        statusObservation?.invalidate()
        statusObservation = nil
        log.info("AVSBDLBackend teardown complete")
    }

    /// Test entry point: external triggers (e.g. simulated decode
    /// failure notification) call into this to exercise the recovery
    /// path without going through Notification posting.
    public func triggerRecovery(reason: String, errorDescription: String?) {
        if let errorDescription {
            lastErrorDescription = errorDescription
            log.error("AVSBDLBackend recovery: \(reason) error=\(errorDescription)")
        } else {
            log.notice("AVSBDLBackend recovery: \(reason)")
        }
        renderer.flushWithRemovalOfDisplayedImage(true) {}
    }

    // MARK: - KVO

    private func installKVO(on systemRenderer: AVSampleBufferVideoRenderer) {
        // `observe(_:options:changeHandler:)` returns an
        // `NSKeyValueObservation` that we invalidate in `teardown()`.
        // The change handler runs on whatever thread KVO fires on;
        // we extract `Sendable` values (the status enum + an optional
        // String description) before hopping to the main actor.
        statusObservation = systemRenderer.observe(\.status, options: [.new]) { [weak self] rendererObj, _ in
            let status: AVQueuedSampleBufferRenderingStatus = rendererObj.status
            let description: String? = rendererObj.error?.localizedDescription
            guard status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.triggerRecovery(reason: "status=failed", errorDescription: description)
            }
        }
    }

    // MARK: - Notifications

    private func installNotificationObservers(for systemRenderer: AVSampleBufferVideoRenderer) {
        let center = NotificationCenter.default
        let didFailToken = center.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: systemRenderer, queue: .main
        ) { [weak self] note in
            // Extract `Sendable` values up front so nothing
            // non-Sendable crosses the actor hop.
            let errorDescription = (note.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey] as? NSError)?.localizedDescription
            Task { @MainActor [weak self] in
                self?.triggerRecovery(reason: "DidFailToDecode", errorDescription: errorDescription)
            }
        }
        let flushToken = center.addObserver(
            forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: systemRenderer, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerRecovery(reason: "RequiresFlushToResumeDecoding", errorDescription: nil)
            }
        }
        notificationObservers = [didFailToken, flushToken]
    }

    private func rateLimitedLogDrop() {
        let now = Date()
        if let last = lastDropLogTime, now.timeIntervalSince(last) < 1.0 {
            return
        }
        lastDropLogTime = now
        log.warning("AVSBDLBackend dropped frame: readyForMoreMediaData=false (total=\(droppedFrameCount))")
    }
}

/// Production adapter that conforms an `AVSampleBufferVideoRenderer` to
/// the `AVSBDLSampleBufferRendering` protocol the backend talks to. The
/// adapter is the only file in the project that calls the modern
/// `enqueueSampleBuffer(_:)` and
/// `flushWithRemovalOfDisplayedImage(_:completionHandler:)` methods on
/// the system renderer, keeping the test seam clean.
@MainActor
final class AVSBDLSystemRendererAdapter: AVSBDLSampleBufferRendering {
    private let renderer: AVSampleBufferVideoRenderer

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }

    func enqueueSampleBuffer(_ buffer: CMSampleBuffer) {
        renderer.enqueue(buffer)
    }

    func flushWithRemovalOfDisplayedImage(_ removeImage: Bool, completion: @escaping @Sendable () -> Void) {
        renderer.flush(removingDisplayedImage: removeImage, completionHandler: completion)
    }
}
