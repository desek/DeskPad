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
