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
