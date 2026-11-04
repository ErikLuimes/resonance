//! The tune index (built by `cargo run -p phosphor-apple --example
//! share_index`) and what a link asks for.

use std::collections::HashMap;
use std::path::Path;

use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct Index {
    pub hvsc: Option<u32>,
    pub tunes: HashMap<String, Tune>,
    /// The MD5s by share code (`short_code`); built on load.
    #[serde(skip)]
    codes: HashMap<String, Vec<String>>,
}

/// One tune; the short keys are the index's.
#[derive(Debug, Clone, Deserialize)]
pub struct Tune {
    #[serde(rename = "p")]
    pub path: String,
    #[serde(rename = "t")]
    pub title: String,
    #[serde(rename = "a")]
    pub author: String,
    #[serde(rename = "r")]
    pub released: String,
    #[serde(rename = "n")]
    pub songs: u16,
    #[serde(rename = "s")]
    pub start_song: u16,
    #[serde(rename = "l", default)]
    pub lengths: Vec<u32>,
    #[serde(rename = "m", default)]
    pub sid_model: u8,
    /// Traits per subtune, as percentages; JSON object keys are strings.
    #[serde(rename = "f", default)]
    pub traits: HashMap<String, [u8; 9]>,
    /// Waveform mix per subtune, as percentages: triangle, saw, pulse, noise.
    #[serde(rename = "w", default)]
    pub mix: HashMap<String, [u8; 4]>,
}

impl Index {
    pub fn load(path: &Path) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
        let index: Self = serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display()))?;
        Ok(Self::new(index.hvsc, index.tunes))
    }

    pub fn new(hvsc: Option<u32>, tunes: HashMap<String, Tune>) -> Self {
        let mut codes: HashMap<String, Vec<String>> = HashMap::new();
        for md5 in tunes.keys() {
            if let Some(code) = short_code(md5) {
                codes.entry(code).or_default().push(md5.clone());
            }
        }
        Self { hvsc, tunes, codes }
    }

    /// The tune a link names, with its full MD5. A share code two tunes
    /// share (never seen yet, but possible) names neither.
    pub fn find(&self, key: &Key) -> Option<(&str, &Tune)> {
        let md5 = match key {
            Key::Md5(md5) => md5,
            Key::Code(code) => match self.codes.get(code).map(Vec::as_slice) {
                Some([md5]) => md5,
                _ => return None,
            },
        };
        self.tunes.get_key_value(md5).map(|(k, t)| (k.as_str(), t))
    }
}

/// What a link names a tune by: its share code (what links are made
/// with), or its whole MD5 (also accepted).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Key {
    Md5(String),
    Code(String),
}

impl Key {
    /// 32 hex digits (any case), or a 12-character share code.
    pub fn parse(raw: &str) -> Option<Self> {
        if raw.len() == 32 && raw.bytes().all(|b| b.is_ascii_hexdigit()) {
            Some(Key::Md5(raw.to_ascii_lowercase()))
        } else if raw.len() == CODE_LEN && raw.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            Some(Key::Code(raw.to_string()))
        } else {
            None
        }
    }

    /// As written in a link.
    pub fn as_str(&self) -> &str {
        match self {
            Key::Md5(s) | Key::Code(s) => s,
        }
    }
}

const CODE_LEN: usize = 12;

/// A tune's share code: the first 72 bits of its MD5 in base64url, 12
/// characters. Computed, never stored, so every release's tunes have one;
/// 72 bits keep HVSC's tunes apart (a clash among 100,000 has odds of about
/// one in 10¹²). The app makes the same (`SharedTuneLink.shortCode`).
pub fn short_code(md5: &str) -> Option<String> {
    use base64::Engine as _;
    if md5.len() != 32 {
        return None;
    }
    let bytes: Vec<u8> = (0..9).map(|i| u8::from_str_radix(&md5[i * 2..i * 2 + 2], 16)).collect::<Result<_, _>>().ok()?;
    Some(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

impl Tune {
    /// The subtune a link names, if the tune has it; else the start song.
    pub fn subtune(&self, asked: Option<u16>) -> u16 {
        asked.filter(|s| (1..=self.songs).contains(s)).unwrap_or(self.start_song.max(1))
    }

    pub fn length(&self, subtune: u16) -> Option<u32> {
        self.lengths.get(usize::from(subtune).checked_sub(1)?).copied()
    }

    pub fn traits(&self, subtune: u16) -> Option<[u8; 9]> {
        self.traits.get(&subtune.to_string()).copied()
    }

    /// Mostly pulse when the index has no mix (an older index).
    pub fn mix(&self, subtune: u16) -> [u8; 4] {
        self.mix.get(&subtune.to_string()).copied().unwrap_or([0, 0, 100, 0])
    }

    /// "MUSICIANS", "GAMES", "DEMOS".
    pub fn section(&self) -> &str {
        self.path.trim_start_matches('/').split('/').next().unwrap_or("")
    }

    /// "Rob Hubbard", or "Unknown composer" for HVSC's "<?>".
    pub fn author_name(&self) -> &str {
        match self.author.trim() {
            "" | "<?>" => "Unknown composer",
            name => name,
        }
    }

    pub fn title_name(&self) -> &str {
        match self.title.trim() {
            "" | "<?>" => self.path.rsplit('/').next().unwrap_or("Untitled").trim_end_matches(".sid"),
            title => title,
        }
    }

    /// "6581", "8580", or nothing when the header doesn't say.
    pub fn chip(&self) -> Option<&'static str> {
        match self.sid_model {
            1 => Some("6581"),
            2 => Some("8580"),
            3 => Some("6581 / 8580"),
            _ => None,
        }
    }
}

pub fn duration(secs: u32) -> String {
    format!("{}:{:02}", secs / 60, secs % 60)
}

/// The trait names, in the index's order (the app's `SoundTrait`).
pub const TRAITS: [&str; 9] = [
    "Notes", "Arpeggios", "Vibrato", "Filter", "Ring mod", "Sync", "Digi", "Noise", "Pulse width",
];

/// The strongest traits worth a chip on the card, strongest first. Notes
/// is left out: every tune has them.
pub fn standout_traits(traits: &[u8; 9]) -> Vec<&'static str> {
    let mut ranked: Vec<(usize, u8)> = traits.iter().copied().enumerate().skip(1).filter(|&(_, v)| v >= 35).collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1));
    ranked.into_iter().take(3).map(|(i, _)| TRAITS[i]).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index() -> Index {
        let index: Index = serde_json::from_str(
            r#"{"hvsc":85,"tunes":{"0123456789abcdef0123456789abcdef":
                {"p":"/MUSICIANS/H/Hubbard_Rob/Commando.sid","t":"Commando","a":"Rob Hubbard",
                 "r":"1985 Elite","n":3,"s":1,"l":[313,21,6],"m":1,
                 "f":{"1":[40,80,10,60,0,0,0,20,50]}}}}"#,
        )
        .unwrap();
        Index::new(index.hvsc, index.tunes)
    }

    #[test]
    fn reads_the_index_the_app_core_writes() {
        let index = index();
        let tune = &index.tunes["0123456789abcdef0123456789abcdef"];
        assert_eq!(tune.section(), "MUSICIANS");
        assert_eq!(tune.subtune(Some(3)), 3);
        assert_eq!(tune.subtune(Some(9)), 1, "a subtune it doesn't have");
        assert_eq!(tune.length(1).map(duration).as_deref(), Some("5:13"));
        assert_eq!(tune.chip(), Some("6581"));
        assert_eq!(standout_traits(&tune.traits(1).unwrap()), ["Arpeggios", "Filter", "Pulse width"]);
        assert_eq!(tune.traits(2), None);
    }

    #[test]
    fn links_name_tunes_by_code_or_md5() {
        assert_eq!(
            Key::parse("0123456789ABCDEF0123456789abcdef"),
            Some(Key::Md5("0123456789abcdef0123456789abcdef".into()))
        );
        assert_eq!(Key::parse("bQGey6gxqfhT"), Some(Key::Code("bQGey6gxqfhT".into())));
        assert_eq!(Key::parse("0123"), None);
        assert_eq!(Key::parse("../etc/pass"), None);
        assert_eq!(Key::parse("../../../../etc/passwd/xxxxxxxxxxx"), None);
    }

    #[test]
    fn share_codes_match_the_apps() {
        // The same examples as the app's TuneShareTests.
        assert_eq!(short_code("6d019ecba831a9f853675aac29a61c10").as_deref(), Some("bQGey6gxqfhT"));
        assert_eq!(short_code("ffffffffffffffffffffffffffffffff").as_deref(), Some("____________"));
        assert_eq!(short_code("0123"), None);
    }

    #[test]
    fn finds_tunes_by_code_and_not_when_two_share_one() {
        let index = index();
        let md5 = "0123456789abcdef0123456789abcdef";
        let code = Key::Code(short_code(md5).unwrap());
        assert_eq!(index.find(&code).map(|(m, _)| m), Some(md5));
        assert_eq!(index.find(&Key::Md5(md5.into())).map(|(m, _)| m), Some(md5));
        let tune = index.tunes[md5].clone();
        // Same first 72 bits, different rest.
        let twin = "0123456789abcdef01ffffffffffffff";
        let clashing = Index::new(None, [(md5.to_string(), tune.clone()), (twin.to_string(), tune)].into());
        assert!(clashing.find(&code).is_none());
        assert!(clashing.find(&Key::Md5(twin.into())).is_some(), "the whole MD5 still tells them apart");
    }
}
