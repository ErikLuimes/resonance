// "The chip" section's scopes, animated as if a tune were playing: the
// same 50 Hz music driver the old in-page player ran in its audio worklet,
// stepped on the main thread without making a sound. Each frame gives every
// voice its note, waveform, gate, envelope level and pulse width, which is
// all the scopes draw from. One stand-in tune after another, as composed by
// tune.js.

import { composeTune } from './tune.js';

const FRAME_HZ = 50;
// How long each stand-in plays before the next one starts.
const TUNE_SECS = 40;

class Voice {
  constructor() {
    this.gate = false;
    this.stage = 3; // 0 attack, 1 decay/sustain, 3 release
    this.env = 0;
    this.aInc = 1; this.dCoef = 0; this.sustain = 0; this.rCoef = 0;
    this.wave = 0;
    this.pw = 0.5;
    this.pitch = 0;
    this.inst = null;
    this.base = 0;
    this.chord = null;
    this.frames = 0;
    this.pwDir = 1;
  }

  // The worklet stepped the envelope per sample; per frame is plenty to look at.
  setEnvelope([a, d, s, r]) {
    this.aInc = 1 / (Math.max(a, 0.001) * FRAME_HZ);
    this.dCoef = Math.exp(-4 / (Math.max(d, 0.001) * FRAME_HZ));
    this.sustain = s;
    this.rCoef = Math.exp(-4 / (Math.max(r, 0.001) * FRAME_HZ));
  }

  setGate(on) {
    this.stage = on ? 0 : 3;
    this.gate = on;
  }

  stepEnvelope() {
    switch (this.stage) {
      case 0:
        this.env += this.aInc;
        if (this.env >= 1) { this.env = 1; this.stage = 1; }
        break;
      case 1:
        this.env = this.sustain + (this.env - this.sustain) * this.dCoef;
        break;
      default:
        this.env *= this.rCoef;
    }
  }
}

export class SilentChip {
  constructor(seeds) {
    this.seeds = seeds;
    this.next = 0;
    this.voices = [new Voice(), new Voice(), new Voice()];
    // Per voice [note, wave, gate, env, pw], like the worklet's reports.
    this.state = [];
    this.seq = 0;
    this.load();
  }

  load() {
    const seed = this.seeds[this.next++ % this.seeds.length];
    this.song = composeTune(seed, 1).song;
    this.row = 0;
    this.rowFrame = 0;
    this.totalFrames = 0;
    for (const v of this.voices) { v.inst = null; v.setGate(false); v.env = 0; v.wave = 0; }
  }

  noteOn(v, ev) {
    const inst = this.song.instruments[ev.i];
    v.inst = inst;
    v.base = ev.n;
    v.chord = ev.c || null;
    v.frames = 0;
    v.pw = inst.pw ?? 0.5;
    v.pwDir = 1;
    v.setEnvelope(inst.adsr);
    if (inst.hr) v.env = 0;
    v.setGate(true);
  }

  /** One 50 Hz frame of the driver. */
  frame() {
    const song = this.song;
    if (this.rowFrame === 0) {
      for (let t = 0; t < 3; t++) {
        const ev = song.tracks[t][this.row];
        if (!ev) continue;
        if (ev.n < 0) this.voices[t].setGate(false);
        else this.noteOn(this.voices[t], ev);
      }
    }
    for (const v of this.voices) {
      this.updateVoice(v);
      v.stepEnvelope();
    }
    this.state = this.voices.map((v) => [
      v.gate && v.wave ? Math.round(v.pitch) : -1, v.wave, v.gate ? 1 : 0, v.env, v.pw,
    ]);
    this.seq++;

    if (++this.totalFrames >= TUNE_SECS * FRAME_HZ) {
      this.load();
      return;
    }
    if (++this.rowFrame >= song.speed) {
      this.rowFrame = 0;
      this.row = (this.row + 1) % song.rows;
    }
    // Hard restart, as in the worklet: gate off just before a new note.
    if (this.rowFrame === song.speed - 2) {
      for (let t = 0; t < 3; t++) {
        const next = song.tracks[t][(this.row + 1) % song.rows];
        if (next && next.n >= 0 && song.instruments[next.i].hr) this.voices[t].setGate(false);
      }
    }
  }

  updateVoice(v) {
    const inst = v.inst;
    if (!inst) return;
    const f = v.frames;
    const step = inst.wt[Math.min(f, inst.wt.length - 1)];
    let note = step.a ?? v.base + (step.t || 0);
    if (inst.arp && v.chord) note += v.chord[Math.floor(f / (inst.arpSpeed || 1)) % v.chord.length];
    if (inst.vib && f > inst.vib.delay) {
      note += inst.vib.depth * Math.sin((2 * Math.PI * (f - inst.vib.delay)) / inst.vib.period);
    }
    v.pitch = note;
    v.wave = step.w;
    if (inst.pws) {
      v.pw += inst.pws * v.pwDir;
      if (v.pw > inst.pwMax) { v.pw = inst.pwMax; v.pwDir = -1; }
      if (v.pw < inst.pwMin) { v.pw = inst.pwMin; v.pwDir = 1; }
    }
    if (inst.len && f === inst.len) v.setGate(false);
    v.frames++;
  }

  /** Run the frames due since `last` (ms); returns the new clock. */
  advance(last, now) {
    let clock = last ?? now;
    // After a hidden tab or an off-screen stretch, don't race to catch up.
    if (now - clock > 250) clock = now - 1000 / FRAME_HZ;
    while (now - clock >= 1000 / FRAME_HZ) {
      this.frame();
      clock += 1000 / FRAME_HZ;
    }
    return clock;
  }
}
