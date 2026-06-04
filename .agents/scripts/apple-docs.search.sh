#!/bin/bash
# @agents-index Searches Xcode's offline documentation symbol index (LMDB) for Apple API doc paths.
#
# Purpose: Xcode ships a 1.65M-entry LMDB index mapping record IDs to Apple
#   documentation URL paths. This script greps that index so agents and humans
#   can discover exact symbol names and canonical doc URLs offline.
#   Why LMDB dump: the database is Apple-internal but the container is standard
#   LMDB; keys are record IDs, values are hex-encoded UTF-8 doc paths.
#
# Usage: apple-docs.search.sh <grep-pattern> [max-results]
#   <grep-pattern>  case-insensitive pattern matched against doc paths,
#                   e.g. "scstreamconfiguration" or "screencapturekit/scstream/"
#   [max-results]   maximum hits to print (default 25)
#
# Output: one doc path per line, prefixed with the full developer.apple.com URL.
# Requires: lmdb (brew install lmdb), python3.
# Side effects: copies the read-only index to /tmp/xcode-docs-index on first run
#   (LMDB needs a writable dir for its lock file).

set -euo pipefail

if [ $# -lt 1 ]; then
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

PATTERN="$1"
MAX="${2:-25}"
SRC="/Applications/Xcode.app/Contents/SharedFrameworks/DNTDocumentationSupport.framework/Versions/A/Resources/external/index"
WORK="/tmp/xcode-docs-index"

# LMDB opens need a writable lock file; the Xcode copy is root-owned read-only.
if [ ! -f "$WORK/data.mdb" ]; then
    cp -r "$SRC" "$WORK" && chmod -R u+w "$WORK"
fi

mdb_dump -s index "$WORK" 2>/dev/null | python3 -c "
import sys, binascii
pattern = sys.argv[1].lower()
limit = int(sys.argv[2])
shown = 0
lines = [l.strip() for l in sys.stdin if l.startswith(' ')]
# Dump alternates key/value lines; values (odd positions) are the doc paths.
for i in range(1, len(lines), 2):
    path = binascii.unhexlify(lines[i]).decode('utf-8', 'replace')
    if pattern in path.lower():
        print(f'https://developer.apple.com/{path}')
        shown += 1
        if shown >= limit:
            break
" "$PATTERN" "$MAX"
