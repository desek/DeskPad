//
//  selftest.launch_dispatch.swift
//  DeskPad
//
//  @agents-index CR-0003 Phase 3 self-test launch dispatcher. Parses
//  `--self-test` and `--self-test-frames=N` from `CommandLine.arguments` (FR-8)
//  and decides whether the process should route through the headless self-test
//  entry point instead of constructing `NSApplicationMain`. When the flag is
//  absent this file is a no-op so production launches are entirely
//  unaffected (NFR-3: zero overhead outside `--self-test`).
//
//  Phase 3 wires the dispatcher plumbing and the Layer 2 read-back primitives
//  but does NOT yet run the loopback (Phase 4 adds the pattern window plus
//  capture handshake). The Phase 3 dispatch path therefore exits early with a
//  stable `FAIL: not_implemented` line so the contract is observable end-to-
//  end before Phase 4 lands, and the exit-code branch in
//  `selftest-deskpad.sh` is exercisable.
//

import Foundation

/// Parsed self-test configuration. Held as a value type so call sites can
/// pass it across phase boundaries without aliasing.
public struct SelfTestConfig: Equatable, Sendable {
    /// Configured frame count (FR-9 default 60, overridable by
    /// `--self-test-frames=N`).
    public let frames: Int

    /// FR-9 default: 60 frames before reading back. Declared here so a
    /// single source-of-truth governs both production and the tests.
    public static let kDefaultFrames: Int = 60

    public init(frames: Int = SelfTestConfig.kDefaultFrames) {
        self.frames = frames
    }
}

/// Result of inspecting the argv stream. Either the launch continues
/// normally, or the dispatcher takes over and the caller MUST NOT proceed to
/// build the AppKit application instance.
public enum SelfTestDispatchOutcome: Equatable {
    case continueNormalLaunch
    case selfTest(SelfTestConfig)
}

/// Static dispatcher surface; no instance state.
public enum SelfTestLaunchDispatch {
    /// Argv flag that triggers the self-test launch mode (FR-8).
    public static let kSelfTestFlag = "--self-test"
    /// Argv flag prefix that overrides the frame count (FR-9).
    public static let kFramesPrefix = "--self-test-frames="

    /// Pure argv parser. Tests drive this with an explicit `arguments`
    /// array; the live entry point passes `CommandLine.arguments`. An
    /// unparseable or non-positive `--self-test-frames=` value falls back
    /// to the default so a malformed argv never silently runs forever.
    public static func parse(arguments: [String]) -> SelfTestDispatchOutcome {
        guard arguments.contains(kSelfTestFlag) else {
            return .continueNormalLaunch
        }
        var frames = SelfTestConfig.kDefaultFrames
        for arg in arguments where arg.hasPrefix(kFramesPrefix) {
            let value = String(arg.dropFirst(kFramesPrefix.count))
            if let parsed = Int(value), parsed > 0 {
                frames = parsed
            }
        }
        return .selfTest(SelfTestConfig(frames: frames))
    }

    /// Live entry point invoked from `main.swift` before `NSApplicationMain`.
    /// Returns normally when the launch should continue; never returns when
    /// the self-test mode is engaged (terminates via the verdict writer).
    public static func dispatchIfRequested(arguments: [String] = CommandLine.arguments) {
        switch parse(arguments: arguments) {
        case .continueNormalLaunch:
            return
        case .selfTest:
            // Phase 3 stub: the Layer 2 read-back math and verdict writer
            // are wired and unit-tested, but the loopback that produces a
            // presented texture to read back lands in Phase 4. Emit a
            // stable FAIL string so the contract is observable now.
            SelfTestVerdictWriter.emitFail(reason: "not_implemented")
        }
    }
}
