//
//  screen.capture_render_coordinator.swift
//  DeskPad
//  @agents-index Top-level CR-0001 Phase 4 coordinator: wires capture
//  (LiveStreamHandle + StreamOutput + StreamCoordinator) to render
//  (DisplayLinkPacer + FramePresenter). Permission probe / watcher
//  and the per-tick render closure live in their own files to honour
//  the NFR-4 / AC-17 200-LOC cap.
//

import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import Metal
import ScreenCaptureKit

/// CR-0002 FR-2: `CMSampleBuffer` is not `Sendable` in Swift 6 strict
/// concurrency. The capture-to-backend push hop completes synchronously
/// during the SCK delivery callback's lifetime, so the buffer is alive
/// for the entire actor hop; this wrapper carries it across without
/// extending its lifetime beyond the hop.
private struct UncheckedSampleBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

public enum CaptureRenderCoordinatorState: Sendable, Equatable {
    case idle
    case running
    case restarting(attempt: Int)
    case permissionRequired
    case failed
}

@MainActor
public final class CaptureRenderCoordinator {
    private let log = Logger(category: "screen")
    private let permissionProbe: any ScreenCapturePermissionProbe
    public let streamCoordinator: StreamCoordinator
    public let hostView: MetalLayerHostView
    public let pacer: DisplayLinkPacer
    public let streamOutput: StreamOutput
    private let textureCache: IOSurfaceTextureCache
    private var blitPipeline: BlitPipeline?
    private let deviceLossRecovery: DeviceLossRecovery
    private let presenter: FramePresenter
    /// CR-0002 Phase 1: the coordinator now reaches the presentation
    /// stage through a `PresentationBackend` existential rather than
    /// the concrete Metal ensemble. The only possible concrete type in
    /// Phase 1 is `MetalBackend`; Phase 2 adds the AVSBDL backend and
    /// Phase 3 lets the user switch between them at runtime.
    public private(set) var currentBackend: any PresentationBackend
    private var permissionWatcher: PermissionWatcher?
    private var liveHandle: LiveStreamHandle?
    private var currentMode: CaptureMode = .lowLatency(panelMaxRefreshHz: 60)
    /// CR-0003 Phase 2: Layer 1 watchdog. Lazily constructed and only
    /// running while `state == .running`; see FR-6 for the emission
    /// contract and `setState(_:)` for the lifecycle wiring.
    private var presentStallWatchdog: PresentStallWatchdog?
    /// CR-0002 Phase 3: throttle the no-op log line emitted when an
    /// adaptive `.lowLatency` request lands on a backend whose
    /// `diagnostics.latencyModeApplicable` is `false` (FR-14). Reset
    /// whenever the active backend changes so the next burst is
    /// announced once.
    private var lastLatencyNoOpLogged: PresentationBackendIdentifier?
    /// CR-0002 Phase 3: notification observer token for the menu
    /// switch event. Removed in `deinit` (test-only path) and via
    /// `tearDownBackendSwitchObserver` when needed.
    private var backendSwitchObserver: NSObjectProtocol?

    public private(set) var state: CaptureRenderCoordinatorState = .idle {
        didSet { didSetState(from: oldValue) }
    }

    private var lastResolution: CGSize = .zero
    private var lastScaleFactor: CGFloat = 1
    private var displayID: CGDirectDisplayID?

    public init(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        permissionProbe: any ScreenCapturePermissionProbe = SystemScreenCapturePermissionProbe()
    ) {
        let resolvedDevice = device ?? MTLCreateSystemDefaultDevice() ?? MTLCopyAllDevices().first!
        self.permissionProbe = permissionProbe
        streamCoordinator = StreamCoordinator()
        hostView = MetalLayerHostView(device: resolvedDevice)
        textureCache = IOSurfaceTextureCache(device: resolvedDevice)
        deviceLossRecovery = DeviceLossRecovery()
        streamOutput = StreamOutput()
        var builtPipeline: BlitPipeline?
        do { builtPipeline = try BlitPipeline(device: resolvedDevice) } catch {
            builtPipeline = nil
            log.error("BlitPipeline init failed: \(String(describing: error))")
        }
        blitPipeline = builtPipeline
        let queue = resolvedDevice.makeCommandQueue()
        presenter = FramePresenter(
            textureCache: textureCache, streamOutput: streamOutput, hostView: hostView,
            commandQueue: queue, getPipeline: { builtPipeline },
            onCommandBufferError: { _ in }
        )
        pacer = DisplayLinkPacer(present: { _ in })
        currentBackend = MetalBackend(
            hostView: hostView, presenter: presenter, streamOutput: streamOutput
        )
        // All stored properties are now initialised; install the
        // closures that capture `self`.
        let presenterRef = presenter
        pacer.replacePresent { tick in presenterRef.present(tick: tick) }
        let pacerRef = pacer
        streamOutput.setOnArrival { Task { @MainActor in pacerRef.markDirty() } }
        // CR-0002 FR-2 / AC-1 / AC-2: per-buffer push hand-off to the
        // active `PresentationBackend`. The Metal backend's `enqueue`
        // republishes through `StreamOutput` (no-op-equivalent), keeping
        // CR-0001's pacer-pull model intact; the AVSBDL backend's
        // `enqueue` is the only sink that makes a frame visible on its
        // `AVSampleBufferDisplayLayer` (FR-7, AC-8).
        streamOutput.setOnSampleBuffer { [weak self] buffer in
            let wrapped = UncheckedSampleBuffer(buffer: buffer)
            Task { @MainActor [weak self] in
                self?.currentBackend.enqueue(wrapped.buffer)
            }
        }
        let actorRef = streamCoordinator
        streamOutput.setStopErrorHandler { _ in Task { await actorRef.triggerRestart() } }
        presenter.setOnCommandBufferError { [weak self] error in
            Task { @MainActor in _ = self?.handleDeviceLoss(error: error) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.evaluatePermission() } }
        // CR-0002 Phase 3 (FR-5, FR-6, AC-7): observe the menu-driven
        // (or test-driven) backend switch notification and perform the
        // live swap on the main actor. The `SCStream` is not stopped;
        // only the backend is torn down and replaced.
        backendSwitchObserver = NotificationCenter.default.addObserver(
            forName: .deskPadPresentationBackendSwitch,
            object: nil, queue: .main
        ) { [weak self] note in
            let raw = (note.userInfo?[PresentationBackendSwitchUserInfoKey.backend] as? String) ?? ""
            let trigger = (note.userInfo?[PresentationBackendSwitchUserInfoKey.trigger] as? String) ?? "unknown"
            guard let identifier = PresentationBackendIdentifier(rawValue: raw) else { return }
            Task { @MainActor in self?.switchBackend(to: identifier, trigger: trigger) }
        }
        // CR-0002 Phase 3 (FR-3, FR-4, AC-4, AC-5, AC-6): resolve the
        // persisted UserDefaults value and the launch argument, and if
        // the resolution selects a non-Metal backend (or surfaces an
        // invalid value) act on it at startup. `--self-test` short-
        // circuits the resolution per FR-19 / AC-21 so the self-test
        // always runs on Metal regardless of preference.
        let args = CommandLine.arguments
        if !args.contains(SelfTestLaunchDispatch.kSelfTestFlag) {
            let selection = PresentationBackendKey.resolve(
                arguments: args, defaults: .standard
            )
            if selection.source == .fallbackInvalidValue {
                log.warning("backend=metal selection fallback: invalid value=\"\(selection.rawInvalidValue ?? "")\" source=fallbackInvalidValue")
            } else {
                log.info("backend=\(selection.identifier.rawValue) selection resolved source=\(selection.source.rawValue)")
            }
            if selection.identifier != .metal {
                switchBackend(to: selection.identifier, trigger: "startup")
            }
        }
    }

    // Observer removal is intentionally not in `deinit`: the coordinator
    // is a `@MainActor` final class and Swift 6 forbids touching
    // actor-isolated stored properties from a nonisolated deinit. The
    // observer closure captures `[weak self]`, so a deallocated
    // coordinator no-ops; the `NotificationCenter` block is reaped when
    // the process exits.

    public func bindDisplay(_ displayID: CGDirectDisplayID) {
        self.displayID = displayID
        log.info("coordinator bound to displayID=\(displayID)")
        Task { @MainActor in await self.startLiveCapture(displayID: displayID) }
    }

    private func startLiveCapture(displayID: CGDirectDisplayID) async {
        guard permissionProbe.preflight() else {
            state = .permissionRequired
            permissionProbe.request()
            startPermissionWatcher()
            return
        }
        do {
            let filter = try await VirtualDisplayFilterFactory().makeFilter(for: displayID)
            let panelMax = NSScreen.main?.maximumFramesPerSecond ?? 60
            currentMode = .lowLatency(panelMaxRefreshHz: panelMax)
            let resolution = lastResolution == .zero ? CGSize(width: 1920, height: 1080) : lastResolution
            let scale = lastScaleFactor == 0 ? 1 : lastScaleFactor
            let configuration = StreamConfigurationFactory().makeConfiguration(
                resolution: resolution, scaleFactor: scale, mode: currentMode
            )
            let handle = try LiveStreamHandle(
                filter: filter, configuration: configuration,
                output: streamOutput, mode: currentMode
            )
            liveHandle = handle
            await streamCoordinator.install(handle: handle)
            try await streamCoordinator.start()
            state = .running
            pacer.attach(toMetalLayer: hostView.metalLayer)
            log.notice("live SCStream started on displayID=\(displayID)")
        } catch {
            log.error("startLiveCapture failed: \(String(describing: error))")
            state = .failed
            startPermissionWatcher()
        }
    }

    public func applyConfiguration(resolution: CGSize, scaleFactor: CGFloat) async {
        guard resolution != .zero else { return }
        if resolution == lastResolution, scaleFactor == lastScaleFactor { return }
        lastResolution = resolution
        lastScaleFactor = scaleFactor
        let width = Int(resolution.width * scaleFactor)
        let height = Int(resolution.height * scaleFactor)
        hostView.setDrawablePixelSize(CGSize(width: width, height: height))
        // CR-0002 FR-12 / AC-12: forward geometry through the
        // `PresentationBackend.configure(displaySize:scaleFactor:)`
        // surface so the AVSBDL backend can flush-on-reconfigure and
        // the Metal backend can keep its drawable size in lock-step
        // through the protocol seam rather than the concrete host view.
        do { try currentBackend.configure(displaySize: resolution, scaleFactor: scaleFactor) }
        catch { log.error("backend=\(currentBackend.diagnostics.identifier) configure failed: \(String(describing: error))") }
        do { try await streamCoordinator.updateConfiguration(width: width, height: height) }
        catch { log.error("updateConfiguration failed: \(String(describing: error))") }
    }

    @discardableResult
    public func evaluatePermission() -> CaptureRenderCoordinatorState {
        if permissionProbe.preflight() {
            permissionWatcher?.stop()
            return state
        }
        state = .permissionRequired
        log.notice("screen recording permission missing; requesting access")
        permissionProbe.request()
        startPermissionWatcher()
        return state
    }

    public func _setStateForTest(_ newState: CaptureRenderCoordinatorState) { state = newState }

    public func handleDeviceLoss(error: NSError?) -> DeviceLossOutcome {
        return deviceLossRecovery.handle(error: error) { [weak self] newDevice in
            guard let self else { return }
            self.hostView.replaceDevice(newDevice)
            self.textureCache.replaceDevice(newDevice)
            try self.blitPipeline?.replaceDevice(newDevice)
        }
    }

    /// FR-18 adaptive-mode evaluation. Public so the integration test
    /// can drive it deterministically by seeding the output's EMA.
    ///
    /// CR-0002 Phase 3 (FR-14, AC-14): when the desired mode is
    /// `.lowLatency` but the active backend reports
    /// `diagnostics.latencyModeApplicable == false`, the
    /// presentation-side effects no-op; the capture-side
    /// `liveHandle.updateMode(_:)` MAY still apply because mode
    /// transitions affect what the capture subsystem produces. The
    /// no-op is logged at most once per backend until the active
    /// backend changes.
    @discardableResult
    public func evaluateAdaptiveMode(switchThresholdSeconds: Double = 1.0 / 45.0) -> CaptureMode {
        let ema = streamOutput.arrivalMetrics.intervalEMA
        let panelMax = NSScreen.main?.maximumFramesPerSecond ?? 60
        let desired: CaptureMode = ema > switchThresholdSeconds
            ? .powerSaving : .lowLatency(panelMaxRefreshHz: panelMax)
        if desired != currentMode {
            let backendId = currentBackend.diagnostics.identifier
            let latencyApplicable = currentBackend.diagnostics.latencyModeApplicable
            log.notice("adaptive mode transition: \(String(describing: currentMode)) -> \(String(describing: desired)) ema=\(ema) backend=\(backendId)")
            currentMode = desired
            if case .lowLatency = desired, !latencyApplicable {
                let parsedId = PresentationBackendIdentifier(rawValue: backendId)
                if lastLatencyNoOpLogged != parsedId {
                    log.notice("adaptive lowLatency request: presentation-side no-op (backend=\(backendId) latencyModeApplicable=false)")
                    lastLatencyNoOpLogged = parsedId
                }
                if let liveHandle {
                    Task { @MainActor in try? await liveHandle.updateMode(desired) }
                }
                return currentMode
            }
            if let liveHandle {
                Task { @MainActor in try? await liveHandle.updateMode(desired) }
            }
        }
        return currentMode
    }

    /// CR-0002 Phase 3 (FR-6, AC-7): live backend switch. Tears down
    /// the current backend, removes its `hostView` from the window's
    /// content view, instantiates the new backend, installs the new
    /// `hostView`, calls `configure(displaySize:scaleFactor:)`, and
    /// logs the elapsed time. The `SCStream` is not stopped; capture
    /// continues uninterrupted. Re-entrant calls into the active
    /// backend are a no-op (idempotent).
    public func switchBackend(to identifier: PresentationBackendIdentifier, trigger: String) {
        let oldIdentifier = currentBackend.diagnostics.identifier
        guard oldIdentifier != identifier.rawValue else {
            log.info("backend switch ignored: already on \(identifier.rawValue) (trigger=\(trigger))")
            return
        }
        let start = Date()
        let oldHostView = currentBackend.hostView
        currentBackend.teardown()
        let newBackend: any PresentationBackend
        switch identifier {
        case .metal:
            newBackend = MetalBackend(
                hostView: hostView, presenter: presenter, streamOutput: streamOutput
            )
        case .avsbdl:
            newBackend = AVSBDLBackend()
        }
        // Swap the host view inside the parent (the window's content
        // view, or whichever superview previously hosted the old
        // backend's view).
        if let parent = oldHostView.superview {
            let frame = oldHostView.frame
            let autoresizing = oldHostView.autoresizingMask
            oldHostView.removeFromSuperview()
            newBackend.hostView.frame = frame
            newBackend.hostView.autoresizingMask = autoresizing
            parent.addSubview(newBackend.hostView)
        }
        currentBackend = newBackend
        lastLatencyNoOpLogged = nil
        let resolution = lastResolution == .zero
            ? CGSize(width: 1920, height: 1080) : lastResolution
        let scale = lastScaleFactor == 0 ? 1 : lastScaleFactor
        do {
            try newBackend.configure(displaySize: resolution, scaleFactor: scale)
        } catch {
            log.error("backend configure failed: \(String(describing: error))")
        }
        let elapsedMs = Date().timeIntervalSince(start) * 1000.0
        log.notice("backend switch: \(oldIdentifier) -> \(identifier.rawValue) trigger=\(trigger) elapsed_ms=\(elapsedMs)")
    }

    /// CR-0003 Phase 2 lifecycle wiring: start the Layer 1 watchdog on
    /// the first transition into `.running`; stop it whenever the
    /// coordinator leaves `.running` for `.idle`, `.permissionRequired`,
    /// or `.failed`. Driven from the `state` property's `didSet` so
    /// every state transition (including the test-only seam
    /// `_setStateForTest`) is covered without duplicating call sites.
    private func didSetState(from oldState: CaptureRenderCoordinatorState) {
        guard oldState != state else { return }
        if state == .running {
            if presentStallWatchdog == nil {
                let outputRef = streamOutput
                presentStallWatchdog = PresentStallWatchdog(
                    sampleProvider: { [weak self] in
                        // CR-0002 FR-18: read `presentedFrameCount`
                        // through the active backend so the watchdog
                        // continues to sample a meaningful value
                        // after a live backend switch.
                        let presented = self?.currentBackend.presentedFrameCount ?? 0
                        return PresentStallSample(
                            ingested: outputRef.ingestedFrameCount,
                            presented: presented,
                            state: self?.state ?? .idle
                        )
                    }
                )
            }
            presentStallWatchdog?.start()
            return
        }
        switch state {
        case .idle, .permissionRequired, .failed:
            presentStallWatchdog?.stop()
        case .restarting, .running:
            break
        }
    }

    private func startPermissionWatcher() {
        if permissionWatcher == nil {
            permissionWatcher = PermissionWatcher(probe: permissionProbe) { [weak self] granted in
                guard let self, granted else { return }
                self.permissionWatcher?.stop()
                if let displayID = self.displayID {
                    Task { @MainActor in await self.startLiveCapture(displayID: displayID) }
                }
            }
        }
        permissionWatcher?.start()
    }
}
