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
    pub favourite: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistInfo {
    pub name: String,
    pub count: u32,
    pub is_favourites: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Described {
    pub title: String,
    pub note: Option<String>,
    pub tunes: Vec<Tune>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Scope {
    pub voices: Vec<Vec<f32>>,
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
    fn a_tune_needs_only_what_a_favourite_answer_has() {
        let tune: Tune = serde_json::from_str(
            r#"{"path":"/a.sid","title":"A","author":"B","released":"1985"}"#,
        )
        .unwrap();
        assert_eq!(tune.songs, 0);
        assert_eq!(tune.secs, None);
    }
}
