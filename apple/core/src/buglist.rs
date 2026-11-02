//! HVSC's bugged-tunes list, `DOCUMENTS/BUGlist.txt`: tunes still in the
//! collection that play wrong notes, fall out of sync or are incomplete
//! rips. Written like STIL.txt: a tune's HVSC path, then `BUG:` fields
//! (continued on indented lines, optionally after a `(#n)` subtune line),
//! each followed by its reporter in brackets:
//!
//! ```text
//! /MUSICIANS/S/Svensson_Roger/Walliball.sid
//!     BUG: Subtune #5 falls out of sync upon looping
//! (Wilfred)
//! ```

use std::collections::HashMap;
use std::path::Path;

/// One reported bug.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Bug {
    /// The `BUG:` text, its lines joined.
    pub text: String,
    /// Who reported it: "iAN CooG".
    pub reporter: Option<String>,
    /// The subtune it's about, when a `(#n)` line names one.
    pub subtune: Option<u16>,
}

/// The list's bugs by lowercased HVSC path.
pub(crate) fn parse(text: &str) -> HashMap<String, Vec<Bug>> {
    let mut out: HashMap<String, Vec<Bug>> = HashMap::new();
    let mut path: Option<String> = None;
    let mut subtune: Option<u16> = None;
    for raw in text.lines() {
        let line = raw.trim_end();
        let trimmed = line.trim();
        if line.starts_with('#') {
            path = None;
        } else if line.starts_with('/') {
            path = Some(trimmed.to_lowercase());
            subtune = None;
        } else if let Some(path) = &path {
            let bugs = out.entry(path.clone()).or_default();
            if let Some(rest) = trimmed.strip_prefix("BUG:") {
                bugs.push(Bug {
                    text: rest.trim().to_string(),
                    reporter: None,
                    subtune,
                });
            } else if let Some(n) = trimmed
                .strip_prefix("(#")
                .and_then(|s| s.strip_suffix(')'))
                .and_then(|n| n.parse().ok())
            {
                subtune = Some(n);
            } else if let Some(name) = trimmed.strip_prefix('(').and_then(|s| s.strip_suffix(')')) {
                if let Some(bug) = bugs.last_mut() {
                    bug.reporter = Some(name.trim().to_string());
                }
            } else if !trimmed.is_empty() {
                // A continuation line of the last field.
                if let Some(bug) = bugs.last_mut() {
                    bug.text.push(' ');
                    bug.text.push_str(trimmed);
                }
            }
        }
    }
    out.retain(|_, bugs| !bugs.is_empty());
    out
}

/// The bugs reported on the tune at `hvsc_path` in the collection at
/// `root`; empty when there are none or the list can't be read.
pub(crate) fn bugs(root: &Path, hvsc_path: &str) -> Vec<Bug> {
    let Ok(bytes) = std::fs::read(root.join("DOCUMENTS").join("BUGlist.txt")) else {
        return Vec::new();
    };
    parse(&crate::databases::decode_stil(&bytes))
        .remove(&hvsc_path.to_lowercase())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST: &str = "\
##############################
# Bugged tunes as of HVSC 85 #
##############################

/DEMOS/A-F/Digital_II.sid
    BUG: Original has part of the samples overwritten by a ML monitor, hence
         playing \"garbage\" at some point.
(iAN CooG)

/MUSICIANS/S/Svensson_Roger/Walliball.sid
(#5)
    BUG: Falls out of sync upon looping
(Wilfred)
";

    #[test]
    fn joins_lines_and_keeps_reporters_and_subtunes() {
        let list = parse(LIST);
        assert_eq!(
            list["/demos/a-f/digital_ii.sid"],
            [Bug {
                text: "Original has part of the samples overwritten by a ML monitor, hence playing \"garbage\" at some point.".into(),
                reporter: Some("iAN CooG".into()),
                subtune: None,
            }]
        );
        assert_eq!(
            list["/musicians/s/svensson_roger/walliball.sid"],
            [Bug {
                text: "Falls out of sync upon looping".into(),
                reporter: Some("Wilfred".into()),
                subtune: Some(5),
            }]
        );
        assert_eq!(list.len(), 2, "the header is no entry");
    }
}
