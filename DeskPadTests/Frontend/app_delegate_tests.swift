//
//  app_delegate_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 1 coverage for `AppDelegate.swift`. Direct-
//  calls the two overridden handlers so the menu/window construction
//  and the terminate-on-close return value are exercised.
//

import AppKit
import XCTest

@testable import DeskPad

@MainActor
final class AppDelegateTests: XCTestCase {
    func testApplicationShouldTerminateAfterLastWindowClosedReturnsTrue() {
        let delegate = AppDelegate()
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    /// Direct-call `applicationDidFinishLaunching(_:)`. The handler builds
    /// the menu and window and dispatches `AppDelegateAction.didFinishLaunching`
    /// to the global store; we assert the window was created and a main
    /// menu is now installed.
    func testApplicationDidFinishLaunchingBuildsWindowAndMenu() {
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        XCTAssertNotNil(delegate.window)
        XCTAssertNotNil(NSApplication.shared.mainMenu)
    }
}
