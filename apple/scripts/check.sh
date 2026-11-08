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

scripts/feature-flags.sh lint
scripts/us-english.sh

echo "Rust tests…"
cargo test -p phosphor-apple

if [ "$RUST_ONLY" = 1 ]; then
    echo "Rust checks passed. Swift tests were skipped."
    exit 0
fi

# An ad-hoc build of its own: in build/DD it would replace the signed Debug app,
# and Siri, Shortcuts and Quick Look stop working on that copy. Unregistered
# afterward so the system doesn't pick its Quick Look extension over the real one.
TEST_APP="$APPLE/build/DD-tests/Build/Products/Debug/Resonance.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
trap '"$LSREGISTER" -u "$TEST_APP" 2>/dev/null || true' EXIT

echo "Swift tests…"
xcodebuild test -quiet -project Resonance.xcodeproj -scheme Resonance \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD-tests \
    CODE_SIGN_IDENTITY=-

scripts/strings.sh check

echo "All checks passed."
