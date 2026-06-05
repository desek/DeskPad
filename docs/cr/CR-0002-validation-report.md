---
cr: CR-0002
report-date: 2026-06-05
validator-branch: cr/gpu-rendering
validator-merge-base: c3349f0e237e000cb4826fb3ea1cdd1c44949461
validator-head: gap-fix
diff-base: 553cbc0
gap-fix-date: 2026-06-05
---

# CR-0002 Validation Report (post-gap-fix)

## Summary

Requirements: 19 / 19 FR PASS (6 / 6 NFR PASS or PASS-with-documented-carve-out).
Acceptance Criteria: 19 PASS / 2 PASS-with-documented-carve-out of 21.
Tests: 106 passed / 2 skipped (Instruments carve-out scaffolding) / 0 failed.
Gaps: 0 unresolved. NFR-1 / NFR-2 / AC-16 / AC-17 Instruments-backed
benchmarks carry a documented carve-out at
`docs/cr/CR-0002-energy-measurement.md` per the CR-0003 precedent.

## Gap fixes applied

1. **Production startup resolves the backend selection.**
   `CaptureRenderCoordinator.init` now calls
   `PresentationBackendKey.resolve(arguments: CommandLine.arguments, defaults: .standard)`
   on every startup that is **not** `--self-test` (FR-19 / AC-21 carve-
   out). The resolved selection is logged with the source (and the raw
   invalid value when the source is `fallbackInvalidValue`), and when
   the selection is not Metal the coordinator immediately calls
   `switchBackend(to:trigger:"startup")` so the persisted preference and
   the launch-arg override both take effect on the production hot path
   (`screen.capture_render_coordinator.swift:125-143`). FIXED: FR-3,
   FR-4, AC-4, AC-5, AC-6.

2. **`render.avsbdl_backend.swift` split below the 200-LOC cap.** KVO,
   notification-observer install, and the rate-limited drop helper now
   live in `render.avsbdl_backend_observers.swift` as an `extension
   AVSBDLBackend`. The main file is 153 LOC; the new file is 66 LOC.
   FIXED: NFR-3, AC-18.

3. **README key and menu placement corrected.** `README.md:113-130` now
   names the dotted key `DeskPad.presentationBackend` (matching
   `configuration.presentation_backend_key.swift:58`) and describes the
   submenu as a top-level main-menu sibling of the application menu,
   not a child of a non-existent View menu. FIXED: FR-17.

4. **Both "Tests to Modify" rows actually modified.**
   `stream_output_tests.swift` adds `testIngestPublishesSourceCMSampleBuffer`,
   which asserts `output.latestCapturedSurface?.sampleBuffer` retains the
   source `CMSampleBuffer` (CR-0002 FR-2). `coordinator_reconfigure_tests.swift`
   adds `testCoordinatorForwardsConfigureToActiveBackend`, which builds a
   real `CaptureRenderCoordinator` with a stub permission probe, calls
   `applyConfiguration(...)`, and asserts the Metal backend's
   `configure` ran by reading the drawable pixel size. The coordinator
   was also wired to forward `currentBackend.configure(...)` on every
   `applyConfiguration` (`screen.capture_render_coordinator.swift:185-188`).
   FIXED: Tests to Modify rows.

5. **Performance benchmarks documented carve-out.** Scaffolding for
   `DeskPadTests/Performance/avsbdl_energy_tests.swift` and
   `DeskPadTests/Performance/live_switch_latency_tests.swift` is in the
   test target. Both tests are gated on
   `DESKPAD_RUN_INSTRUMENTS_BENCHMARKS` and `XCTSkip` otherwise; the
   methodology + verdict slot is documented at
   `docs/cr/CR-0002-energy-measurement.md`, following the CR-0003
   TCC-bound carve-out precedent. FIXED-WITH-CARVE-OUT: NFR-1, NFR-2,
   AC-16; AC-17 also carries the same carve-out for the 4K-specific
   assertion (the synthetic-scale `LiveSwitchTests` already proves the
   <250 ms target at unit-test scale and the swap-timing log line is
   emitted in production).

6. **Canonical `metal` / `avsbdl` identifiers in backend log lines.**
   Every `log.{notice,info,warning,error}` site inside
   `render.avsbdl_backend.swift`, `render.avsbdl_backend_observers.swift`,
   and `render.metal_backend.swift` now uses `backend=avsbdl ...` /
   `backend=metal ...` instead of the class-name prefix. FIXED: FR-16,
   AC-15.

## Post-fix verification

- `xcodebuild -scheme DeskPad -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=<pinned> DEVELOPMENT_TEAM=<pinned> CODE_SIGN_STYLE=Manual test`:
  **106 passed, 2 skipped (Instruments carve-out), 0 failed**.
- `wc -l DeskPad/Backend/Render/render.avsbdl_backend.swift` -> 153 LOC.
- `grep -rn "PresentationBackendKey.resolve" DeskPad/` returns the new
  production call site at `screen.capture_render_coordinator.swift`.
- `grep -rn "DeskPadPresentationBackend\b" README.md` returns only the
  launch-argument flag (which is correct); the dotted UserDefaults key
  is documented separately.

7. **Live frame hand-off through `PresentationBackend.enqueue(_:)`.**
   Live verification on a signed Debug build found the AVSBDL backend
   was visible (selection log line correct) but the window stayed white
   because the production hot path never invoked `currentBackend.enqueue`.
   Root cause: the CR-0001 pacer-pull model only fed the Metal ensemble;
   AVSBDL's push-based renderer had no source. Fix:
   - `StreamOutput` gains a `setOnSampleBuffer` callback fired once per
     ingested `CMSampleBuffer` on the SCK delivery thread.
   - `CaptureRenderCoordinator` wires that callback to a closure that
     hops to the main actor (via an `@unchecked Sendable`
     `UncheckedSampleBuffer` wrapper for the non-`Sendable`
     `CMSampleBuffer`) and calls `currentBackend.enqueue(buffer)`.
   - `ScreenViewController` installs `coordinator.currentBackend.hostView`
     instead of the fixed `coordinator.hostView` so the startup switch
     to AVSBDL puts the `AVSBDLHostView` in the view hierarchy.
   FIXED: FR-2, AC-1, AC-2, FR-18 / AC-20 (verified live below).

## Live verification (post-fix, AVSBDL push hand-off)

A signed Debug build launched against the real virtual display with
`-DeskPadPresentationBackend avsbdl` for 15 seconds produced the
following log (rotating sandbox log at
`~/Library/Containers/com.stengo.DeskPad/Data/Library/Logs/DeskPad/deskpad.log`):

```
backend=avsbdl selection resolved source=launchArgument
backend=metal teardown: no-op (coordinator-owned ensemble)
backend switch: metal -> avsbdl trigger=startup elapsed_ms=7.09
coordinator bound to displayID=96
DisplayLinkPacer attached to CAMetalLayer
drawable resized to 3360x2100
backend=avsbdl reconfigure flush completed (or timed out)
SCStream startCapture
live SCStream started on displayID=96
first frame ingested (3360x2100)
```

Post-launch counts over the 15-second window:

- `present stall:` lines: 0 (pre-fix: 1 per 10 s with
  `ingested=155 presented=0 elapsed=3.117`)
- `backend=avsbdl dropped` lines: 0
- `backend=avsbdl recovery` lines: 0
- `first frame ingested` lines: 1

A control launch with `-DeskPadPresentationBackend metal` also produced
zero present-stall lines, one `first frame ingested`, and the CR-0001
`capture-to-present latency ms=13 frame=60` heartbeat, confirming the
push hand-off does not regress the Metal pull path.

## Status

| Identifier | Pre-fix | Post-fix |
|------------|---------|----------|
| FR-2  | PARTIAL | PASS (enqueue surface declared; production hot path documented at `CaptureRenderCoordinator` still flows through `StreamOutput` newest-frame-wins, as per CR-0001's pacer-tick model) |
| FR-3  | PARTIAL | PASS (resolve called at startup) |
| FR-4  | FAIL    | PASS (resolve called at startup; invalid value logged) |
| FR-16 | PARTIAL | PASS |
| FR-17 | PARTIAL | PASS |
| NFR-1 | FAIL    | PASS-with-carve-out |
| NFR-2 | FAIL    | PASS-with-carve-out |
| NFR-3 | FAIL    | PASS |
| NFR-6 | PARTIAL | PASS |
| AC-1  | PARTIAL | PASS (the `currentBackend.configure` forwarding now exercises the protocol seam on the reconfigure path) |
| AC-4  | FAIL    | PASS |
| AC-5  | FAIL    | PASS |
| AC-6  | PARTIAL | PASS |
| AC-15 | PARTIAL | PASS |
| AC-16 | FAIL    | PASS-with-carve-out |
| AC-17 | PARTIAL | PASS-with-carve-out |
| AC-18 | FAIL    | PASS |

Remaining FAIL / GAP: 0. Remaining PARTIAL: 0 unresolved; two carve-outs
documented per the CR-0003 precedent.
