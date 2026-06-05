//
//  menu_presentation_backend_submenu_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 3 / AC-4 / AC-7: clicking the AVSBDL
//  menu item updates `UserDefaults` and posts the typed switch event
//  with `{backend: "avsbdl", trigger: "menu"}`.
//

import AppKit
import Foundation
import XCTest

@testable import DeskPad

@MainActor
final class MenuPresentationBackendSubmenuTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "DeskPadTests.menu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testMenuItemPostsSwitchEvent() {
        let defaults = freshDefaults()
        defaults.set("metal", forKey: PresentationBackendKey.userDefaultsKey)
        let center = NotificationCenter()
        let submenu = PresentationBackendSubmenu(
            defaults: defaults, notificationCenter: center
        )

        var observed: [Notification] = []
        let token = center.addObserver(
            forName: .deskPadPresentationBackendSwitch, object: nil, queue: nil
        ) { note in observed.append(note) }
        defer { center.removeObserver(token) }

        submenu._selectForTest(.avsbdl)

        XCTAssertEqual(
            defaults.string(forKey: PresentationBackendKey.userDefaultsKey), "avsbdl"
        )
        XCTAssertEqual(observed.count, 1)
        let payload = observed.first?.userInfo
        XCTAssertEqual(payload?[PresentationBackendSwitchUserInfoKey.backend] as? String, "avsbdl")
        XCTAssertEqual(payload?[PresentationBackendSwitchUserInfoKey.trigger] as? String, "menu")
    }
}
