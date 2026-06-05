#!/usr/bin/env bash
# @agents-index CR-0003 Phase 4 / FR-14: builds DeskPad Debug, launches the
# binary with `--self-test`, parses the PASS/FAIL verdict line from stdout
# (with a fallback to the rotating on-disk log), prints the verdict, and
# exits with the same status as the self-test process.
#
# Usage:
#   .agents/scripts/selftest-deskpad.sh           # build + run + verdict
#   .agents/scripts/selftest-deskpad.sh --help    # show this help
#   .agents/scripts/selftest-deskpad.sh -h        # show this help
#
# Exit codes:
#   0   PASS line observed
#   1   FAIL line observed (or no verdict line found)
#
# CR cross-reference: docs/cr/CR-0003-test-hardening-and-rendering-self-test.md.
#
# TCC / signing notes (carry-over from CR-0001):
#   Screen Recording permission is bound to the code signature. Ad-hoc
#   signatures change on every build, so an ad-hoc build re-prompts for TCC
#   on every launch. To keep the grant stable, this script prefers the
#   machine-local Apple Development identity recorded in `.env`
#   (`DESKPAD_CODESIGN_IDENTITY`, optionally with `DESKPAD_DEVELOPMENT_TEAM`)
#   and falls back to ad-hoc `CODE_SIGN_IDENTITY="-"` only when `.env` is
#   absent. `.env` is git-ignored and contains a personal identity that must
#   not leak into commits; see `.agents/scripts/build-deskpad-signed.sh`.
#
# Fallback note (CR-0003 Open Questions, virtual display addressability):
#   The Phase 4 loopback runs entirely on an offscreen Metal texture; the
#   captured-IOSurface comparison documented in FR-12 is dropped here,
#   matching the CR's authorized fallback when the virtual display is not
#   addressable from a headless self-test process.

set -euo pipefail

usage() {
    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        echo "Unknown argument: $1" >&2
        echo "" >&2
        usage >&2
        exit 1
        ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# Prefer the pinned identity from .env so the TCC grant survives rebuilds.
# Fall back to ad-hoc signing only when .env is absent.
if [ -f .env ]; then
    # shellcheck disable=SC1091
    source .env
fi

BUILD_ARGS=(
    -scheme DeskPad
    -configuration Debug
    -derivedDataPath build
)
if [ -n "${DESKPAD_CODESIGN_IDENTITY:-}" ]; then
    echo "Signing with pinned identity from .env" >&2
    BUILD_ARGS+=("CODE_SIGN_IDENTITY=${DESKPAD_CODESIGN_IDENTITY}")
    if [ -n "${DESKPAD_DEVELOPMENT_TEAM:-}" ]; then
        BUILD_ARGS+=("DEVELOPMENT_TEAM=${DESKPAD_DEVELOPMENT_TEAM}")
    fi
else
    echo "No .env signing identity; falling back to ad-hoc (-)" >&2
    BUILD_ARGS+=('CODE_SIGN_IDENTITY=-')
fi

echo "Building DeskPad Debug..." >&2
xcodebuild "${BUILD_ARGS[@]}" build 2>&1 | tail -5

BINARY="build/Build/Products/Debug/DeskPad.app/Contents/MacOS/DeskPad"
if [ ! -x "$BINARY" ]; then
    echo "ERROR: built binary not found at $BINARY" >&2
    exit 1
fi

STDOUT_LOG="$(mktemp -t deskpad-selftest.XXXXXX)"
trap 'rm -f "$STDOUT_LOG"' EXIT

echo "Launching $BINARY --self-test" >&2
set +e
"$BINARY" --self-test >"$STDOUT_LOG" 2>&1
PROCESS_STATUS=$?
set -e

VERDICT="$(grep -E '^(PASS|FAIL):' "$STDOUT_LOG" | head -1 || true)"

# Fallback: if stdout did not carry the verdict (e.g. swallowed by AppKit's
# stream redirection), look for it in the rotating on-disk log file. Match
# the two-candidate enumeration used by tail-deskpad-log.sh.
if [ -z "$VERDICT" ]; then
    SANDBOX_LOG="$HOME/Library/Containers/com.stengo.DeskPad/Data/Library/Logs/DeskPad/deskpad.log"
    USER_LOG="$HOME/Library/Logs/DeskPad/deskpad.log"
    for candidate in "$SANDBOX_LOG" "$USER_LOG"; do
        if [ -f "$candidate" ]; then
            VERDICT="$(grep -E '^(PASS|FAIL):' "$candidate" | tail -1 || true)"
            if [ -n "$VERDICT" ]; then break; fi
        fi
    done
fi

if [ -z "$VERDICT" ]; then
    echo "FAIL: no_verdict_line process_status=${PROCESS_STATUS}"
    exit 1
fi

echo "$VERDICT"
exit "$PROCESS_STATUS"
