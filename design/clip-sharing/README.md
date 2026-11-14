# Clip sharing

A short video of the visualizer that's playing, with its sound, made from Now
Playing, to post or send. Designed 2026-11-11, built 2026-11-14 (not yet
click-tested). The mockup beside this file (`mockup.html`) shows the reduced
first version that was reviewed; the build has the options too (Erik: "the
whole 1st plan with tools for selecting exact parts").

## In short

- **Share Clip…** at the top right of Now Playing (⇧⌘E) opens a sheet: a
  still of the clip's first frame, **Shape** (Square · Wide), **Length**
  (6 · 15 · 30 s, 15 to start; both remembered) and **Which part**, a strip of
  the tune that starts on the last *length* seconds you heard. **Make Clip**
  renders, then Save…, Messages, Mail, AirDrop and More….
- **Every visualizer Now Playing offers makes clips**, all twelve.
- **Visualizers that build up start nearly fresh**: Ink, Liquid Light, Nimbus
  and Sound Map get 2 s of lead-in and then grow through the clip, rather than
  replaying up to a minute to match the screen exactly (Erik's call: seeing
  them evolve is part of the show).
- **1080 × 1080 or 1728 × 1080, 60 fps, H.264 and AAC in an .mp4**, about
  15 MB for 15 s (22 MB for Liquid Light, Silicon and Particles).
- Burned in: the title, the composer, and the tune's link
  (`useresonance.app/t/<code>`), on a small card at the bottom left.
- **Frames are rendered offline**, not captured from the screen: a second engine
  plays the same stretch of the tune silently, and the visualizer draws into the
  encoder's own pixel buffers. No Screen Recording permission, nothing from the
  window's controls, and faster than real time (a 2 s test clip with its
  lead-in renders in 0.3–1.3 s, depending on the visualizer).
- **Sync isn't tuned, it's built in**: each video frame and its audio come from
  the same sample count. Measured: zero frames between them in the decoded file.
- **Short and credited, always** (see Music rights).
- **Experimental**: only the button and the menu command are `#if ALPHA`, so
  only Debug and alpha builds show them. Everything else compiles in every
  build.

## Where the button goes

Now Playing has no toolbar; its controls are a top row over the visualizer
(close, Surprise Me, the picker in the middle, Visualizers… at the end) and the
tune's row at the bottom (Favorite, Add to…, Share…).

**Share Clip…** goes in the top row, just left of Visualizers…:

    [×] [Surprise Me]        [Ferrofluid | Notes | Sound Map]        [Share Clip…] [Visualizers…]

- It's about the visualizer, so it sits with the other visualizer control.
  Share… at the bottom stays the tune's link, as now.
- It's an extra like Visualizers…: faded and unclickable while idle, kept while
  the sheet is open. Nothing about it changes the window's toolbar.
- Labeled, no glyph, bordered capsule, large, like its neighbors.
- Room: the picker is centered on the window, so it meets the right-hand
  buttons when half the width is less than half the picker plus those buttons
  and the margin. With estimated sizes (a three-segment picker about 330 pt,
  Share Clip… about 110, Visualizers… about 120, 10 pt gaps, 44 pt margins):
  W / 2 ≥ 165 + 10 + 110 + 10 + 120 + 44, so W ≥ about 920 pt. Today, without
  Share Clip…, it's about 680. The window can be 790 wide. So under about 920 pt
  Share Clip… moves to the bottom row, next to Share… (the same button, placed by
  the width Now Playing has, read with `onGeometryChange`; no toolbar
  involved). The build uses this 920 pt estimate (`clipButtonRoom`); the
  click-test should confirm the top row doesn't crowd just above it. The
  mockup's width control shows both places.
- A menu command too, View › Share Clip… (⇧⌘E), enabled while Now Playing shows.

Not in the player bar or the inspector: the clip is of Now Playing's
visualizer, so it starts where that visualizer is.

## The sheet

1. **Share Clip…** opens the sheet with the options and a still of the clip's
   first frame with the burned-in card, so you see what will be posted. The
   still follows the options (200 ms after the last change).
2. **Which part** is a strip of the tune's length with the clip's window on
   it, dragged to place. It starts on the last *length* seconds you heard (the
   moment that made you press the button), snaps back to it within 8 points of
   "now", which is marked (in points: a second is a point or two of a long
   tune's strip), and says what it is: "1:27 – 1:42, the 15 seconds you just
   heard". Under *length* seconds into the tune, it's the tune's first seconds
   (offline, the engine can render past what you've heard). A press on the
   window, or within 6 points of it, takes hold of it (a 6 s window is a few
   points wide); one elsewhere centers the window there. VoiceOver can
   adjust it. The still waits until the strip is let go, and dims while it's
   out of date.
3. **Make Clip** renders: "Rendering… 8 of 15 s" with Cancel. Playback keeps
   going; the clip doesn't touch what you hear.
4. **Then**: the file's name and size, **Save…** (a save panel, Movies by
   default), **Messages**, **Mail**, **AirDrop**, **More…** (the system's share
   menu, which has the rest), and "Saved to … Show in Finder" after a save.
   - Messages, Mail and More… get the text "Commando by Rob Hubbard" and the
     link beside the clip. More… hands them to `NSSharingServicePicker` as
     separate items: `ShareLink`'s message was dropped by Notes and most
     other services, which kept only the file.
   - Save… also copies the link, and says so, to paste as the caption where
     the file is uploaded (no service reads a link out of a video), and sets
     Finder's "Where from" on the file, as Safari does on a download. The
   clip lives in the app's temporary folder until the sheet closes. It's named
   `<Title> — <Composer> (<Visualizer>).mp4`.

**The still's cost** (`ClipBench.stills`, 1:30 into Commando, M5 Pro): the
second engine's skip to the start takes 1.3–1.5 s, now off the main thread
(on it, it froze the window's visualizer for that long on every release of
the strip). Then the painter, 15–25 ms (Silicon 150 ms; Notes' 2 s of note
analysis is kept for the last tune), and the lead-in's frames on the main
thread, 0.13–0.9 s (Terrain's 4 s the longest), handing the main thread back
after each frame.

A sheet, not a popover: it holds a preview and a progress bar, and stays put
while it renders. Esc or Cancel stops a render and throws the file away.

### Which visualizers

All twelve that Now Playing offers. The button hides for a view that can't
make one (`ClipPainters.canClip`: the chip and raster views, which Now Playing
doesn't offer). Visualizers stay additive: none was removed or changed in what
it shows.

| Visualizers | How a clip draws them |
| --- | --- |
| Notes, Ink, Liquid Light, Ferrofluid, Terrain, Nimbus, Sound Map | Their Metal renderers' `encode(into:commands:…)`, into a texture at clip size. |
| Particles | The same; its draw was split out of the `MTKViewDelegate` for it. |
| Silicon | `SCNRenderer` with its own depth texture; the tour is a function of time. |
| Halo | `ImageRenderer` of its `colorEffect` shader, uploaded into a texture. |
| Radial, Spectrum | Their layer views offscreen at 540 pt, scaled 2×, drawn by `CARenderer` into a texture, cleared first each frame (`CARenderer` draws over what's there). |

Checked by `ClipTests.everyOfferedVisualizerMakesAClip`, which renders each
one and requires its last frame to show more than the background, and by eye
on those frames (2026-11-14).

## Options

- **Shape**: Square · Wide (1728 × 1080, 16:10). Remembered.
- **Length**: 6 s · 15 s · 30 s. Remembered. 15 s to start. No more than
  30 s (see Music rights).
- **Which part**: the strip above.

## Size and length

| | Square | Wide |
| --- | --- | --- |
| Pixels | 1080 × 1080 | 1728 × 1080 (16:10) |
| Frame rate | 60 | 60 |
| Video | H.264 High, 8 Mbit/s (12 for Liquid Light, Silicon, Particles) | the same |
| Audio | AAC-LC stereo 48 kHz, 256 kbit/s | the same |
| 15 s | about 15 MB (22 MB) | the same |

- **Square by default.** It shows whole in every feed (X, Mastodon, Bluesky,
  Instagram's feed, Threads, Discord, Messages) without being cropped, and on a
  phone held upright it's the biggest a sideways-shaped picture gets.
- **Wide is 16:10**, the Mac window's shape and the website showcase's
  clips.
- **The cap is 1080 pixels tall.** Feeds re-encode to 1080 or below, so more is
  bytes nobody sees. Wide at 1728 is 1080 tall; 1920 × 1200 is past the cap.
- **No portrait 9:16 for now.** The visualizers are drawn for wide and square
  windows; tall would need each one re-framed. Possible later as a third shape.
- **15 s to start.** Long enough for a phrase of a tune, short enough that
  feeds autoplay it and the file stays small. 6 s for a loop, 30 s at most
  (about 30 MB, or 45 MB).
- **H.264, not HEVC.** Both encode at the same speed here (below), but H.264
  plays everywhere a link preview might show it; the services re-encode anyway.
- **The bitrate is measured, not picked**: the lowest whose SSIM against a
  ProRes master is 0.98 or more. 8 Mbit/s, except Liquid Light, Silicon and
  Particles, which get 12 (Bitrate, below).

### Bitrate

Measured 2026-11-14 (`ClipBench.bitrates`, run with
`TEST_RUNNER_CLIP_BENCH=1`): each visualizer's 15 s of Commando from 0:20,
in both shapes, rendered as a ProRes 422 HQ master and re-encoded through the
clip's own H.264 settings (`ClipWriter.videoSettings`) at 4–12 Mbit/s. The
score is luma SSIM, computed as ffmpeg's `ssim` filter does (8 × 8 windows
4 pixels apart), over every third frame. Mean SSIM, the lower of the two
shapes:

| Mbit/s | 4 | 6 | 8 | 10 | 12 |
| --- | --- | --- | --- | --- | --- |
| Halo, Radial, Sound Map, Notes, Nimbus | 0.992+ | 0.993+ | 0.994+ | 0.994+ | 0.994+ |
| Ferrofluid | 0.982 | 0.987 | 0.989 | 0.991 | 0.992 |
| Spectrum | 0.979 | 0.987 | 0.991 | 0.993 | 0.994 |
| Ink | 0.978 | 0.985 | 0.988 | 0.989 | 0.990 |
| Terrain | 0.968 | 0.978 | **0.984** | 0.987 | 0.989 |
| Particles | 0.871 | 0.904 | 0.923 | 0.935 | 0.944 |
| Silicon | 0.895 | 0.910 | 0.920 | 0.929 | 0.935 |
| Liquid Light | 0.769 | 0.794 | 0.826 | 0.852 | 0.873 |

- **8 Mbit/s** is the lowest that keeps nine of the twelve at 0.98 or more;
  Terrain in Wide sets it (0.984, worst frame 0.981). A 15 s clip is about
  15 MB.
- **Liquid Light, Silicon and Particles** don't reach 0.98 at any rate
  measured: Liquid Light's swirls, Silicon's grain and glints as the camera
  moves, and Particles' thousands of points are fine detail moving
  everywhere. They gain about 0.01–0.03 per 2 Mbit/s, so 0.98 would take
  20 Mbit/s or more for Liquid Light and far more for Silicon. They get 12,
  the most measured (about 22 MB for 15 s). Liquid Light at 4 and 6 Mbit/s
  came out at 10–12.5 MB anyway: the encoder can't get that low.
- Whether those three look worse is for eyes, not SSIM: the feeds re-encode
  every upload to well below 8 Mbit/s anyway.

## What's burned in

A card at the bottom left, over a dark gradient that runs up from the bottom
edge (so it reads on Nimbus's pale sky too):

    Commando                                  (SF Pro Display, bold)
    Rob Hubbard                               (SF Pro, regular)
    useresonance.app/t/Xk3mR9_aQ2bF           (SF Mono, the accent's tint)

and the Resonance mark (icon and name, small) at the bottom right.

- **The link is the tune share's** (`PlayerStore.prepareShare`, which works it
  out on the Mac from the tune's MD5; it contacts nothing). It's shown without
  `https://`, which nobody types. `?s=<n>` is added only for a subtune other
  than the start song, as Share… does; HVSC's `&v=` is left off the picture
  (the full link, with it, goes in the message text and the file's metadata).
- **SF Mono for the code**, because it's 12 case-sensitive base64url characters
  someone may type off a phone: SF Mono tells l, I and 1, and 0 and O, apart.
- **On for the whole clip**, so any frame someone grabs carries it.
- Size from the clip's height: the title is 4.4 % of it (48 px at 1080), the
  composer 2.8 %, the link 2.2 %, with a 4.4 % margin. Never under the
  visualizer's middle: the card keeps to the bottom 22 %.
- **Not from HVSC** (prepareShare returns nil): the title and composer from the
  file's header, and `useresonance.app` in place of a tune link.
- **No share server in this build** (`SharedTuneLink.shareBase` is nil): the
  same as not from HVSC.
- Not shown: the release line, chip model, the transport, the voice chips, the
  pointer. They're Now Playing's controls, not the picture.
- Metadata: title `Commando`, artist `Rob Hubbard`, the comment the full
  `https://` link, copyright the header's release line (`1985 Elite`), date
  its year (`1985`), description the HVSC path
  (`HVSC /MUSICIANS/H/Hubbard_Rob/Commando.sid`, so the tune can be found
  without the share server; left out for a tune outside the collection), and
  the encoder "Resonance <version>". Nothing else: the subtune, chip model,
  clip start and visualizer are trivia the link already leads to. An .mp4
  keeps only iTunes-style tags (`iTunesMetadataSongName`, `…Artist`,
  `…UserComment`, `…Copyright`, `…ReleaseDate`, `…Description`,
  `…EncodingTool`); the common and QuickTime identifiers are dropped without
  an error, which is how the first build's clips came out with none (checked
  with ffprobe). The tags survive Messages, Mail and AirDrop, which send the
  file as it is; services that re-encode an upload (WhatsApp, the social
  sites) strip them, so the link is burned in as well.

## How the frames are made

Three ways were looked at. Measured on an M5 Pro (macOS 27.0.1); scripts in
`bench/` (`bench/run.sh` runs them all).

### Chosen: offline, into the encoder's buffers

When the clip starts rendering, a second libsidplayfp instance (the engine and chip the player
uses, reSIDfp or SIDLite-direct) is built on a worker thread, like a seek's
(`residfp_player::Seeker`). It runs silently to the pre-roll's start, then in
steps of one video frame (800 samples at 48 kHz): each step renders the audio
and reports the chips' state and scope samples, as the output callback does
(`Report::capture`), into a feed of its own. The visualizer's renderer, a
second instance at the clip's size, draws that step into a pixel buffer from the
writer's pool, and both go to `AVAssetWriter`.

Measured, with a stand-in shader of about a millisecond a frame, 15 s at 60 fps:

| | H.264 | HEVC |
| --- | --- | --- |
| 1080 × 1080 | 1.96 s, 7.7× real time, 18.2 MB | 2.03 s, 7.4×, 19.8 MB |
| 1728 × 1080 | 2.95 s, 5.1×, 18.2 MB | 3.08 s, 4.9×, 19.5 MB |
| 1920 × 1200 | 3.60 s, 4.2×, 18.2 MB | 3.73 s, 4.0×, 18.3 MB |

(12 Mbit/s for these; 30 fps at 1080 × 1080 was 15× real time.) The video goes
straight from the GPU to the hardware encoder: the renderer draws into a
`CVMetalTextureCache` texture over the pixel buffer's IOSurface, so there's no
read-back.

The visualizers themselves cost less at clip sizes than full screen: 1080 × 1080
is 20 % of a 3024 × 1964 screen's pixels, and the dearest per-pixel ones are
3.6 ms (Ferrofluid) and about 5 ms (Sound Map) full screen. The emulation is
about 27 ms per second of tune (design/scrubbing/README.md), so 15 s is 0.4 s of
CPU. All told a 15 s square clip should take 3–4 s; the bench in the build
measures each visualizer to confirm.

How each kind of visualizer draws offline:

- **Metal renderers** (Notes, Terrain, Ink, Liquid Light, Ferrofluid, Nimbus,
  Sound Map) already draw into any texture through `render(width:height:…)`,
  which the tests use. The clip passes the pixel buffer's texture instead.
- **Particles** drew only in its `MTKViewDelegate`; it got the same
  `encode(into:commands:…)` split the others have.
- **Halo** (a SwiftUI shader): through `ImageRenderer` at the clip's size,
  then into a texture. Measured with a `colorEffect` like Halo's at
  1080 × 1080, read back into a bitmap: 1.1 ms a frame, on the main thread.
- **Radial and Spectrum** turned out to be layer-backed views, not Canvases:
  they're built offscreen at 540 pt, scaled 2×, and `CARenderer` draws the
  layer tree into a texture, cleared first each frame. So they're laid out at
  clip size in points, not stretched pixels.
- **Silicon** (SceneKit): `SCNRenderer` into the pixel buffer's texture with
  `render(atTime:viewport:commandBuffer:passDescriptor:)`, the scene's time
  the clip's. Its tour is a function of time, so the clip shows the same
  camera the window did at that moment.

**Quality**: offline there's no frame budget, so `VisualizerQuality` is held at
full, whatever the window was at.

**Time**: in a clip, every visualizer's clock is the tune's own time. A clip
of the tune's start opens on the start of each tour (Silicon's run low along
the package, then up and over it), and the same part of a tune always gets
the same shots, which a shared clip should. It doesn't follow the window,
whose tours run on the Mac's clock (Erik, 2026-11-14: a clip of the start
should show the start). Two things on the way: the first build took "the
screen's time when the tune was there", which put the camera at an arbitrary
point of the tour; and SceneKit commits node changes at the end of a run-loop
turn, so Silicon drew each frame with the previous frame's camera and every
clip's first frame with the scene's starting one, until the painter flushed a
transaction around its update (`ClipTests.theSamePartGetsTheSameShots`). The
smoothers never step backwards in time, since a clip's dates come before the
`.now` its views were set up at. Renderers
that take a `clock` get the clip's; ones that read the feed
read the offline feed with synthetic instants. The feed's reads already map an
`Instant` to a position (`VizFeed::playhead`); the offline feed sets output
latency and the fine-tune offset to zero and anchors its playhead so instant
*k* is frame *k*. No read API changes for the views' renderers.

**Pre-roll**: before the clip's first frame, each visualizer runs (drawn, not
encoded) from a little earlier in the tune. There are two kinds:

- **Short memory** (fast rise, slow fall): long enough for what it remembers
  to fade below half an 8-bit step, 1/510 of full, so the first frame looks as
  the screen did. That's ln 510 ≈ 6.2 time constants of its slowest smoothing.
  Ferrofluid's slowest is the pull sinking (`FerroField.sink`, 0.28 s): 1.7 s,
  so 2 s.
- **Builds up** (Ink, Liquid Light, Nimbus, Sound Map): matching the screen
  would mean replaying up to a minute (Ink's dye halves in about 3 s, so 27 s;
  Liquid Light's in about 8 s; Sound Map's map and Nimbus's churn add up from
  the tune's start). Instead they start fresh, with a fixed 2 s lead-in, and
  the clip shows them growing, which Erik prefers. The 2 s is so the first
  frame isn't an empty glass or an empty sky: many feeds show the first frame
  before the clip plays.

| Visualizer | Remembers | Pre-roll |
| --- | --- | --- |
| Notes, Silicon | nothing (time only) | 0 |
| Terrain | 4 s of rows | 4 s |
| Ferrofluid | pull sinks with τ 0.28 s | 2 s |
| Ink, Liquid Light, Nimbus, Sound Map | builds up | 2 s, then grows through the clip |
| Halo, Radial, Spectrum | fast rise, slow fall, under 1 s | 1 s |
| Particles | where its particles were sent (never settles) | 2 s |

Pre-roll is cut short by the tune's start. At most 4 s, so it adds well under
a second to a render.

**Measured** (2026-11-14, `ClipBench.leadIns`, Commando from 0:30, square):
the first frame after each lead-in against one after 20 s of lead-in, as the
mean difference in 8-bit levels above the card, and luma SSIM. The same render
twice differs by 0.000, so renders are repeatable.

| Lead-in | 0 | 0.5 s | 1 s | 2 s | 4 s | 8 s | 16 s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Terrain | 34.8 | 28.4 | 22.8 | 16.3 | 11.6 | 10.5 | 12.0 |
| Ferrofluid | 23.8 | 1.57 | 0.09 | 0.62 | 0.66 | 0.80 | 0.59 |
| Halo | 18.2 | 12.3 | 11.6 | 10.7 | 11.3 | 10.2 | 8.8 |
| Radial | 13.5 | 0.50 | 0.45 | 0.37 | 0.41 | 0.59 | 0.68 |
| Spectrum | 29.3 | 3.59 | 3.03 | 3.65 | 3.92 | 3.40 | 3.4 |
| Particles | 13.2 | 16.1 | 16.4 | 16.3 | 16.1 | 15.7 | about 16 |

- What a lead-in can fix stops changing by 4 s for Terrain, 1 s for
  Ferrofluid and 0.5 s for Halo, Radial and Spectrum. So Terrain's 4 s and
  Ferrofluid's 2 s stand, and Halo, Radial and Spectrum went from 2 s to 1 s
  (which halves the slowest stills, below).
- What's left (Terrain and Halo about 10 levels, Spectrum about 3.5) doesn't
  shrink with a longer lead-in, even 16 s against 20 s: it comes from where
  the engine starts, not from what the visualizer remembers. Clips no longer
  try to match the window, so that's fine.
- Particles never settles: its particles go wherever the voices sent them.

### Not chosen: ScreenCaptureKit on the app's window

- **Permission.** An `SCStream` of the app's own window still needs Screen
  Recording (TCC asks, and System Settings › Privacy & Security lists it). Since
  macOS 15 the system also asks again from time to time whether to keep allowing
  an app that captures without the system picker. Going through
  `SCContentSharingPicker` instead avoids the standing permission, but the person
  then picks the window in a system picker every time. Both are a lot of
  ceremony for "share what's on screen". (From Apple's documentation and WWDC23
  and WWDC24 sessions; not tried here, to keep a permission prompt off this Mac.)
- **It's the window**, at its size and shape: the clip would be the window's
  aspect, cropped for square, scaled for 1080, with the controls in it unless
  they hide (and they come back whenever the pointer moves).
- **Real time only**: 15 s takes 15 s, after you press the button, so it can't
  be the moment you just heard.
- **Sync** would need its audio too: SCK can capture the app's own audio
  (`capturesAudio`), but that's the mixed output after the volume slider, and
  each stream has its own clock, so the offset between them has to be worked
  out from timestamps.

### Not chosen: live offscreen while it plays

A second renderer during playback, drawing the same feed at clip size, with
the audio tapped in the output callback (`Source::render`, stamped by
`live.samples`). Sync would be as exact as offline. But it's real time, it
either records forward after the button (not the moment you heard) or always
keeps the last 30 s (two renderers and an encoder running all the time, which
undoes "Less CPU while a tune plays"), and every hitch in the window's frame
timing is in the clip.

## Audio and sync

- **The engine's own samples**, not a loopback. The offline engine is the
  player's engine, chip and sampling method, so the clip sounds as the player
  does. No device, no BlackHole, no capture permission.
- **Unity gain**: the volume slider doesn't apply. The player's 10 ms fade
  (`FADE`) is used at the clip's two ends so they don't click.
- **Sync is by construction.** Video frame *k* and its audio both come from
  samples *800k* to *800(k+1)* of the same engine, and are stamped from that
  count: video at k / 60 s, audio at the first sample's index / 48,000.
  There's no latency in the file: output latency and the feed's buffer model
  are about the speakers, and offline there are none.
- **Measured** (`bench/sync.swift`): a white frame and a 1 ms click stamped on
  the same frame every half second, encoded, then decoded with ffmpeg. Flashes at
  0.116667, 0.616667, 1.116667, 1.616667 s; clicks at 0.11667, 0.61667, 1.11667,
  1.61667 s. Zero offset, so AAC's priming samples are handled by the writer's
  edit list (both tracks start at 0.000000).
- **Measured in the build** (`ClipTests`, the tests in `clip.rs`):
  - The C64 waits a random 0–8191 cycles between power-on and the tune's
    init (design/scrubbing). A clip borrows the playing track's delay, so it
    sounds like what you heard; a tune that isn't playing keeps the delay its
    first clip drew, so its clips agree with each other.
  - Two clips from the same start differ by at most 2 LSB (reSIDfp's dither).
  - A clip from 2 s against the tune rendered from 0: best aligned 3–4
    samples (0.06–0.08 ms) late, with a mean difference of 0.003–0.009 there
    against 0.10 a hundred samples away. That's the filter and resampler
    settling after the skip, a fraction of one 16.7 ms video frame.
  - The clip's feed gets one frame per C64 frame (49–50 a second): the render
    splits at C64 frame boundaries as well as at video frames.
- **The writer interleaves its inputs**, and either one stops taking data
  while the other is behind. Waiting on the video input before handing it the
  frame's audio deadlocked on the first frame, so frames and audio queue (up to
  2 s) and go in as each input takes them; ten seconds without progress is an
  error, not a hang.
- A sample rate of 48 kHz whatever the output device runs at, so 800 samples
  is exactly a 60 fps frame.

## Music rights

Every clip carries 15 s of someone's tune. Posting a short credited excerpt is
how the scene has always passed music around, but the app is still making it
easy to redistribute HVSC audio. That's the same care as elsewhere (the SID
model research stays private, CSDb waits for its admins), so clips follow
three rules:

- **Short.** 6, 15 or 30 s, never over 30 s. No whole-tune export, and no audio-only export: a clip is a
  picture with its sound, not a way to rip the tune.
- **Always credited.** The title and composer are burned into every frame and
  can't be turned off, and the file's metadata names them too. A tune without a
  composer in its header says so ("Unknown composer"), rather than leaving the
  line out.
- **Pointed home.** The burned-in link goes to the tune's page, which credits
  the composer and HVSC and offers the app; it doesn't host the audio.

Nothing is uploaded: the clip goes wherever the person sends it, as a
screenshot would. Whether HVSC's team should hear about it before clip sharing
leaves the experimental tier is Erik's call; it would be a courtesy, not a
condition, since the tunes' rights are their composers', not HVSC's.

## Feature flag

**Experimental**, `clipSharing` in `FeatureFlags.swift`, so Debug and alpha
builds have it and beta and final don't:

- It contacts no one: the link is worked out on the Mac and the file is shared
  through the system. Nothing needs anyone's permission, so not restricted.
- It's unfinished in ways testers should try: the bitrate, the lead-ins and
  how slow Macs cope.
- Music rights (above) want a look before it reaches beta.

Only the way in is behind `#if ALPHA`: the Share Clip… button (either row)
and the menu command (Erik: "only to disable the button in production"). The
sheet, the renderer, the painters, the encoder and their tests compile in
every build. Its line in `scripts/feature-markers.tsv` is the button's help
text, `Share a video clip of this visualizer`, which only the button has.
`shipsWhen`: "Clips of every offered visualizer pass the bitrate and lead-in
checks on a slow Mac, and Erik has click-tested the sheet."

## To settle

- Whether Liquid Light, Silicon and Particles at 12 Mbit/s look right
  (SSIM says they're below 0.98; see Bitrate).
- A slow Mac (an M1 Air): the time for a 15 s square clip.
- The click-test: the sheet, the strip's drag and snap, and the button's
  placement at widths around 920 pt.
- Whether the sheet's still should be a short looping preview instead (a
  second of frames). Started with the still.

## Not part of this

The website and its social card are the other session's. Clip sharing doesn't
upload anything or use the share server; a clip goes wherever the person sends it.
