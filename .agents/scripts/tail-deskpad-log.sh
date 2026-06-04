#!/usr/bin/env bash
# @agents-index Live-tail the DeskPad rotating log file written by the
# in-app LogFileSink. Resolves the sandboxed app container's Logs directory
# first (where a signed sandboxed build actually writes), then falls back to
# the non-sandboxed user Library path. Wraps `tail -F` so file rotation is
# followed across rename boundaries.
#
# Usage:
#   .agents/scripts/tail-deskpad-log.sh           # tail the active log file
#   .agents/scripts/tail-deskpad-log.sh --path    # print the resolved path and exit
#   .agents/scripts/tail-deskpad-log.sh --help    # show this help
#
# Exit codes:
#   0   normal exit (user interrupted tail, or --path/--help requested)
#   1   no log file found at either candidate path
#
# Why this exists:
#   The project's CLI-first rule (see CLAUDE.md) says recurring operations
#   live as scripts under .agents/scripts/. Inspecting the rotating log file
#   is a recurring operation, so it is captured here instead of being
#   retyped per session.

set -euo pipefail

usage() {
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
}

# Resolve the two candidate paths. The sandboxed path is the canonical home
# of the log file when DeskPad runs as a signed sandboxed build; the
# non-sandboxed path is used by ad-hoc local builds and by tests that bypass
# the sandbox.
SANDBOX_PATH="$HOME/Library/Containers/com.stengo.DeskPad/Data/Library/Logs/DeskPad/deskpad.log"
USER_PATH="$HOME/Library/Logs/DeskPad/deskpad.log"

resolve_path() {
    if [ -f "$SANDBOX_PATH" ]; then
        echo "$SANDBOX_PATH"
        return 0
    fi
    if [ -f "$USER_PATH" ]; then
        echo "$USER_PATH"
        return 0
    fi
    return 1
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --path)
        if path=$(resolve_path); then
            echo "$path"
            exit 0
        fi
        echo "No DeskPad log file found. Checked:" >&2
        echo "  $SANDBOX_PATH" >&2
        echo "  $USER_PATH" >&2
        exit 1
        ;;
    "")
        if ! path=$(resolve_path); then
            echo "No DeskPad log file found. Checked:" >&2
            echo "  $SANDBOX_PATH" >&2
            echo "  $USER_PATH" >&2
            echo "Run the app once so it can create the log file, then retry." >&2
            exit 1
        fi
        echo "Tailing $path (Ctrl-C to stop)" >&2
        exec tail -F "$path"
        ;;
    *)
        echo "Unknown argument: $1" >&2
        echo "" >&2
        usage >&2
        exit 1
        ;;
esac
