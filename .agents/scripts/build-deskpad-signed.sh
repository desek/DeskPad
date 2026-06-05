#!/bin/bash
# @agents-index Builds DeskPad Release and signs it with the stable Apple Development certificate so the TCC Screen Recording grant survives rebuilds.
#
# Purpose: ad-hoc signatures change on every build, invalidating the
#   Screen Recording permission each time. Signing with the keychain's
#   Apple Development identity keeps the signature stable across builds,
#   so the grant is one-time. xcodebuild cannot see GUI-added Xcode
#   accounts from the CLI, so we build unsigned and codesign manually.
#
# Usage: build-deskpad-signed.sh [--install]
#   --install   also copy the signed app to /Applications and launch it
#
# Output: signed app at build/Build/Products/Release/DeskPad.app
# Requires: an "Apple Development" identity in the login keychain
#   (Xcode -> Settings -> Accounts -> Manage Certificates).

set -euo pipefail
cd "$(dirname "$0")/../.."

# Prefer the pinned identity from .env (DESKPAD_CODESIGN_IDENTITY);
# fall back to keychain discovery when .env is absent.
if [ -f .env ]; then
    # shellcheck disable=SC1091
    source .env
fi
IDENTITY="${DESKPAD_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')}"
if [ -z "$IDENTITY" ]; then
    echo "ERROR: no valid Apple Development identity in keychain" >&2
    echo "Create one in Xcode -> Settings -> Accounts -> Manage Certificates" >&2
    exit 1
fi

echo "Building (unsigned)..."
xcodebuild -scheme DeskPad -configuration Release -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -2

APP=build/Build/Products/Release/DeskPad.app
echo "Signing with: $IDENTITY"
codesign --force --options runtime \
    --entitlements DeskPad/DeskPad.entitlements \
    --sign "$IDENTITY" "$APP"
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier|flags"

if [ "${1:-}" = "--install" ]; then
    pkill -f DeskPad.app || true
    sleep 1
    rm -rf /Applications/DeskPad.app
    cp -R "$APP" /Applications/
    open /Applications/DeskPad.app
    echo "Installed and launched /Applications/DeskPad.app"
fi
