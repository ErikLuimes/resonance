//! Smart playlists: choosing and ordering tunes by a recipe. Everything here
//! works on plain `Tune` values, so it's tested without a collection; `ffi`
//! fills them in from the library, the fingerprints and the heard list.
//!
//! `design/smart-playlists` has the reasoning and how intensity was checked.

use rand::seq::SliceRandom;
use rand::Rng;
use std::collections::HashSet;

/// Played tunes needed before "different from what you play" means anything.
pub(crate) const MIN_HISTORY: usize = 25;

/// The share of a rising playlist that stays chill before it starts to climb.
const CHILL_SHARE: f64 = 0.6;
/// How intense (0–1, against the pool) the climb gets by the end.
const PEAK: f64 = 0.95;
/// Tunes whose title matches more often than this aren't versions of one
/// piece: "Tune", "Intro" and the like.
const MAX_VERSIONS: usize = 12;

/// How energetic a whole list should be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Energy {
    Any,
    Calm,
    Medium,
    Intense,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct Tune {
    pub path: String,
    pub title: String,
    pub author: String,
    /// Zero when the length isn't known.
    pub secs: u32,
    pub heard: bool,
    /// Whether the fingerprint scan has reached it.
    pub scanned: bool,
    /// Notes started per second, all voices.
    pub notes: f32,
    /// Noise hits per second.
    pub drums: f32,
    /// The voices' levels added up.
    pub loudness: f32,
    /// The loudest voice's level.
    pub peak: f32,
    pub arps: f32,
    /// Share of the frames that play samples.
    pub digi: f32,
    /// Cosine to the average of the heard tunes.
    pub to_heard: f32,
    /// Where it ranks in `intensities`' pool, 0–1.
    pub intensity: f32,
    /// The folder a MUSICIANS tune is in, "Hubbard_Rob"; the section's otherwise.
    pub folder: String,
    pub year: Option<u16>,
    /// Sound traits, in `SOUNDS` order.
    pub sounds: [f32; SOUNDS],
    pub is_8580: bool,
    /// How many SID chips it uses; 0 until it's scanned.
    pub chips: u8,
}

/// Arpeggios, filter, drums, bass, pulse width, samples, ring mod and sync.
pub(crate) const SOUNDS: usize = 8;

/// What counts as having plenty of each sound: the top quarter of the music,
/// or the top half when already down to a few composers' tunes.
pub(crate) fn plenty(tunes: &[Tune], narrowed: bool) -> [f32; SOUNDS] {
    std::array::from_fn(|k| {
        let mut values: Vec<f32> = tunes.iter().filter(|t| t.is_music()).map(|t| t.sounds[k]).collect();
        values.sort_by(f32::total_cmp);
        values.get(values.len() * if narrowed { 2 } else { 3 } / 4).copied().unwrap_or(0.0)
    })
}

impl Tune {
    /// Music rather than silence, a digi sample or a tune with no title:
    /// what the chosen-by-sound recipes pick from.
    fn is_music(&self) -> bool {
        self.scanned && self.peak > 0.02 && self.notes > 0.3 && self.digi < 0.1 && !self.title.starts_with("<?")
    }

    /// Calm: few notes, hardly any drums, in the lower part of the pool.
    fn is_chill(&self) -> bool {
        self.notes <= 3.5 && self.drums < 1.0 && self.intensity < 0.2
    }

    /// Whether it suits a list that's calm or intense throughout. Wider than
    /// `is_chill`, which has an hour's arc to keep from sounding busy.
    pub fn fits_energy(&self, energy: Energy) -> bool {
        match energy {
            Energy::Any => true,
            Energy::Calm => self.notes <= 6.0 && self.intensity < 0.35,
            Energy::Medium => (0.35..0.6).contains(&self.intensity),
            Energy::Intense => self.intensity >= 0.6,
        }
    }
}

/// Rank each tune's pace, drums, loudness and arpeggios against the rest of
/// `pool`, weigh them, and rank the result: 0 is the calmest of the pool and
/// 1 the most intense. Pace counts most, as it's what a listener notices
/// first; see the design note.
pub(crate) fn rate_intensity(tunes: &mut [Tune], pool: &[usize]) {
    let ranks = |value: &dyn Fn(&Tune) -> f32, tunes: &[Tune]| -> Vec<f32> {
        let mut sorted: Vec<f32> = pool.iter().map(|&i| value(&tunes[i])).collect();
        sorted.sort_by(f32::total_cmp);
        let len = sorted.len().max(1) as f32;
        pool.iter()
            .map(|&i| sorted.partition_point(|&x| x < value(&tunes[i])) as f32 / len)
            .collect()
    };
    let notes = ranks(&|t| t.notes, tunes);
    let drums = ranks(&|t| t.drums, tunes);
    let loudness = ranks(&|t| t.loudness, tunes);
    let arps = ranks(&|t| t.arps, tunes);
    let blended: Vec<f32> =
        (0..pool.len()).map(|k| 0.4 * notes[k] + 0.25 * drums[k] + 0.2 * loudness[k] + 0.15 * arps[k]).collect();
    let mut sorted = blended.clone();
    sorted.sort_by(f32::total_cmp);
    let len = sorted.len().max(1) as f32;
    for (k, &i) in pool.iter().enumerate() {
        tunes[i].intensity = sorted.partition_point(|&x| x < blended[k]) as f32 / len;
    }
}

/// Whether a rising playlist can use this tune: a whole tune, not a jingle
/// or an epic that would take over the arc.
fn fits_arc(t: &Tune) -> bool {
    t.is_music() && (120..=330).contains(&t.secs)
}

/// About `total` seconds that stay chill, then climb: at most one tune per
/// composer while there are others to pick. Returns indexes into `tunes`, in
/// playing order, and how many tunes it chose from. Only `allowed` tunes count,
/// and intensity is against those: the calmest of one composer's are their
/// calm ones, however they'd rank against everybody.
pub(crate) fn rising(
    tunes: &mut [Tune],
    total: u32,
    allowed: &dyn Fn(&Tune) -> bool,
    rng: &mut impl Rng,
) -> (Vec<usize>, usize) {
    let pool: Vec<usize> = (0..tunes.len()).filter(|&i| fits_arc(&tunes[i]) && allowed(&tunes[i])).collect();
    if pool.is_empty() {
        return (Vec::new(), 0);
    }
    rate_intensity(tunes, &pool);
    let mut by_intensity = pool.clone();
    by_intensity.sort_by(|&a, &b| tunes[a].intensity.total_cmp(&tunes[b].intensity));
    let chill: Vec<usize> = by_intensity.iter().copied().filter(|&i| tunes[i].is_chill()).collect();

    let mut chosen = Vec::new();
    let mut used = HashSet::new();
    let mut authors = HashSet::new();
    let mut elapsed = 0u32;
    while elapsed < total {
        let progress = f64::from(elapsed) / f64::from(total.max(1));
        let candidates: &[usize] = if progress < CHILL_SHARE && !chill.is_empty() {
            &chill
        } else {
            // The chill stretch ends about a fifth of the way up the pool.
            let climb = ((progress - CHILL_SHARE).max(0.0) / (1.0 - CHILL_SHARE)).min(1.0);
            let wanted = 0.2 + climb * (PEAK - 0.2);
            let width = (by_intensity.len() as f64 * 0.06).ceil() as usize;
            let start = ((wanted - 0.03).max(0.0) * by_intensity.len() as f64) as usize;
            let start = start.min(by_intensity.len().saturating_sub(width.max(1)));
            &by_intensity[start..(start + width.max(1)).min(by_intensity.len())]
        };
        let pick = pick_new(candidates, &used, &authors, tunes, rng)
            .or_else(|| pick_new(&by_intensity, &used, &authors, tunes, rng));
        let Some(i) = pick else { break };
        used.insert(i);
        authors.insert(tunes[i].author.as_str().to_owned());
        chosen.push(i);
        elapsed += tunes[i].secs;
    }
    (chosen, pool.len())
}

/// Taking turns between the calm third and the intense third of what's
/// `allowed`, for about `total` seconds. Returns the order and the pool's size.
pub(crate) fn alternating(
    tunes: &mut [Tune],
    total: u32,
    allowed: &dyn Fn(&Tune) -> bool,
    rng: &mut impl Rng,
) -> (Vec<usize>, usize) {
    let pool: Vec<usize> = (0..tunes.len()).filter(|&i| fits_arc(&tunes[i]) && allowed(&tunes[i])).collect();
    if pool.is_empty() {
        return (Vec::new(), 0);
    }
    rate_intensity(tunes, &pool);
    let mut sorted = pool.clone();
    sorted.sort_by(|&a, &b| tunes[a].intensity.total_cmp(&tunes[b].intensity));
    let third = sorted.len().div_ceil(3);
    let (calm, intense) = (&sorted[..third], &sorted[sorted.len() - third..]);
    let (mut chosen, mut used, mut authors, mut elapsed) = (Vec::new(), HashSet::new(), HashSet::new(), 0u32);
    while elapsed < total {
        let side = if chosen.len() % 2 == 0 { calm } else { intense };
        let Some(i) = pick_new(side, &used, &authors, tunes, rng) else { break };
        used.insert(i);
        authors.insert(tunes[i].author.clone());
        chosen.push(i);
        elapsed += tunes[i].secs;
    }
    (chosen, pool.len())
}

/// A random unused candidate, by a composer not used yet if there is one.
fn pick_new(
    candidates: &[usize],
    used: &HashSet<usize>,
    authors: &HashSet<String>,
    tunes: &[Tune],
    rng: &mut impl Rng,
) -> Option<usize> {
    let open: Vec<usize> = candidates.iter().copied().filter(|i| !used.contains(i)).collect();
    let fresh: Vec<usize> = open.iter().copied().filter(|&i| !authors.contains(&tunes[i].author)).collect();
    fresh.choose(rng).or_else(|| open.choose(rng)).copied()
}

/// Unheard music unlike what's been played, shuffled. Not the very furthest
/// tunes, which are mostly oddities rather than a different kind of music, but
/// the band from 75% to 95% of the way out. Returns the band.
pub(crate) fn different(tunes: &[Tune]) -> Vec<usize> {
    let mut pool: Vec<usize> =
        (0..tunes.len()).filter(|&i| tunes[i].is_music() && !tunes[i].heard && tunes[i].secs >= 90).collect();
    pool.sort_by(|&a, &b| tunes[b].to_heard.total_cmp(&tunes[a].to_heard));
    let (from, to) = (pool.len() * 3 / 4, pool.len() * 19 / 20);
    pool[from..to].to_vec()
}

/// Every tune that's music, for rating against the whole collection.
pub(crate) fn music(tunes: &[Tune]) -> Vec<usize> {
    (0..tunes.len()).filter(|&i| tunes[i].is_music()).collect()
}

/// Too slight for a list of a set length: jingles, and tunes that scanned as
/// silence. "All" still has them, as it says.
pub(crate) fn is_slight(t: &Tune) -> bool {
    t.secs < 60 || (t.scanned && t.peak <= 0.02)
}

/// Order tunes so each leads into the next: from the first, always the closest
/// to the one before by another composer, or by anyone once only theirs are
/// left. `sounds` holds each tune's unit vector, where it has one; those
/// without one go last, as they came.
pub(crate) fn flow(sounds: &[Option<&[f32]>], authors: &[&str]) -> Vec<usize> {
    let mut left: Vec<usize> = (0..sounds.len()).filter(|&i| sounds[i].is_some()).collect();
    let unknown: Vec<usize> = (0..sounds.len()).filter(|&i| sounds[i].is_none()).collect();
    let mut order = Vec::with_capacity(sounds.len());
    if !left.is_empty() {
        order.push(left.remove(0));
    }
    while let Some(&last) = order.last() {
        let here = sounds[last].unwrap_or(&[]);
        let closeness = |i: usize| -> f32 {
            sounds[i].map_or(f32::MIN, |s| s.iter().zip(here).map(|(a, b)| a * b).sum())
        };
        let best = |only_others: bool| {
            left.iter()
                .enumerate()
                .filter(|(_, &i)| !only_others || authors[i] != authors[last])
                .max_by(|a, b| closeness(*a.1).total_cmp(&closeness(*b.1)))
                .map(|(k, _)| k)
        };
        let Some(next) = best(true).or_else(|| best(false)) else { break };
        order.push(left.remove(next));
    }
    order.extend(unknown);
    order
}

/// Cut `order` once it plays for `total` seconds; everything when None.
pub(crate) fn fill(order: Vec<usize>, tunes: &[Tune], total: Option<u32>) -> Vec<usize> {
    let Some(total) = total else { return order };
    let mut elapsed = 0u32;
    order
        .into_iter()
        .take_while(|&i| {
            let more = elapsed < total;
            elapsed += tunes[i].secs;
            more
        })
        .collect()
}

/// Lower-case words, with spelled-out ordinals as digits so that "Second
/// Reality" and "2nd Reality" meet.
pub(crate) fn name_words(name: &str) -> Vec<String> {
    name.split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(|w| match w.to_lowercase().as_str() {
            "first" => "1st".to_string(),
            "second" => "2nd".to_string(),
            "third" => "3rd".to_string(),
            "fourth" => "4th".to_string(),
            other => other.to_string(),
        })
        .collect()
}

/// Whether a title holds every word of `wanted`, whole: "love" isn't "glove"
/// or "lovely".
pub(crate) fn title_has(title: &str, wanted: &[String]) -> bool {
    let words = name_words(title);
    wanted.iter().all(|w| words.contains(w))
}

/// Where a tune goes in a list asked for by title: the title itself before
/// those that only hold it, each oldest first, more often the original.
pub(crate) fn title_rank(tune: &Tune, wanted: &str) -> (bool, u16) {
    (piece_words(&tune.title) != piece_words(wanted), tune.year.unwrap_or(u16::MAX))
}

/// A title's words without what marks one part of a piece or a leading "The":
/// "2nd Reality (part 2)" and "2nd Reality" are both "2nd reality", and "The
/// Last Ninja" is "last ninja".
fn piece_words(title: &str) -> Vec<String> {
    let head = title.split('(').next().unwrap_or(title);
    let mut words = name_words(head);
    if words.len() > 1 && matches!(words[0].as_str(), "the" | "a" | "an") {
        words.remove(0);
    }
    words
}

/// The other tunes that are versions of `title`, by name. Too many matches
/// means it's a generic title, not a piece, so there are none.
pub(crate) fn versions<'a>(title: &str, seed_path: &str, tunes: &'a [Tune]) -> Vec<&'a Tune> {
    let wanted = piece_words(title);
    if wanted.is_empty() {
        return Vec::new();
    }
    let found: Vec<&Tune> =
        tunes.iter().filter(|t| t.path != seed_path && piece_words(&t.title) == wanted).collect();
    if found.len() > MAX_VERSIONS {
        Vec::new()
    } else {
        found
    }
}

/// Whose tune it is, by folder. Usually the nearest one, which can be a person
/// inside a group ("Tinnitus/Trompkins"). But 35 composers have a "Worktunes"
/// folder of their own, and those aren't one composer.
pub(crate) fn composer_folder(path: &std::path::Path, nearest: &str) -> String {
    if nearest.eq_ignore_ascii_case("worktunes") || nearest.eq_ignore_ascii_case("unreleased") {
        if let Some(owner) = path.parent().and_then(|p| p.parent()).and_then(|p| p.file_name()) {
            return owner.to_string_lossy().into_owned();
        }
    }
    nearest.to_string()
}

/// Tunes with a title word starting with each word of `name`, so "2nd reali"
/// finds "2nd Reality" while it's being typed: exact pieces first, then titles
/// starting that way.
pub(crate) fn find_by_name<'a>(name: &str, tunes: &'a [Tune], limit: usize) -> Vec<&'a Tune> {
    let wanted = piece_words(name);
    if wanted.is_empty() {
        return Vec::new();
    }
    let mut found: Vec<&Tune> = tunes
        .iter()
        .filter(|t| {
            let words = name_words(&t.title);
            wanted.iter().all(|w| words.iter().any(|word| word.starts_with(w.as_str())))
        })
        .collect();
    found.sort_by_key(|t| {
        let words = piece_words(&t.title);
        let starts = words.len() >= wanted.len()
            && wanted.iter().zip(&words).all(|(w, word)| word.starts_with(w.as_str()));
        // The oldest of a title first: more often the original than a cover.
        let same = words == wanted;
        (!same, !starts, words, t.year.unwrap_or(u16::MAX), t.author.clone())
    });
    found.truncate(limit);
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::rngs::StdRng;
    use rand::SeedableRng;

    fn tune(path: &str, title: &str) -> Tune {
        Tune {
            path: path.into(),
            title: title.into(),
            author: path.into(),
            secs: 200,
            scanned: true,
            peak: 0.5,
            notes: 5.0,
            ..Tune::default()
        }
    }

    /// `count` tunes from calm to busy, each by its own composer.
    fn spread(count: usize) -> Vec<Tune> {
        (0..count)
            .map(|i| {
                let f = i as f32 / count as f32;
                Tune {
                    notes: 0.5 + f * 20.0,
                    drums: f * 12.0,
                    loudness: f,
                    arps: f * 10.0,
                    ..tune(&format!("t{i}"), &format!("Tune {i}"))
                }
            })
            .collect()
    }

    #[test]
    fn intensity_ranks_calm_below_busy() {
        let mut tunes = spread(100);
        let pool: Vec<usize> = (0..100).collect();
        rate_intensity(&mut tunes, &pool);
        assert!(tunes[0].intensity < 0.05);
        assert!(tunes[99].intensity > 0.95);
    }

    #[test]
    fn rising_reaches_the_length_stays_calm_then_climbs() {
        let mut tunes = spread(2000);
        let (order, pool) = rising(&mut tunes, 3600, &|_| true, &mut StdRng::seed_from_u64(1));
        assert_eq!(pool, 2000);
        let total: u32 = order.iter().map(|&i| tunes[i].secs).sum();
        assert!((3600..3800).contains(&total), "{total}");
        let levels: Vec<f32> = order.iter().map(|&i| tunes[i].intensity).collect();
        let chill = levels.len() * 3 / 5 - 1;
        assert!(levels[..chill].iter().all(|&l| l < 0.2), "{levels:?}");
        assert!(*levels.last().unwrap() > 0.75, "{levels:?}");
    }

    #[test]
    fn rising_repeats_no_tune_or_composer_while_it_can() {
        let mut tunes = spread(2000);
        let (order, _) = rising(&mut tunes, 3600, &|_| true, &mut StdRng::seed_from_u64(2));
        let authors: HashSet<&str> = order.iter().map(|&i| tunes[i].author.as_str()).collect();
        assert_eq!(authors.len(), order.len());
    }

    #[test]
    fn rising_stops_when_the_pool_runs_out() {
        let mut tunes = spread(3);
        let (order, _) = rising(&mut tunes, 3600, &|_| true, &mut StdRng::seed_from_u64(3));
        assert_eq!(order.len(), 3);
    }

    #[test]
    fn silence_samples_and_lengths_stay_out_of_the_arc() {
        let mut tunes = vec![
            Tune { peak: 0.0, ..tune("silent", "Silent") },
            Tune { digi: 0.5, ..tune("digi", "Digi") },
            Tune { secs: 30, ..tune("jingle", "Jingle") },
            tune("untitled", "<?>"),
            tune("good", "Good"),
        ];
        let (order, pool) = rising(&mut tunes, 100, &|_| true, &mut StdRng::seed_from_u64(4));
        assert_eq!(pool, 1);
        assert_eq!(order, vec![4]);
    }

    #[test]
    fn only_allowed_tunes_make_the_arc() {
        let mut tunes = vec![Tune { heard: true, ..tune("heard", "Heard") }, tune("new", "New")];
        let (order, _) = rising(&mut tunes, 100, &|t| !t.heard, &mut StdRng::seed_from_u64(5));
        assert_eq!(order, vec![1]);
    }

    #[test]
    fn alternating_takes_turns() {
        let mut tunes = spread(300);
        let (order, _) = alternating(&mut tunes, 1200, &|_| true, &mut StdRng::seed_from_u64(6));
        assert!(order.len() >= 6);
        for (k, &i) in order.iter().enumerate() {
            if k % 2 == 0 {
                assert!(tunes[i].intensity < 0.4);
            } else {
                assert!(tunes[i].intensity > 0.6);
            }
        }
    }

    #[test]
    fn the_last_ninja_is_last_ninja() {
        let tunes = vec![
            Tune { year: Some(2009), ..tune("later", "Last Ninja") },
            Tune { year: Some(1987), ..tune("original", "The Last Ninja") },
        ];
        assert_eq!(find_by_name("last ninja", &tunes, 8)[0].path, "original");
    }

    #[test]
    fn energy_splits_calm_from_intense() {
        let mut tunes = spread(100);
        let pool: Vec<usize> = (0..100).collect();
        rate_intensity(&mut tunes, &pool);
        assert!(tunes[1].fits_energy(Energy::Calm) && !tunes[1].fits_energy(Energy::Intense));
        assert!(tunes[99].fits_energy(Energy::Intense) && !tunes[99].fits_energy(Energy::Calm));
    }

    #[test]
    fn different_skips_the_nearest_and_the_extremes() {
        let tunes: Vec<Tune> = (0..100)
            .map(|i| Tune { to_heard: 1.0 - i as f32 / 100.0, ..tune(&format!("t{i}"), "T") })
            .collect();
        let band = different(&tunes);
        assert_eq!(band.len(), 20);
        assert_eq!(band.first(), Some(&75));
        assert_eq!(band.last(), Some(&94));
    }

    #[test]
    fn different_leaves_out_heard_tunes() {
        let tunes: Vec<Tune> = (0..100).map(|i| Tune { heard: true, ..tune(&format!("t{i}"), "T") }).collect();
        assert!(different(&tunes).is_empty());
    }

    #[test]
    fn fill_stops_once_the_total_is_reached() {
        let tunes = vec![tune("a", "A"), tune("b", "B"), tune("c", "C")];
        assert_eq!(fill(vec![0, 1, 2], &tunes, Some(300)), vec![0, 1]);
        assert_eq!(fill(vec![0, 1, 2], &tunes, None), vec![0, 1, 2]);
    }

    #[test]
    fn second_reality_finds_2nd_reality() {
        let tunes = vec![
            tune("eye", "2nd Reality"),
            tune("kb2", "2nd Reality (part 2)"),
            tune("other", "Second Thoughts"),
        ];
        let found = find_by_name("Second Reality", &tunes, 8);
        let paths: Vec<&str> = found.iter().map(|t| t.path.as_str()).collect();
        assert_eq!(paths, vec!["eye", "kb2"]);
    }

    #[test]
    fn flow_goes_to_the_closest_next() {
        let (a, b, c): (&[f32], &[f32], &[f32]) = (&[1.0, 0.0], &[0.0, 1.0], &[0.9, 0.1]);
        let sounds = [Some(a), Some(b), Some(c)];
        assert_eq!(flow(&sounds, &["x", "y", "z"]), vec![0, 2, 1]);
    }

    #[test]
    fn flow_keeps_a_composer_apart_while_it_can() {
        let (a, b, c): (&[f32], &[f32], &[f32]) = (&[1.0, 0.0], &[0.99, 0.0], &[0.0, 1.0]);
        let sounds = [Some(a), Some(b), Some(c)];
        // The closest is by the same composer, so the other goes between.
        assert_eq!(flow(&sounds, &["x", "x", "y"]), vec![0, 2, 1]);
    }

    #[test]
    fn flow_puts_tunes_it_cant_compare_last() {
        let a: &[f32] = &[1.0];
        assert_eq!(flow(&[None, Some(a)], &["x", "y"]), vec![1, 0]);
    }

    #[test]
    fn slight_tunes_are_short_or_silent() {
        assert!(is_slight(&Tune { secs: 22, ..tune("a", "A") }));
        assert!(is_slight(&Tune { peak: 0.0, ..tune("a", "A") }));
        assert!(!is_slight(&tune("a", "A")));
    }

    #[test]
    fn asking_for_a_title_puts_it_first_oldest_first() {
        let exact_new = Tune { year: Some(2020), ..tune("a", "Airwolf") };
        let exact_old = Tune { year: Some(1987), ..tune("b", "Airwolf") };
        let remix = Tune { year: Some(1985), ..tune("c", "Airwolf Remix") };
        assert!(title_rank(&exact_old, "airwolf") < title_rank(&exact_new, "airwolf"));
        assert!(title_rank(&exact_new, "airwolf") < title_rank(&remix, "airwolf"));
    }

    #[test]
    fn a_title_holds_whole_words() {
        let wanted = name_words("techno");
        assert!(title_has("Techno Death", &wanted));
        assert!(title_has("My TECHNO Mix", &wanted));
        assert!(!title_has("Technology", &wanted));
        assert!(title_has("2nd Reality", &name_words("second reality")));
    }

    #[test]
    fn part_of_a_word_finds_a_title_while_typing() {
        let tunes = vec![
            tune("other", "A 2nd Reality Check"),
            tune("eye", "2nd Reality"),
            tune("no", "Realm"),
            tune("no2", "Unreal"),
        ];
        let paths = |name: &str| -> Vec<String> {
            find_by_name(name, &tunes, 8).iter().map(|t| t.path.clone()).collect()
        };
        assert_eq!(paths("2nd reali"), vec!["eye", "other"]);
        assert_eq!(paths("reali"), vec!["eye", "other"]);
        assert_eq!(paths("real"), vec!["no", "eye", "other"]);
    }

    #[test]
    fn the_oldest_of_a_title_comes_first() {
        let tunes = vec![
            Tune { year: Some(2001), ..tune("cover", "Comic Bakery") },
            Tune { year: None, ..tune("unknown", "Comic Bakery") },
            Tune { year: Some(1986), ..tune("original", "Comic Bakery") },
        ];
        let found = find_by_name("comic bakery", &tunes, 8);
        assert_eq!(found[0].path, "original");
        assert_eq!(found[2].path, "unknown");
    }

    #[test]
    fn versions_are_the_other_tunes_of_the_same_piece() {
        let tunes = vec![
            tune("kb1", "2nd Reality (part 1)"),
            tune("kb2", "2nd Reality (part 2)"),
            tune("eye", "2nd Reality"),
            tune("no", "Reality"),
        ];
        let found = versions("2nd Reality (part 2)", "kb2", &tunes);
        let paths: Vec<&str> = found.iter().map(|t| t.path.as_str()).collect();
        assert_eq!(paths, vec!["kb1", "eye"]);
    }

    #[test]
    fn worktunes_belong_to_their_composer() {
        let folder = |path: &str, nearest: &str| composer_folder(std::path::Path::new(path), nearest);
        assert_eq!(folder("MUSICIANS/D/DRAX/Worktunes/A.sid", "Worktunes"), "DRAX");
        assert_eq!(folder("MUSICIANS/S/SFR/Worktunes/001.sid", "Worktunes"), "SFR");
        assert_eq!(folder("MUSICIANS/L/Link/unreleased/A.sid", "unreleased"), "Link");
        assert_eq!(folder("MUSICIANS/D/DRAX/A.sid", "DRAX"), "DRAX");
        assert_eq!(folder("MUSICIANS/T/Tinnitus/Trompkins/A.sid", "Trompkins"), "Trompkins");
    }

    #[test]
    fn a_generic_title_has_no_versions() {
        let tunes: Vec<Tune> = (0..20).map(|i| tune(&format!("t{i}"), "Tune")).collect();
        assert!(versions("Tune", "t0", &tunes).is_empty());
    }
}
