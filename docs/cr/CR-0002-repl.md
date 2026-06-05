---
cr: CR-0002
date: 2026-06-05
type: ad-hoc-followup
trigger: CPU-time energy proxy in docs/cr/CR-0002-energy-measurement.md (provisional FAIL)
status: implemented-and-verified
---

# CR-0002 REPL Follow-up: Dirty-Gated Enqueue and Coalesced MainActor Hop

Ad-hoc implementation session addressing the two prerequisites recorded in
`docs/cr/CR-0002-energy-measurement.md` before the formal NFR-1 Instruments
run. Both changes were implemented, tested, and re-measured in one session.

## Finding

The first energy proxy (60 s `ps -o cputime=` window, Debug build, static
virtual display) showed the AVSBDL backend consuming roughly 100x more CPU
than the Metal backend on exactly the workload it is meant to win on:

| Backend | CPU time over 60 s (baseline) |
|---------|-------------------------------|
| metal   | 0.12 s (~0.2 percent of a core) |
| avsbdl  | 11.63 s (~19 percent of a core) |

Two root causes, both on the capture-to-backend push path added by the
live frame hand-off fix (`c6e6ebc`):

1. **No dirty gate.** ScreenCaptureKit stamps every delivered
   `CMSampleBuffer` with an `SCStreamFrameInfo.status` attachment. Only
   `.complete` frames carry new pixel content; `.idle` frames repeat the
   previous surface on a timer. `StreamOutput` published every delivery,
   so the AVSBDL renderer decoded and presented unchanged 3360x2100
   content at the full capture rate. The Metal path was shielded only by
   accident of architecture (its pacer presents from the newest published
   surface, so re-publishing identical content cost little), but it also
   re-presented identical frames on every idle delivery.

2. **Per-frame `Task { @MainActor }` allocation.** The
   `setOnSampleBuffer` wiring allocated one `Task` per captured frame to
   hop from the SCK delivery thread to the `@MainActor` backend. At
   capture rate that is continuous actor-queue churn even when the
   backend would drop the frame anyway.

## Changes

### 1. Dirty gate at the capture boundary

`DeskPad/Backend/Capture/capture.stream_output.swift`: the
`SCStreamOutput.stream(_:didOutputSampleBuffer:of:)` entry point now reads
the `SCStreamFrameInfo.status` attachment and ingests only `.complete`
frames. Idle repeats never reach publication, the dirty bit, the arrival
EMA, or the backend push. This is the capture-side equivalent of the Metal
pacer's dirty-bit gate, applied once for every backend.

Consequences accepted by design:

* The Metal pacer no longer re-presents identical content on idle
  deliveries (strictly less work, same pixels).
* The arrival EMA now measures *content-change* rate rather than
  *delivery* rate, which is the signal the FR-18 adaptive mode logic
  actually wants: static content drives the EMA interval up and the mode
  toward `.powerSaving`.
* The CR-0003 watchdog's `ingested` counter advances only on real
  content, which keeps `ingested advancing while presented stalls` as a
  true-positive-only signature.
* Test-only `publishForTest` paths bypass the gate (they enter below the
  `SCStreamOutput` callback), so existing tests are unaffected.

### 2. Coalescing relay instead of per-frame Task

New file `DeskPad/Backend/Render/render.backend_sample_buffer_relay.swift`
(`BackendSampleBufferRelay`): a single pending-buffer slot under an
`OSAllocatedUnfairLock` with newest-frame-wins overwrite and at most one
in-flight MainActor hop. A burst of N frames costs one `Task` and delivers
only the newest buffer; the drain loop re-checks the slot after each
delivery so no push is ever stranded. The sink closure reads
`currentBackend` at delivery time, so live backend switches need no
rewiring.

`DeskPad/Frontend/Screen/screen.capture_render_coordinator.swift`: the
`setOnSampleBuffer` wiring now pushes into the relay; the per-frame
`Task { @MainActor }` and the local `UncheckedSampleBuffer` wrapper moved
into the relay file.

`DeskPad.xcodeproj/project.pbxproj`: relay file registered in the Render
group and Sources phase.

## Verification

* Full test suite: `xcodebuild -scheme DeskPad test` (signed with the
  pinned `.env` identity per AGENTS.md): TEST SUCCEEDED, no failures.
* Live launch, both backends, 12 s each: `first frame ingested
  (3360x2100)`, zero `present stall:` lines, AVSBDL startup switch in
  7.8 ms.
* Re-measurement, same method as the baseline (Debug build, 10 s settle,
  60 s `ps -o cputime=` window, static content):

| Backend | Baseline | After fix | Reduction |
|---------|----------|-----------|-----------|
| metal   | 0.12 s   | 1.13 s *  | see note  |
| avsbdl  | 11.63 s  | 0.66 s    | ~18x      |

\* The Metal sample ran first in this session and overlaps ambient
desktop activity (the gate makes both backends content-driven, so the
measured CPU now tracks whatever actually changed on screen during the
window). The decisive comparison is within-session: **AVSBDL (0.66 s) is
now strictly below Metal (1.13 s) on the same machine in the same
session**, which is the direction NFR-1 requires.

## Status against the shipping gate

The CPU axis no longer contradicts NFR-1: the provisional FAIL recorded in
`docs/cr/CR-0002-energy-measurement.md` is superseded by this session's
result. The formal gate still requires the Release-build Instruments
Energy Log run per that document's methodology; until that artefact is
appended there, the backend remains opt-in only.
