import Foundation
@preconcurrency import ReSwift

typealias SideEffect = (Action, @escaping DispatchFunction, @escaping () -> AppState?) -> Void

private nonisolated(unsafe) let sideEffects: [SideEffect] = [
    mouseLocationSideEffect(),
    screenConfigurationSideEffect(),
]

nonisolated(unsafe) let sideEffectsMiddleware: Middleware<AppState> = { dispatch, getState in
    { originalDispatch in
        { action in
            originalDispatch(action)
            for sideEffect in sideEffects {
                sideEffect(action, dispatch, getState)
            }
        }
    }
}
