//! Fingerprints on disk: one SQLite file in Resonance's data folder, next
//! to the saved session.
//!
//! `fingerprints` is keyed by MD5 + subtune, so a tune that moves within
//! HVSC (or appears twice) keeps its scan; `tunes` maps each collection
//! path to the MD5 it had when last scanned. Every scan first writes its
//! row as `scanning`; a row still `scanning` when the next scan starts was
//! cut short, perhaps by a crash in the emulator, and is retried once
//! before it's given up on.

use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension, Row};

use super::extract::{Fingerprint, BINS, FEATURES};

/// Bump when the extractor changes what it measures: rows from another
/// version count as unscanned and are redone.
pub(crate) const EXTRACTOR_VERSION: i64 = 1;
/// The tables' layout; another value drops them (they're only a cache).
const SCHEMA: i64 = 1;
/// Scans of one subtune before it's marked failed for good.
pub(crate) const MAX_ATTEMPTS: i64 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Status {
    Scanning = 0,
    Done = 1,
    Failed = 2,
}

impl Status {
    fn from_i64(v: i64) -> Self {
        match v {
            1 => Status::Done,
            2 => Status::Failed,
            _ => Status::Scanning,
        }
    }
}

/// A scanned subtune, for "Sounds like".
pub(crate) struct FeatureRow {
    pub path: String,
    pub subtune: u16,
    pub is_start: bool,
    pub features: [f32; FEATURES],
}

pub(crate) struct Store {
    conn: Connection,
}

const FP_COLUMNS: &str = "scanned_secs, is_pal, num_chips, activity, \
    mix_tri, mix_saw, mix_pul, mix_noi, notes_per_sec, arp_rate, vibrato_rate, \
    filter_usage, cutoff_mean, cutoff_spread, cutoff_motion, ring, sync, d418_rate, digi, \
    pwm_depth, noise_hits, pulse_bass, pitch_mean, pitch_spread, level1, level2, level3, tags";

impl Store {
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        Self::setup(Connection::open(path)?)
    }

    #[cfg(test)]
    pub fn in_memory() -> rusqlite::Result<Self> {
        Self::setup(Connection::open_in_memory()?)
    }

    fn setup(conn: Connection) -> rusqlite::Result<Self> {
        // WAL: readers (the UI's lookups) never wait on the scan's writes.
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        let schema: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if schema != SCHEMA {
            conn.execute_batch("DROP TABLE IF EXISTS fingerprints; DROP TABLE IF EXISTS tunes;")?;
        }
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS tunes (
                path TEXT PRIMARY KEY,
                md5 TEXT NOT NULL,
                start_song INTEGER NOT NULL,
                songs INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS tunes_md5 ON tunes(md5);
            CREATE TABLE IF NOT EXISTS fingerprints (
                md5 TEXT NOT NULL,
                subtune INTEGER NOT NULL,
                status INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                version INTEGER NOT NULL,
                error TEXT,
                scanned_secs REAL, is_pal INTEGER, num_chips INTEGER, activity BLOB,
                mix_tri REAL, mix_saw REAL, mix_pul REAL, mix_noi REAL,
                notes_per_sec REAL, arp_rate REAL, vibrato_rate REAL,
                filter_usage REAL, cutoff_mean REAL, cutoff_spread REAL, cutoff_motion REAL,
                ring REAL, sync REAL, d418_rate REAL, digi REAL, pwm_depth REAL,
                noise_hits REAL, pulse_bass REAL, pitch_mean REAL, pitch_spread REAL,
                level1 REAL, level2 REAL, level3 REAL, tags INTEGER,
                PRIMARY KEY (md5, subtune)
            );",
        )?;
        conn.pragma_update(None, "user_version", SCHEMA)?;
        Ok(Self { conn })
    }

    /// Remember which MD5 a collection path holds.
    pub fn set_tune(&self, path: &str, md5: &str, start_song: u16, songs: u16) -> rusqlite::Result<()> {
        self.conn.execute(
            "INSERT INTO tunes (path, md5, start_song, songs) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(path) DO UPDATE SET md5 = ?2, start_song = ?3, songs = ?4",
            params![path, md5, start_song, songs],
        )?;
        Ok(())
    }

    /// A subtune's scan state under the current extractor, and its attempts.
    pub fn status(&self, md5: &str, subtune: u16) -> rusqlite::Result<Option<(Status, i64)>> {
        self.conn
            .query_row(
                "SELECT status, attempts FROM fingerprints
                 WHERE md5 = ?1 AND subtune = ?2 AND version = ?3",
                params![md5, subtune, EXTRACTOR_VERSION],
                |r| Ok((Status::from_i64(r.get(0)?), r.get(1)?)),
            )
            .optional()
    }

    /// Record that a scan is starting, before it runs.
    pub fn mark_scanning(&self, md5: &str, subtune: u16) -> rusqlite::Result<()> {
        self.conn.execute(
            "INSERT INTO fingerprints (md5, subtune, status, attempts, version)
             VALUES (?1, ?2, 0, 1, ?3)
             ON CONFLICT(md5, subtune) DO UPDATE SET
                status = 0,
                attempts = CASE WHEN version = ?3 THEN attempts + 1 ELSE 1 END,
                version = ?3, error = NULL",
            params![md5, subtune, EXTRACTOR_VERSION],
        )?;
        Ok(())
    }

    /// Undo `mark_scanning`'s attempt for a scan that was stopped.
    pub fn forget_attempt(&self, md5: &str, subtune: u16) -> rusqlite::Result<()> {
        self.conn.execute(
            "UPDATE fingerprints SET attempts = MAX(attempts - 1, 0)
             WHERE md5 = ?1 AND subtune = ?2 AND status = 0",
            params![md5, subtune],
        )?;
        Ok(())
    }

    pub fn mark_failed(&self, md5: &str, subtune: u16, error: &str) -> rusqlite::Result<()> {
        self.conn.execute(
            "UPDATE fingerprints SET status = 2, error = ?3 WHERE md5 = ?1 AND subtune = ?2",
            params![md5, subtune, error],
        )?;
        Ok(())
    }

    pub fn save(&self, md5: &str, subtune: u16, fp: &Fingerprint) -> rusqlite::Result<()> {
        let activity: Vec<u8> = fp.activity.iter().flatten().copied().collect();
        self.conn.execute(
            &format!(
                "INSERT OR REPLACE INTO fingerprints
                 (md5, subtune, status, attempts, version, error, {FP_COLUMNS})
                 VALUES (?1, ?2, 1,
                    COALESCE((SELECT attempts FROM fingerprints WHERE md5 = ?1 AND subtune = ?2), 1),
                    ?3, NULL, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17,
                    ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30, ?31)"
            ),
            params![
                md5,
                subtune,
                EXTRACTOR_VERSION,
                fp.scanned_secs,
                fp.is_pal,
                fp.num_chips,
                activity,
                fp.mix[0],
                fp.mix[1],
                fp.mix[2],
                fp.mix[3],
                fp.notes_per_sec,
                fp.arp_rate,
                fp.vibrato_rate,
                fp.filter_usage,
                fp.cutoff_mean,
                fp.cutoff_spread,
                fp.cutoff_motion,
                fp.ring,
                fp.sync,
                fp.d418_rate,
                fp.digi,
                fp.pwm_depth,
                fp.noise_hits,
                fp.pulse_bass,
                fp.pitch_mean,
                fp.pitch_spread,
                fp.voice_level[0],
                fp.voice_level[1],
                fp.voice_level[2],
                fp.tags,
            ],
        )?;
        Ok(())
    }

    /// The fingerprint of the tune at a collection path: `subtune`, or the
    /// tune's start song. Also returns the subtune it's for.
    pub fn by_path(&self, path: &str, subtune: Option<u16>) -> rusqlite::Result<Option<(u16, Fingerprint)>> {
        self.conn
            .query_row(
                &format!(
                    "SELECT f.subtune, {FP_COLUMNS} FROM tunes t
                     JOIN fingerprints f ON f.md5 = t.md5
                        AND f.subtune = COALESCE(?2, t.start_song)
                     WHERE t.path = ?1 AND f.status = 1 AND f.version = ?3"
                ),
                params![path, subtune, EXTRACTOR_VERSION],
                |r| Ok((r.get(0)?, read_fingerprint(r, 1)?)),
            )
            .optional()
    }

    /// Every scanned subtune's feature vector, with a path that holds it.
    pub fn features(&self) -> rusqlite::Result<Vec<FeatureRow>> {
        let mut stmt = self.conn.prepare(&format!(
            "SELECT t.path, f.subtune, f.subtune = t.start_song, {FP_COLUMNS}
             FROM fingerprints f JOIN tunes t ON t.md5 = f.md5
             WHERE f.status = 1 AND f.version = ?1"
        ))?;
        let rows = stmt.query_map(params![EXTRACTOR_VERSION], |r| {
            let fp = read_fingerprint(r, 3)?;
            Ok(FeatureRow {
                path: r.get(0)?,
                subtune: r.get(1)?,
                is_start: r.get(2)?,
                features: fp.features(),
            })
        })?;
        rows.collect()
    }

    /// Subtunes scanned and given up on, under the current extractor.
    pub fn counts(&self) -> rusqlite::Result<(u32, u32)> {
        self.conn.query_row(
            "SELECT COALESCE(SUM(status = 1), 0), COALESCE(SUM(status = 2), 0)
             FROM fingerprints WHERE version = ?1",
            params![EXTRACTOR_VERSION],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
    }
}

fn read_fingerprint(r: &Row, at: usize) -> rusqlite::Result<Fingerprint> {
    let f = |i: usize| -> rusqlite::Result<f32> { Ok(r.get::<_, Option<f64>>(at + i)?.unwrap_or(0.0) as f32) };
    let blob: Vec<u8> = r.get::<_, Option<Vec<u8>>>(at + 3)?.unwrap_or_default();
    let mut activity = [[0u8; BINS]; 3];
    for (i, lane) in activity.iter_mut().enumerate() {
        if let Some(src) = blob.get(i * BINS..(i + 1) * BINS) {
            lane.copy_from_slice(src);
        }
    }
    Ok(Fingerprint {
        scanned_secs: f(0)?,
        is_pal: r.get::<_, Option<bool>>(at + 1)?.unwrap_or(true),
        num_chips: r.get::<_, Option<u8>>(at + 2)?.unwrap_or(1),
        activity,
        mix: [f(4)?, f(5)?, f(6)?, f(7)?],
        notes_per_sec: f(8)?,
        arp_rate: f(9)?,
        vibrato_rate: f(10)?,
        filter_usage: f(11)?,
        cutoff_mean: f(12)?,
        cutoff_spread: f(13)?,
        cutoff_motion: f(14)?,
        ring: f(15)?,
        sync: f(16)?,
        d418_rate: f(17)?,
        digi: f(18)?,
        pwm_depth: f(19)?,
        noise_hits: f(20)?,
        pulse_bass: f(21)?,
        pitch_mean: f(22)?,
        pitch_spread: f(23)?,
        voice_level: [f(24)?, f(25)?, f(26)?],
        tags: r.get::<_, Option<u32>>(at + 27)?.unwrap_or(0),
    })
}
