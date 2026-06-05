<h3 align="center">
  <a href="https://github.com/Stengo/DeskPad/blob/main/DeskPad/Assets.xcassets/AppIcon.appiconset/Icon-256.png">
  <img src="https://github.com/Stengo/DeskPad/blob/main/DeskPad/Assets.xcassets/AppIcon.appiconset/Icon-256.png?raw=true" alt="DeskPad Icon" width="128">
  </a>
</h3>

# DeskPad
A virtual monitor for screen sharing

<h3 align="center">
  <a href="https://github.com/Stengo/DeskPad/blob/main/screenshot.jpg">
  <img src="https://github.com/Stengo/DeskPad/blob/main/screenshot.jpg?raw=true" alt="DeskPad Screenshot">
  </a>
</h3>

Certain workflows require sharing the entire screen (usually due to switching through multiple applications), but if the presenter has a much larger display than the audience it can be hard to see what is happening.

DeskPad creates a virtual display that is mirrored within its application window so that you can create a dedicated, easily shareable workspace.

# Requirements
macOS 15.0 or later on an Apple Silicon or Intel Mac with Metal 3 support. DeskPad's capture pipeline is built on ScreenCaptureKit and a Metal-backed `CAMetalLayer` paced by `CAMetalDisplayLink`; earlier macOS versions are not supported. Users on macOS 13 or 14 should stay on the last DeskPad release that targeted their OS version.

# Installation
You can either download the [latest release binary](https://github.com/Stengo/DeskPad/releases) or install via [Homebrew](https://brew.sh) by calling `brew install --cask deskpad`.

# Usage
DeskPad behaves like any other display. Launching the app is equivalent to plugging in a monitor, so macOS will take care of properly arranging your windows to their previous configuration.

You can change the display resolution through the system preferences and the application window will adjust accordingly.

Whenever you move your mouse cursor to the virtual display, DeskPad will highlight its title bar in blue and move the application window to the front to let you know where you are.

<h3 align="center">
  <a href="https://github.com/Stengo/DeskPad/blob/main/demonstration.gif">
  <img src="https://github.com/Stengo/DeskPad/blob/main/demonstration.gif?raw=true" alt="DeskPad Demonstration">
  </a>
</h3>

# Troubleshooting

## Screen recording permission (macOS 15+)

DeskPad now captures the virtual display through ScreenCaptureKit, so screen
recording permission is required for the mirrored window to show frames. On
first launch the system will present the standard TCC prompt. If you dismiss
it, or revoke permission later, the mirrored window goes blank until you
re-grant access.

1. **Open System Settings** → **Privacy & Security** → **Screen Recording**
2. **Enable DeskPad** by checking the box next to it
3. **Restart DeskPad** so the new permission takes effect

If permission was revoked while DeskPad was running, DeskPad will detect this
via `CGPreflightScreenCaptureAccess` and trigger a fresh TCC prompt through
`CGRequestScreenCaptureAccess`. Accept the prompt and the mirror resumes
without restarting the app. If the prompt does not appear, follow the steps
above and restart DeskPad.

## Log files

DeskPad writes structured logs to `~/Library/Logs/DeskPad/deskpad.log` (every
line is tagged `filename:line`). Inspect this file when reporting issues; it
records capture and render state transitions, permission events, and any
device-loss recovery.

If the mirrored window goes blank but the app keeps running, search the log
for the literal prefix `present stall:`. An always-on watchdog emits a
warning line of the form `present stall: ingested=N presented=M elapsed=S`
whenever frames are arriving from ScreenCaptureKit but the presenter has
stopped advancing for three seconds, which fingerprints the white-window
failure class. See CR-0003.

## Rendering self-test (developers)

DeskPad ships an autonomous rendering self-test so the white-window failure
class is machine-detectable without launching the app and watching the
window. Build and run it from the repository root:

```sh
.agents/scripts/selftest-deskpad.sh
```

The script builds DeskPad in Debug, launches the binary with `--self-test`,
parses the verdict from stdout (falling back to the on-disk log), prints the
verdict line, and exits with the same status as the self-test process. A
`PASS` line looks like `PASS: frames=60 mean=R,G,B variance=V`; a `FAIL` line
carries a stable reason suffix (for example `uniform_white`, `low_variance`,
or `present_mismatch_at_point=(X,Y) expected=(R,G,B) actual=(R,G,B)`). Exit
code 0 indicates PASS; non-zero indicates FAIL.

Screen Recording (TCC) permission is bound to the code signature, so an
ad-hoc rebuild re-prompts on every run. To keep the grant stable across
rebuilds, copy `.env.example` to `.env` and fill in your machine-local
signing identity (`DESKPAD_CODESIGN_IDENTITY`, optionally
`DESKPAD_DEVELOPMENT_TEAM`); the script prefers the pinned identity when
`.env` is present and falls back to ad-hoc signing otherwise. `.env` is
git-ignored and must not be committed.

See `docs/cr/CR-0003-test-hardening-and-rendering-self-test.md` for the
full design and `docs/cr/CR-0003-coverage-summary.md` for the per-file
test coverage table and documented TCC-bound carve-outs.

# Presentation backends

DeskPad ships two presentation backends behind a single capture pipeline.
The default is the Metal backend from CR-0001; an opt-in
`AVSampleBufferDisplayLayer` (AVSBDL) backend is available from CR-0002
for the screen-sharing and static-content use case where the system video
pipeline's energy efficiency outweighs interactive latency.

## How to switch backends

There are three ways to select a backend, in increasing precedence:

1. **Menu** (runtime, persists): the main menu bar contains a
   top-level **Presentation Backend** menu (installed as a sibling of
   the application menu, with no parent menu) with **Metal (low
   latency)** and **AVSampleBufferDisplayLayer (energy efficient)**.
   Selecting an item tears down the active backend, swaps the host
   view, brings up the new backend, and keeps the `SCStream` capture
   session running with no permission re-prompt. The choice is written
   to `UserDefaults`.
2. **UserDefaults key** (persisted): the `DeskPad.presentationBackend`
   user default takes the string values `metal` or `avsbdl`. Set it
   from the shell with
   `defaults write com.stengo.DeskPad "DeskPad.presentationBackend" avsbdl`.
   Invalid values log a warning and fall back to `metal`. The next
   launch reads this value during `CaptureRenderCoordinator.init` and
   activates the selected backend at startup.
3. **Launch argument** (per-launch, does not persist): pass
   `-DeskPadPresentationBackend avsbdl` (or `metal`) on the command
   line. The launch argument overrides the persisted user default for
   the current launch only.

The rendering self-test (`--self-test`) always runs on the Metal backend
regardless of preference; the AVSBDL backend cannot satisfy the
read-back-and-assert path that Layer 2 and Layer 3 rely on.

## Metal versus AVSBDL trade-offs

| Aspect                         | Metal (default)                          | AVSBDL (opt-in)                                  |
|--------------------------------|------------------------------------------|--------------------------------------------------|
| Latency                        | Lowest, paced by `CAMetalDisplayLink`    | Higher, paced by the system video pipeline       |
| Energy / power efficiency      | Higher CPU+GPU cost on static workloads  | Lower energy on static and screen-sharing loads  |
| Adaptive low-latency mode      | Applies (CR-0001)                        | Not applicable, disabled while AVSBDL is active  |
| Rendering self-test support    | Yes (read-back, gradient assertions)     | No, self-test forces Metal                       |
| Best fit                       | Interactive, animated, low-latency work  | Screen-sharing, document mirroring, idle content |

When the AVSBDL backend is active, requests from the adaptive mode
controller to engage low-latency mode are no-ops and are logged once.
The CR-0003 present-stall watchdog continues to work backend-agnostically
because both backends expose a monotonic `presentedFrameCount`.

See `docs/cr/CR-0002-avsamplebufferdisplaylayer-backend.md` for the full
design.
