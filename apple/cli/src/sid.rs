//! A SID file's header (HVSC's SID_file_format.txt), read without the app.
//! The same as Shared/SIDHeader.swift, which the Quick Look extension uses.

use serde::Serialize;

#[derive(Debug, PartialEq, Serialize)]
pub struct Header {
    pub format: &'static str,
    pub title: String,
    pub author: String,
    pub released: String,
    pub songs: u16,
    pub model: Option<&'static str>,
    pub clock: Option<&'static str>,
    pub chips: u8,
}

/// `field`'s bytes up to the first NUL, as Windows-1252 (Latin-1 is the same
/// for every letter HVSC's names use).
fn text(field: &[u8]) -> String {
    field
        .iter()
        .take_while(|b| **b != 0)
        .map(|b| *b as char)
        .collect::<String>()
        .trim()
        .to_string()
}

pub fn parse(data: &[u8]) -> Option<Header> {
    if data.len() < 118 {
        return None;
    }
    let format = match &data[0..4] {
        b"PSID" => "PSID",
        b"RSID" => "RSID",
        _ => return None,
    };
    let word = |at: usize| u16::from_be_bytes([data[at], data[at + 1]]);
    let version = word(4);
    let mut header = Header {
        format,
        title: text(&data[22..54]),
        author: text(&data[54..86]),
        released: text(&data[86..118]),
        songs: word(14),
        model: None,
        clock: None,
        chips: 1,
    };
    // The rest came in with version 2.
    if version >= 2 && data.len() >= 124 {
        let flags = word(118);
        header.clock = match (flags >> 2) & 3 {
            1 => Some("PAL"),
            2 => Some("NTSC"),
            3 => Some("PAL and NTSC"),
            _ => None,
        };
        header.model = match (flags >> 4) & 3 {
            1 => Some("MOS 6581"),
            2 => Some("MOS 8580"),
            3 => Some("MOS 6581 and 8580"),
            _ => None,
        };
        header.chips += u8::from(version >= 3 && data[122] != 0);
        header.chips += u8::from(version >= 4 && data[123] != 0);
    }
    Some(header)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(magic: &[u8; 4], version: u8, flags: u8, second: u8, third: u8) -> Vec<u8> {
        let mut bytes = vec![0u8; 124];
        bytes[..4].copy_from_slice(magic);
        bytes[5] = version;
        bytes[15] = 3;
        bytes[22..30].copy_from_slice(b"Commando");
        bytes[54..65].copy_from_slice(b"Rob Hubbard");
        bytes[86..96].copy_from_slice(b"1985 Elite");
        bytes[119] = flags;
        bytes[122] = second;
        bytes[123] = third;
        bytes
    }

    #[test]
    fn reads_the_fields() {
        let header = parse(&file(b"PSID", 2, 0b0001_0100, 0, 0)).unwrap();
        assert_eq!(header.format, "PSID");
        assert_eq!(header.title, "Commando");
        assert_eq!(header.author, "Rob Hubbard");
        assert_eq!(header.released, "1985 Elite");
        assert_eq!(header.songs, 3);
        assert_eq!(header.model, Some("MOS 6581"));
        assert_eq!(header.clock, Some("PAL"));
        assert_eq!(header.chips, 1);
    }

    #[test]
    fn reads_accents() {
        let mut bytes = file(b"PSID", 2, 0, 0, 0);
        bytes[54..65].fill(0);
        bytes[54..64].copy_from_slice(b"S\xF8ren Lund");
        assert_eq!(parse(&bytes).unwrap().author, "Søren Lund");
    }

    #[test]
    fn version_one_has_no_flags() {
        let header = parse(&file(b"PSID", 1, 0b0001_0100, 0x42, 0)[..118]).unwrap();
        assert_eq!(header.model, None);
        assert_eq!(header.chips, 1);
    }

    #[test]
    fn counts_chips_by_version() {
        assert_eq!(parse(&file(b"RSID", 2, 0, 0x42, 0)).unwrap().chips, 1);
        assert_eq!(parse(&file(b"RSID", 3, 0, 0x42, 0x50)).unwrap().chips, 2);
        assert_eq!(parse(&file(b"RSID", 4, 0, 0x42, 0x50)).unwrap().chips, 3);
    }

    #[test]
    fn anything_else_isnt_a_header() {
        assert!(parse(b"").is_none());
        assert!(parse(&file(b"MThd", 2, 0, 0, 0)).is_none());
        assert!(parse(&file(b"PSID", 2, 0, 0, 0)[..100]).is_none());
    }
}
