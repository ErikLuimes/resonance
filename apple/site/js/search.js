// The Library section's search, over a sample of HVSC's MUSICIANS folder.
// It ranks like Phosphor's HVSC search (src/hvsc_browser.rs, score_entry):
// every word must match within one field, a contiguous match always beats
// a scattered (fuzzy) one, and title and author hits outweigh the
// release field. Accents are folded, so "hulsbeck" finds Hülsbeck.

const SUBSTRING_BOOST = 10_000;
const FIELDS = [['title', 3], ['author', 3], ['released', 1]];
const MAX_SHOWN = 60;

const fold = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

function substringScore(hay, term) {
  const at = hay.indexOf(term);
  if (at < 0) return null;
  const wordStart = at === 0 || /[^a-z0-9]/.test(hay[at - 1]);
  const positions = Array.from({ length: term.length }, (_, k) => at + k);
  return { score: 100 + (wordStart ? 50 : 0) - Math.min(at, 40) + (hay.length === term.length ? 100 : 0), positions };
}

function fuzzyScore(hay, term) {
  const positions = [];
  let from = 0;
  for (const ch of term) {
    const at = hay.indexOf(ch, from);
    if (at < 0) return null;
    positions.push(at);
    from = at + 1;
  }
  const span = positions[positions.length - 1] - positions[0] + 1;
  return { score: Math.max(80 - (span - term.length) * 4 - positions[0], 1), positions };
}

function scoreField(hay, terms) {
  let total = 0;
  const marks = new Set();
  for (const term of terms) {
    const sub = substringScore(hay, term);
    const hit = sub ? { ...sub, score: SUBSTRING_BOOST + sub.score } : fuzzyScore(hay, term);
    if (!hit) return null;
    total += hit.score;
    hit.positions.forEach((p) => marks.add(p));
  }
  return { score: total, marks };
}

export class TuneSearch {
  constructor(data) {
    this.authors = data.authors;
    this.tunes = data.tunes.map(([title, author, released, songs, length]) => {
      const tune = { title, author: data.authors[author], released, songs, length };
      tune.folded = { title: fold(title), author: fold(tune.author), released: fold(released) };
      return tune;
    });
  }

  search(query) {
    const terms = fold(query).split(/\s+/).filter(Boolean);
    if (!terms.length) return { total: 0, results: [] };
    const hits = [];
    for (const tune of this.tunes) {
      let best = null;
      for (const [field, weight] of FIELDS) {
        const m = scoreField(tune.folded[field], terms);
        if (m && (!best || m.score * weight > best.score)) best = { score: m.score * weight, field, marks: m.marks };
      }
      if (best) hits.push({ tune, ...best });
    }
    hits.sort((a, b) => b.score - a.score || a.tune.title.localeCompare(b.tune.title));
    return { total: hits.length, results: hits.slice(0, MAX_SHOWN) };
  }
}

const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

/** `text` with the characters at `marks` wrapped in <mark>. */
export function highlight(text, marks) {
  if (!marks) return escape(text);
  let out = '';
  let open = false;
  for (let i = 0; i < text.length; i++) {
    const on = marks.has(i);
    if (on && !open) out += '<mark>';
    if (!on && open) out += '</mark>';
    open = on;
    out += escape(text[i]);
  }
  return open ? out + '</mark>' : out;
}

export function formatLength(secs) {
  if (secs == null) return '—';
  const s = Math.floor(secs);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}
