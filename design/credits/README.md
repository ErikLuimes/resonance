# Credits page

Both are built: the app's in `apple/Resonance/Views/CreditsView.swift`, opened from About Resonance and the Help menu, and the terminal app's in `apple/cli/src/credits.rs`. [intro-mockup.html](intro-mockup.html) is the reference: open it in a browser. It's one self-contained page that loops. It has no sound and no connection to the app, so the voices and the tune named at the end are stand-ins.

## The sequence

The window is a 320×200 picture scaled up with hard pixels: a starfield with a vignette, and flat white vector letters with hard edges.

1. `THANKS FOR LISTENING TO` passes right to left, calm and readable. The stars drift the opposite way.
2. The camera starts moving as the last word arrives.
3. `RESONANCE` arrives and the letters start turning slowly. It's the camera that makes it hard to read.
4. `WE WOULD LIKE TO THANK THE FOLLOWING PEOPLE` passes in the same motion.
5. With the text offscreen, the stars settle.
6. The credits play as flat text over the normal star flight, independent of the stars.

## What was decided

- **The letters are part of the stars' 3D scene.** They never land in front of the camera. The camera moves past them.
- **The stars** are the Starfield theme's flight, from `ThemeBadgeView.swift`. Leave the flight and the vignette alone.
- **The rotation stays slow.** Fast letter rotation was tried and rejected.
- **The letters are super bold** and wider than tall. Our own shapes.
- **The sine scroller and raster bars were removed.** Don't bring them back unasked.
- **The stars collapsing into text**, as the demo does it, isn't wanted yet.
- **The ending:** after `AND MOST OF ALL`, `YOU`, `THANKS FOR LISTENING`, the nearest two-thirds of the stars fall into a heart, while the rest stay out there. Two in three draw its surface and every third goes inside, for body and for depth in the burst. The heart is those stars and nothing else: extra points to fill it in looked like things appearing from nowhere, and were taken out at the user's request. It beats, and after the first beat the camera starts moving again, turning and creeping forward with the heart in real 3D. On the third beat a sphere spreads from the middle of the heart. It only decides when each star starts to move: each then drifts outwards slowly at its own speed, as the camera goes through them. They're the same stars throughout: nothing fades in. Pushing every star alike across the flat picture read as a circle, and fading to a copy of the field felt disconnected. Then it all fades to black and the window closes. The music plays on. The heart's surface is from the particle hero on backtostatic.com, the user's own site (`heart()` in its `site.js`). It's the one part not in hard pixels: the app draws it at four times the size in round dots, as squares looked wrong on it. The beat is a heart at deep rest, from the user's formula: 52 a minute with a flat pause, longer and thinner as it contracts, and the gaps drift with a five-second breath. The formula's comment says it peaks at about 1.15, while the sum comes to about 1.04; it's used as the sum gives it. With Reduce Motion the heart stands still and fades. The mockups don't show this.
- **The billing:** Erik Luimes directed and Claude wrote the code, and the credits say so with funny job titles. The list is in `pages` in the mockup.

## Still to check or decide

- The engine credits are checked against the `AUTHORS` files and reSID's README. The filter's measurements are Dag Lem's, the distortion simulation Antti Lankila's, and Leandro Nini's are the transistor-level reverse engineering and the engines themselves. The mockups still show older titles.
- The last page names what's playing. It needs a fallback for HVSC's unknown composer, `<?>`, and it should follow a change of tune. If nothing is playing, Favorites starts, or Surprise Me if that can't play; something paused is left alone.
- Whether the stars react to the music. The idea was the camera speeding up slightly with the level.
- How to close it: Esc and a click, with perhaps a brief hint, as there's no button.
- With Reduce Motion on, it should show a still page.
- The mockup's stars jump when it loops. The real one just ends when closed.
- [terminal-mockup.html](terminal-mockup.html) is the terminal version as approved; it's built in `apple/cli/src/credits.rs`. The earlier cracktro idea for the terminal was dropped.

## The reference

The style comes from the text part of *Crystal Dream II* by Triton (1993): a browser port is at <https://treylorswift.github.io/demoscene-recomp/web/cd2/>. Its slide runs about 7 seconds at about 3.75 letters a second in the top third of the screen, with letters about 65 px tall near and 25 px far on the 200-row screen. Its wild part runs about 11 seconds with 2 to 4 letters of about 40 to 60 px in view.

It's a reference to watch only. The code, letter shapes and wording here are our own, and nothing from the demo should go into Resonance.

Triton gets its own page in the credits, `ALL RESPECT TO THE DEMOSCENE`, because the idea came from them. They're credited in the intro of `Acknowledgments.txt` too, from `apple/scripts/acknowledgments.sh`.
