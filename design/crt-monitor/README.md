# The monitor: a 1084S easter egg

Built and click-tested 2026-11-08: `apple/Resonance/Views/MonitorView.swift` (the case and the renderer), `apple/Resonance/Model/MonitorScreen.swift` (the glyphs, the frame, the boot and the player screen) and `apple/Resonance/Shaders/Monitor.metal` (the mockup's shader, line for line). About Resonance shows the monitor under its buttons, off; its power button starts it there, in place, and closing About switches it off. The keys go through `AppKeys.handleInMonitor` while About is in front. The case image in the app is still the reference photo below with its white cut out ([1084s.png](1084s.png)), as a placeholder in `Assets.xcassets/Monitor1084S`.

A Commodore monitor stands in the app, switched off. Press its power button and the tube warms up, a C64 boots, loads `RESONANCE` and runs it: a 40×25 PETSCII-style player showing what the app is playing, live, and answering the app's own keyboard shortcuts. Press the button again and the picture collapses to a line, a dot, and fades.

[mockup.html](mockup.html) is the reference, built with three.js. It needs a web server (the `design-mockups` entry in `.claude/launch.json` serves this folder on port 8643, or `python3 -m http.server --directory design`) and the network, for three.js from jsdelivr. The case in the mockup is the same 1702 render the app uses, [monitor-1702.png](monitor-1702.png) (see "The case" below). The mockup began with a photo of a 1084S, which is why the measurements below speak of one.

Nothing in the mockup is click-tested by Erik yet. It was driven in the browser pane: power on, boot, the player, the keys, power off, and the picture's colors were read back from the canvas.

## The case (2026-11-08): a rendered Commodore 1702

The case is [monitor-1702.png](monitor-1702.png), a still render of the 1702 from "Commodore 64 || Computer (Full Pack)" by dark_igorek on Sketchfab, CC BY 4.0, the model c64ready.com uses for its Retro Vibes scene and serves as `https://c64ready.com/models/commodore_64.glb` (18.7 MB; a 4K-texture build is beside it at 100 MB). Erik: "use the 3D models from these guys." The pack also holds the breadbin, a 1541, a joystick, cables and the power brick. The credit is in the acknowledgments.

[blender/render.py](blender/render.py) makes the render: Blender 5.2, Cycles on the GPU, 96 samples, film transparent; only the monitor's meshes (`Object_17`, `_18`, `_19` the screen, `_21`), an 85 mm lens 2° above the screen's center, the case at 64% of a 2400×2000 frame, one big soft key light front-top-left, a fill from the right, a rim from behind, a gray world. About two minutes. Run it as

    /Applications/Blender.app/Contents/MacOS/Blender -b --python design/crt-monitor/blender/render.py -- commodore_64.glb monitor monitor-1702.png

with the GLB fetched from c64ready (it is not in this repository). The script also prints the screen mesh's corners in the image. `render.py ... c64 c64.png` renders the breadbin from 22° above, for the day it comes back.

Measured on the render: the visible glass 546–1854 × 384–1342 with corners of about 80 px (the mesh's bounding box projects to 519–1881 × 372–1355, a little wider than what shows, as the tube curves back); the power light, a 32×14 bar on the badge strip at (1371,1572), unlit in the render and drawn lit over it; the brown POWER rocker at 1967–2030 × 1565–1623 with its label under it, the button's zone 1930–2070 × 1540–1670; the sticker a 260-px square at (330,150) on the black bezel, its corner over the glass. The case spans 308–2092 × 176–1877.

What came before it: HomeComputerMuseum's photo of a 1084S-P, found on their collection pages (all rights reserved; the request for permission is no longer needed), and for an hour Gestumblindi's CC BY-SA 4.0 Commodore 1084 from Wikimedia Commons, seen a little from the side with the glass mapped as a perspective quad through a homography, which Erik had reverted: the straight-on view was the better one. Its measurements, should a turned tube return: the glass's corners (880,495), (3125,440), (3115,2085), (885,2100) on the 3834×2938 photo, flattened about 2238×1625 with 70-px corners; the case's front (660,232), (3445,192), (3405,2635), (668,2562).

**Live 3D, decided and deferred (2026-11-08).** Erik chose, among a still render of the breadbin, renders per pressed key and the model live in the app, the live one: the three machines in SceneKit from a USDZ exported by Blender, the CRT rendered to a texture on the `Object_19` screen mesh, keycaps sunk by a geometry shader modifier (c64ready's `keycap-press.js` has each cap's center in the keyboard mesh's space), the camera gliding to the monitor on power as c64ready's "virtual fullscreen" does, the power button hit-tested in 3D. Then he set it aside for the MVP: the still render above, and nothing else for now.

## What was measured, and from where

From the reference screenshot of a C64 screen (2000×1533, the whole tube face):

- **Two colors, nothing else.** Background `#654db6`, border and text `#9e8be1`. The text's brightest pixel reads `#b09af8` and its average `#9983e2`: on a CRT a thin stroke comes out a little darker than a flat field of the same color and glows around its edges. The mockup gets the same effect from the halation term below, and its flat fields land on the two colors within two levels.
- **The frame is 384×272 with 320×200 inside at (32,36).** The border takes 8.9% of the width and 13.2% of the height in the reference; 32/384 and 36/272 are 8.3% and 13.2%. Every cell is 8×8 and nothing is drawn between cells.
- **Barrel curvature.** The raster's top edge sits 35 px lower at the corners than at the middle, on a tube 1431 px tall. A lookup distortion `q *= 1 + k·|q|²` reproduces that bow at `k ≈ 0.07`, with `|q| = 1` at the raster's edge.
- **Scanlines are one per C64 line, and shallow.** The border's brightness along a column swings ±7% with a period of 5.6 px, which is the 1533 px height over 272 lines. A Gaussian beam with σ = 0.4 of the line pitch gives ±7% (its first harmonic is `2·exp(−2π²σ²)`). The beam is a little wider where it is bright (×0.85 to ×1.2 with luminance), as on a real tube.
- **No vignette to speak of.** The border reads the same at the edges and the middle of the reference; the mockup darkens the corners by 8% at most.

From the photo of the 1084S (1200×900):

- **The glass** runs from x 278 to 863 and y 178 to 632, with corners of about a 30 px radius, so 585×454: four by three, give or take. Around it the 1084S has a dark recessed frame, 60 to 90 px wide on the top and sides and none at the bottom. The app and the mockup draw the tube 12% larger, out into that recess (x 240 to 895, y 145 to 632), because the case is small in About and the recess is a uniform dark gray; nothing else in the photo moves.
- **The bezel's shadow** reaches about 50 px into the glass on each side, so the glass darkens toward its rim.
- **The power LED** is the 8 px dot at (874,709), with POWER under it. The photo's LED is unlit gray-green; lit, it's green. The mockup's power button is the area around the LED and its label. The real 1084S has its switch at the back right, which no one would find; the label is the button.
- **The glass when off** reads `#58595f` to `#676d71` in the studio-lit photo. The mockup's room is dimmer: `#2b2d30` to `#424548`, lighter at the bottom, a soft highlight top left and a broader one bottom right.

## How the tube is drawn

One fragment shader over the glass, with the photo behind it. In order:

1. **Glass shape.** A rounded rectangle with the measured corners, antialiased over one device pixel against the photo. Outside it, a little of the picture's light spills onto the bezel (half the picture's mean luminance, falling off over 12 px).
2. **Geometry.** Glass coordinates to raster coordinates: the raster fills 93% of the glass, the barrel term above, then the power animation's horizontal and vertical scale, then the warm-up wobble.
3. **The picture.** The 384×272 frame is a texture with mipmaps. Horizontally each texel is drawn crisp with a one-pixel edge (the pixel-art trick: snap to the nearest texel boundary, blend across one pixel's footprint), then softened by three taps 0.4 texel apart (0.18, 0.64, 0.18) for the monitor's video bandwidth. Vertically the four nearest lines contribute through the beam's Gaussian, whose width is the beam's σ combined with the pixel's own footprint (σ² + w²/12), so the scanlines fade out instead of aliasing when there are fewer than about two device pixels per line. When the beam is defocused (σ above 0.6, during warm-up) the weights are normalized so the picture doesn't dim as it blurs.
4. **Halation.** 10% of the picture blurred over 8 texels plus 5% blurred over 32 (mip levels 3 and 5), reaching 5 texels past the raster's edge; the sum is divided by 1.15 so a flat field keeps its color. This is what makes text glow and read slightly darker than the border.
5. **Shadow mask.** The 1084S's 0.42 mm pitch is 1.1 photo px, so at the mockup's size it is below the pixels and is left off; it fades in (RGB stripes, up to 22% deep) only once a triad covers 2.5 to 6 device pixels, as on a very large window.
6. **Noise.** 3% per-pixel brightness noise and a quarter-texel horizontal jitter per line, new each frame: composite video is never quite still.
7. **Phosphor.** Anything driven past white goes white: 80% of the excess luminance is added to all channels. Only the power-off line and dot reach that.
8. **The glass again.** The dark glass with its reflection is added at full strength when off and at 4% when the picture is on, so the picture's colors stay the reference's and the reflection is still faintly there in the black beyond the raster.

### Power on

The LED lights at once. The tube shows nothing for 1.0 s (heaters). Then over 0.7 s the raster opens vertically from 3% with an ease-out, and from 90% horizontally; brightness ramps up over 0.45 s and overshoots by 22% before settling over 1.8 s; the beam starts defocused (σ 0.95) and sharpens over 1.4 s; a horizontal shimmy of 1.2% decays over about a second (the deflection and degaussing settling). The boot text appears as the raster opens, as on a real C64 that was already running when the monitor came on.

### Power off

The LED goes dark at once. Over 0.12 s the raster collapses vertically to a line while its brightness rises to 2.4× (the beam's energy on fewer lines), over the next 0.33 s the line shrinks to a dot, and the dot fades with a 0.55 s time constant. Everything shown is the frame's own light: the collapsed line is the picture's average color, driven to white by step 7.

These are plausible figures for a 1980s tube, not measurements of a 1084S. If someone has one, a phone video of it switching on and off would replace them.

## What the screen shows

The boot: `**** RESONANCE 64 SID PLAYER ****`, `64K RAM SYSTEM  63165 SID TUNES FREE` (the collection's tune count), `READY.`, then `LOAD"RESONANCE",8,1` typed at about 12 characters a second, `SEARCHING FOR RESONANCE`, `LOADING`, `READY.`, `RUN`. The cursor blinks at the C64's 3 Hz. Any key skips to the player.

The player, in 40 columns and two colors; reverse video is the only emphasis:

| Row | Content |
|---|---|
| 0 | `RESONANCE 64` … `SID PLAYER`, in reverse |
| 2 | The list's name (`RECENTLY PLAYED`, `SURPRISE ME`), and its count |
| 3–12 | Ten rows of the list around the selection; `>` marks the selection, the playing row is in reverse |
| 14–17 | `PLAYING`, `BY`, `YEAR` (HVSC's released field), `SONG n OF m`, `TIME mm:ss / mm:ss` |
| 18 | A 36-cell progress bar, solid blocks over a checker pattern |
| 20–22 | The three SID voices: waveform name, a 30-cell level with a peak marker |
| 24 | `PLAYING`/`PAUSED`/`STOPPED`, the volume in ten cells, `SHUFFLE` when on |

The glyphs are our own 8×8 set in the spirit of the C64's upper-case font, as a hex table in the mockup. The Commodore character ROM is not ours to ship, and the app shouldn't carry it; the table moves into the app as it is. Accented letters are drawn without their accents, lower case as upper.

In the mockup the data is a simulation over a dozen tunes from Recently Played and voices that fire on a sixteenth-note grid. In the app:

- the list, the playing row, elapsed, duration, the subtune and the state come from `PlayerStore` (`queue`, `currentIndex`, `nowPlaying`, `elapsed`, `duration`, `state`, `queueSource`), the volume from Preferences;
- the three voice levels and waveform names come from `VisualizerFeed`, the same frames the visualizers use;
- the keys are the app's own: the monitor's window forwards every `KeyAction` to the existing handlers and only redraws. Both the normal and the vim sets work in the mockup; emacs needs nothing extra once the app does the handling.

## Building it in Metal

One `MTKView` over the glass region of the case image, with the photo as a plain `Image` behind it, and the shader above ported line for line (it is plain GLSL ES 3.0 with `textureLod`, `fwidth` and nothing else): one quad, one fragment function, uniforms for time, the three animation parameters (scale x and y, brightness), focus, wobble, ambient and the collapse flag. The view is transparent (`layer.isOpaque = false`, premultiplied alpha), clears to transparent, and draws at the display's scale factor; the shader needs the device pixels per photo pixel, as the mockup's `uPx`, for its edge, scanline and mask footprints.

The 384×272 frame is drawn on the CPU each frame it changes, from the glyph table into a `CGContext` with hard pixels, and uploaded as a texture with mipmaps (`MTLBlitCommandEncoder.generateMipmaps`). It is 1000 glyph blits at most; a tick at 60 Hz is nothing.

The size matters more than anything in the shader. The text reads at two device pixels per texel and no fewer: a 384-texel raster needs 768 device pixels, so the glass needs about 826 and the whole monitor about 850 points wide at 2× (1700 at 1×). The About window is 340 points wide, so a monitor in it would be ornamental.

**The sticker (2026-11-08, approved).** About's icon moved onto the bezel as a sticker of the app icon, top left, a corner over the glass, 100 photo pixels wide and five degrees crooked. It is drawn in code (`IconSticker` in MonitorView.swift): a yellowed paper edge, the print faded and warmed, a crease with its shadow and highlight, scratches and scuffs from a seeded generator so they never change, a lifting corner, and a trace of gloss. Erik asked for it large and old-school grungy with a small wrinkle.

**The breadbin (2026-11-08, built, tried, taken out).** Erik's brainstorm idea, built with a photo he supplied (a product render of unknown origin, not kept in the repository): it slid in under the monitor, typed the boot on its keys and pressed the C64 key for each app key. Seen on the desk, the typing looked wrong (dark rectangles over a photo in perspective), and Erik took it out: "else a real 3D model of the breadbin". So it waits for a render from the CC BY model (below). The key map measured from the photo, should it come back: four rows with their caps centered at y 197, 219, 242 and 266 of the 551-px photo, standard keys 27×18 at a 32-pixel pitch starting at x 118 (←), 160 (Q), 168 (A) and 180 (Z); CTRL 100–141, RUN/STOP 87–118, SHIFT LOCK 120–151, C= 84–115, the left SHIFT 120–165, the right 490–541, CLR/HOME 553–582, INST/DEL 585–614, RESTORE 568–612, RETURN 545–610, CRSR 548–582 and 585–620, the space bar 165–475 at y 294, f1 to f7 at x 655–697, y 197 to 266, the power LED at (660,158), and the case's drop shadow from y 419. The mapping of app keys was: Space; CRSR right and down, with SHIFT for back and up; RETURN; + and −; RUN/STOP for stop and Esc; CLR/HOME for the top; S and R for shuffle and Surprise Me.

**Size in About (2026-11-08, Erik's calls after seeing it small, then with the breadbin; approved as "super smooth").** About is 440 points wide. Off, the monitor stands 320 points wide at the top where the icon was. Switched on, the About window itself grows, over 0.7 s with Core Animation, to three quarters of the screen's visible height and 1.1 times that wide (capped at 90% of the screen's width), centered on the screen; About's text fades out and the monitor grows with the window to 96% of its width, centered vertically. The layout is computed from the window's live size, so it is one motion; the first version did it in three steps (window, layout switch, monitor) and looked chunky. When the picture has collapsed and the dot faded, the window shrinks back to the frame it had and the text returns. The window's resizability is `.contentMinSize` with the resizable style bit removed, so SwiftUI sizes it at rest and leaves it alone while it grows.

**Every opening of About is a new instance (2026-11-08, after an evening of it not being one).** Erik's rule: closing About means no instance; opening it means a clean one, the monitor off, nothing running. SwiftUI's `Window` keeps the About window and its view alive after the close button, so the view's appearance handlers, the window's close notification and its occlusion changes all proved unreliable for that, one after another, and a reset on any occlusion change even switched the monitor off while the window was growing. What holds: `AboutSession` (AboutView.swift) sits behind the About menu item, starts the monitor over, bumps a generation number and then opens the window; About's content is keyed on that number, so SwiftUI builds a new view tree with a new renderer each time, and the new instance puts the window back to its resting frame before it shows. Three more guards stay underneath: the model starts over by itself when its drawing pauses for half a second (the renderer draws only while About is on screen); at About's small size the monitor can only be off (half a second of grace after a power press, for the grow); and the power button's lock is a deadline, not a flag, so a window animation that never reports its end can't wedge it.

**Decided (2026-11-08), after click-testing the window version: in About, in place.** Erik tried the separate `Resonance 64` window and wanted the monitor to simply start where it stands, small, with nothing opening; the text is then texture rather than reading matter, which is the point of an easter egg. The window is gone. The monitor fills About's width (284 points), keeps its state while About is open, and is off again next time, as a real one left unplugged.

Still to decide: whether the boot sequence runs every time or only the first; whether pressing POWER makes the 1084S's click and degauss thump (there is no sound anywhere else in the UI); and whether the screen should also show the `Under the Hood` tracker page as a second program (`LOAD"TRACKER",8,1`), which would be the natural next page.
