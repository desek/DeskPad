//
//  configuration.presentation_backend_key.swift
//  DeskPad
//
//  @agents-index CR-0002 Phase 3: declares the `UserDefaults` key, the
//  enum of valid values, and the launch-argument override parser for the
//  presentation backend selection. Centralized in one file so the menu,
//  the bootstrap, the coordinator, and the self-test path all resolve
//  the same string set without duplication (CR-0002 FR-3, FR-4, FR-19).
//

import Foundation

/// Canonical identifiers for the two presentation backends. The raw
/// string values match the `UserDefaults` and log-line vocabulary
/// declared in `PresentationBackendDiagnostics.identifier`.
public enum PresentationBackendIdentifier: String, Sendable, CaseIterable {
    case metal
    case avsbdl
}

/// Source the resolved backend identifier came from. Logged on every
/// resolution so an investigator can tell whether a launch arg, a
/// persisted preference, or the registered default decided the value
/// (CR-0002 FR-16).
public enum PresentationBackendSelectionSource: String, Sendable {
    case launchArgument
    case userDefaults
    case fallbackInvalidValue
    case defaultRegistered
    case selfTestOverride
}

/// One-shot resolution outcome: the chosen identifier plus the source.
public struct PresentationBackendSelection: Sendable, Equatable {
    public let identifier: PresentationBackendIdentifier
    public let source: PresentationBackendSelectionSource
    public let rawInvalidValue: String?

    public init(
        identifier: PresentationBackendIdentifier,
        source: PresentationBackendSelectionSource,
        rawInvalidValue: String? = nil
    ) {
        self.identifier = identifier
        self.source = source
        self.rawInvalidValue = rawInvalidValue
    }
}

/// Static surface holding the constants and the pure resolution
/// function. Tests drive `resolve(arguments:defaults:)` directly with
/// synthesised inputs; production calls it via the bootstrap and the
/// coordinator.
public enum PresentationBackendKey {
    /// `UserDefaults` key. The value is one of
    /// `PresentationBackendIdentifier.rawValue`.
    public static let userDefaultsKey = "DeskPad.presentationBackend"

    /// Launch-argument flag. The value following it (in the next argv
    /// position) selects the backend for the current launch only and
    /// does not write back to `UserDefaults` (CR-0002 FR-4, AC-5).
    public static let launchArgumentFlag = "-DeskPadPresentationBackend"

    /// Resolved identifier when no other source applies.
    public static let defaultIdentifier: PresentationBackendIdentifier = .metal

    /// Pure resolution. Order of precedence per CR-0002 FR-3, FR-4:
    /// launch argument > `UserDefaults` value > registered default
    /// (`metal`). Invalid values in either source fall back to
    /// `metal` and the raw invalid string is surfaced so the caller
    /// can log it (CR-0002 FR-4).
    public static func resolve(
        arguments: [String],
        defaults: UserDefaults
    ) -> PresentationBackendSelection {
        if let argSelection = parseLaunchArgument(arguments: arguments) {
            return argSelection
        }
        if let stored = defaults.string(forKey: userDefaultsKey) {
            if let identifier = PresentationBackendIdentifier(rawValue: stored) {
                return PresentationBackendSelection(
                    identifier: identifier, source: .userDefaults
                )
            }
            return PresentationBackendSelection(
                identifier: defaultIdentifier,
                source: .fallbackInvalidValue,
                rawInvalidValue: stored
            )
        }
        return PresentationBackendSelection(
            identifier: defaultIdentifier, source: .defaultRegistered
        )
    }

    /// Parse the `-DeskPadPresentationBackend <value>` argv pair. An
    /// invalid value falls back to `metal` with the raw value
    /// surfaced; the flag without a following token is treated as
    /// invalid for the same reason.
    private static func parseLaunchArgument(
        arguments: [String]
    ) -> PresentationBackendSelection? {
        guard let flagIndex = arguments.firstIndex(of: launchArgumentFlag) else {
            return nil
        }
        let valueIndex = flagIndex + 1
        guard valueIndex < arguments.count else {
            return PresentationBackendSelection(
                identifier: defaultIdentifier,
                source: .fallbackInvalidValue,
                rawInvalidValue: ""
            )
        }
        let raw = arguments[valueIndex]
        if let identifier = PresentationBackendIdentifier(rawValue: raw) {
            return PresentationBackendSelection(
                identifier: identifier, source: .launchArgument
            )
        }
        return PresentationBackendSelection(
            identifier: defaultIdentifier,
            source: .fallbackInvalidValue,
            rawInvalidValue: raw
        )
    }
}
