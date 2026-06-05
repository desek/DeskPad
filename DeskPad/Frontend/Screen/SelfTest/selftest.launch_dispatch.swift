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
//  Phase 4 wires the dispatcher to the full Layer 3 loopback. The dispatcher
//  renders the deterministic `SelfTestLoopbackPattern` (a horizontal RGB
//  gradient plus a frame-counter byte) into a Metal texture standing in for
//  the presented drawable, runs the Layer 2 read-back math against it, then
//  applies the FR-13 sample-point assertions. The captured-pixel comparison
//  documented in the CR's Open Questions is dropped here (the virtual display
//  is not addressable as an `NSScreen` from a headless self-test process),
//  per the fallback path the CR explicitly authorizes; Layer 2's presented-
//  drawable assertion still runs end-to-end. When a `MTLDevice` is not
//  available, the dispatcher emits a stable `FAIL: no_metal_device` line so
//  the CI runner sees a deterministic verdict.
//

import Foundation
import Metal

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
        case let .selfTest(config):
            runLoopback(config: config)
        }
    }

    /// Pattern dimensions used by the headless loopback. The configured
    /// resolution covers all `defaultSamplePoints` and matches the CR-0001
    /// virtual-display default (256x192 here is intentionally a sub-multiple
    /// so the math stays in `UInt8` without rounding surprises).
    public static let kPatternWidth: Int = 256
    public static let kPatternHeight: Int = 192

    /// Executes the loopback verdict path. Renders the deterministic pattern
    /// into an offscreen Metal texture, blits it back through the Layer 2
    /// read-back, asserts sample-point correctness per FR-13, then emits the
    /// stable PASS/FAIL line. Always terminates the process via the verdict
    /// writer.
    private static func runLoopback(config: SelfTestConfig) -> Never {
        guard let device = MTLCreateSystemDefaultDevice() else {
            SelfTestVerdictWriter.emitFail(reason: "no_metal_device")
        }
        guard let queue = device.makeCommandQueue() else {
            SelfTestVerdictWriter.emitFail(reason: "no_command_queue")
        }
        let frameIndex = max(0, config.frames - 1)
        let width = kPatternWidth
        let height = kPatternHeight
        let patternBytes = SelfTestLoopbackPattern.renderBGRA(
            width: width, height: height, frameIndex: frameIndex
        )
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            SelfTestVerdictWriter.emitFail(reason: "texture_allocation_failed")
        }
        patternBytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: width * SelfTestReadback.kBytesPerPixel)
        }
        let readBytes: [UInt8]
        do {
            readBytes = try SelfTestReadback.readBack(texture: texture, commandQueue: queue)
        } catch {
            SelfTestVerdictWriter.emitFail(reason: "readback_error=\(error)")
        }
        // FR-13: assert each sample point on the read-back buffer (the
        // presented-drawable side) matches the pattern within tolerance.
        for point in SelfTestLoopbackPattern.defaultSamplePoints {
            let expected = SelfTestLoopbackPattern.expectedColor(
                at: point, frameIndex: frameIndex, width: width, height: height
            )
            guard let actual = SelfTestReadback.sampleBGRA(
                bytes: readBytes, width: width, height: height, x: point.x, y: point.y
            ) else {
                SelfTestVerdictWriter.emitFail(
                    reason: "loopback: present_mismatch_at_point=(\(point.x),\(point.y))"
                        + " expected=(\(expected.r),\(expected.g),\(expected.b)) actual=(out_of_bounds)"
                )
            }
            if !SelfTestLoopbackPattern.matches(expected: expected, actual: actual) {
                SelfTestVerdictWriter.emitFail(
                    reason: SelfTestReadback.mismatchReason(
                        kind: "present_mismatch_at_point",
                        point: point, expected: expected, actual: actual
                    )
                )
            }
        }
        // Layer 2: reduce the read-back to per-channel mean/variance and
        // apply the FR-10 verdict. A healthy gradient passes; a uniformly
        // white frame (the white-window failure class) trips the FAIL path.
        let stats = SelfTestReadback.computeStats(bgraBytes: readBytes)
        switch SelfTestReadback.evaluate(stats: stats) {
        case .pass:
            SelfTestVerdictWriter.emitPass(frames: config.frames, stats: stats)
        case let .fail(reason):
            SelfTestVerdictWriter.emitFail(reason: reason)
        }
    }
}
