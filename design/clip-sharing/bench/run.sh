#!/bin/bash
# The measurements in ../README.md. Builds into a temporary folder and leaves
# the clips there; the sync check needs ffmpeg and ffprobe (Homebrew).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cd "$OUT"
xcrun swiftc -O -swift-version 5 "$HERE/bench.swift" -o bench 2>/dev/null
xcrun swiftc -O -swift-version 5 "$HERE/sync.swift" -o sync 2>/dev/null
xcrun metal -c "$HERE/fx.metal" -o fx.air && xcrun metallib fx.air -o fx.metallib
xcrun swiftc -O -swift-version 5 "$HERE/imagerenderer.swift" -o imagerenderer 2>/dev/null
echo "Encoding (Metal into the writer's pixel buffers, H.264/HEVC + AAC):"
./bench "$OUT"
echo "SwiftUI through ImageRenderer, read back into a bitmap:"
./imagerenderer "$OUT/fx.metallib"
echo "Sync: a white frame and a click on the same sample count, every 0.5 s:"
./sync "$OUT" >/dev/null
F="$OUT/clip-avc1-1080x1080-60.mp4"
ffprobe -v error -f lavfi -i "movie=$F,signalstats" -show_entries frame=pts_time:frame_tags=lavfi.signalstats.YAVG \
    -of csv=p=0 | awk -F, '$2>200{print "  flash at", $1}' | head -4
ffmpeg -v error -i "$F" -map 0:a -f f32le -ac 1 -ar 48000 - | python3 -c "
import sys, struct
d = sys.stdin.buffer.read(); a = struct.unpack('%df' % (len(d) // 4), d)
hits, last = [], -10**9
for i, x in enumerate(a):
    if abs(x) > 0.3 and i - last > 4800: hits.append(i / 48000); last = i
print('  clicks at', ', '.join('%.5f' % t for t in hits[:4]))"
echo "Clips are in $OUT"
