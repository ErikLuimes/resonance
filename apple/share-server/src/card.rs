//! The preview card chat apps show for a link: 1200×630, drawn as SVG and
//! rendered to PNG with resvg: the tune, its strongest traits, and its
//! fingerprint as the app's list rows draw it (`SoundBarcode`), in the
//! trait palette of `SoundGlyphs.swift` on Now Playing's dark background.

use std::sync::{Arc, OnceLock};

use base64::Engine as _;
use resvg::{tiny_skia, usvg};

use crate::tune::{self, Tune};

/// The card is laid out in 1200×630 units (Open Graph's recommended size)
/// and delivered at two thirds of that: still the 1.91:1 ratio large
/// previews need, sharp in a chat bubble, and a third of the pixels.
pub const WIDTH: u32 = 1200;
pub const HEIGHT: u32 = 630;
pub const OUT_WIDTH: u32 = 800;
pub const OUT_HEIGHT: u32 = 420;
const JPEG_QUALITY: u8 = 85;
/// Bump when the card's look changes: cards cached on disk under another
/// version are rendered again.
pub const VERSION: u32 = 1;

const BACKGROUND: &str = "#14161c";
const FONTS: &str = "Inter, 'SF Pro Display', 'Helvetica Neue', Helvetica, Arial, sans-serif";

/// `SoundTrait.color`, per trait.
const TRAIT_COLORS: [&str; 9] = [
    "#f2f2f5", "#59c7e8", "#59c7e8", "#a37df5", "#f2a154", "#f2a154", "#f07070", "#f2a154", "#80dba3",
];

const ICON: &[u8] = include_bytes!("../../site/assets/icon-256.png");

/// The card for a tune, or Resonance's own card when `tune` is None.
pub fn svg(tune: Option<(&Tune, u16)>, hvsc: Option<u32>) -> String {
    let mut out = format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}">
<rect width="{WIDTH}" height="{HEIGHT}" fill="{BACKGROUND}"/>
"#
    );
    let icon = format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(ICON));
    match tune {
        Some((tune, subtune)) => {
            let section = match hvsc {
                Some(v) => format!("HVSC {v} · {}", tune.section()),
                None => format!("HVSC · {}", tune.section()),
            };
            text(&mut out, 80, 120, 26, "#9aa0b0", 500, 3.0, &section);
            // The text keeps left of x 700, clear of the barcode: lengths
            // are capped by an average glyph width (about 0.58 em for the
            // bold title, 0.55 for the author, 0.5 for the facts).
            let (title, size) = fit(tune.title_name(), &[(72, 14), (58, 18), (46, 23)]);
            text(&mut out, 80, 205, size, "#f2f2f5", 700, 0.0, &title);
            let (author, _) = fit(tune.author_name(), &[(38, 29)]);
            text(&mut out, 80, 205 + 58, 38, "#c8ccd8", 500, 0.0, &author);
            // Two lines: when it was released, then how it plays.
            let released = clip(tune.released.trim(), 44);
            let mut playing = Vec::new();
            if let Some(len) = tune.length(subtune) {
                playing.push(tune::duration(len));
            }
            if tune.songs > 1 {
                playing.push(format!("subtune {subtune} of {}", tune.songs));
            }
            if let Some(chip) = tune.chip() {
                playing.push(chip.to_string());
            }
            let mut y = 312;
            for line in [released, playing.join("  ·  ")] {
                if !line.is_empty() && line != "<?>" {
                    text(&mut out, 80, y, 26, "#9aa0b0", 400, 0.0, &line);
                    y += 36;
                }
            }
            let traits = tune.traits(subtune);
            if let Some(traits) = traits {
                chips(&mut out, 80, y + 4, &tune::standout_traits(&traits));
                // The barcode, not the app's sphere: chat apps shrink the
                // card, and nine bars still read where the sphere's dots
                // blur. The share page shows the sphere.
                barcode(&mut out, 740.0, 190.0, 390.0, 220.0, &traits);
            } else {
                out.push_str(&format!(
                    r#"<image x="800" y="170" width="260" height="260" xlink:href="{icon}"/>"#
                ));
            }
        }
        None => {
            out.push_str(&format!(r#"<image x="80" y="150" width="200" height="200" xlink:href="{icon}"/>"#));
            text(&mut out, 80, 450, 72, "#f2f2f5", 700, 0.0, "Resonance");
            text(&mut out, 80, 510, 34, "#c8ccd8", 400, 0.0, "SID music, native to your Mac");
            return out + "</svg>";
        }
    }
    // The signature: the app's icon and name, bottom left.
    out.push_str(&format!(r#"<image x="80" y="500" width="64" height="64" xlink:href="{icon}"/>"#));
    text(&mut out, 160, 543, 30, "#c8ccd8", 600, 0.0, "Resonance");
    out + "</svg>"
}

/// `SoundBarcode`: a bar per trait, always in the same place, on a faint
/// track, brighter the stronger.
fn barcode(out: &mut String, x: f32, y: f32, width: f32, height: f32, traits: &[u8; 9]) {
    let gap = 10.0;
    let bar = (width - gap * 8.0) / 9.0;
    for (i, &value) in traits.iter().enumerate() {
        let v = f32::from(value) / 100.0;
        let left = x + i as f32 * (bar + gap);
        let h = (v * height).max(6.0);
        out.push_str(&format!(
            r##"<rect x="{left}" y="{y}" width="{bar}" height="{height}" rx="6" fill="#ffffff" fill-opacity="0.07"/>
<rect x="{left}" y="{:.1}" width="{bar}" height="{h:.1}" rx="6" fill="{}" fill-opacity="{:.2}"/>
"##,
            y + height - h,
            TRAIT_COLORS[i],
            0.35 + 0.65 * v
        ));
    }
}

fn chips(out: &mut String, x: u32, y: u32, names: &[&str]) {
    let mut at = x as f32;
    for name in names {
        let width = 34.0 + 15.5 * name.chars().count() as f32;
        out.push_str(&format!(
            r##"<rect x="{at}" y="{y}" width="{width}" height="48" rx="24" fill="#2a2f3a"/>"##
        ));
        text(out, (at + 17.0) as u32, y + 33, 26, "#dfe2ea", 500, 0.0, name);
        at += width + 12.0;
    }
}

#[allow(clippy::too_many_arguments)]
fn text(out: &mut String, x: u32, y: u32, size: u32, fill: &str, weight: u32, spacing: f32, value: &str) {
    out.push_str(&format!(
        r#"<text x="{x}" y="{y}" font-family="{FONTS}" font-size="{size}" font-weight="{weight}" letter-spacing="{spacing}" fill="{fill}">{}</text>
"#,
        escape(value)
    ));
}

/// The largest size at which `value` fits, as (size, characters) pairs
/// from large to small; the last one truncates.
fn fit(value: &str, sizes: &[(u32, usize)]) -> (String, u32) {
    let count = value.chars().count();
    for &(size, chars) in sizes {
        if count <= chars {
            return (value.to_string(), size);
        }
    }
    let &(size, chars) = sizes.last().expect("a size");
    (clip(value, chars), size)
}

fn clip(value: &str, chars: usize) -> String {
    if value.chars().count() <= chars {
        return value.to_string();
    }
    let kept: String = value.chars().take(chars.saturating_sub(1)).collect();
    format!("{}…", kept.trim_end())
}

pub fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// The system's fonts, loaded once (Inter in the container).
fn fonts() -> Arc<usvg::fontdb::Database> {
    static FONTS: OnceLock<Arc<usvg::fontdb::Database>> = OnceLock::new();
    FONTS
        .get_or_init(|| {
            let mut db = usvg::fontdb::Database::new();
            db.load_system_fonts();
            if let Ok(dir) = std::env::var("FONT_DIR") {
                db.load_fonts_dir(dir);
            }
            db.set_sans_serif_family("Inter");
            Arc::new(db)
        })
        .clone()
}

/// The card as a JPEG, OUT_WIDTH × OUT_HEIGHT. The background is opaque,
/// so the pixmap's alpha (dropped) changes nothing.
pub fn jpeg(svg: &str) -> Result<Vec<u8>, String> {
    let options = usvg::Options { fontdb: fonts(), ..Default::default() };
    let tree = usvg::Tree::from_str(svg, &options).map_err(|e| e.to_string())?;
    let mut pixmap = tiny_skia::Pixmap::new(OUT_WIDTH, OUT_HEIGHT).ok_or("pixmap")?;
    let scale = OUT_WIDTH as f32 / WIDTH as f32;
    resvg::render(&tree, tiny_skia::Transform::from_scale(scale, scale), &mut pixmap.as_mut());
    let mut out = Vec::new();
    jpeg_encoder::Encoder::new(&mut out, JPEG_QUALITY)
        .encode(pixmap.data(), OUT_WIDTH as u16, OUT_HEIGHT as u16, jpeg_encoder::ColorType::Rgba)
        .map_err(|e| e.to_string())?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tune(title: &str) -> Tune {
        serde_json::from_value(serde_json::json!({
            "p": "/MUSICIANS/H/Hubbard_Rob/Commando.sid", "t": title, "a": "Rob Hubbard",
            "r": "1985 Elite", "n": 3, "s": 1, "l": [313], "m": 1,
            "f": {"1": [40, 80, 10, 60, 0, 0, 0, 20, 50]}
        }))
        .unwrap()
    }

    #[test]
    fn card_shows_the_tune_and_escapes_it() {
        let svg = svg(Some((&tune("Rock & <Roll>"), 1)), Some(85));
        assert!(svg.contains("HVSC 85 · MUSICIANS"));
        assert!(svg.contains("Rock &amp; &lt;Roll&gt;"));
        assert!(svg.contains(">1985 Elite<"));
        assert!(svg.contains(">5:13  ·  subtune 1 of 3  ·  6581<"));
        assert!(svg.contains(">Arpeggios<"));
        assert_eq!(svg.matches(r#"rx="6""#).count(), 18, "the barcode: a track and a bar per trait");
        let jpeg = jpeg(&svg).unwrap();
        assert_eq!(&jpeg[..3], [0xFF, 0xD8, 0xFF], "a JPEG");
        assert!(jpeg.len() < 60_000, "{} bytes", jpeg.len());
    }

    #[test]
    fn long_titles_shrink_then_clip() {
        assert_eq!(fit("Commando", &[(72, 14), (46, 23)]), ("Commando".into(), 72));
        let long = "A".repeat(30);
        assert_eq!(fit(&long, &[(72, 22), (46, 36)]).1, 46);
        let longer = "A".repeat(50);
        let (clipped, _) = fit(&longer, &[(72, 22), (46, 36)]);
        assert_eq!(clipped.chars().count(), 36);
        assert!(clipped.ends_with('…'));
    }

    #[test]
    fn the_generic_card_renders() {
        assert!(jpeg(&svg(None, None)).is_ok());
    }
}

