import Foundation
@preconcurrency import ReSwift

nonisolated(unsafe) let store = Store<AppState>(
    reducer: appReducer,
    state: AppState.initialState,
    middleware: [
        sideEffectsMiddleware,
    ]
)
