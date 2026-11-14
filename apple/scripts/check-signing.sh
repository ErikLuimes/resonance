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

# The MCP server an assistant runs keeps its sandbox through every re-signing.
MCP="$BUNDLE/Contents/Helpers/resonance-mcp"
if [ -f "$MCP" ]; then
    ENTITLEMENTS="$(codesign -d --entitlements - --xml "$MCP" 2>/dev/null || true)"
    if ! grep -q 'com.apple.security.app-sandbox' <<<"$ENTITLEMENTS" \
        || ! grep -q "$TEAM.resonance" <<<"$ENTITLEMENTS"; then
        echo "Contents/Helpers/resonance-mcp: not in the App Sandbox with the group $TEAM.resonance" >&2
        FAILED=$((FAILED + 1))
    fi
fi

if [ "$BINARIES" -eq 0 ]; then
    echo "error: no binaries in $BUNDLE" >&2
    exit 1
fi
if [ "$FAILED" -gt 0 ]; then
    echo "error: $FAILED of $BINARIES binaries wouldn't pass notarization" >&2
    exit 1
fi
echo "Signing checked: $BINARIES binaries"
