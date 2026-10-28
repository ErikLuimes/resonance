#!/bin/bash
# Build the Rust core (libphosphor_apple.a) and regenerate its Swift bindings.
#
# Runs as the first build phase of the PhosphorCore framework target, and
# works from a terminal too:  apple/scripts/build-core.sh  [Debug|Release]
#
# Outputs (each copied only when its content changed, so Xcode doesn't
# recompile or relink for nothing):
#   apple/PhosphorCore/Generated/{PhosphorCore.swift, PhosphorCoreFFI.h, module.modulemap}
#   $BUILT_PRODUCTS_DIR/libphosphor_apple.a   (when run from Xcode)
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GENERATED="$APPLE_DIR/PhosphorCore/Generated"

# Xcode runs scripts with a minimal PATH. Homebrew's rustup is keg-only.
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v cargo >/dev/null; then
    echo "error: cargo not found. Install Rust: brew install rustup && rustup default stable"
    exit 1
fi

CONFIGURATION="${CONFIGURATION:-${1:-Debug}}"
if [ "$CONFIGURATION" = "Release" ]; then
    PROFILE=release
    PROFILE_FLAG=(--release)
else
    PROFILE=debug
    PROFILE_FLAG=()
fi

# Cargo finds apple/.cargo/config.toml from the working directory.
cd "$APPLE_DIR"
# The host is the only target (macOS 27 is Apple-silicon only), so no
# --target: this shares build artifacts with `cargo test` and the examples.
cargo build -p phosphor-apple --lib ${PROFILE_FLAG[@]+"${PROFILE_FLAG[@]}"}
cargo build -p uniffi-bindgen --release --quiet

LIB="$APPLE_DIR/target/$PROFILE/libphosphor_apple.a"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$APPLE_DIR/target/release/uniffi-bindgen-swift" \
    --swift-sources --headers --modulemap \
    --module-name PhosphorCoreFFI \
    --modulemap-filename module.modulemap \
    "$LIB" "$TMP"

copy_if_changed() {
    if ! cmp -s "$1" "$2"; then
        mkdir -p "$(dirname "$2")"
        cp "$1" "$2"
        echo "updated $2"
    fi
}

for f in PhosphorCore.swift PhosphorCoreFFI.h module.modulemap; do
    copy_if_changed "$TMP/$f" "$GENERATED/$f"
done

if [ -n "${BUILT_PRODUCTS_DIR:-}" ]; then
    copy_if_changed "$LIB" "$BUILT_PRODUCTS_DIR/libphosphor_apple.a"
fi
