#!/bin/bash
# The one check to run before calling a change done.
#
#   apple/scripts/check.sh           Rust core tests, then the app's Swift tests
#   apple/scripts/check.sh --rust    Rust core tests only, for Rust-only changes
#
# It doesn't check formatting yet: much of apple/ isn't rustfmt-clean, so
# `cargo fmt --check` would fail on every run until that's cleaned up.
set -euo pipefail

APPLE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APPLE"

# The same PATH build-core.sh uses: Homebrew's rustup is keg-only.
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

case "${1:-}" in
    "") RUST_ONLY=0 ;;
    --rust) RUST_ONLY=1 ;;
    *) echo "usage: apple/scripts/check.sh [--rust]" >&2; exit 2 ;;
esac

echo "Rust tests…"
cargo test -p phosphor-apple

if [ "$RUST_ONLY" = 1 ]; then
    echo "Rust checks passed. Swift tests were skipped."
    exit 0
fi

echo "Swift tests…"
xcodebuild test -quiet -project Resonance.xcodeproj -scheme Resonance \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD \
    CODE_SIGN_IDENTITY=-

echo "All checks passed."
