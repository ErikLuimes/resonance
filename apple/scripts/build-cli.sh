#!/bin/bash
# Build the `resonance` command line tool and put it in the app, signed.
#
# Runs as a build phase of the Resonance target, before Xcode signs the app.
# It goes in Contents/Helpers: in Contents/MacOS, `resonance` would be the same
# file as the app's own `Resonance` on a case-insensitive disk.
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    PROFILE=release
    PROFILE_FLAG=(--release)
else
    PROFILE=debug
    PROFILE_FLAG=()
fi

cd "$APPLE_DIR"
cargo build -p resonance-cli ${PROFILE_FLAG[@]+"${PROFILE_FLAG[@]}"}

HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$HELPERS"
cp "$APPLE_DIR/target/$PROFILE/resonance" "$HELPERS/resonance"

# Signed as the app will be: notarization checks every executable inside it.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
FLAGS=(--force --sign "$IDENTITY" --identifier nl.luimes.resonance.cli)
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ] && [ "$IDENTITY" != "-" ]; then
    FLAGS+=(--options runtime --timestamp)
fi
codesign "${FLAGS[@]}" "$HELPERS/resonance"
