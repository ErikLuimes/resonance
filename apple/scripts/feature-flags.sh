#!/bin/bash
# Feature flags, for scripts. The rules: design/feature-flags/README.md.
#
#   feature-flags.sh conditions <stage>   The Swift flags a Release build of this
#                                         release stage gets: ALPHA for "alpha.7",
#                                         nothing for "beta.2" or "" (final).
#                                         Any other stage is an error.
#   feature-flags.sh lint                 FeatureFlags.swift and
#                                         feature-markers.tsv list the same
#                                         features, with the same tiers.
#   feature-flags.sh check <app> <stage>  Fails if the app holds a marker of a
#                                         feature this stage must not contain.
set -euo pipefail

APPLE="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT="$APPLE/Resonance/Model/FeatureFlags.swift"
MARKERS="$APPLE/scripts/feature-markers.tsv"
TAB="$(printf '\t')"

conditions() {
    case "$1" in
        alpha|alpha.*) echo ALPHA ;;
        beta|beta.*|"") echo "" ;;
        *)
            echo "error: unknown release stage \"$1\": it's alpha.N, beta.N or empty for a final release" >&2
            exit 1
            ;;
    esac
}

# "csdb restricted" for each feature, sorted.
swift_features() {
    sed -nE 's/^[[:space:]]*case \.([A-Za-z0-9_]+): \.(restricted|experimental)$/\1 \2/p' "$SWIFT" | sort
}

# The file's lines without comments. An empty list isn't an error here: lint
# reports it, with what's missing.
marker_lines() {
    grep -vE '^(#|$)' "$MARKERS" || true
}

marker_features() {
    marker_lines | cut -f1,2 | tr '\t' ' ' | sort
}

lint() {
    local swift markers
    swift="$(swift_features)"
    markers="$(marker_features)"
    if [ -z "$swift" ]; then
        echo "error: found no features in ${SWIFT#"$APPLE"/}; has its format changed?" >&2
        exit 1
    fi
    if [ "$swift" != "$markers" ]; then
        echo "error: FeatureFlags.swift and feature-markers.tsv disagree." >&2
        echo "FeatureFlags.swift:" >&2
        echo "$swift" | sed 's/^/  /' >&2
        echo "feature-markers.tsv:" >&2
        echo "$markers" | sed 's/^/  /' >&2
        exit 1
    fi
    # A restricted feature with no marker couldn't be caught in a release.
    local feature tier pattern
    while IFS="$TAB" read -r feature tier pattern; do
        if [ "$tier" = restricted ] && [ -z "$pattern" ]; then
            echo "error: restricted feature $feature has no marker in feature-markers.tsv" >&2
            exit 1
        fi
    done < <(marker_lines)
}

check() {
    local app="$1" stage="$2" allowed found failed=0 feature tier pattern
    if [ ! -d "$app" ]; then
        echo "error: no app at $app" >&2
        exit 1
    fi
    allowed="$(conditions "$stage")"
    while IFS="$TAB" read -r feature tier pattern; do
        [ -n "$pattern" ] || continue
        if [ "$tier" = experimental ] && [ "$allowed" = ALPHA ]; then
            continue
        fi
        # Every file, so a resource or a framework can't hide one.
        found="$(grep -rlaE "$pattern" "$app" || true)"
        if [ -n "$found" ]; then
            echo "error: a build for release stage \"${stage:-final}\" must not contain $feature ($tier):" >&2
            echo "$found" | sed "s|^$app/|  |" >&2
            failed=1
        fi
    done < <(marker_lines)
    [ "$failed" = 0 ] || exit 1
}

case "${1:-}" in
    conditions) conditions "${2:-}" ;;
    lint) lint ;;
    check)
        [ $# -ge 2 ] || { echo "usage: feature-flags.sh check <app> <stage>" >&2; exit 2; }
        lint
        check "$2" "${3:-}"
        ;;
    *)
        echo "usage: feature-flags.sh conditions <stage> | lint | check <app> <stage>" >&2
        exit 2
        ;;
esac
