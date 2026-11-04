#!/bin/bash
# Build the published fingerprint set from a finished scan.
#
#   apple/scripts/fingerprint-set.sh [fingerprints.sqlite]
#
# Takes this Mac's fingerprints (by default Resonance's own database), keeps
# only the finished ones, and writes apple/build/fingerprints-x<N>.zip, N
# being the extractor version that made them. Resonance downloads that file
# from the GitHub release tagged "fingerprints" (download_fingerprints in
# core/src/ffi.rs), so upload it there, replacing the old one:
#
#   gh release upload fingerprints apple/build/fingerprints-x1.zip --clobber
#
# (Create the release once first: gh release create fingerprints --title
# "Fingerprints" --notes "The fingerprint set Resonance downloads.")
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$HOME/Library/Application Support/Resonance/fingerprints.sqlite}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A consistent copy, even while Resonance is writing to it.
sqlite3 "$SOURCE" ".backup '$WORK/fingerprints.sqlite'"
DB="$WORK/fingerprints.sqlite"

VERSIONS="$(sqlite3 "$DB" "SELECT DISTINCT version FROM fingerprints WHERE status = 1")"
if [ "$(echo "$VERSIONS" | wc -l | tr -d ' ')" != 1 ] || [ -z "$VERSIONS" ]; then
    echo "error: the fingerprints come from more than one extractor version ($VERSIONS); finish a scan first" >&2
    exit 1
fi

# Only finished fingerprints travel; one plain file, no WAL, compacted.
sqlite3 "$DB" "DELETE FROM fingerprints WHERE status != 1; PRAGMA journal_mode = DELETE; VACUUM;" >/dev/null
[ "$(sqlite3 "$DB" "PRAGMA integrity_check")" = ok ] || { echo "error: the copy failed its integrity check" >&2; exit 1; }

OUT="$APPLE_DIR/build/fingerprints-x$VERSIONS.zip"
mkdir -p "$APPLE_DIR/build"
rm -f "$OUT"
(cd "$WORK" && zip -9 -q "$OUT" fingerprints.sqlite)

echo "$(sqlite3 "$DB" "SELECT COUNT(*) FROM fingerprints") fingerprints, $(sqlite3 "$DB" "SELECT COUNT(*) FROM tunes") tunes"
ls -lh "$OUT"
