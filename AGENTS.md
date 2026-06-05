# DeskPad

A virtual monitor for screen sharing on macOS. The app creates a virtual display via the private `CGVirtualDisplay` API (declared in `DeskPad/DeskPad-Bridging-Header.h`, no public docs) and mirrors its contents into an app window through a ScreenCaptureKit + Metal pipeline (see CR-0001).

## Project facts

- macOS app, Swift 6 with `SWIFT_STRICT_CONCURRENCY = complete`, AppKit, deployment target macOS 15.0
- Rendering pipeline: `ScreenCaptureKit` (`SCStream`) captures the virtual display on a dedicated background queue; frames are presented via a `CAMetalLayer` paced by `CAMetalDisplayLink` with a dirty-bit gate and a newest-frame-wins drop policy. No `CGDisplayStream` and no `CVDisplayLink` anywhere. See `docs/cr/CR-0001-gpu-rendering-pipeline.md`.
- State management: ReSwift (SPM dependency), unidirectional flow: Action -> Store -> Reducer -> Subscriber. ReSwift is intentionally out of the frame-delivery hot path; the capture/render subsystem is self-contained.
- Layout: `DeskPad/Backend/` (state, side effects, plus `Capture/` and `Render/` subsystems), `DeskPad/Frontend/` (view controllers, view data, Metal layer host view, capture-render coordinator), `DeskPad/Helpers/`, `DeskPad/Logging/` (structured logger + rotating file sink)
- Tests: `DeskPadTests/` target in `DeskPad.xcodeproj` (created by CR-0001); run with `xcodebuild -scheme DeskPad test`. Mirrors the source namespace (`Logging/`, `Capture/`, `Render/`, `Integration/`, `Performance/`).
- Build: `xcodebuild -scheme DeskPad -configuration Release -derivedDataPath build`
- Screen Recording (TCC) permission is required for the mirror view; permission grants are tied to the code signature, so unsigned builds re-prompt on every launch. Sign at least ad-hoc (`CODE_SIGN_IDENTITY="-"`). Revocation mid-session is detected via `CGPreflightScreenCaptureAccess` and re-prompted via `CGRequestScreenCaptureAccess` without restarting the app.
- Logs: structured `os.Logger` lines tagged `filename:line` are teed to `~/Library/Logs/DeskPad/deskpad.log` with size-based rotation. Tail with `.agents/scripts/tail-deskpad-log.sh`.
- Present-stall watchdog: an always-on main-actor task wired into the capture-render coordinator emits one greppable warning per ten-second stall window with the literal prefix `present stall: ingested=N presented=M elapsed=S` whenever capture is `.running`, ingestion advances, and presentation does not for three seconds. The signature makes the white-window failure class machine-detectable from the on-disk log without human eyes. See CR-0003.
- Rendering self-test: `DeskPad --self-test` (parsed in `main.swift`) routes the binary through a headless diagnostic instead of constructing the main window. Layer 2 reads back the presented drawable, computes per-channel mean and variance, and emits one `PASS: frames=N mean=R,G,B variance=V` or `FAIL: <reason>` line; Layer 3 renders a known RGB-gradient pattern offscreen and asserts sample-point pixel values within tolerance. Exit status is `0` on PASS and non-zero on FAIL. Drive it from the CLI with `.agents/scripts/selftest-deskpad.sh`, which prefers the pinned signing identity in `.env` (`DESKPAD_CODESIGN_IDENTITY`, optionally `DESKPAD_DEVELOPMENT_TEAM`; see `.env.example`) so the TCC grant survives rebuilds, and falls back to ad-hoc `CODE_SIGN_IDENTITY=-` when `.env` is absent. See CR-0003 and `docs/cr/CR-0003-coverage-summary.md` for the per-file coverage table and documented TCC-bound carve-outs.
- Governance: Change Requests live under `docs/cr/`. Author with the `/governance` skill, run with `/run-cr-team`.

## Finding code: @agents-index

Every tracked source file carries a one-line `@agents-index` annotation in its top docstring stating the file's purpose. Reconstruct a whole-repo index on demand:

```sh
grep -rn "@agents-index" .
```

Prefer this over directory listing when looking for where a responsibility lives. When creating a file, add the annotation; when changing a file's purpose, update it.

## Apple API docs: offline search

Apple's macOS framework docs are not on DeepWiki (closed source). Use these instead, in order:

1. **Symbol discovery** (exact names, canonical doc URLs, fully offline):
   ```sh
   .agents/scripts/apple-docs.search.sh <pattern> [max-results]
   # e.g. .agents/scripts/apple-docs.search.sh scstreamconfiguration 25
   ```
   Greps Xcode's offline documentation index (1.65M symbols, LMDB). An empty result means the symbol likely does not exist under that name. Requires `brew install lmdb`.
2. **Semantics, signatures, availability/deprecation** (ground truth for the installed SDK): read the headers under
   `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/`
3. **Full prose articles** (online): append the path printed by the search script to `https://developer.apple.com/`.

For `CGVirtualDisplay` and other private APIs there are no docs anywhere; the bridging header and runtime behavior are the only references.

## Dependency docs

ReSwift and the project itself are indexed on DeepWiki (`ReSwift/ReSwift`, `Stengo/DeskPad`); use the `deepwiki` MCP for dependency questions. Note DeepWiki tracks the latest upstream version, verify against the pinned version in `Package.resolved`.
