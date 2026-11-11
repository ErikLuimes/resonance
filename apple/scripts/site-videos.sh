#!/bin/bash
# Turn screen recordings into the website's videos.
#
#   apple/scripts/site-videos.sh <recording.mov> <name> [start-seconds] [length-seconds]
#
# <name> is the slot on the page: smart-playlists, sounds-like, now-playing, library and
# playlists (the hero's tour chapters, each shown again in its own section
# further down), hvsc-update, or a visualizer's vis-<name>: vis-ink,
# vis-silicon and vis-notes are the featured three, recorded in the whole
# Now Playing window; vis-halo, vis-particles, vis-radial, vis-sound-map,
# vis-spectrum, vis-terrain, vis-nimbus, vis-liquid-light and vis-ferrofluid
# are bare recordings of the visualizer alone. Until a slot has its video,
# its .jpg (the app's chooser picture) stands in. Writes apple/site/media/<name>.mp4 (H.264,
# which every current browser plays) and <name>.jpg (the poster, from the
# first frame shown). No WebM: for these recordings VP9 came out bigger.
#
# The window is cut out of the black margin a ⇧⌘5 selection leaves around it
# (CROP=w:h:x:y, in pixels, sets it by hand). The sound is kept and brought
# to one loudness for every clip: the page starts videos muted (browsers only
# autoplay muted video) and its Sound button turns it on.
#
# POSTER=<seconds> takes the poster from that point of the clip instead.
#
# CROP=<w:h:0:0> for a bare visualizer recording, whose black background
# would fool the margin detection.
#
# QUALITY=lower squeezes a busy clip (the visualizers' fine, moving detail is
# the hardest picture to compress) to a sensible size for a web page.
set -euo pipefail

if [ $# -lt 2 ]; then
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

# x264 quality (lower is better and bigger).
case "${QUALITY:-normal}" in
    lower) CRF=30 ;;
    *) CRF=24 ;;
esac

INPUT="$1"
NAME="$2"
START="${3:-0}"
LENGTH="${4:-}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/site/media"
mkdir -p "$OUT"

TRIM=(-ss "$START")
[ -n "$LENGTH" ] && TRIM+=(-t "$LENGTH")

# The window: the box inside the black margin, measured on one frame. (The
# window's own shadow fools ffmpeg's cropdetect; the margin is pure black.)
if [ -z "${CROP:-}" ]; then
    FRAME="$(mktemp)"
    trap 'rm -f "$FRAME"' EXIT
    read -r W H < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$INPUT" | tr ',' ' ')
    ffmpeg -y -loglevel error -ss "$START" -i "$INPUT" -frames:v 1 -pix_fmt gray -f rawvideo "$FRAME"
    CROP="$(python3 -I - "$FRAME" "$W" "$H" <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
w, h = int(sys.argv[2]), int(sys.argv[3])
cols = [max(data[y * w + x] for y in range(0, h, 8)) for x in range(w)]
rows = [max(data[y * w + x] for x in range(0, w, 8)) for y in range(h)]
lit = lambda v: v > 4
left = next(x for x in range(w) if lit(cols[x]))
right = next(x for x in range(w - 1, -1, -1) if lit(cols[x]))
top = next(y for y in range(h) if lit(rows[y]))
bottom = next(y for y in range(h - 1, -1, -1) if lit(rows[y]))
# Even sizes, as H.264 needs.
cw, ch = (right - left + 1) // 2 * 2, (bottom - top + 1) // 2 * 2
print(f"{cw}:{ch}:{left}:{top}")
EOF
)"
fi
echo "window: $CROP"

# 1600 wide is sharp on a Retina laptop without the file getting heavy; 30 fps
# is plenty for UI, the visualizers included. WIDTH=<pixels> for a smaller
# slot: the visualizer grid's tiles are 800.
VIDEO="crop=$CROP,scale='min(${WIDTH:-1600},iw)':-2:flags=lanczos,fps=30"
# One loudness for every clip (EBU R128, -16 LUFS, like most web video).
AUDIO="loudnorm=I=-16:TP=-1.5:LRA=11"

# A recording without sound (no audio track) still converts; it just stays
# silent. Only the first video stream: some files also carry a cover picture.
ffmpeg -y -loglevel error "${TRIM[@]}" -i "$INPUT" -map 0:v:0 -map '0:a:0?' -vf "$VIDEO" -af "$AUDIO" \
    -c:v libx264 -preset slow -crf "$CRF" -pix_fmt yuv420p -movflags +faststart \
    -c:a aac -b:a 160k -ac 2 -ar 48000 \
    "$OUT/$NAME.mp4"
ffmpeg -y -loglevel error -ss "${POSTER:-0}" -i "$OUT/$NAME.mp4" -frames:v 1 -q:v 3 "$OUT/$NAME.jpg"

ls -lh "$OUT/$NAME".{mp4,jpg}
