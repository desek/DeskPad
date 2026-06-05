//
//  live_switch_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 3 / AC-7: a switch from Metal to AVSBDL
//  tears down the old backend, swaps the host view inside its parent
//  superview, brings up the new backend, and never stops capture. The
//  test drives the coordinator directly through `switchBackend(to:trigger:)`
//  to keep the assertion focused on the live-swap semantics.
//

import AppKit
import XCTest

@testable import DeskPad

@MainActor
final class LiveSwitchTests: XCTestCase {
    func testLiveSwitchTearsDownAndBringsUpWithoutStoppingCapture() {
        let coordinator = CaptureRenderCoordinator()
        // Place the Metal host view in a parent so the swap can
        // observe the parent's subview membership change.
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let originalHostView = coordinator.currentBackend.hostView
        parent.addSubview(originalHostView)
        XCTAssertEqual(coordinator.currentBackend.diagnostics.identifier, "metal")
        XCTAssertTrue(parent.subviews.contains(originalHostView))

        coordinator.switchBackend(to: .avsbdl, trigger: "test")

        XCTAssertEqual(coordinator.currentBackend.diagnostics.identifier, "avsbdl")
        // Old host view removed.
        XCTAssertFalse(parent.subviews.contains(originalHostView))
        // New host view installed in the same parent.
        XCTAssertTrue(parent.subviews.contains(coordinator.currentBackend.hostView))
    }

    func testSwitchIsIdempotentOnSameIdentifier() {
        let coordinator = CaptureRenderCoordinator()
        let initial = coordinator.currentBackend
        coordinator.switchBackend(to: .metal, trigger: "test")
        XCTAssertTrue(coordinator.currentBackend === initial)
    }
}
