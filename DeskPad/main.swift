import AppKit

// CR-0003 Phase 3: route `--self-test` argv through the headless dispatcher
// before NSApplicationMain. Outside self-test mode this is a no-op
// (NFR-3: zero overhead on the production launch path).
SelfTestLaunchDispatch.dispatchIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
