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
import Foundation
import Metal
import ScreenCaptureKit

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
        let actorRef = streamCoordinator
        streamOutput.setStopErrorHandler { _ in Task { await actorRef.triggerRestart() } }
        presenter.setOnCommandBufferError { [weak self] error in
            Task { @MainActor in _ = self?.handleDeviceLoss(error: error) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.evaluatePermission() } }
    }

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
    @discardableResult
    public func evaluateAdaptiveMode(switchThresholdSeconds: Double = 1.0 / 45.0) -> CaptureMode {
        let ema = streamOutput.arrivalMetrics.intervalEMA
        let panelMax = NSScreen.main?.maximumFramesPerSecond ?? 60
        let desired: CaptureMode = ema > switchThresholdSeconds
            ? .powerSaving : .lowLatency(panelMaxRefreshHz: panelMax)
        if desired != currentMode {
            log.notice("adaptive mode transition: \(String(describing: currentMode)) -> \(String(describing: desired)) ema=\(ema)")
            currentMode = desired
            if let liveHandle {
                Task { @MainActor in try? await liveHandle.updateMode(desired) }
            }
        }
        return currentMode
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
