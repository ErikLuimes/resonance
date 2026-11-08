//! What the app answers with (Resonance/Services/ControlCommands.swift).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tune {
    pub path: String,
    pub title: String,
    pub author: String,
    pub released: String,
    #[serde(default)]
    pub songs: u32,
    #[serde(default)]
    pub secs: Option<u32>,
    /// How alike, 0–1, in Sounds Like.
    #[serde(default)]
    pub score: Option<f64>,
    /// When it last played, in seconds since 1970, in Recently Played.
    #[serde(default, rename = "playedAt", skip_serializing_if = "Option::is_none")]
    pub played_at: Option<u64>,
}

/// The collection's front door (HvscOverview in the app).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HvscOverview {
    pub version: Option<String>,
    pub release_date: Option<String>,
    pub total_tunes: u32,
    pub musician_tunes: u32,
    pub game_tunes: u32,
    pub demo_tunes: u32,
    pub composers: u32,
    pub songlength_entries: u32,
    pub documents: u32,
    pub update: Option<HvscUpdate>,
    pub disks: Vec<HvscDisk>,
    pub playlists: Vec<HvscPlaylist>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HvscUpdate {
    pub number: u32,
    pub new_sids: Option<u32>,
    pub fixed_rips: Option<u32>,
    pub credit_fixes: Option<u32>,
    pub moved: Option<u32>,
    pub text: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct HvscDisk {
    pub name: String,
    pub images: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct HvscPlaylist {
    pub name: String,
    pub file: String,
    pub tracks: u32,
}

/// How much of each waveform a tune uses.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Mix {
    pub triangle: f32,
    pub saw: f32,
    pub pulse: f32,
    pub noise: f32,
}

/// A tune's fingerprint for drawing; the last two only when asked for in detail.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Print {
    pub path: String,
    pub traits: Vec<f32>,
    #[serde(default)]
    pub mix: Option<Mix>,
    /// How loud each voice is across the tune, voice 1 first.
    #[serde(default)]
    pub activity: Option<Vec<Vec<u8>>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Now {
    pub path: String,
    pub title: String,
    pub author: String,
    pub released: String,
    pub song: u32,
    pub songs: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub state: String,
    pub now: Option<Now>,
    pub elapsed: f64,
    pub duration: Option<f64>,
    pub has_collection: bool,
    pub favorite: bool,
    /// The list it's playing from; an app before this didn't say.
    #[serde(default)]
    pub source: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistInfo {
    pub name: String,
    pub count: u32,
    pub is_favorites: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Described {
    pub title: String,
    pub note: Option<String>,
    /// What it took from the sentence; an app before this didn't say.
    #[serde(default)]
    pub understood: Option<String>,
    /// "19 tunes, 61 minutes".
    #[serde(default)]
    pub facts: Option<String>,
    pub tunes: Vec<Tune>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Scope {
    pub voices: Vec<Vec<f32>>,
}

/// A tune as a tracker would show it (TrackerAnswer in the app).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TrackerSong {
    pub path: String,
    pub song: u32,
    pub chip: u32,
    pub frame_rate: f64,
    pub frames_per_row: f32,
    pub has_grid: bool,
    pub chips: u32,
    pub instruments: Vec<TrackerInstrument>,
    pub rows: Vec<TrackerRow>,
}

impl TrackerSong {
    /// The row playing `secs` in.
    pub fn row_at(&self, secs: f64) -> usize {
        let frame = (secs * self.frame_rate) as u32;
        self.rows.partition_point(|row| row.f <= frame).saturating_sub(1)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct TrackerInstrument {
    pub name: String,
    pub ad: u8,
    pub sr: u8,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct TrackerRow {
    pub f: u32,
    /// Each voice: "C-4 02 ARP", "--- 00 VIB", or empty for nothing at all.
    pub v: Vec<String>,
    /// 11-bit cutoff.
    pub c: u16,
    pub r: u8,
    /// Which voices the filter takes: bits 0–2.
    pub ro: u8,
    /// Bits 0–2: low-pass, band-pass, high-pass.
    pub m: u8,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct TrackerPosition {
    pub path: Option<String>,
    pub song: u32,
    pub heard: Option<f64>,
    /// The chip the rest is about.
    pub chip: u32,
    pub chips: u32,
    pub levels: Vec<f32>,
    pub notes: Vec<Option<String>>,
    /// Each chip's notes.
    #[serde(rename = "allNotes")]
    pub all_notes: Vec<Vec<Option<String>>>,
    /// Each chip's voice levels, 0–1.
    #[serde(rename = "allLevels")]
    pub all_levels: Vec<Vec<f32>>,
    /// The latest frames, oldest first.
    pub frames: Vec<PositionFrame>,
}

/// One frame's registers, $00–$1C, as hex: every chip's, one after the other.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct PositionFrame {
    pub i: u64,
    pub r: String,
}

impl PositionFrame {
    pub fn registers(&self) -> Vec<u8> {
        (0..self.r.len() / 2).filter_map(|n| u8::from_str_radix(self.r.get(n * 2..n * 2 + 2)?, 16).ok()).collect()
    }
}

/// "4:12".
pub fn clock(secs: f64) -> String {
    let whole = secs.max(0.0) as u64;
    format!("{}:{:02}", whole / 60, whole % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clock_pads_seconds() {
        assert_eq!(clock(252.9), "4:12");
        assert_eq!(clock(5.0), "0:05");
        assert_eq!(clock(-3.0), "0:00");
    }

    #[test]
    fn a_tune_needs_only_what_a_favorite_answer_has() {
        let tune: Tune = serde_json::from_str(
            r#"{"path":"/a.sid","title":"A","author":"B","released":"1985"}"#,
        )
        .unwrap();
        assert_eq!(tune.songs, 0);
        assert_eq!(tune.secs, None);
    }
}
