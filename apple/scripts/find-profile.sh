#!/bin/bash
# Whether a provisioning profile of this name and team is installed: Xcode's
# signing needs one for the app's universal links.
#
#   apple/scripts/find-profile.sh <name> <team id>
set -uo pipefail

for FILE in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"* \
            "$HOME/Library/MobileDevice/Provisioning Profiles/"*; do
    [ -f "$FILE" ] || continue
    PROFILE="$(security cms -D -i "$FILE" 2>/dev/null)" || continue
    NAME="$(plutil -extract Name raw -o - - <<<"$PROFILE" 2>/dev/null)"
    TEAM="$(plutil -extract TeamIdentifier.0 raw -o - - <<<"$PROFILE" 2>/dev/null)"
    if [ "$NAME" = "$1" ] && [ "$TEAM" = "$2" ]; then
        exit 0
    fi
done
exit 1
