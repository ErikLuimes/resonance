//! The page a shared link opens: Open Graph and Twitter tags for the
//! preview, then the card, Open in Resonance and Download Resonance.

use crate::card::escape;
use crate::tune::{self, Tune};

pub struct Link<'a> {
    /// What the app looks the tune up by: its MD5 when the index has it,
    /// else what the link said.
    pub key: &'a str,
    /// What this page's own links use: the tune's share code.
    pub code: &'a str,
    /// 0: the start song.
    pub subtune: u16,
    /// The tune's start song, which links leave out; 0 when unknown.
    pub start: u16,
    /// The sender's HVSC release, from the link.
    pub hvsc: Option<u32>,
}

pub struct Site<'a> {
    /// This server's public address, "https://share.example" (no slash).
    pub base: &'a str,
    /// Where Download Resonance goes.
    pub download: &'a str,
    /// GoatCounter's count address, which counts the page's visits and its
    /// links' clicks without cookies; None counts nothing.
    pub goatcounter: Option<&'a str>,
}

/// The app's own link: `resonance://tune/<md5>?s=2&v=85&p=/MUSICIANS/…`,
/// with the whole MD5, so the app needs no share-code lookup.
/// The path lets a collection without that MD5 (an older release) find it;
/// the title and author (`t`, `a`) name it while it's missing.
pub fn app_link(link: &Link, tune: Option<&Tune>) -> String {
    let mut url = format!("resonance://tune/{}", link.key);
    let mut sep = '?';
    let mut param = |name: &str, value: String| {
        url.push(sep);
        url.push_str(&format!("{name}={value}"));
        sep = '&';
    };
    if link.subtune != 0 {
        param("s", link.subtune.to_string());
    }
    if let Some(v) = link.hvsc {
        param("v", v.to_string());
    }
    if let Some(tune) = tune {
        param("p", encode(&tune.path));
        param("t", encode(tune.title_name()));
        param("a", encode(tune.author_name()));
    }
    url
}

/// The tune on DeepSID, which plays HVSC in the browser:
/// `https://deepsid.chordian.net/?file=/MUSICIANS/…&subtune=2`. DeepSID
/// counts subtunes from 1, as links do; the start song is left out.
pub fn deepsid_link(link: &Link, tune: &Tune) -> String {
    let mut url = format!("https://deepsid.chordian.net/?file={}", encode(&tune.path));
    if link.subtune != 0 && link.subtune != link.start {
        url.push_str(&format!("&subtune={}", link.subtune));
    }
    url
}

pub fn tune_page(site: &Site, link: &Link, tune: &Tune) -> String {
    let title = format!("{} — {}", tune.title_name(), tune.author_name());
    let mut facts: Vec<String> = vec![tune.released.trim().to_string()];
    if let Some(len) = tune.length(link.subtune) {
        facts.push(tune::duration(len));
    }
    facts.retain(|f| !f.is_empty() && f != "<?>");
    let description = format!(
        "{}. Play it in Resonance, the SID music player for Mac.",
        if facts.is_empty() { "A Commodore 64 tune from HVSC".to_string() } else { facts.join(" · ") }
    );
    let query = query(link);
    let page_url = format!("{}/t/{}{query}", site.base, link.code);
    let image = format!("{}/card/{}.jpg?s={}", site.base, link.code, link.subtune);
    let hero = match tune.traits(link.subtune) {
        Some(traits) => tune_hero(tune, link, &traits),
        None => format!(r#"<img class="card" src="{}" width="800" height="420" alt="{}">
<h1>{}</h1>"#, escape(&image), escape(&title), escape(&title)),
    };
    page(
        site,
        &title,
        &description,
        &page_url,
        &image,
        &format!(
            r#"{hero}
<p class="where">{}</p>
<div class="actions">
  <a class="button primary" href="{}" data-goatcounter-click="share-open">Open in Resonance</a>
  <a class="button" href="{}" data-goatcounter-click="share-download">Download Resonance</a>
</div>
<p class="note">Resonance plays the tune from your own copy of HVSC, the High Voltage SID Collection. It finds it even if your collection is an older release, and offers the update when it's missing.</p>
<p class="note">Not on a Mac? <a href="{}" data-goatcounter-click="share-deepsid">Listen on DeepSID</a>, in your browser.</p>"#,
            escape(&tune.path),
            escape(&app_link(link, Some(tune))),
            escape(site.download),
            escape(&deepsid_link(link, tune)),
        ),
    )
}

/// The tune's fingerprint sphere, turning (drawn by `SPHERE_JS`, the app's
/// MorphSphere), beside its title, composer and strongest traits.
fn tune_hero(tune: &Tune, link: &Link, traits: &[u8; 9]) -> String {
    let mix = tune.mix(link.subtune);
    let list = |v: &[u8]| v.iter().map(u8::to_string).collect::<Vec<_>>().join(",");
    let mut facts = vec![tune.released.trim().to_string()];
    if let Some(len) = tune.length(link.subtune) {
        facts.push(tune::duration(len));
    }
    if tune.songs > 1 {
        facts.push(format!("subtune {} of {}", link.subtune, tune.songs));
    }
    facts.retain(|f| !f.is_empty() && f != "<?>");
    let chips: String = tune::standout_traits(traits)
        .iter()
        .map(|t| format!(r#"<span class="chip">{t}</span>"#))
        .collect();
    format!(
        r#"<div class="hero">
  <canvas class="sphere" width="360" height="360" data-traits="{}" data-mix="{}" role="img" aria-label="Sound fingerprint"></canvas>
  <div class="text">
    <p class="section">{}</p>
    <h1>{}</h1>
    <p class="author">{}</p>
    <p class="facts">{}</p>
    <p class="chips">{chips}</p>
  </div>
</div>
<script>{SPHERE_JS}</script>"#,
        list(traits),
        list(&mix),
        escape(&match link.hvsc { Some(v) => format!("HVSC {v} · {}", tune.section()), None => tune.section().to_string() }),
        escape(tune.title_name()),
        escape(tune.author_name()),
        escape(&facts.join(" · ")),
    )
}

/// `MorphSphereShape` (SoundGlyphs.swift), turning as in the app's hover
/// card: the same math, so the page shows the sphere the app does.
const SPHERE_JS: &str = r#"
(() => {
  const canvas = document.querySelector('canvas.sphere');
  if (!canvas) return;
  const traits = canvas.dataset.traits.split(',').map(v => v / 100);
  const mix = canvas.dataset.mix.split(',').map(Number);
  const palette = ['#80dba3', '#a37df5', '#59c7e8', '#f2a154'];
  const lattice = (i, n) => {
    const y = 1 - 2 * (i + 0.5) / n, r = Math.sqrt(1 - y * y), a = i * 2.39996;
    return [r * Math.cos(a), y, r * Math.sin(a)];
  };
  const hash = (a, b) => { const x = Math.sin(a * 127.1 + b * 311.7) * 43758.5453; return x - Math.floor(x); };
  const pick = u => {
    const total = mix.reduce((s, m) => s + m, 0);
    if (total <= 0) return 2;
    let sum = 0;
    for (let i = 0; i < mix.length; i++) { sum += mix[i] / total; if (u <= sum) return i; }
    return 2;
  };
  const dirs = traits.map((_, k) => lattice(k, traits.length));
  const points = Array.from({ length: 900 }, (_, i) => {
    const p = lattice(i, 900);
    let radius = 0.36;
    dirs.forEach((d, k) => { radius += traits[k] * 0.58 * Math.pow(Math.max(0, p[0] * d[0] + p[1] * d[1] + p[2] * d[2]), 8); });
    return { x: p[0] * radius, y: p[1] * radius, z: p[2] * radius, c: pick(hash(i, 3)) };
  });
  const extent = Math.max(0.1, ...points.map(p => Math.hypot(p.x, p.y, p.z)));
  const ratio = window.devicePixelRatio || 1;
  const size = canvas.width;
  canvas.style.width = size + 'px';
  canvas.width = canvas.height = size * ratio;
  const ctx = canvas.getContext('2d');
  ctx.scale(ratio, ratio);
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const draw = time => {
    const angle = still ? 0.6 : time / 1000 * 0.45;
    const [cy, sy, cx, sx] = [Math.cos(angle), Math.sin(angle), Math.cos(0.3), Math.sin(0.3)];
    const camera = 3.2, scale = size * 0.44 * (camera - extent / 2) / extent;
    const projected = points.map(p => {
      const x = p.x * cy + p.z * sy, z0 = -p.x * sy + p.z * cy;
      const y = p.y * cx - z0 * sx, z = p.y * sx + z0 * cx, k = 1 / (camera - z);
      return [z, size / 2 + x * scale * k, size / 2 - y * scale * k, p.c];
    }).sort((a, b) => a[0] - b[0]);
    ctx.clearRect(0, 0, size, size);
    for (const [z, x, y, c] of projected) {
      const depth = (z + 1) / 2, dot = (0.7 + 1.3 * depth) * 2.4;
      ctx.globalAlpha = 0.25 + 0.7 * depth;
      ctx.fillStyle = palette[c];
      ctx.fillRect(x - dot / 2, y - dot / 2, dot, dot);
    }
    if (!still) requestAnimationFrame(draw);
  };
  requestAnimationFrame(draw);
})();
"#;

/// A link to a tune this server doesn't know (a newer HVSC than its
/// index, or a mistyped link): the app may still have it.
pub fn unknown_page(site: &Site, link: &Link) -> String {
    page(
        site,
        "A tune shared from Resonance",
        "Play it in Resonance, the SID music player for Mac.",
        &format!("{}/t/{}{}", site.base, link.code, query(link)),
        &format!("{}/card.jpg", site.base),
        &format!(
            r#"<img class="card" src="{}/card.jpg" width="800" height="420" alt="Resonance">
<h1>A tune shared from Resonance</h1>
<p class="note">This tune isn't in the server's copy of HVSC yet. Resonance can still look for it in yours.</p>
<div class="actions">
  <a class="button primary" href="{}" data-goatcounter-click="share-open">Open in Resonance</a>
  <a class="button" href="{}" data-goatcounter-click="share-download">Download Resonance</a>
</div>"#,
            escape(site.base),
            escape(&app_link(link, None)),
            escape(site.download),
        ),
    )
}

/// `?s=2&v=85`, leaving out the start song.
fn query(link: &Link) -> String {
    let mut params = Vec::new();
    if link.subtune != 0 && link.subtune != link.start {
        params.push(format!("s={}", link.subtune));
    }
    if let Some(v) = link.hvsc {
        params.push(format!("v={v}"));
    }
    if params.is_empty() { String::new() } else { format!("?{}", params.join("&")) }
}

fn page(site: &Site, title: &str, description: &str, url: &str, image: &str, body: &str) -> String {
    let (title, description, url, image) = (escape(title), escape(description), escape(url), escape(image));
    // GoatCounter's script also counts clicks on the `data-goatcounter-click`
    // links. A page counts as its path alone: the canonical link's `?s=2&v=85`
    // would otherwise count one tune once per subtune and HVSC release.
    let counter = site.goatcounter.map_or(String::new(), |count| {
        format!(r#"<script>window.goatcounter = {{ path: (p) => p.split('?')[0] }};</script>
<script data-goatcounter="{}" async src="https://gc.zgo.at/count.js"></script>
"#, escape(count))
    });
    format!(
        r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<meta property="og:type" content="music.song">
<meta property="og:site_name" content="Resonance">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{description}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{image}">
<meta property="og:image:type" content="image/jpeg">
<meta property="og:image:width" content="800">
<meta property="og:image:height" content="420">
<meta property="og:image:alt" content="{title}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{title}">
<meta name="twitter:description" content="{description}">
<meta name="twitter:image" content="{image}">
<link rel="canonical" href="{url}">
<style>
  :root {{ color-scheme: dark; --bg: #0f1115; --text: #f2f2f5; --muted: #9aa0b0; --accent: #59c7e8; }}
  body {{ margin: 0; background: var(--bg); color: var(--text); font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Inter", "Helvetica Neue", sans-serif; }}
  main {{ max-width: 720px; margin: 0 auto; padding: 48px 16px; }}
  img.card {{ width: 100%; height: auto; border-radius: 14px; display: block; margin-bottom: 28px; }}
  h1 {{ font-size: 34px; line-height: 1.15; margin: 0 0 4px; font-weight: 700; }}
  .hero {{ display: flex; flex-wrap: wrap; align-items: center; gap: 12px 32px; margin-bottom: 20px; }}
  .sphere {{ flex: none; max-width: 100%; height: auto; }}
  /* Shrinks beside the sphere rather than wrapping under it; only a phone
     is too narrow for both (the sphere is 360 wide). */
  .hero .text {{ flex: 1 1 220px; min-width: 0; overflow-wrap: anywhere; }}
  .section {{ color: var(--muted); letter-spacing: .08em; font-size: 13px; text-transform: uppercase; margin: 0 0 6px; }}
  .author {{ font-size: 20px; color: #c8ccd8; margin: 0 0 6px; }}
  .facts {{ color: var(--muted); margin: 0 0 12px; }}
  .chip {{ display: inline-block; background: #2a2f3a; border-radius: 999px; padding: 3px 12px; margin: 0 6px 6px 0; font-size: 14px; }}
  .where {{ color: var(--muted); margin: 0; font-size: 14px; word-break: break-all; }}
  .actions {{ display: flex; flex-wrap: wrap; gap: 12px; margin: 24px 0; }}
  .button {{ display: inline-block; padding: 10px 20px; border-radius: 999px; color: var(--text); text-decoration: none; border: 1px solid #3a3f4c; font-weight: 600; }}
  .button.primary {{ background: var(--accent); border-color: var(--accent); color: #0b0d12; }}
  .note {{ color: var(--muted); font-size: 15px; }}
  .note a {{ color: var(--accent); text-decoration: none; }}
  .note a:hover {{ text-decoration: underline; }}
</style>
</head>
<body>
<main>
{body}
</main>
{counter}</body>
</html>
"#
    )
}

/// Percent-encode a query value, keeping slashes readable.
pub fn encode(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => out.push(byte as char),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tune() -> Tune {
        serde_json::from_value(serde_json::json!({
            "p": "/MUSICIANS/H/Hubbard_Rob/Commando & Co.sid", "t": "Commando", "a": "Rob Hubbard",
            "r": "1985 Elite", "n": 3, "s": 1, "l": [313]
        }))
        .unwrap()
    }

    const SITE: Site = Site { base: "https://share.example", download: "https://erikluimes.github.io/resonance/", goatcounter: None };

    #[test]
    fn goatcounter_counts_only_when_set() {
        let link = Link { key: "x", code: "x", subtune: 1, start: 1, hvsc: None };
        let html = tune_page(&SITE, &link, &tune());
        assert!(!html.contains("gc.zgo.at"), "no counting without GOATCOUNTER");
        for event in ["share-open", "share-download", "share-deepsid"] {
            assert!(html.contains(&format!(r#"data-goatcounter-click="{event}""#)), "{event}");
        }
        let counted = Site { goatcounter: Some("https://example.goatcounter.com/count"), ..SITE };
        let html = tune_page(&counted, &link, &tune());
        assert!(html.contains(r#"<script data-goatcounter="https://example.goatcounter.com/count" async src="https://gc.zgo.at/count.js"></script>"#));
        assert!(html.contains("p.split('?')[0]"), "counted per tune, not per subtune or HVSC release");
        assert!(unknown_page(&counted, &link).contains("gc.zgo.at"));
    }

    #[test]
    fn the_page_carries_the_preview_tags() {
        let md5 = "0123456789abcdef0123456789abcdef";
        let link = Link { key: md5, code: "ASNFZ4mrze8B", subtune: 1, start: 1, hvsc: Some(85) };
        let html = tune_page(&SITE, &link, &tune());
        assert!(html.contains(r#"<meta property="og:title" content="Commando — Rob Hubbard">"#));
        assert!(html.contains(r#"content="https://share.example/card/ASNFZ4mrze8B.jpg?s=1""#));
        assert!(html.contains(r#"<meta property="og:url" content="https://share.example/t/ASNFZ4mrze8B?v=85">"#), "the start song left out");
        let other = tune_page(&SITE, &Link { subtune: 3, ..link }, &tune());
        assert!(other.contains(r#"content="https://share.example/t/ASNFZ4mrze8B?s=3&amp;v=85""#));
        assert!(html.contains(r#"<meta name="twitter:card" content="summary_large_image">"#));
        assert!(html.contains("1985 Elite · 5:13. Play it in Resonance"));
        assert!(html.contains(
            "resonance://tune/0123456789abcdef0123456789abcdef?s=1&amp;v=85&amp;p=/MUSICIANS/H/Hubbard_Rob/Commando%20%26%20Co.sid&amp;t=Commando&amp;a=Rob%20Hubbard"
        ));
    }

    #[test]
    fn the_page_links_to_deepsid() {
        let link = Link { key: "x", code: "x", subtune: 1, start: 1, hvsc: None };
        let html = tune_page(&SITE, &link, &tune());
        assert!(html.contains(r#"href="https://deepsid.chordian.net/?file=/MUSICIANS/H/Hubbard_Rob/Commando%20%26%20Co.sid" data-goatcounter-click="share-deepsid">"#), "the start song left out");
        let other = tune_page(&SITE, &Link { subtune: 2, ..link }, &tune());
        assert!(other.contains("Commando%20%26%20Co.sid&amp;subtune=2\""));
    }

    #[test]
    fn unknown_tunes_still_open_in_the_app() {
        let link = Link { key: "ASNFZ4mrze8B", code: "ASNFZ4mrze8B", subtune: 2, start: 0, hvsc: None };
        let html = unknown_page(&SITE, &link);
        assert!(html.contains("resonance://tune/ASNFZ4mrze8B?s=2\""), "the app looks the code up itself");
        let bare = unknown_page(&SITE, &Link { subtune: 0, ..link });
        assert!(bare.contains("resonance://tune/ASNFZ4mrze8B\""));
        assert!(html.contains("https://share.example/card.jpg"));
    }
}
