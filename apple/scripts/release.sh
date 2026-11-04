#!/bin/bash
# Build a Resonance release: a Release build, signed with Developer ID,
# notarized and stapled, in a disk image.
#
#   apple/scripts/release.sh
#
# Writes apple/build/release/Resonance-<version>.dmg, where <version> is the
# project's MARKETING_VERSION and RELEASE_STAGE: 0.1.0-alpha.1. Publish it
# on a GitHub release (a pre-release for an alpha or beta); the website's
# Download button picks up its .dmg.
#
# Signing needs a "Developer ID Application" certificate in the keychain
# (from the Apple Developer Program), and notarizing a notarytool profile,
# stored once with:
#
#   xcrun notarytool store-credentials resonance-notary \
#       --apple-id <you@example.com> --team-id <TEAMID>
#
# NOTARY_PROFILE=<name> uses another profile. Without the certificate it
# builds an unsigned image instead (Resonance-<version>-unsigned.dmg): fine
# for trying the build, but other Macs will refuse to open it.
set -euo pipefail

APPLE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$APPLE/build/release"
PROFILE="${NOTARY_PROFILE:-resonance-notary}"
cd "$APPLE"

VERSION="$(xcodebuild -project Resonance.xcodeproj -scheme Resonance -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3; exit }')"
STAGE="$(xcodebuild -project Resonance.xcodeproj -scheme Resonance -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "RELEASE_STAGE" { print $3; exit }')"
# "0.1.0-alpha.1" with a release stage (RELEASE_STAGE), "0.1.0" without.
VERSION="$VERSION${STAGE:+-$STAGE}"
BUILD="$(xcodebuild -project Resonance.xcodeproj -scheme Resonance -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "CURRENT_PROJECT_VERSION" { print $3; exit }')"

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
    -destination 'generic/platform=macOS' -archivePath "$OUT/Resonance.xcarchive" "${SIGNING[@]}"

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

ls -lh "$OUT/$NAME.dmg"
shasum -a 256 "$OUT/$NAME.dmg"
