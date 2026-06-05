import Cocoa
import ReSwift

enum AppDelegateAction: Action {
    case didFinishLaunching
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    /// CR-0002 Phase 3: held for the application's lifetime so menu
    /// items retain their target (`PresentationBackendSubmenu`). Without
    /// this strong reference the radio handlers would be deallocated as
    /// soon as `applicationDidFinishLaunching` returned.
    var presentationBackendSubmenu: PresentationBackendSubmenu?

    func applicationDidFinishLaunching(_: Notification) {
        // CR-0002 Phase 3: register UserDefaults defaults before any
        // view loads so the first read of DeskPad.presentationBackend
        // returns "metal" rather than nil (FR-3, AC-3).
        PresentationBackendDefaultsBootstrap.register()

        let viewController = ScreenViewController()
        window = NSWindow(contentViewController: viewController)
        window.delegate = viewController
        window.title = "DeskPad"
        window.makeKeyAndOrderFront(nil)
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.backgroundColor = .white
        window.contentMinSize = CGSize(width: 400, height: 300)
        window.contentMaxSize = CGSize(width: 5120, height: 2160)
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenNone)

        let mainMenu = NSMenu()
        let mainMenuItem = NSMenuItem()
        let subMenu = NSMenu(title: "MainMenu")
        let quitMenuItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        subMenu.addItem(quitMenuItem)
        mainMenuItem.submenu = subMenu

        // CR-0002 Phase 3: install the Presentation Backend submenu as
        // a second top-level menu item alongside MainMenu (FR-5).
        let backendSubmenu = PresentationBackendSubmenu()
        presentationBackendSubmenu = backendSubmenu

        mainMenu.items = [mainMenuItem, backendSubmenu.menuItem]
        NSApplication.shared.mainMenu = mainMenu

        store.dispatch(AppDelegateAction.didFinishLaunching)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        return true
    }
}
