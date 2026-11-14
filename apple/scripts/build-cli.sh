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
cp "$APPLE_DIR/target/$PROFILE/resonance-mcp" "$HELPERS/resonance-mcp"

# Signed as the app will be: notarization checks every executable inside it.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
FLAGS=(--force --sign "$IDENTITY")
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ] && [ "$IDENTITY" != "-" ]; then
    FLAGS+=(--options runtime)
    # Timestamps need Apple's server: Debug builds work offline without one.
    [ "${CONFIGURATION:-Debug}" = "Release" ] && FLAGS+=(--timestamp)
fi
codesign "${FLAGS[@]}" --identifier app.useresonance.resonance.cli "$HELPERS/resonance"

# The MCP server goes in the App Sandbox, with the app group whose container
# holds the socket. Groups belong to a team, so a build signed without one
# leaves it unsandboxed; it then finds the socket in the app's own container.
TEAM="${DEVELOPMENT_TEAM:-}"
MCP_FLAGS=("${FLAGS[@]}" --identifier app.useresonance.resonance.mcp)
if [ -n "$TEAM" ] && [ "$IDENTITY" != "-" ]; then
    ENTITLEMENTS="$DERIVED_FILE_DIR/ResonanceMCP.entitlements"
    mkdir -p "$DERIVED_FILE_DIR"
    sed "s/TEAM\.resonance/$TEAM.resonance/" "$APPLE_DIR/Config/ResonanceMCP.entitlements" > "$ENTITLEMENTS"
    MCP_FLAGS+=(--entitlements "$ENTITLEMENTS")
fi
codesign "${MCP_FLAGS[@]}" "$HELPERS/resonance-mcp"
