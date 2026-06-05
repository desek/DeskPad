//
//  selftest.verdict_writer.swift
//  DeskPad
//
//  @agents-index CR-0003 Phase 3 verdict writer. Emits exactly one
//  `PASS: frames=N mean=R,G,B variance=V` or `FAIL: <reason>` line to stdout
//  (FR-9 / FR-10) and terminates the process with status 0 on PASS or a
//  non-zero status on FAIL (FR-11). Centralizes the literal stdout format so a
//  single source-of-truth governs the contract that
//  `.agents/scripts/selftest-deskpad.sh` parses against.
//
//  The writer is intentionally side-effectful (`print` + `exit`); the pure
//  read-back math lives in `selftest.readback.swift` so unit tests can drive
//  the verdict logic without process exit.
//

import Foundation

/// Surface for emitting the self-test verdict line and terminating. Static
/// methods only; there is no per-process state worth carrying around.
public enum SelfTestVerdictWriter {
    /// Default process exit code used for any FAIL outcome. FR-11 permits
    /// distinct non-zero codes per distinct reason; for now we use `1` as a
    /// single failure code and reserve the right to specialize later
    /// without changing the script contract.
    public static let kFailExitCode: Int32 = 1

    /// Emit a PASS line and `exit(0)`. `frames` is the configured count and
    /// `stats` is the per-channel reduction. The variance reported is the
    /// average of the three channel variances so a single scalar `V` lands
    /// in the verdict line per FR-9.
    public static func emitPass(frames: Int, stats: SelfTestPixelStats) -> Never {
        let mean = SelfTestReadback.format3(stats.meanR, stats.meanG, stats.meanB)
        let avgVar = (stats.varianceR + stats.varianceG + stats.varianceB) / 3.0
        let line = String(format: "PASS: frames=%d mean=%@ variance=%.6f",
                          frames, mean as CVarArg, avgVar)
        print(line)
        // Flush stdout before exiting; without this the verdict can be lost
        // when a caller redirects to a pipe that closes on process exit.
        fflush(stdout)
        exit(0)
    }

    /// Emit a FAIL line and `exit(kFailExitCode)`. `reason` is the stable
    /// machine-parseable string the read-back evaluator produced. No further
    /// formatting is applied so callers control the exact suffix.
    public static func emitFail(reason: String) -> Never {
        emitFail(reason: reason, code: kFailExitCode)
    }

    /// Emit a FAIL line and `exit(code)`. The explicit-code overload is
    /// reserved for future use when distinct non-zero codes carry meaning.
    public static func emitFail(reason: String, code: Int32) -> Never {
        let line = "FAIL: \(reason)"
        print(line)
        fflush(stdout)
        exit(code)
    }
}
