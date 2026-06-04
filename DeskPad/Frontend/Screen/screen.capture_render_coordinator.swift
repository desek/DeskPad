//
//  screen.capture_render_coordinator.swift
//  DeskPad
//
//  @agents-index Top-level coordinator that wires the CR-0001 Phase 2
//  capture subsystem to the Phase 3 render subsystem. Owns the
//  `StreamCoordinator`, the `MetalLayerHostView`, the `DisplayLinkPacer`,
//  the `BlitPipeline`, the `IOSurfaceTextureCache`, and the
//  `DeviceLossRecovery` utility, and observes
//  `NSApplication.didChangeScreenParametersNotification` to drive
//  reconfiguration without restarting the stream (FR-6, AC-9).
//
//  The coordinator also owns the permission-revocation watcher: it polls
//  `CGPreflightScreenCaptureAccess` while the stream is in a terminal
//  failed state and surfaces a `.permissionRequired` state when the
//  user has revoked access mid-session (FR-8, AC-7), then triggers
//  `CGRequestScreenCaptureAccess` to walk the user through re-granting.
//
//  Lives in `Frontend/Screen/` because it is the screen subsystem's
//  outward-facing entry point; `ScreenViewController` constructs it once
//  in `viewDidLoad` and forwards the resolution/scale-factor ReSwift
//  fragment via `applyConfiguration(...)`.
//

import AppKit
import CoreGraphics
import Foundation
import Metal
import ScreenCaptureKit

/// Externally-observable state of the coordinator. Mirrors the
/// `StreamCoordinator` lifecycle but adds a `.permissionRequired` case so
/// the view layer can react to revoked screen-recording permission
/// without reaching into the actor (FR-8).
public enum CaptureRenderCoordinatorState: Sendable, Equatable {
    case idle
    case running
    case restarting(attempt: Int)
    case permissionRequired
    case failed
}

/// Seam for the system-level permission APIs so tests can drive
/// `permissionRequired` transitions deterministically.
public protocol ScreenCapturePermissionProbe: Sendable {
    /// Returns `true` when the calling process currently has screen
    /// recording permission. Production binds this to
    /// `CGPreflightScreenCaptureAccess()`.
    func preflight() -> Bool
    /// Requests permission interactively (TCC prompt). Production binds
    /// this to `CGRequestScreenCaptureAccess()`.
    @discardableResult
    func request() -> Bool
}

/// Production implementation backed by the actual TCC entry points.
/// Constructed once by the coordinator; tests inject their own probe.
public struct SystemScreenCapturePermissionProbe: ScreenCapturePermissionProbe {
    public init() {}
    public func preflight() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public func request() -> Bool {
        return CGRequestScreenCaptureAccess()
    }
}

/// Owns the capture + render pipeline. `@MainActor`-isolated because both
/// the `MetalLayerHostView` and the `DisplayLinkPacer` are main-actor
/// surfaces; the underlying `StreamCoordinator` is an actor so SCK
/// mutating calls are still off the main thread.
@MainActor
public final class CaptureRenderCoordinator {
    private let log = Logger(category: "screen")
    private let permissionProbe: any ScreenCapturePermissionProbe

    /// Stream-coordinator actor that owns the live `SCStream`. Public so
    /// `ScreenViewController` can inspect counts in tests if needed; the
    /// view controller normally only calls the coordinator's own surface.
    public let streamCoordinator: StreamCoordinator

    /// Host view the screen view controller installs into its content
    /// hierarchy. The view owns the `CAMetalLayer` and the `MTLDevice`.
    public let hostView: MetalLayerHostView

    /// Display-link pacer driving present cadence. Marked dirty whenever
    /// the capture path publishes a new `IOSurface`.
    public let pacer: DisplayLinkPacer

    private let textureCache: IOSurfaceTextureCache
    private var blitPipeline: BlitPipeline?
    private let deviceLossRecovery: DeviceLossRecovery
    private let streamOutput: StreamOutput

    /// Current externally-observable coordinator state. Exposed so
    /// integration tests can assert the `.permissionRequired` transition
    /// without reaching into the underlying actor.
    public private(set) var state: CaptureRenderCoordinatorState = .idle

    /// Last applied resolution / scale factor, retained so the
    /// reconfigure path can detect actual changes vs no-op redeliveries
    /// of the same ReSwift fragment.
    private var lastResolution: CGSize = .zero
    private var lastScaleFactor: CGFloat = 1
    private var displayID: CGDirectDisplayID?

    /// Build the coordinator. The `MTLDevice` is acquired here so the
    /// host view, the texture cache, and the blit pipeline all share one.
    /// Pass a custom `permissionProbe` in tests.
    public init(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        permissionProbe: any ScreenCapturePermissionProbe = SystemScreenCapturePermissionProbe()
    ) {
        let resolvedDevice = device ?? MTLCreateSystemDefaultDevice()
            ?? MTLCopyAllDevices().first!
        self.permissionProbe = permissionProbe
        streamCoordinator = StreamCoordinator()
        hostView = MetalLayerHostView(device: resolvedDevice)
        textureCache = IOSurfaceTextureCache(device: resolvedDevice)
        deviceLossRecovery = DeviceLossRecovery()
        streamOutput = StreamOutput()
        do {
            blitPipeline = try BlitPipeline(device: resolvedDevice)
        } catch {
            blitPipeline = nil
            // Logger does not take an Error directly; format manually.
            log.error("BlitPipeline init failed: \(String(describing: error))")
        }
        pacer = DisplayLinkPacer(present: { [streamOutput] in
            _ = streamOutput.latestSurface
        })
        registerForScreenParameterChanges()
    }

    /// Bind the coordinator to the virtual display the controller created.
    /// Called once from `ScreenViewController.viewDidLoad` after the
    /// `CGVirtualDisplay` is built.
    public func bindDisplay(_ displayID: CGDirectDisplayID) {
        self.displayID = displayID
        log.info("coordinator bound to displayID=\(displayID)")
    }

    /// Apply a new captured-resolution / scale-factor pair. Mirrors the
    /// old `ScreenViewController.update(with:)` branch but routes through
    /// the stream coordinator's `updateConfiguration` API rather than
    /// rebuilding the capture (FR-6, AC-9). No-ops when the pair has not
    /// changed since the last apply.
    public func applyConfiguration(resolution: CGSize, scaleFactor: CGFloat) async {
        guard resolution != .zero else { return }
        if resolution == lastResolution, scaleFactor == lastScaleFactor {
            return
        }
        lastResolution = resolution
        lastScaleFactor = scaleFactor
        let width = Int(resolution.width * scaleFactor)
        let height = Int(resolution.height * scaleFactor)
        hostView.setDrawablePixelSize(CGSize(width: width, height: height))
        do {
            try await streamCoordinator.updateConfiguration(width: width, height: height)
        } catch {
            log.error("updateConfiguration failed: \(String(describing: error))")
        }
    }

    /// Walk the permission state machine: if `CGPreflightScreenCaptureAccess`
    /// returns false, transition to `.permissionRequired` and ask the
    /// system to prompt the user. Returns the resulting state so the
    /// integration test can assert against it without reading the
    /// coordinator's mutable property under actor isolation guards.
    @discardableResult
    public func evaluatePermission() -> CaptureRenderCoordinatorState {
        if permissionProbe.preflight() {
            return state
        }
        state = .permissionRequired
        log.notice("screen recording permission missing; requesting access")
        permissionProbe.request()
        return state
    }

    /// Test-only hook so the integration tests can drive the
    /// permission-revocation path after a simulated restart exhaustion.
    public func _setStateForTest(_ newState: CaptureRenderCoordinatorState) {
        state = newState
    }

    /// Recover from device loss by acquiring a fresh `MTLDevice` and
    /// propagating it to the host view, the texture cache, and the blit
    /// pipeline. Hooked up so an external command-buffer completion
    /// handler can call into this method when it observes a device-loss
    /// error code on a completed buffer.
    public func handleDeviceLoss(error: NSError?) -> DeviceLossOutcome {
        return deviceLossRecovery.handle(error: error) { [weak self] newDevice in
            guard let self else { return }
            self.hostView.replaceDevice(newDevice)
            self.textureCache.replaceDevice(newDevice)
            try self.blitPipeline?.replaceDevice(newDevice)
        }
    }

    // MARK: - Private

    /// Subscribe to `NSApplication.didChangeScreenParametersNotification`
    /// so the coordinator can react to display reconfiguration without a
    /// ReSwift round-trip (FR-6). The existing ReSwift dispatch in
    /// `ScreenConfigurationSideEffect` continues to function in parallel.
    private func registerForScreenParameterChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Trigger a permission re-check whenever the screen layout
            // changes; cheap and catches mid-session revocation.
            _ = self.evaluatePermission()
        }
    }
}
