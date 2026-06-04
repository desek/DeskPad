//
//  ScreenConfigurationSideEffect.swift
//  DeskPad
//
//  @agents-index Observes `NSApplication.didChangeScreenParametersNotification`,
//  resolves the matching `NSScreen` for the virtual display, and dispatches a
//  `ScreenConfigurationAction.set` into the ReSwift store. CR-0001 Phase 4
//  additionally publishes a typed `ScreenConfigurationEvent` through
//  `ScreenConfigurationEvents.shared` so the new
//  `CaptureRenderCoordinator` can react without round-tripping through the
//  global store on the hot path.
//

import Foundation
@preconcurrency import ReSwift

private nonisolated(unsafe) var isObserving = false

enum ScreenConfigurationAction: Action {
    case set(resolution: CGSize, scaleFactor: CGFloat)
}

/// Typed event published every time the side effect observes a screen
/// parameter change. The legacy ReSwift dispatch path is preserved; the
/// event is a parallel subscription channel the CR-0001 Phase 4
/// coordinator subscribes to (per Phase 4 step 3).
public struct ScreenConfigurationEvent: Sendable, Equatable {
    public let resolution: CGSize
    public let scaleFactor: CGFloat
    public let displayID: CGDirectDisplayID?
}

/// Tiny pub-sub bus for `ScreenConfigurationEvent`. Kept main-actor
/// isolated because the notification fires on the main queue and the
/// subscribers (the screen coordinator) are themselves main-actor.
@MainActor
public final class ScreenConfigurationEvents {
    /// Process-wide instance the side effect publishes through.
    public static let shared = ScreenConfigurationEvents()

    private var subscribers: [(ScreenConfigurationEvent) -> Void] = []

    private init() {}

    /// Append a subscriber. The closure is retained for the lifetime of
    /// the publisher; DeskPad subscribes exactly once at coordinator
    /// construction time so leak risk is bounded.
    public func subscribe(_ handler: @escaping (ScreenConfigurationEvent) -> Void) {
        subscribers.append(handler)
    }

    /// Fan an event out to every subscriber.
    public func publish(_ event: ScreenConfigurationEvent) {
        for subscriber in subscribers {
            subscriber(event)
        }
    }
}

func screenConfigurationSideEffect() -> SideEffect {
    return { _, dispatch, getState in
        if isObserving == false {
            isObserving = true
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: NSApplication.shared,
                queue: .main
            ) { _ in
                let displayID = getState()?.screenConfigurationState.displayID
                guard let screen = NSScreen.screens.first(where: {
                    $0.displayID == displayID
                }) else {
                    return
                }
                let resolution = screen.frame.size
                let scaleFactor = screen.backingScaleFactor
                dispatch(ScreenConfigurationAction.set(
                    resolution: resolution,
                    scaleFactor: scaleFactor
                ))
                let event = ScreenConfigurationEvent(
                    resolution: resolution,
                    scaleFactor: scaleFactor,
                    displayID: displayID
                )
                MainActor.assumeIsolated {
                    ScreenConfigurationEvents.shared.publish(event)
                }
            }
        }
    }
}
