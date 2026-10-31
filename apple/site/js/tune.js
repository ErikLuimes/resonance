// Composes the website demo's tunes: a seeded random chiptune in the
// classic three-voice C64 layout. Voice 1 plays the lead, voice 2 fakes
// chords with a 50 Hz arpeggio through a sweeping filter, and voice 3
// shares its time between the bass and the drums.

export const TRI = 0x10, SAW = 0x20, PUL = 0x40, NOI = 0x80;

const NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

/** "C#4" for a MIDI note number, like Resonance's visualizer labels. */
export function noteName(midi) {
  if (midi < 0 || midi > 127) return null;
  return NOTE_NAMES[midi % 12] + (Math.floor(midi / 12) - 1);
}

/** "PUL+SAW", in the order the app lists them. */
export function waveName(wave) {
  const parts = [];
  if (wave & TRI) parts.push('TRI');
  if (wave & SAW) parts.push('SAW');
  if (wave & PUL) parts.push('PUL');
  if (wave & NOI) parts.push('NOI');
  return parts.join('+');
}

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const pick = (r, list) => list[Math.floor(r() * list.length)];
const mod = (n, m) => ((n % m) + m) % m;

const MODES = {
  minor: { scale: [0, 2, 3, 5, 7, 8, 10], progs: [[0, 5, 2, 6], [0, 3, 6, 2], [0, 5, 3, 4], [0, 6, 5, 6], [0, 3, 0, 4]] },
  dorian: { scale: [0, 2, 3, 5, 7, 9, 10], progs: [[0, 3, 0, 3], [0, 6, 3, 0], [0, 3, 6, 4]] },
  major: { scale: [0, 2, 4, 5, 7, 9, 11], progs: [[0, 4, 5, 3], [0, 5, 3, 4], [0, 3, 4, 3], [5, 3, 0, 4]] },
};

// Instruments: a wave table stepped once per frame ({w: waveform,
// t: semitones from the note, or a: an absolute note}), ADSR in seconds,
// pulse-width sweeps, vibrato, and hard restart.
const LEADS = [
  { wt: [{ w: PUL }], adsr: [0.004, 0.4, 0.55, 0.18], pw: 0.25, pws: 0.006, pwMin: 0.1, pwMax: 0.5, vib: { delay: 12, depth: 0.2, period: 6 }, hr: true },
  { wt: [{ w: SAW, t: 12 }, { w: PUL }], adsr: [0.002, 0.35, 0.5, 0.15], pw: 0.35, pws: 0.004, pwMin: 0.15, pwMax: 0.5, vib: { delay: 10, depth: 0.25, period: 6 }, hr: true },
  { wt: [{ w: PUL, t: 12 }, { w: TRI }], adsr: [0.02, 0.3, 0.75, 0.22], vib: { delay: 8, depth: 0.3, period: 7 }, hr: true },
  { wt: [{ w: SAW }], adsr: [0.003, 0.45, 0.45, 0.2], vib: { delay: 14, depth: 0.18, period: 5 }, hr: true },
];
const ARPS = [
  { wt: [{ w: PUL }], arp: true, adsr: [0.001, 0.6, 0.4, 0.15], pw: 0.2, pws: 0.003, pwMin: 0.08, pwMax: 0.45, hr: true },
  { wt: [{ w: SAW }], arp: true, adsr: [0.001, 0.5, 0.35, 0.12], hr: true },
  { wt: [{ w: PUL }], arp: true, arpSpeed: 2, adsr: [0.001, 0.4, 0.3, 0.1], pw: 0.5, pws: 0.008, pwMin: 0.2, pwMax: 0.5, hr: true },
];
const BASSES = [
  { wt: [{ w: PUL }], adsr: [0.001, 0.25, 0.35, 0.05], pw: 0.4, pws: 0.01, pwMin: 0.12, pwMax: 0.48, hr: true },
  { wt: [{ w: SAW, t: 12 }, { w: SAW }], adsr: [0.001, 0.22, 0.3, 0.05], hr: true },
];
const KICK = {
  wt: [{ w: PUL, a: 60 }, { w: PUL, a: 50 }, { w: TRI, a: 45 }, { w: TRI, a: 41 }, { w: TRI, a: 38 }, { w: TRI, a: 36 }, { w: TRI, a: 35 }],
  adsr: [0.001, 0.16, 0, 0.04], pw: 0.5, hr: true,
};
const SNARE = {
  wt: [{ w: PUL, a: 66 }, { w: NOI, a: 92 }, { w: PUL, a: 58 }, { w: NOI, a: 88 }, { w: NOI, a: 86 }],
  adsr: [0.001, 0.2, 0, 0.05], pw: 0.5, hr: true,
};

// Two bars of lead rhythm, in 16th-note rows.
const LEAD_RHYTHMS = [
  [4, 2, 2, 4, 4, 2, 2, 4, 8],
  [6, 2, 4, 4, 6, 2, 8],
  [2, 2, 2, 2, 4, 4, 4, 4, 8],
  [3, 3, 2, 4, 4, 3, 3, 2, 8],
  [8, 4, 4, 4, 2, 2, 8],
  [4, 4, 2, 2, 4, 4, 4, 8],
  [2, 4, 2, 4, 4, 2, 2, 2, 2, 8],
];
const ARP_RHYTHMS = ['x.......x.......', 'x..x..x.x..x..x.', 'x.x.x.x.x.x.x.x.', 'x...x...x...x...', 'x..x..x...x..x..'];
// Voice 3, one bar: K kick, S snare, b bass, o bass an octave up.
const GROOVES = ['K.o.S.boK.o.S.bo', 'K.b.S.o.K.b.S.ob', 'K.oKS.o.K.obS.o.', 'KbobSbobKbobSbob', 'K.b.S.b.K.bbS.bo'];

const ADJECTIVES = ['Neon', 'Chrome', 'Midnight', 'Turbo', 'Crystal', 'Vector', 'Cosmic', 'Pixel', 'Lunar', 'Hyper', 'Glass', 'Velvet', 'Electric', 'Static', 'Solar', 'Arctic', 'Phantom', 'Golden', 'Silent', 'Rapid', 'Infinite', 'Distant', 'Hidden', 'Liquid'];
const NOUNS = ['Run', 'Dreams', 'Horizon', 'Cascade', 'Circuit', 'Odyssey', 'Overdrive', 'Skyline', 'Reactor', 'Mirage', 'Drift', 'Pulse', 'Voyage', 'Orbit', 'Tides', 'Signal', 'Frontier', 'Echoes', 'Nights', 'Engine', 'Garden', 'Highway', 'Lagoon', 'Spiral'];

export const SUBTUNES = 3;
const BAR = 16;
const BARS = 16;
const LEAD_LO = 6, LEAD_HI = 15; // lead range, in scale steps above the key's root

/** The title every subtune of `seed` shares. */
export function tuneTitle(seed) {
  const r = mulberry32(seed * 7919 + 17);
  return `${pick(r, ADJECTIVES)} ${pick(r, NOUNS)}`;
}

/**
 * A tune for the demo player. Subtunes of one seed share a title and a
 * key but get their own tempo, chords and melody.
 */
export function composeTune(seed, subtune = 1) {
  const keyRng = mulberry32(seed);
  const root = 52 + Math.floor(keyRng() * 8); // E3 … B3
  const modeName = keyRng() < 0.55 ? 'minor' : keyRng() < 0.45 ? 'dorian' : 'major';
  const mode = MODES[modeName];
  const scale = mode.scale;

  const r = mulberry32(seed * 131 + subtune * 977);
  const speed = pick(r, [5, 6, 6, 6, 7]);
  const progA = pick(r, mode.progs);
  let progB = pick(r, mode.progs);
  if (progB === progA) progB = mode.progs[(mode.progs.indexOf(progA) + 1) % mode.progs.length];
  const arpRhythm = pick(r, ARP_RHYTHMS);
  const groove = pick(r, GROOVES);
  const fourNoteArp = r() < 0.5;

  const step = (s) => root + scale[mod(s, 7)] + 12 * Math.floor(s / 7);
  const isChordTone = (s, deg) => [0, 2, 4].includes(mod(s - deg, 7));
  const nearChordTone = (s, deg) => {
    const near = [0, 1, -1, 2, -2, 3, -3].map((d) => s + d).filter((x) => isChordTone(x, deg));
    return r() < 0.7 ? near[0] : near[1] ?? near[0];
  };
  const reflect = (s) => (s > LEAD_HI ? 2 * LEAD_HI - s : s < LEAD_LO ? 2 * LEAD_LO - s : s);

  // A two-bar phrase over two chords: chord tones on strong beats, steps
  // and small leaps in between, and a chord tone to land on.
  function phrase(rhythm, chords, start) {
    let s = start;
    let pos = 0;
    return rhythm.map((dur, i) => {
      const deg = chords[Math.floor(pos / BAR)];
      const last = i === rhythm.length - 1;
      if (i === 0 || last || pos % 8 === 0) s = nearChordTone(s, deg);
      else if (pos % 4 === 0) s = r() < 0.7 ? nearChordTone(s, deg) : s + pick(r, [-1, 1]);
      else s += pick(r, [-1, 1, -1, 1, -2, 2, 0, 3, -3]);
      s = reflect(s);
      const rest = i > 0 && !last && dur <= 2 && r() < 0.12;
      const note = { pos, dur, s: rest ? null : s };
      pos += dur;
      return note;
    });
  }

  // The same phrase moved along the scale to follow the chords, with a
  // new last note.
  function sequence(notes, shift, endChord) {
    return notes.map((n, i) => {
      if (n.s === null) return n;
      let s = reflect(n.s + shift);
      if (i === notes.length - 1) s = nearChordTone(s, endChord);
      return { ...n, s };
    });
  }

  const shiftBetween = (from, to) => {
    const d = mod(to - from, 7);
    return d > 3 ? d - 7 : d;
  };

  // Lead: an A section's motif and its sequence, a B section, then the
  // motif again with a new ending.
  const motifA = phrase(pick(r, LEAD_RHYTHMS), [progA[0], progA[1]], 9);
  const answerA = sequence(motifA, shiftBetween(progA[0], progA[2]), progA[3]);
  const motifB = phrase(pick(r, LEAD_RHYTHMS), [progB[0], progB[1]], 11);
  const answerB = sequence(motifB, shiftBetween(progB[0], progB[2]), progB[3]);
  const lastS = [...motifA].reverse().find((n) => n.s !== null)?.s ?? 9;
  const ending = phrase(pick(r, LEAD_RHYTHMS), [progA[2], progA[3]], lastS);
  const leadPlan = [[4, motifA], [6, answerA], [8, motifB], [10, answerB], [12, motifA], [14, ending]];

  const rows = BAR * BARS;
  const tracks = [0, 1, 2].map(() => new Array(rows).fill(null));

  for (const [bar, notes] of leadPlan) {
    for (const n of notes) {
      tracks[0][bar * BAR + n.pos] = n.s === null ? { n: -1 } : { n: step(n.s), i: 0 };
    }
  }

  const chordOf = (deg) => {
    const third = mod(scale[mod(deg + 2, 7)] - scale[deg], 12);
    const fifth = mod(scale[mod(deg + 4, 7)] - scale[deg], 12);
    return fourNoteArp ? [0, third, fifth, 12] : [0, third, fifth];
  };

  for (let bar = 0; bar < BARS; bar++) {
    const deg = (bar >= 8 && bar < 12 ? progB : progA)[bar % 4];
    const base = bar * BAR;

    let arpRoot = root + scale[deg];
    if (arpRoot > root + 7) arpRoot -= 12;
    for (let k = 0; k < BAR; k++) {
      if (arpRhythm[k] === 'x') tracks[1][base + k] = { n: arpRoot, i: 1, c: chordOf(deg) };
    }

    let bass = root - 12 + scale[deg];
    while (bass > 50) bass -= 12;
    while (bass < 36) bass += 12;
    let pattern = groove;
    if (bar < 2) pattern = pattern.replaceAll('K', 'b').replaceAll('S', 'o');
    if (bar === 7 || bar === 11 || bar === 15) pattern = pattern.slice(0, 12) + 'S.SS';
    for (let k = 0; k < BAR; k++) {
      const c = pattern[k];
      const ev = c === 'K' ? { n: 0, i: 3 } : c === 'S' ? { n: 0, i: 4 } : c === 'b' ? { n: bass, i: 2 } : c === 'o' ? { n: bass + 12, i: 2 } : null;
      if (ev) tracks[2][base + k] = ev;
    }
  }

  const frames = rows * speed;
  return {
    seed,
    subtune,
    title: tuneTitle(seed),
    author: 'Surprise Me',
    released: `2026 Web Demo #${seed}`,
    key: `${NOTE_NAMES[root % 12]} ${modeName}`,
    bpm: Math.round((50 * 60) / (speed * 4)),
    lengthSecs: frames / 50,
    song: {
      speed,
      rows,
      tracks,
      instruments: [pick(r, LEADS), pick(r, ARPS), pick(r, BASSES), KICK, SNARE],
      filter: {
        mask: 0b010,
        lo: 300 + r() * 250,
        hi: 2400 + r() * 2200,
        res: 1.6 + r() * 1.6,
        period: frames / 2,
      },
    },
  };
}
