#!/usr/bin/env python3
"""Make the website's social cards (1200 x 630) from frames of the recordings.

    python3 -I design/site-sharing/make-cards.py

Writes each card's HTML into design/site-sharing/cards/ and has Chrome save
it as a picture:
  - the site's card (design A) as apple/site/assets/og-card.jpg, with the
    other two designs kept beside the HTML for when it's swapped;
  - a card per visualizer as apple/site/assets/cards/<slug>.jpg, and its
    page, apple/site/v/<slug>/index.html: the link the site's Share copies.
    A link preview comes from the page linked, so each visualizer needs a
    page of its own; it sends people on to the showcase (#vis-<slug>).

The frames (frames/) come from the recordings: the featured three cut above
Now Playing's controls, the other nine from the bare recordings. The layouts
are the approved mockup's (mockup.html beside this file).
"""
import pathlib
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SITE = ROOT / "apple" / "site"
CARDS = HERE / "cards"
BASE = "https://erikluimes.github.io/resonance/"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# slug, name, line, frame, object-position. The lines are the app's own
# (NowPlayingVisual.summary).
VISUALS = [
    ("halo", "Halo", "A glowing ring per voice", "bare-halo.jpg", "50% 50%"),
    ("particles", "Particles", "A sphere of points that ripples with each note", "bare-particles.jpg", "50% 50%"),
    ("radial", "Radial", "A ring of spectrum bars per voice", "bare-radial.jpg", "50% 50%"),
    ("sound-map", "Sound Map", "Every note placed by how it sounds", "bare-soundMap.jpg", "50% 45%"),
    ("notes", "Notes", "The tune as sheet music, a ball hopping from note to note", "notes-6-mid.jpg", "75% 50%"),
    ("spectrum", "Spectrum", "An analyzer with each voice's curve, peaks and notes", "bare-spectrum.jpg", "50% 30%"),
    ("terrain", "Terrain", "The last seconds of the spectrum as a landscape", "bare-terrain.jpg", "50% 60%"),
    ("ink", "Ink", "Each voice pours dye into swirling water", "ink-18-top.jpg", "50% 30%"),
    ("liquid-light", "Liquid Light", "Glossy oil on a projector's glass, like a 1960s light show", "bare-liquidLight.jpg", "50% 50%"),
    ("ferrofluid", "Ferrofluid", "Black liquid that stands in spikes where a voice sounds", "bare-ferrofluid.jpg", "50% 60%"),
    ("silicon", "Silicon", "The tune's SID in 3D, opened up: the real die, at work", "silicon-14-top.jpg", "50% 20%"),
    ("nimbus", "Nimbus", "Balls of cloud that merge, swell and glow with each voice", "bare-nimbus.jpg", "50% 50%"),
]

ICON = (SITE / "assets" / "icon-256.png").as_uri()

STYLE = """
* { box-sizing: border-box; }
html, body { margin: 0; width: 1200px; height: 630px; overflow: hidden; background: #07080d; }
body { position: relative; color: #f3f4f8;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", Arial, sans-serif; }
.bg { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.shade-left { position: absolute; inset: 0; background: linear-gradient(90deg, rgba(7,8,13,.96) 0%, rgba(7,8,13,.82) 34%, rgba(7,8,13,0) 66%); }
.shade-bottom { position: absolute; inset: 0; background: linear-gradient(0deg, rgba(7,8,13,.95) 0%, rgba(7,8,13,.6) 30%, rgba(7,8,13,0) 55%); }
.brand { display: flex; align-items: center; gap: 16px; font-size: 34px; font-weight: 700; letter-spacing: -0.01em; }
.brand img { width: 64px; height: 64px; border-radius: 15px; }
.headline { font-size: 64px; line-height: 1.02; font-weight: 800; letter-spacing: -0.03em; margin: 0; }
.grad { background: linear-gradient(100deg, #3fd0e8 0%, #9b6bff 52%, #ff9a3c 100%);
  -webkit-background-clip: text; background-clip: text; color: transparent; }
.small { font: 500 22px ui-monospace, "SF Mono", Menlo, monospace; color: #a4a9bc; }
.vname { font-size: 96px; font-weight: 800; letter-spacing: -0.035em; line-height: 1; margin: 0; }
.vline { font-size: 30px; color: #c9ccd8; line-height: 1.25; margin: 12px 0 0; max-width: 900px; }
"""


def page(body):
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{STYLE}</style></head><body>{body}</body></html>"


def frame(name):
    return (HERE / "frames" / name).as_uri()


SITE_CARDS = {
    # A: Silicon, the headline on the left. The site's card.
    "site-a": f"""
<img class="bg" src="{frame('silicon-8-top.jpg')}" style="object-position: 70% 0%">
<div class="shade-left"></div>
<div style="position:absolute; left:72px; top:70px; bottom:64px; display:flex; flex-direction:column; justify-content:space-between; width:600px">
  <div class="brand"><img src="{ICON}">Resonance</div>
  <p class="headline">Every C64 tune.<br><span class="grad">Say what you'd like to hear.</span></p>
  <div class="small">A Mac player for SID music</div>
</div>""",
    # B: three visualizers side by side.
    "site-b": f"""
<div style="position:absolute; inset:0 0 170px 0; display:grid; grid-template-columns:1fr 1fr 1fr; gap:6px">
  <img src="{frame('ink-12-top.jpg')}" style="width:100%; height:100%; object-fit:cover; object-position:45% 10%">
  <img src="{frame('silicon-14-top.jpg')}" style="width:100%; height:100%; object-fit:cover; object-position:50% 0%">
  <img src="{frame('notes-12-top.jpg')}" style="width:100%; height:100%; object-fit:cover; object-position:40% 0%">
</div>
<div style="position:absolute; left:64px; right:64px; bottom:46px; display:flex; align-items:flex-end; justify-content:space-between">
  <div>
    <div class="brand" style="font-size:30px"><img src="{ICON}" style="width:52px;height:52px;border-radius:12px">Resonance</div>
    <p style="margin:14px 0 0; font-size:38px; font-weight:700; letter-spacing:-.02em">Every C64 tune. <span class="grad">Watch the chip play it.</span></p>
  </div>
  <div class="small">12 visualizers</div>
</div>""",
    # C: Ink full bleed, the headline at the bottom.
    "site-c": f"""
<img class="bg" src="{frame('ink-18-top.jpg')}" style="object-position: 50% 30%">
<div class="shade-bottom"></div>
<div style="position:absolute; left:72px; right:72px; bottom:58px">
  <div class="brand" style="font-size:30px; margin-bottom:18px"><img src="{ICON}" style="width:52px;height:52px;border-radius:12px">Resonance</div>
  <p class="headline" style="font-size:58px">Every C64 tune.<br><span class="grad">Say what you'd like to hear.</span></p>
</div>""",
}


def visual_card(name, line, picture, position):
    return f"""
<img class="bg" src="{frame(picture)}" style="object-position: {position}">
<div class="shade-bottom"></div>
<div style="position:absolute; left:72px; right:72px; bottom:56px">
  <p class="vname">{name}</p>
  <p class="vline">{line}</p>
  <div class="brand" style="font-size:26px; margin-top:26px"><img src="{ICON}" style="width:44px;height:44px;border-radius:10px">A Resonance visualizer</div>
</div>"""


def render(html_path, jpg_path):
    with tempfile.TemporaryDirectory() as tmp:
        png = pathlib.Path(tmp) / "card.png"
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        "--allow-file-access-from-files", "--force-device-scale-factor=1",
                        "--window-size=1200,630", f"--screenshot={png}", html_path.as_uri()],
                       check=True, capture_output=True)
        jpg_path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "86", str(png), "--out", str(jpg_path)],
                       check=True, capture_output=True)
    print(jpg_path.relative_to(ROOT))


CARDS.mkdir(exist_ok=True)
for key, body in SITE_CARDS.items():
    html = CARDS / f"{key}.html"
    html.write_text(page(body))
    out = SITE / "assets" / "og-card.jpg" if key == "site-a" else CARDS / f"{key}.jpg"
    render(html, out)
for slug, name, line, picture, position in VISUALS:
    html = CARDS / f"{slug}.html"
    html.write_text(page(visual_card(name, line, picture, position)))
    render(html, SITE / "assets" / "cards" / f"{slug}.jpg")


def visual_page(slug, name, line):
    title = f"{name}, a Resonance visualizer"
    description = f"{line}. One of twelve in Resonance, a Mac player for Commodore 64 music."
    url = f"{BASE}v/{slug}/"
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title}</title>
  <meta name="description" content="{description}">
  <link rel="canonical" href="{url}">
  <meta property="og:type" content="website">
  <meta property="og:title" content="{title}">
  <meta property="og:description" content="{description}">
  <meta property="og:url" content="{url}">
  <meta property="og:image" content="{BASE}assets/cards/{slug}.jpg">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta name="twitter:card" content="summary_large_image">
  <link rel="icon" type="image/png" sizes="64x64" href="../../assets/favicon-64.png">
  <!-- Written by design/site-sharing/make-cards.py. Link previews read the
       tags above; people go straight on to the visualizer on the site. -->
  <script>
    // Counted first (GoatCounter's pixel; previews don't run this, people do),
    // then on to the site: at once if the count is slow, never on localhost.
    const go = () => location.replace('../../#vis-{slug}');
    if (location.hostname === 'localhost' || location.hostname === '127.0.0.1') go();
    else {{
      const pixel = new Image();
      pixel.onload = pixel.onerror = go;
      pixel.src = 'https://erikluimes.goatcounter.com/count?p=' + encodeURIComponent('/v/{slug}/')
        + '&t=' + encodeURIComponent(document.title) + '&r=' + encodeURIComponent(document.referrer);
      setTimeout(go, 400);
    }}
  </script>
  <style>body {{ margin: 0; min-height: 100vh; display: grid; place-content: center; background: #07080d; color: #f3f4f8;
    font: 16px -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; }} a {{ color: #3fd0e8; }}</style>
</head>
<body>
  <p><a href="../../#vis-{slug}">{name} in Resonance</a></p>
</body>
</html>
"""


for slug, name, line, _, _ in VISUALS:
    out = SITE / "v" / slug / "index.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(visual_page(slug, name, line))
    print(out.relative_to(ROOT))
