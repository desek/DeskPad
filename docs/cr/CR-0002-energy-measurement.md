---
cr: CR-0002
report-date: 2026-06-05
status: deferred-with-carve-out
precedent: CR-0003 coverage summary documented TCC-bound carve-outs
---

# CR-0002 Energy and Latency Measurement (deferred carve-out)

This document satisfies the bookkeeping half of NFR-1 / NFR-2 / AC-16 / AC-17:
the CR's Test Strategy table specifies two Instruments-backed performance
tests (`DeskPadTests/Performance/avsbdl_energy_tests.swift` and
`DeskPadTests/Performance/live_switch_latency_tests.swift`). Both files are
present in the diff as **scaffolding only** because the underlying
measurements are Instruments-backed manual benchmarks that cannot be
captured headlessly inside `xcodebuild test` without skewing the very
energy / latency numbers under measurement.

## Carve-out (precedent)

CR-0003's `docs/cr/CR-0003-coverage-summary.md` established the documented-
carve-out pattern for TCC-bound work that cannot ship as a green CI signal
without running outside the headless test harness. CR-0002 extends the same
pattern to Instruments-bound work:

- The scaffolding files exist so the Test Strategy rows are not orphans.
  Each declares the workload, the methodology, and the harness command that
  will produce the artefact.
- The actual measurements are run out-of-band on Apple Silicon hardware
  with a real virtual display and a real 4K window, then summarised by
  appending to this document. Until the appended summary is present, the
  AVSBDL backend ships with a runtime banner (the existing FR-14 once-per-
  backend log line) but is gated by a runtime opt-in (`UserDefaults` /
  launch argument) rather than the default.

## Methodology (NFR-1 / AC-16, energy)

1. Build the Release binary, signed against the pinned identity in `.env`.
2. Launch DeskPad with `-DeskPadPresentationBackend metal`. Pin the
   captured virtual display to 4K at the panel's native scale. Open a
   static document (Preview / a single screenshot) and let the pipeline
   settle for 30 seconds.
3. Open Instruments -> "Energy Log" template. Record 5 minutes wall-clock.
4. Quit DeskPad. Relaunch with `-DeskPadPresentationBackend avsbdl` and
   repeat the recording on an identical workload.
5. Report `Energy Impact (avg)`, `CPU Time`, and `GPU Time` per
   recording. The AVSBDL recording **MUST** be strictly less than the
   Metal recording on at least one of the three metrics for the backend
   to ship as a user-facing option per the CR's NFR-1 contract.
6. Append the verdict (PASS / FAIL with numbers) to the "Results" section
   below.

## Methodology (NFR-2 / AC-16, frame rate)

Same launch arguments as NFR-1. Use the in-app structured log line
`backend=avsbdl presentedFrameCount=...` over a 60-second window of
animated content (a video playing inside the captured virtual display).
Assert AVSBDL's `presentedFrameCount` advances at a rate not less than
95 percent of Metal's over the same workload. Append to "Results".

## Methodology (AC-17, swap latency at 4K)

1. Launch DeskPad with the captured display at 4K. Wait for the first
   frame.
2. Use the CLI script `osascript -e 'tell ...'` (or the future
   `.agents/scripts/measure-backend-swap.sh`) to drive the menu click
   ten times alternating Metal / AVSBDL.
3. Grep the structured log for `backend switch: ... elapsed_ms=...` and
   confirm every sample is below 250 ms.

## Results

### 2026-06-05: CPU-time proxy (pre-Instruments, Debug build)

Not the formal NFR-1 measurement, but an early proxy taken after the live
frame hand-off fix (`c6e6ebc`). Debug build signed with the pinned `.env`
identity; 60 s `ps -o cputime=` window per backend after a 10 s settle, on
an idle/static virtual display.

| Backend | CPU time over 60 s | Approx. share of one core |
|---------|--------------------|---------------------------|
| metal   | 0.12 s             | ~0.2 percent              |
| avsbdl  | 11.63 s            | ~19 percent               |

Verdict: **provisional FAIL** on the CPU axis. The AVSBDL enqueue path
runs at full capture rate with a per-frame `Task { @MainActor }` hop and
renderer enqueue plus decode even on unchanged content, while the Metal
pacer idles behind its dirty-bit gate. Before the formal Release-build
Instruments Energy Log run, the AVSBDL path needs (1) dirty-gating of the
enqueue equivalent to the Metal pacer's gate and (2) removal of the
per-frame main-actor `Task` allocation. Until the formal measurement shows
a strict improvement, the CR's shipping gate keeps the backend opt-in
only. Cross-reference: addendum in `docs/cr/CR-0002-validation-report.md`.
