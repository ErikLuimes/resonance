#!/bin/bash
# Keeps the String Catalogs in step with the code. Xcode does this when it
# builds; a command-line build doesn't.
#
#   apple/scripts/strings.sh sync    Adds the code's new strings to the catalogs
#                                    and drops the ones it no longer has.
#   apple/scripts/strings.sh check   Fails if the code has a string its catalog
#                                    doesn't.
#
# Both read what the last check.sh build extracted, so run that first. A string
# inside an #if counts only when its flag was on for that build. The rules:
# "Strings" in apple/README.md.
set -euo pipefail

APPLE="$(cd "$(dirname "$0")/.." && pwd)"
INTERMEDIATES="$APPLE/build/DD-tests/Build/Intermediates.noindex/Resonance.build/Debug"

extracted_folder() {
    local folder="$INTERMEDIATES/$1.build/Objects-normal/arm64"
    if ! compgen -G "$folder/*.stringsdata" >/dev/null; then
        echo "error: nothing extracted for $1 yet: run apple/scripts/check.sh first" >&2
        exit 1
    fi
    echo "$folder"
}

sync_target() {
    local target="$1" folder
    shift
    folder="$(extracted_folder "$target")"
    xcrun xcstringstool sync "$@" --stringsdata "$folder"/*.stringsdata
}

check_target() {
    local target="$1" folder scratch catalog failed=0
    shift
    folder="$(extracted_folder "$target")"
    scratch="$(mktemp -d)"
    for catalog in "$@"; do
        cp "$catalog" "$scratch/"
    done
    # In a copy, and only adding: a string missing from the code may belong to a
    # flag that's off in this build.
    xcrun xcstringstool sync "$scratch"/*.xcstrings --skip-marking-strings-stale \
        --stringsdata "$folder"/*.stringsdata
    for catalog in "$@"; do
        python3 - "$catalog" "$scratch/$(basename "$catalog")" <<'EOF' || failed=1
import json
import sys

catalog, synced = sys.argv[1:]
have = json.load(open(catalog, encoding="utf-8"))["strings"]
want = json.load(open(synced, encoding="utf-8"))["strings"]
missing = sorted(set(want) - set(have))
if missing:
    print(f"error: {catalog} is missing {len(missing)} strings the code uses:", file=sys.stderr)
    for key in missing[:10]:
        print(f"  {key}", file=sys.stderr)
    print("Run apple/scripts/strings.sh sync. Xcode also adds them when it builds.", file=sys.stderr)
    sys.exit(1)
EOF
    done
    rm -rf "$scratch"
    return "$failed"
}

run() {
    "$1" Resonance "$APPLE/Resonance/Localizable.xcstrings" "$APPLE/Resonance/AppShortcuts.xcstrings"
    "$1" ResonanceQuickLook "$APPLE/ResonanceQuickLook/Localizable.xcstrings"
}

case "${1:-}" in
    sync) run sync_target ;;
    check) run check_target ;;
    *)
        echo "usage: apple/scripts/strings.sh sync | check" >&2
        exit 2
        ;;
esac
