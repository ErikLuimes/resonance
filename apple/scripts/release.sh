#!/bin/bash
# Build a Resonance release: a Release build, signed with Developer ID,
# notarized and stapled, in a disk image, and its entry in the update feed.
#
#   apple/scripts/release.sh
#
# Writes apple/build/release/Resonance-<version>.dmg, where <version> is the
# project's MARKETING_VERSION and RELEASE_STAGE: 0.1.0-alpha.1. Publish it
# on a GitHub release tagged v<version> (a pre-release for an alpha or
# beta); the website's Download button picks up its .dmg.
#
# It also signs the .dmg for Sparkle, the app's updater, and adds it to
# site/appcast.xml, the feed the app checks. Commit and push the feed once
# the GitHub release is published: the entry links to the release's .dmg.
# The build number (CURRENT_PROJECT_VERSION) must be higher than the
# newest in the feed; Sparkle compares those.
#
# Signing updates needs Sparkle's EdDSA key in the login keychain, made
# once with Sparkle's generate_keys (README.md, Releases, has the steps).
# Its public half is the SPARKLE_PUBLIC_ED_KEY build setting, which the
# script checks against the keychain. A release notes file,
# release-notes/<version>.md, goes into the update dialog if present.
#
# Signing needs a "Developer ID Application" certificate in the keychain
# (from the Apple Developer Program), and notarizing a notarytool profile,
# stored once with:
#
#   xcrun notarytool store-credentials resonance-notary \
#       --apple-id <you@example.com> --team-id <TEAMID>
#
# NOTARY_PROFILE=<name> uses another profile. Without the certificate it
# builds an unsigned (ad-hoc signed) image instead
# (Resonance-<version>-unsigned.dmg): Gatekeeper makes people approve it
# in System Settings the first time, but updates install without that.
#
# For testing the updater against a local feed:
#   SPARKLE_KEY_ACCOUNT  keychain account of the EdDSA key (generate_keys
#                        --account; default: ed25519, Sparkle's default)
#   SPARKLE_PUBLIC_ED_KEY, SPARKLE_FEED_URL   override the build settings
#   APPCAST              the feed to add to (default: site/appcast.xml)
#   DOWNLOAD_URL_PREFIX  where the .dmg will be (default: the GitHub release)
set -euo pipefail

APPLE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$APPLE/build/release"
PROFILE="${NOTARY_PROFILE:-resonance-notary}"
APPCAST="${APPCAST:-$APPLE/site/appcast.xml}"
# Sparkle's tools come with its Swift package, resolved here.
PACKAGES="$APPLE/build/SourcePackages"
SPARKLE_BIN="$PACKAGES/artifacts/sparkle/Sparkle/bin"
KEY_ACCOUNT=(--account "${SPARKLE_KEY_ACCOUNT:-ed25519}")
cd "$APPLE"

VERSION="$(xcodebuild -project Resonance.xcodeproj -scheme Resonance -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3; exit }')"
STAGE="$(xcodebuild -project Resonance.xcodeproj -scheme Resonance -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "RELEASE_STAGE" { print $3; exit }')"
# "0.1.0-alpha.1" with a release stage (RELEASE_STAGE), "0.1.0" without.
VERSION="$VERSION${STAGE:+-$STAGE}"
BUILD="$(xcodebuild -project Resonance.xcodeproj -scheme Resonance -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "CURRENT_PROJECT_VERSION" { print $3; exit }')"
PROJECT_KEY="$(xcodebuild -project Resonance.xcodeproj -scheme Resonance -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "SPARKLE_PUBLIC_ED_KEY" { print $3; exit }')"
PUBLIC_KEY="${SPARKLE_PUBLIC_ED_KEY:-$PROJECT_KEY}"

# Updates: before the long build, check they can be signed, and that this
# build is newer than the feed's newest.
xcodebuild -resolvePackageDependencies -quiet -project Resonance.xcodeproj -scheme Resonance \
    -clonedSourcePackagesDirPath "$PACKAGES"
# generate_keys -p prints the public key, or an error (also to stdout).
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" "${KEY_ACCOUNT[@]}" -p 2>/dev/null \
    | grep -E '^[A-Za-z0-9+/]{43}=$' || true)"
if [ -z "$KEYCHAIN_KEY" ]; then
    echo "No Sparkle EdDSA key in the keychain. Make one with:" >&2
    echo "  $SPARKLE_BIN/generate_keys" >&2
    echo "(README.md, Releases, has the steps.)" >&2
    exit 1
fi
if [ "$KEYCHAIN_KEY" != "$PUBLIC_KEY" ]; then
    echo "The keychain's Sparkle key ($KEYCHAIN_KEY) isn't the app's" >&2
    echo "SPARKLE_PUBLIC_ED_KEY (${PUBLIC_KEY:-empty}). Set the build setting to the" >&2
    echo "keychain's key; never change it once released, or updates stop working." >&2
    exit 1
fi
if [ -f "$APPCAST" ]; then
    NEWEST="$(grep -o '<sparkle:version>[0-9]*' "$APPCAST" | grep -o '[0-9]*$' | sort -n | tail -1 || true)"
    if [ -n "$NEWEST" ] && [ "$BUILD" -le "$NEWEST" ]; then
        echo "Build $BUILD isn't newer than the feed's newest, $NEWEST: raise CURRENT_PROJECT_VERSION." >&2
        exit 1
    fi
fi
UPDATES=(SPARKLE_PUBLIC_ED_KEY="$PUBLIC_KEY" ${SPARKLE_FEED_URL:+SPARKLE_FEED_URL="$SPARKLE_FEED_URL"})

# The Developer ID certificate, and its team (the identity ends "(TEAMID)").
IDENTITY="$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
TEAM="$(sed -E 's/.*\(([A-Z0-9]+)\)$/\1/' <<<"$IDENTITY")"

rm -rf "$OUT"
mkdir -p "$OUT"
echo "Resonance $VERSION ($BUILD)"

if [ -n "$IDENTITY" ]; then
    echo "Signing as $IDENTITY"
    SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=$TEAM"
             OTHER_CODE_SIGN_FLAGS=--timestamp)
    NAME="Resonance-$VERSION"
else
    echo "No Developer ID Application certificate: building unsigned"
    # No hardened runtime: its library validation only loads frameworks
    # signed by the app's own team, and an ad-hoc build has none, so the
    # app couldn't load PhosphorCore. (Notarization needs it; this build
    # isn't notarized.)
    SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO)
    NAME="Resonance-$VERSION-unsigned"
fi

echo "Archiving (the Rust core builds in release mode; this takes a few minutes)…"
xcodebuild archive -quiet -project Resonance.xcodeproj -scheme Resonance -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$OUT/Resonance.xcarchive" \
    -clonedSourcePackagesDirPath "$PACKAGES" "${SIGNING[@]}" "${UPDATES[@]}"

if [ -n "$IDENTITY" ]; then
    cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>teamID</key><string>$TEAM</string>
</dict>
</plist>
EOF
    xcodebuild -exportArchive -quiet -archivePath "$OUT/Resonance.xcarchive" \
        -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export"
    APP="$OUT/export/Resonance.app"
    codesign --verify --deep --strict --verbose=1 "$APP"
else
    APP="$OUT/Resonance.xcarchive/Products/Applications/Resonance.app"
fi

# The disk image: the app and a link to Applications to drag it onto.
echo "Making $NAME.dmg…"
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Resonance $VERSION" -srcfolder "$STAGING" -fs APFS -format ULMO -ov "$OUT/$NAME.dmg"
rm -rf "$STAGING"

if [ -n "$IDENTITY" ]; then
    codesign --sign "$IDENTITY" --timestamp "$OUT/$NAME.dmg"
    echo "Notarizing (usually a few minutes)…"
    xcrun notarytool submit "$OUT/$NAME.dmg" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$OUT/$NAME.dmg"
    spctl --assess --type open --context context:primary-signature --verbose=1 "$OUT/$NAME.dmg"
fi

# The update feed: generate_appcast signs the .dmg with the keychain's
# EdDSA key and adds an entry for it to the feed, linking to the release.
echo "Adding $NAME.dmg to the update feed…"
FEED="$OUT/feed"
mkdir -p "$FEED"
cp "$OUT/$NAME.dmg" "$FEED/"
[ -f "$APPCAST" ] && cp "$APPCAST" "$FEED/appcast.xml"
NOTES="$APPLE/release-notes/$VERSION.md"
[ -f "$NOTES" ] && cp "$NOTES" "$FEED/$NAME.md"
"$SPARKLE_BIN/generate_appcast" "${KEY_ACCOUNT[@]}" --maximum-deltas 0 --maximum-versions 0 --embed-release-notes \
    --download-url-prefix "${DOWNLOAD_URL_PREFIX:-https://github.com/ErikLuimes/resonance/releases/download/v$VERSION/}" \
    -o "$FEED/appcast.xml" "$FEED"
# The entry's version is CFBundleShortVersionString, 0.1.0 for every alpha:
# give it the release stage, as the app's update dialog shows it.
python3 -I - "$FEED/appcast.xml" "$BUILD" "$VERSION" <<'EOF'
import re, sys
path, build, version = sys.argv[1:]
feed = open(path).read()
def name(item):
    item = item.group(0)
    if "<sparkle:version>%s</sparkle:version>" % build not in item:
        return item
    item = re.sub(r"<title>.*?</title>", "<title>%s</title>" % version, item)
    return re.sub(r"<sparkle:shortVersionString>.*?</sparkle:shortVersionString>",
                  "<sparkle:shortVersionString>%s</sparkle:shortVersionString>" % version, item)
open(path, "w").write(re.sub(r"<item>.*?</item>", name, feed, flags=re.S))
EOF
cp "$FEED/appcast.xml" "$APPCAST"

ls -lh "$OUT/$NAME.dmg"
shasum -a 256 "$OUT/$NAME.dmg"
echo "Updated $APPCAST: commit and push it after publishing the GitHub release."
