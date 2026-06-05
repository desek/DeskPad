//
//  render.avsbdl_backend.swift
//  DeskPad
//
//  @agents-index CR-0002 Phase 2: the `AVSampleBufferDisplayLayer`-based
//  `PresentationBackend`. Drives every enqueue, flush, status read, and
//  notification observation through the layer's modern
//  `sampleBufferRenderer` (`AVSampleBufferVideoRenderer`); the
//  deprecated direct-on-layer methods are never referenced (FR-7, AC-8).
//  Display-immediately attachment stamped on every buffer (FR-8); no
//  synchronizer / control timebase (FR-9). Readiness gated on
//  `readyForMoreMediaData`; not-ready buffers dropped with rate-limited
//  logging (FR-13). KVO of `status` and the `DidFailToDecode` /
//  `RequiresFlushToResumeDecoding` notifications all trigger the same
//  flush-and-resume recovery (FR-10, FR-11); the install routines live
//  in `render.avsbdl_backend_observers.swift` so this file honours the
//  200-LOC small-file convention.
//

import AppKit
import AVFoundation
import CoreMedia
import Foundation

/// Abstraction over the subset of `AVSampleBufferVideoRenderer` the
/// backend uses, so tests can substitute a spy without instantiating a
/// real `AVSampleBufferDisplayLayer`.
@MainActor
public protocol AVSBDLSampleBufferRendering: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    func enqueueSampleBuffer(_ buffer: CMSampleBuffer)
    func flushWithRemovalOfDisplayedImage(_ removeImage: Bool, completion: @escaping @Sendable () -> Void)
}

/// `AVSampleBufferDisplayLayer`-based presentation backend.
@MainActor
public final class AVSBDLBackend: NSObject, PresentationBackend {
    private let hostViewImpl: NSView
    private let renderer: AVSBDLSampleBufferRendering
    let log = Logger(category: "render")

    /// CR-0002 FR-18: monotonic count of successful, readiness-gated
    /// enqueues. Read by the coordinator and the CR-0003 watchdog.
    public private(set) var presentedFrameCount: Int = 0

    var droppedFrameCount: Int = 0
    var lastDropLogTime: Date?
    private var lastErrorDescription: String?
    private var hasBeenConfigured: Bool = false
    var statusObservation: NSKeyValueObservation?
    var notificationObservers: [NSObjectProtocol] = []

    /// Production constructor.
    override public convenience init() {
        let host = AVSBDLHostView(frame: .zero)
        _ = host.layer
        let layerRenderer = host.sampleBufferDisplayLayer.sampleBufferRenderer
        self.init(
            renderer: AVSBDLSystemRendererAdapter(renderer: layerRenderer),
            hostView: host,
            systemRenderer: layerRenderer
        )
    }

    /// Test-only constructor that accepts an injected renderer and host
    /// view. Phase 2 tests reach the backend through this entry point.
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
            // not stall the reconfigure path.
            _ = semaphore.wait(timeout: .now() + .seconds(1))
            log.notice("backend=avsbdl reconfigure flush completed (or timed out)")
        }
        let newRect = CGRect(origin: .zero, size: displaySize)
        hostViewImpl.frame = newRect
        hostViewImpl.bounds = newRect
        if let avHost = hostViewImpl as? AVSBDLHostView {
            avHost.sampleBufferDisplayLayer.bounds = newRect
        }
        hasBeenConfigured = true
    }

    /// CR-0002 FR-7, FR-8, FR-13.
    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard renderer.isReadyForMoreMediaData else {
            droppedFrameCount += 1
            rateLimitedLogDrop()
            return
        }
        guard applyDisplayImmediatelyAttachment(sampleBuffer) else {
            droppedFrameCount += 1
            log.warning("backend=avsbdl dropped buffer: could not set DisplayImmediately attachment")
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
        log.info("backend=avsbdl teardown complete")
    }

    /// Test entry point: external triggers (e.g. simulated decode
    /// failure notification) drive this to exercise the recovery path
    /// without going through `NotificationCenter`.
    public func triggerRecovery(reason: String, errorDescription: String?) {
        if let errorDescription {
            lastErrorDescription = errorDescription
            log.error("backend=avsbdl recovery: \(reason) error=\(errorDescription)")
        } else {
            log.notice("backend=avsbdl recovery: \(reason)")
        }
        renderer.flushWithRemovalOfDisplayedImage(true) {}
    }
}
