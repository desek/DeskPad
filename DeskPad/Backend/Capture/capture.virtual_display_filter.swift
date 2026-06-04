//
//  capture.virtual_display_filter.swift
//  DeskPad
//
//  @agents-index Factory that builds an `SCContentFilter` targeting a specific
//  `CGDirectDisplayID` (the virtual display DeskPad creates via the private
//  `CGVirtualDisplay` API), by resolving the matching `SCDisplay` from
//  `SCShareableContent` and wrapping it in a display-scoped filter that
//  excludes all windows.
//
//  Lives in `Backend/Capture/` so the SCK-specific knowledge is contained to
//  one place. The factory is the only Capture surface that has to know how
//  DeskPad's virtual display maps onto ScreenCaptureKit's content model;
//  downstream (stream configuration, stream output, stream coordinator) only
//  see an opaque `SCContentFilter`.
//

import Foundation
import ScreenCaptureKit

/// Errors raised when the SCK filter factory cannot resolve a content filter
/// for a given `CGDirectDisplayID`. The cases are exposed so callers can
/// distinguish "permission missing" (the only recoverable case) from
/// "display vanished" (treated as a permanent error and reported to the user).
public enum VirtualDisplayFilterError: Error, Sendable {
    /// `SCShareableContent.current` enumerated successfully but no `SCDisplay`
    /// matched the requested `CGDirectDisplayID`. Almost always means the
    /// virtual display was torn down between creation and capture start.
    case displayNotFound(CGDirectDisplayID)
    /// `SCShareableContent.current` itself failed. The underlying error is
    /// surfaced verbatim so the coordinator can log the SCK reason code.
    case shareableContentLookupFailed(any Error)
}

/// Stateless factory that resolves a `CGDirectDisplayID` to an
/// `SCContentFilter` capturing that display only, with no window inclusions or
/// exclusions. Stateless and `Sendable` so it crosses actor boundaries freely.
public struct VirtualDisplayFilterFactory: Sendable {
    public init() {}

    /// Build an `SCContentFilter` for the given display.
    ///
    /// Implementation: enumerate `SCShareableContent.current.displays`, find
    /// the one whose `displayID` matches, and wrap it with
    /// `SCContentFilter(display:excludingWindows:)` passing an empty exclusion
    /// list (DeskPad mirrors the entire virtual display).
    ///
    /// - Parameter displayID: The `CGDirectDisplayID` of the virtual display
    ///   to capture, as published by `CGVirtualDisplay.displayID`.
    /// - Returns: A fresh `SCContentFilter` scoped to that display.
    /// - Throws: `VirtualDisplayFilterError` when shareable content cannot be
    ///   retrieved or the requested display is no longer present.
    public func makeFilter(for displayID: CGDirectDisplayID) async throws -> SCContentFilter {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw VirtualDisplayFilterError.shareableContentLookupFailed(error)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw VirtualDisplayFilterError.displayNotFound(displayID)
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }
}
