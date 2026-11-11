#!/bin/bash
# Makes the still pictures the visualizer chooser shows (Assets:
# VisualizerPictures), a set for each preset theme. Remake a visualizer's
# when its look changes, and add a set when a theme is added.
#
#   1. Run a Debug build with RESONANCE_VISUALIZER_PICTURES=1 in its
#      environment and no other Resonance open, e.g.
#        open -g --env RESONANCE_VISUALIZER_PICTURES=1 Resonance.app --args -volume 0 -theme c64
#      It opens a bare window with every offered visualizer running large,
#      in that theme, behind the other windows (App/VisualizerPictures.swift).
#      `-volume 0` keeps it quiet.
#   2. Play a tune (`resonance play <file>`) and wait for a moment worth keeping.
#   3. apple/scripts/visualizer-pictures.sh shoot shot.png
#      photographs that window, wherever it is. Take a few; a theme's
#      pictures needn't all come from one.
#   4. apple/scripts/visualizer-pictures.sh cut <theme> shot.png [name…]
#      cuts the named visualizers' pictures out of a shot into the asset
#      catalog, or all of them when none is named.
#
# The names are NowPlayingVisual's, in the order of `offered`: keep VISUALS
# in step with it. The themes are VoiceTheme's ids.
set -euo pipefail

APPLE="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$APPLE/Resonance/Assets.xcassets/VisualizerPictures"
VISUALS=(halo particles radial soundMap notes spectrum terrain ink liquidLight ferrofluid silicon nimbus)
COLUMNS=3
# A picture, in pixels: twice the chooser's largest card (170 by 105 points).
WIDTH=340
HEIGHT=211

usage() {
    echo "usage: apple/scripts/visualizer-pictures.sh shoot <shot.png> | cut <theme> <shot.png> [name…]" >&2
    exit 2
}

shoot() {
    local out="$1" window
    # The capture window is the one that's 3 by 4 cells of 340 by 211 points.
    window="$(swift - <<'EOF'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where window[kCGWindowOwnerName as String] as? String == "Resonance" {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    if bounds["Width"] as? Double == 1020, bounds["Height"] as? Double == 844 {
        print(window[kCGWindowNumber as String] as? Int ?? 0)
        break
    }
}
EOF
)"
    if [ -z "$window" ]; then
        echo "error: no Visualizer Pictures window: launch a Debug build with RESONANCE_VISUALIZER_PICTURES=1" >&2
        exit 1
    fi
    screencapture -x -o -l "$window" "$out"
    echo "Shot $out"
}

# A folder of the asset catalog whose name is part of its images' names.
namespace() {
    mkdir -p "$1"
    cat > "$1/Contents.json" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "provides-namespace" : true
  }
}
EOF
}

cut() {
    local theme="$1" shot="$2" index name set cells=()
    shift 2
    namespace "$ASSETS"
    namespace "$ASSETS/$theme"
    for index in "${!VISUALS[@]}"; do
        name="${VISUALS[$index]}"
        if [ $# -gt 0 ] && [[ " $* " != *" $name "* ]]; then continue; fi
        set="$ASSETS/$theme/$name.imageset"
        mkdir -p "$set"
        cells+=("$index=$set/$name.heic")
        cat > "$set/Contents.json" <<EOF
{
  "images" : [
    {
      "filename" : "$name.heic",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF
        echo "Cut $theme/$name"
    done
    [ ${#cells[@]} -gt 0 ] || { echo "error: no visualizer by that name" >&2; exit 1; }
    swift "$APPLE/scripts/visualizer-pictures-cut.swift" "$shot" "$COLUMNS" $(((${#VISUALS[@]} + COLUMNS - 1) / COLUMNS)) \
        "$WIDTH" "$HEIGHT" "${cells[@]}"
}

case "${1:-}" in
    shoot) [ $# -eq 2 ] || usage; shoot "$2" ;;
    cut) [ $# -ge 3 ] || usage; shift; cut "$@" ;;
    *) usage ;;
esac
