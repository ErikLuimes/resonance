use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::extract::*;
use super::similar::Index;
use super::store::{FeatureRow, Status, Store, MAX_ATTEMPTS};
use super::*;
use crate::databases::Databases;

/// Frames of a PAL tune where `f` returns each frame's writes.
fn run(frames: u32, mut f: impl FnMut(u32) -> Vec<(u32, u8, u8)>) -> Fingerprint {
    let mut x = Extractor::new(true, 1, frames);
    for i in 0..frames {
        x.frame(&f(i));
    }
    x.finish()
}

/// Voice 1 at full volume with pulse, instant attack, full sustain.
fn setup() -> Vec<(u32, u8, u8)> {
    vec![(0, 0x18, 0x0F), (0, 0x05, 0x00), (0, 0x06, 0xF0), (0, 0x03, 0x08)]
}

fn freq(hz: f64) -> [u8; 2] {
    ((hz * 16_777_216.0 / 985_248.0).round() as u16).to_le_bytes()
}

#[test]
fn silence_is_silent() {
    let fp = run(500, |_| Vec::new());
    assert!(fp.is_silent());
    assert_eq!(fp.tags, 0);
    assert_eq!(fp.notes_per_sec, 0.0);
}

#[test]
fn a_held_note_fills_its_lane() {
    let [lo, hi] = freq(440.0);
    let fp = run(256, |i| {
        let mut w = Vec::new();
        if i == 0 {
            w = setup();
            w.extend([(0, 0x00, lo), (0, 0x01, hi), (0, 0x04, 0x41)]);
        }
        w
    });
    assert!(fp.activity[0].iter().all(|&a| a > 200), "{:?}", fp.activity[0]);
    assert!(fp.activity[1].iter().all(|&a| a == 0));
    assert!((fp.mix[2] - 1.0).abs() < 1e-6, "all pulse: {:?}", fp.mix);
    assert!((fp.pitch_mean - 69.0).abs() < 0.1, "A4: {}", fp.pitch_mean);
    assert_eq!(fp.arp_rate, 0.0);
    assert!(!fp.is_silent());
}

#[test]
fn release_fades_rather_than_snapping() {
    let mut x = Extractor::new(true, 1, 100);
    let mut w = setup();
    w.extend([(0, 0x00, 0x00), (0, 0x01, 0x10), (0, 0x06, 0xF9), (0, 0x04, 0x41)]);
    x.frame(&w);
    x.frame(&[(0, 0x04, 0x40)]);
    let after_one = x.level(0);
    assert!(after_one > 0.9 && after_one < 1.0, "{after_one}");
}

#[test]
fn counts_gate_edges_including_hard_restarts() {
    // A note every 10 frames, each a gate off and on inside one frame.
    let fp = run(500, |i| {
        let mut w = if i == 0 { setup() } else { Vec::new() };
        w.extend([(0, 0x00, 0x00), (0, 0x01, 0x10)]);
        if i % 10 == 0 {
            w.extend([(10, 0x04, 0x40), (20, 0x04, 0x41)]);
        }
        w
    });
    let secs = 500.0 / 50.12;
    assert!((fp.notes_per_sec - 50.0 / secs).abs() < 0.1, "{}", fp.notes_per_sec);
}

#[test]
fn an_arpeggio_reads_as_one_and_vibrato_doesnt() {
    let chord = [261.63, 329.63, 392.0].map(freq);
    let arp = run(500, |i| {
        let mut w = if i == 0 { setup() } else { Vec::new() };
        let [lo, hi] = chord[i as usize % 3];
        w.extend([(0, 0x00, lo), (0, 0x01, hi), (0, 0x04, 0x41)]);
        w
    });
    assert!(arp.arp_rate > 40.0, "{}", arp.arp_rate);
    assert!(arp.tags & tag::ARPEGGIOS != 0);

    let vib = run(500, |i| {
        let mut w = if i == 0 { setup() } else { Vec::new() };
        let cents = 30.0 * (i as f64 * std::f64::consts::TAU / 8.0).sin();
        let [lo, hi] = freq(440.0 * 2f64.powf(cents / 1200.0));
        w.extend([(0, 0x00, lo), (0, 0x01, hi), (0, 0x04, 0x41)]);
        w
    });
    assert_eq!(vib.arp_rate, 0.0);
    assert!(vib.vibrato_rate > 10.0, "{}", vib.vibrato_rate);
    assert!(vib.tags & tag::VIBRATO != 0);
}

#[test]
fn spots_d418_digis() {
    let fp = run(200, |i| {
        let mut w = if i == 0 { setup() } else { Vec::new() };
        // About 8 kHz of 4-bit samples.
        w.extend((0..160).map(|k| (k * 120, 0x18, (k % 16) as u8)));
        w
    });
    assert!(fp.digi > 0.99, "{}", fp.digi);
    assert!(fp.d418_rate > 7000.0, "{}", fp.d418_rate);
    assert!(fp.tags & tag::DIGI != 0);
    assert!(fp.is_silent() == false);
}

#[test]
fn measures_filter_sweeps_ring_and_pulse_width() {
    let [lo, hi] = freq(110.0);
    let fp = run(300, |i| {
        let mut w = if i == 0 { setup() } else { Vec::new() };
        let cutoff = (i * 6 % 2048) as u16;
        let pw = 0x200 + (i % 50) * 40;
        w.extend([
            (0, 0x00, lo),
            (0, 0x01, hi),
            (0, 0x02, pw as u8),
            (0, 0x03, (pw >> 8) as u8),
            (0, 0x15, (cutoff & 7) as u8),
            (0, 0x16, (cutoff >> 3) as u8),
            (0, 0x17, 0x01),
            (0, 0x18, 0x1F),
            (0, 0x04, 0x41),
        ]);
        w
    });
    assert!(fp.filter_usage > 0.99, "{}", fp.filter_usage);
    assert!(fp.cutoff_motion > 0.1, "{}", fp.cutoff_motion);
    assert!(fp.tags & tag::FILTER_SWEEPS != 0);
    assert!(fp.pwm_depth > 0.4, "{}", fp.pwm_depth);
    assert!(fp.pulse_bass > 0.99, "{}", fp.pulse_bass);
    assert_eq!(fp.ring, 0.0);

    let ring = run(100, |i| {
        let mut w = if i == 0 { setup() } else { Vec::new() };
        w.extend([(0, 0x00, lo), (0, 0x01, hi), (0, 0x04, 0x15)]);
        w
    });
    assert!(ring.ring > 0.99 && ring.tags & tag::RING_MOD != 0);
}

#[test]
fn feature_vectors_are_finite() {
    let fp = run(10, |_| Vec::new());
    assert!(fp.features().iter().all(|x| x.is_finite()));
    assert!(fp.traits().iter().all(|x| (0.0..=1.0).contains(x)));
}

#[test]
#[ignore = "reads the HVSC collection; run with --ignored"]
fn scans_real_tunes() {
    let root = std::path::PathBuf::from(std::env::var("HOME").unwrap())
        .join("Library/Application Support/phosphor/HVSC");
    for rel in [
        "MUSICIANS/H/Hubbard_Rob/Commando.sid",
        "MUSICIANS/H/Hubbard_Rob/Monty_on_the_Run.sid",
        "MUSICIANS/G/Galway_Martin/Arkanoid.sid",
        "MUSICIANS/T/Tel_Jeroen/Cybernoid_II.sid",
        "MUSICIANS/H/Hubbard_Rob/Delta.sid",
    ] {
        let Ok(data) = std::fs::read(root.join(rel)) else {
            eprintln!("{rel}: not in the collection");
            continue;
        };
        let t = std::time::Instant::now();
        let fp = scan_tune(&data, 1, 180.0, &|| false).unwrap().unwrap();
        let lanes: Vec<String> = fp
            .activity
            .iter()
            .map(|l| l.iter().step_by(4).map(|&a| b" .:-=+*#%@"[a as usize * 9 / 255] as char).collect())
            .collect();
        eprintln!("{rel} in {:?}\n  {}\n  {}\n  {}", t.elapsed(), lanes[0], lanes[1], lanes[2]);
        let mut fp = fp;
        fp.activity = [[0; BINS]; 3];
        eprintln!("  {fp:?}");
    }
}

// ── Store, scan and similarity ───────────────────────────────────────────────

/// A PSID whose init sets up voice 1 (pulse, gate on) and whose play
/// routine writes a rising counter, plus `step`, to its pitch high byte.
fn psid(songs: u16, step: u8) -> Vec<u8> {
    let init: &[u8] = &[
        0xA9, 0x0F, 0x8D, 0x18, 0xD4, // LDA #$0F, STA $D418
        0xA9, 0x00, 0x8D, 0x05, 0xD4, // AD
        0xA9, 0xF0, 0x8D, 0x06, 0xD4, // SR
        0xA9, 0x08, 0x8D, 0x03, 0xD4, // PW hi
        0xA9, 0x41, 0x8D, 0x04, 0xD4, // pulse + gate
        0x60,
    ];
    let play_at = 0x1000 + init.len() as u16;
    let play: &[u8] = &[
        0xAD, 0x00, 0x20, // LDA $2000
        0x18, 0x69, step, // CLC, ADC #step
        0x8D, 0x00, 0x20, // STA $2000
        0x8D, 0x01, 0xD4, // STA $D401
        0x60,
    ];
    let mut h = vec![0u8; 0x7C];
    h[0..4].copy_from_slice(b"PSID");
    h[4..6].copy_from_slice(&2u16.to_be_bytes());
    h[6..8].copy_from_slice(&0x7Cu16.to_be_bytes());
    h[8..10].copy_from_slice(&0x1000u16.to_be_bytes());
    h[10..12].copy_from_slice(&0x1000u16.to_be_bytes());
    h[12..14].copy_from_slice(&play_at.to_be_bytes());
    h[14..16].copy_from_slice(&songs.to_be_bytes());
    h[16..18].copy_from_slice(&1u16.to_be_bytes());
    h[0x16..0x1A].copy_from_slice(b"Test");
    h[0x77] = 0x04; // PAL
    h.extend_from_slice(init);
    h.extend_from_slice(play);
    h
}

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("resonance-fp-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn wait_for(scanner: &Scanner) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while scanner.is_running() {
        assert!(Instant::now() < deadline, "scan didn't finish");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn emulates_a_psid() {
    let fp = scan_tune(&psid(1, 1), 1, 10.0, &|| false).unwrap().unwrap();
    assert!((fp.scanned_secs - 10.0).abs() < 0.05, "{}", fp.scanned_secs);
    assert!(fp.voice_level[0] > 0.9, "{:?}", fp.voice_level);
    assert!(fp.mix[2] > 0.99, "{:?}", fp.mix);
    assert!(fp.arp_rate > 1.0, "the pitch climbs: {}", fp.arp_rate);
    assert!(scan_tune(&psid(1, 1), 1, 10.0, &|| true).unwrap().is_none());
    assert!(scan_tune(b"not a sid", 1, 1.0, &|| false).is_err());
}

#[test]
fn store_round_trips_by_path_and_start_song() {
    let store = Store::in_memory().unwrap();
    let fp = scan_tune(&psid(1, 1), 1, 4.0, &|| false).unwrap().unwrap();
    store.set_tune("MUSICIANS/T/Test/A.sid", "abc", 2, 3).unwrap();
    store.mark_scanning("abc", 2).unwrap();
    assert_eq!(store.by_path("MUSICIANS/T/Test/A.sid", None).unwrap(), None);
    store.save("abc", 2, &fp).unwrap();

    let (sub, back) = store.by_path("MUSICIANS/T/Test/A.sid", None).unwrap().unwrap();
    assert_eq!(sub, 2);
    assert_eq!(back.activity, fp.activity);
    assert_eq!(back.tags, fp.tags);
    assert!((back.arp_rate - fp.arp_rate).abs() < 1e-4);
    assert!(store.by_path("MUSICIANS/T/Test/A.sid", Some(1)).unwrap().is_none());
    assert_eq!(store.status("abc", 2).unwrap(), Some((Status::Done, 1)));
    assert_eq!(store.counts().unwrap(), (1, 0));
}

#[test]
fn an_interrupted_scan_is_retried_then_given_up_on() {
    let store = Store::in_memory().unwrap();
    store.mark_scanning("abc", 1).unwrap();
    assert_eq!(store.status("abc", 1).unwrap(), Some((Status::Scanning, 1)));
    // Stopped on purpose: doesn't count.
    store.forget_attempt("abc", 1).unwrap();
    store.mark_scanning("abc", 1).unwrap();
    assert_eq!(store.status("abc", 1).unwrap(), Some((Status::Scanning, 1)));
    store.mark_scanning("abc", 1).unwrap();
    assert_eq!(store.status("abc", 1).unwrap(), Some((Status::Scanning, MAX_ATTEMPTS)));
}

#[test]
fn forgetting_failed_keeps_the_rest_and_clear_forgets_all() {
    let store = Store::in_memory().unwrap();
    let fp = scan_tune(&psid(1, 1), 1, 4.0, &|| false).unwrap().unwrap();
    store.mark_scanning("good", 1).unwrap();
    store.save("good", 1, &fp).unwrap();
    store.mark_scanning("bad", 1).unwrap();
    store.mark_failed("bad", 1, "crashed").unwrap();
    assert_eq!(store.counts().unwrap(), (1, 1));

    store.forget_failed().unwrap();
    assert_eq!(store.counts().unwrap(), (1, 0));
    assert_eq!(store.status("bad", 1).unwrap(), None);

    store.clear().unwrap();
    assert_eq!(store.counts().unwrap(), (0, 0));
}

#[test]
fn scans_a_collection_and_resumes_without_rescanning() {
    let dir = temp_dir("scan");
    let root = dir.join("HVSC");
    let tunes: Vec<ScanTune> = (0..4u8)
        .map(|i| {
            let rel = format!("MUSICIANS/T/Test/Tune_{i}.sid");
            let path = root.join(&rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, psid(2, i + 1)).unwrap();
            ScanTune { path, rel }
        })
        .collect();
    let again = |t: &[ScanTune]| {
        t.iter()
            .map(|t| ScanTune { path: t.path.clone(), rel: t.rel.clone() })
            .collect::<Vec<_>>()
    };

    let db = dir.join("fingerprints.sqlite");
    let fps = Fingerprints::new(db.clone());
    fps.scanner().start(again(&tunes), 8, Arc::new(Databases::default()));
    wait_for(fps.scanner());
    let p = fps.scanner().progress();
    assert!(p.finished && p.error.is_none(), "{p:?}");
    assert_eq!((p.done, p.failed, p.total), (8, 0, 8));
    assert_eq!(p.revision, 8);

    let (sub, fp) = fps.lookup("MUSICIANS/T/Test/Tune_2.sid", None).unwrap();
    assert_eq!(sub, 1);
    assert!(!fp.is_silent());
    assert!(fps.lookup("MUSICIANS/T/Test/Tune_2.sid", Some(2)).is_some());

    // A fresh scanner on the same store finds everything done.
    let resumed = Scanner::new(db);
    resumed.start(again(&tunes), 8, Arc::new(Databases::default()));
    wait_for(&resumed);
    let p = resumed.progress();
    assert!(p.finished, "{p:?}");
    assert_eq!((p.done, p.revision), (8, 0), "nothing rescanned");

    let similar = fps.index_for(None);
    assert!(similar.contains("MUSICIANS/T/Test/Tune_0.sid"));
    let hits = similar.similar("MUSICIANS/T/Test/Tune_0.sid", None, 10);
    assert_eq!(hits.len(), 3, "one per other file");
    assert!(hits.iter().all(|m| m.path != "MUSICIANS/T/Test/Tune_0.sid"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn stopping_a_scan_keeps_its_place() {
    let dir = temp_dir("stop");
    let path = dir.join("Long.sid");
    std::fs::write(&path, psid(3, 1)).unwrap();
    let scanner = Scanner::new(dir.join("fp.sqlite"));
    scanner.set_paused(true);
    scanner.start(
        vec![ScanTune { path, rel: "Long.sid".into() }],
        3,
        Arc::new(Databases::default()),
    );
    std::thread::sleep(Duration::from_millis(100));
    assert!(scanner.progress().paused && scanner.progress().done == 0);
    scanner.cancel();
    assert!(!scanner.is_running());
    assert!(!scanner.progress().finished);
    let _ = std::fs::remove_dir_all(&dir);
}

fn row(path: &str, features: [f32; FEATURES]) -> FeatureRow {
    FeatureRow { path: path.into(), subtune: 1, is_start: true, features }
}

#[test]
fn similarity_ranks_the_closest_first() {
    let base = [0.5f32; FEATURES];
    let mut near = base;
    near[4] += 0.1;
    let mut far = base;
    far[4] += 3.0;
    far[7] -= 2.0;
    let mut other = base;
    other[13] += 1.0;
    let index = Index::build(vec![
        row("a", base),
        row("near", near),
        row("far", far),
        row("other", other),
        row("b", [0.4; FEATURES]),
    ]);
    assert!(index.score("a", "near").unwrap() > index.score("a", "far").unwrap());
    assert!((index.score("a", "a").unwrap() - 1.0).abs() < 1e-4);
    assert_eq!(index.score("a", "missing"), None);
    let hits = index.similar("a", None, 2);
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].path, "near");
    assert!(hits[0].score > hits[1].score);
    assert!(index.similar("missing", None, 5).is_empty());
}

#[test]
fn similarity_survives_constant_features() {
    let index = Index::build(vec![row("a", [1.0; FEATURES]), row("b", [1.0; FEATURES])]);
    let hits = index.similar("a", None, 5);
    assert_eq!(hits.len(), 1);
    assert!(hits[0].score.is_finite());
}
