//
//  menu.presentation_backend_submenu.swift
//  DeskPad
//
//  @agents-index CR-0002 Phase 3: builds the "Presentation Backend"
//  radio-style submenu and posts the typed switch event the coordinator
//  observes. Selecting an item writes `UserDefaults`
//  (`DeskPad.presentationBackend`) and posts
//  `Notification.Name.deskPadPresentationBackendSwitch` with
//  `{backend: "metal" | "avsbdl", trigger: "menu"}` userInfo
//  (CR-0002 FR-5, AC-4, AC-7). The coordinator picks up the
//  notification and performs the live swap.
//

import AppKit
import Foundation

public extension Notification.Name {
    /// Notification posted when the user (or any other in-process
    /// source) requests a backend switch. The userInfo payload
    /// **MUST** contain `"backend"` mapped to a
    /// `PresentationBackendIdentifier.rawValue` and `"trigger"`
    /// describing the source (e.g. `"menu"`, `"launchArgument"`).
    static let deskPadPresentationBackendSwitch =
        Notification.Name("com.stengo.DeskPad.PresentationBackendSwitch")
}

/// Userinfo keys for `deskPadPresentationBackendSwitch`. Centralised so
/// the notifier and the observer cannot drift.
public enum PresentationBackendSwitchUserInfoKey {
    public static let backend = "backend"
    public static let trigger = "trigger"
}

/// Builds the "Presentation Backend" submenu and routes menu clicks
/// through a target/action sink so the menu item retains a strong
/// reference to its handler. Held by `AppDelegate` for the lifetime of
/// the application.
@MainActor
public final class PresentationBackendSubmenu: NSObject {
    public let menuItem: NSMenuItem
    private let metalItem: NSMenuItem
    private let avsbdlItem: NSMenuItem
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    public init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        let submenu = NSMenu(title: "Presentation Backend")
        metalItem = NSMenuItem(
            title: "Metal (low latency, default)",
            action: #selector(PresentationBackendSubmenu.selectMetal(_:)),
            keyEquivalent: ""
        )
        avsbdlItem = NSMenuItem(
            title: "AVSampleBufferDisplayLayer (power-optimized)",
            action: #selector(PresentationBackendSubmenu.selectAVSBDL(_:)),
            keyEquivalent: ""
        )
        menuItem = NSMenuItem(title: "Presentation Backend", action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        super.init()
        metalItem.target = self
        avsbdlItem.target = self
        submenu.addItem(metalItem)
        submenu.addItem(avsbdlItem)
        refreshCheckmarks()
    }

    /// Update the radio-style check marks from the current persisted
    /// value. Called on construction and after each user click so the
    /// menu reflects the active backend even if the value was changed
    /// out-of-band (e.g. by a launch argument or test).
    public func refreshCheckmarks() {
        let current = defaults.string(forKey: PresentationBackendKey.userDefaultsKey)
        let identifier = current.flatMap(PresentationBackendIdentifier.init(rawValue:))
            ?? PresentationBackendKey.defaultIdentifier
        metalItem.state = (identifier == .metal) ? .on : .off
        avsbdlItem.state = (identifier == .avsbdl) ? .on : .off
    }

    @objc public func selectMetal(_: Any?) {
        applySelection(.metal)
    }

    @objc public func selectAVSBDL(_: Any?) {
        applySelection(.avsbdl)
    }

    /// Test entry point exposing the click pathway without
    /// `performClick(_:)` (which requires the menu to be hosted in a
    /// `NSWindow` or `NSApplication.mainMenu` to fire its action).
    public func _selectForTest(_ identifier: PresentationBackendIdentifier) {
        applySelection(identifier)
    }

    private func applySelection(_ identifier: PresentationBackendIdentifier) {
        defaults.set(identifier.rawValue, forKey: PresentationBackendKey.userDefaultsKey)
        refreshCheckmarks()
        notificationCenter.post(
            name: .deskPadPresentationBackendSwitch,
            object: self,
            userInfo: [
                PresentationBackendSwitchUserInfoKey.backend: identifier.rawValue,
                PresentationBackendSwitchUserInfoKey.trigger: "menu",
            ]
        )
    }
}
