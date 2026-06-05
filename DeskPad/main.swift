import AppKit
import Foundation

// CR-0002 Phase 3 (FR-19, AC-21): when `--self-test` is present, log
// that the Metal backend is force-selected for the duration of the
// self-test run regardless of the persisted `DeskPad.presentationBackend`
// preference or the `-DeskPadPresentationBackend` launch argument. The
// self-test path itself uses an offscreen Metal pipeline (CR-0003) and
// never constructs the AVSBDL backend, so the override is observable
// purely through this log line. The persisted UserDefaults value is
// **not** modified.
if CommandLine.arguments.contains(SelfTestLaunchDispatch.kSelfTestFlag) {
    let storedRaw = UserDefaults.standard.string(
        forKey: PresentationBackendKey.userDefaultsKey
    ) ?? "<unset>"
    let log = Logger(category: "selftest")
    log.notice(
        "self-test backend override: forcing backend=metal (persisted=\(storedRaw))"
    )
}

// CR-0003 Phase 3: route `--self-test` argv through the headless dispatcher
// before NSApplicationMain. Outside self-test mode this is a no-op
// (NFR-3: zero overhead on the production launch path).
SelfTestLaunchDispatch.dispatchIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
