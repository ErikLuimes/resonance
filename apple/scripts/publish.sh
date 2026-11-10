#!/bin/bash
# Publish a Resonance release end to end, in the order that never leaves
# the update feed pointing at a missing download.
#
#   apple/scripts/publish.sh
#
# Bump MARKETING_VERSION, CURRENT_PROJECT_VERSION and RELEASE_STAGE, write
# release-notes/<version>.md, commit and push, then run this. It:
#
#   1. checks: clean tree, HEAD pushed to origin/main, tag unused, notes
#      present, build number above the feed's newest, and the fingerprint
#      and embedding sets this build downloads are on the "fingerprints"
#      release;
#   2. runs release.sh (build, sign, notarize, appcast entry);
#   3. asks, then creates the GitHub release with the .dmg and notes (which
#      tags HEAD on GitHub in the same step, so a failed upload leaves no
#      stray tag), fetches the tag, and last commits and pushes the appcast.
#
# An aborted run leaves its appcast entry in site/appcast.xml; revert it
# (git checkout apple/site/appcast.xml) before running again.
#
# GITHUB_TOKEN, if set, must be allowed to write releases (Contents:
# read and write); otherwise run with GITHUB_TOKEN= to use `gh auth login`.
set -euo pipefail

APPLE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$APPLE/.." && pwd)"
REPO="${RESONANCE_REPO:-ErikLuimes/resonance}"
APPCAST="$APPLE/site/appcast.xml"
cd "$ROOT"

fail() { echo "error: $*" >&2; exit 1; }

# 1. Checks
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "not on main"
[ -z "$(git status --porcelain)" ] \
    || fail "the working tree isn't clean: commit the version bump first (and revert apple/site/appcast.xml if an earlier run left its entry)"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || fail "HEAD isn't what origin/main has; push first (the tag must land on the released commit)"

SETTINGS="$(cd "$APPLE" && xcodebuild -project Resonance.xcodeproj -scheme Resonance \
    -configuration Release -showBuildSettings 2>/dev/null)"
setting() { echo "$SETTINGS" | awk -v k="$1" '$1 == k { print $3; exit }'; }
STAGE="$(setting RELEASE_STAGE)"
VERSION="$(setting MARKETING_VERSION)${STAGE:+-$STAGE}"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
TAG="v$VERSION"
NOTES="$APPLE/release-notes/$VERSION.md"
echo "Releasing $VERSION (build $BUILD) from $(git rev-parse --short HEAD)"

[ -f "$NOTES" ] || fail "no release notes at ${NOTES#$ROOT/}"
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    fail "$TAG already exists on origin"
fi
NEWEST="$(grep -o '<sparkle:version>[0-9]*' "$APPCAST" | grep -o '[0-9]*$' | sort -n | tail -1)"
[ "${NEWEST:-0}" -lt "$BUILD" ] || fail "build $BUILD isn't above the feed's newest ($NEWEST)"

STORE="$APPLE/core/src/fingerprint/store.rs"
EXTRACTOR="$(sed -n 's/.*const EXTRACTOR_VERSION: i64 = \([0-9]*\);.*/\1/p' "$STORE")"
EMBEDDING="$(sed -n 's/.*const EMBEDDING_SET: i64 = \([0-9]*\);.*/\1/p' "$STORE")"
[ -n "$EXTRACTOR" ] && [ -n "$EMBEDDING" ] || fail "couldn't read the data versions from store.rs"
ASSETS="$(gh release view fingerprints --repo "$REPO" --json assets -q '.assets[].name')"
for asset in "fingerprints-x$EXTRACTOR.zip" "embeddings-e$EMBEDDING.zip"; do
    echo "$ASSETS" | grep -qx "$asset" \
        || fail "$asset isn't on the fingerprints release (apple/scripts/fingerprint-set.sh, similarity-bench/export_embeddings.py)"
done
echo "Checks passed: data sets x$EXTRACTOR and e$EMBEDDING are published."

# 2. Build
RESONANCE_PUBLISHING=1 "$APPLE/scripts/release.sh"
DMG="$(ls -t "$APPLE"/build/release/Resonance-"$VERSION"*.dmg 2>/dev/null | head -1 || true)"
[ -n "$DMG" ] && [ -f "$DMG" ] || fail "release.sh left no .dmg for $VERSION in apple/build/release"

# 3. Publish
echo
echo "Ready to publish:"
echo "  tag      $TAG at $(git rev-parse --short HEAD)"
echo "  release  $(basename "$DMG") (${STAGE:+pre-release, }notes from ${NOTES#$ROOT/})"
echo "  then     commit and push site/appcast.xml"
read -r -p "Publish? [y/N] " answer
[ "$answer" = y ] || { echo "Not published. The .dmg and the appcast change are left in place."; exit 0; }

# GitHub makes the tag at this commit along with the release: no tag is
# pushed ahead of a release that might then fail to upload.
gh release create "$TAG" "$DMG" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Resonance $VERSION" --notes-file "$NOTES" ${STAGE:+--prerelease}
git fetch -q origin "refs/tags/$TAG:refs/tags/$TAG"

# The feed goes last: its entry links to the .dmg that now exists.
git add "$APPCAST"
git commit -q -m "Appcast: $VERSION"
git push origin main
echo "Published $TAG. Once the site has deployed, check it from the outside:"
echo "  apple/scripts/release-check.sh"
