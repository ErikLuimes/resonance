#!/bin/bash
# Check every binary in a bundle the way notarization will, without the wait:
# signed with Developer ID by this team, with a secure timestamp, and, for
# executables, the hardened runtime.
#
#   apple/scripts/check-signing.sh <bundle> <team id>
set -euo pipefail

BUNDLE="$1"
TEAM="$2"
BINARIES=0
FAILED=0

while IFS= read -r -d '' FILE; do
    KIND="$(file -b "$FILE")"
    case "$KIND" in
        *Mach-O*) ;;
        *) continue ;;
    esac
    BINARIES=$((BINARIES + 1))
    INFO="$(codesign -dvvv "$FILE" 2>&1 || true)"
    PROBLEMS=""
    grep -q '^Authority=Developer ID Application' <<<"$INFO" || PROBLEMS="$PROBLEMS, not Developer ID"
    grep -q "^TeamIdentifier=$TEAM\$" <<<"$INFO" || PROBLEMS="$PROBLEMS, not team $TEAM"
    grep -q '^Timestamp=' <<<"$INFO" || PROBLEMS="$PROBLEMS, no secure timestamp"
    case "$KIND" in
        *executable*)
            grep -qE 'flags=[^ ]*runtime' <<<"$INFO" || PROBLEMS="$PROBLEMS, no hardened runtime"
            ;;
    esac
    if [ -n "$PROBLEMS" ]; then
        echo "${FILE#"$BUNDLE"/}: ${PROBLEMS#, }" >&2
        FAILED=$((FAILED + 1))
    fi
done < <(find "$BUNDLE" -type f -print0)

if [ "$BINARIES" -eq 0 ]; then
    echo "error: no binaries in $BUNDLE" >&2
    exit 1
fi
if [ "$FAILED" -gt 0 ]; then
    echo "error: $FAILED of $BINARIES binaries wouldn't pass notarization" >&2
    exit 1
fi
echo "Signing checked: $BINARIES binaries"
