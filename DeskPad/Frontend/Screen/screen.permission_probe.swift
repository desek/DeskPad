//
//  screen.permission_probe.swift
//  DeskPad
//
//  @agents-index Extracted permission-probe seam used by the
//  CR-0001 Phase 4 coordinator. Previously lived inline in
//  `screen.capture_render_coordinator.swift`; split out to keep that
//  file under the NFR-4 / AC-17 200-LOC cap and to give the permission
//  watcher (FR-8 2 Hz poll, see `screen.permission_watcher.swift`) a
//  dedicated, small unit to depend on.
//

import CoreGraphics
import Foundation

/// Seam for the system-level permission APIs so tests can drive
/// `permissionRequired` transitions deterministically. The production
/// implementation forwards to `CGPreflightScreenCaptureAccess` /
/// `CGRequestScreenCaptureAccess`; tests inject a stub.
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
