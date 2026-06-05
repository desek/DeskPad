//
//  configuration.user_defaults.bootstrap.swift
//  DeskPad
//
//  @agents-index CR-0002 Phase 3: registers `UserDefaults` defaults
//  before any view loads, so the very first read of
//  `DeskPad.presentationBackend` returns `"metal"` rather than `nil`
//  (CR-0002 FR-3, AC-3). Invoked from `AppDelegate` before the main
//  menu is constructed.
//

import Foundation

/// Static entry point so call sites are visibly idempotent. Calling
/// `register()` repeatedly is harmless: `register(defaults:)` only
/// supplies values for keys that are not already present in the
/// argument-domain or persistent stores.
public enum PresentationBackendDefaultsBootstrap {
    /// Register every `UserDefaults` default this CR introduces.
    /// Today that is just `DeskPad.presentationBackend`; future
    /// presentation-stage keys are added here so a single call from
    /// `AppDelegate` keeps the launch path one line.
    public static func register(into defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            PresentationBackendKey.userDefaultsKey:
                PresentationBackendKey.defaultIdentifier.rawValue,
        ])
    }
}
