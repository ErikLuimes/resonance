// The website demo's sound: three SID-style voices and a tiny music driver
// that ticks 50 times a second (one PAL frame), the way a C64 tune's play
// routine does. It is not an emulator — Resonance plays real SID files
// through Phosphor's reSID and SIDLite engines — but it follows the chip's
// rules: three oscillators, four waveforms (combined ones are ANDed), an
// ADSR envelope per voice, the 23-bit noise LFSR and one resonant filter.

const TRI = 0x10, SAW = 0x20, PUL = 0x40, NOI = 0x80;
const FRAME_HZ = 50;

const midiHz = (n) => 440 * Math.pow(2, (n - 69) / 12);

// Softens the steps of the saw and pulse waves so high notes don't alias.
function polyBlep(t, dt) {
  if (t < dt) { t /= dt; return t + t - t * t - 1; }
  if (t > 1 - dt) { t = (t - 1) / dt; return t * t + t + t + 1; }
  return 0;
}

class Voice {
  constructor() {
    this.phase = 0;
    this.hz = 0;
    this.wave = 0;
    this.pw = 0.5;
    this.gate = false;
    this.stage = 3; // 0 attack, 1 decay/sustain, 3 release
    this.env = 0;
    this.aInc = 1; this.dCoef = 0; this.sustain = 0; this.rCoef = 0;
    this.lfsr = 0x7ffff8;
    this.noiseAcc = 0;
    this.noiseOut = 0;
    this.muted = false;
    // Driver state.
    this.inst = null;
    this.base = 0;
    this.chord = null;
    this.frames = 0;
    this.pwDir = 1;
    this.pitch = 0;
  }

  setEnvelope([a, d, s, r]) {
    this.aInc = 1 / (Math.max(a, 0.001) * sampleRate);
    this.dCoef = Math.exp(-4 / (Math.max(d, 0.001) * sampleRate));
    this.sustain = s;
    this.rCoef = Math.exp(-4 / (Math.max(r, 0.001) * sampleRate));
  }

  setGate(on) {
    if (on) this.stage = 0;
    else this.stage = 3;
    this.gate = on;
  }

  stepNoise() {
    const l = this.lfsr;
    const bit = ((l >> 22) ^ (l >> 17)) & 1;
    this.lfsr = ((l << 1) | bit) & 0x7fffff;
    const n = this.lfsr;
    // The eight LFSR taps the SID routes to its noise output.
    const byte = (((n >> 22) & 1) << 7) | (((n >> 20) & 1) << 6) | (((n >> 16) & 1) << 5) |
      (((n >> 13) & 1) << 4) | (((n >> 11) & 1) << 3) | (((n >> 7) & 1) << 2) |
      (((n >> 4) & 1) << 1) | ((n >> 2) & 1);
    this.noiseOut = byte / 127.5 - 1;
  }

  sample() {
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

    const dt = this.hz / sampleRate;
    let p = this.phase + dt;
    if (p >= 1) p -= 1;
    this.phase = p;

    const w = this.wave;
    if (w & NOI) {
      // The real chip clocks its LFSR 16 times per oscillator cycle.
      this.noiseAcc += dt * 16;
      while (this.noiseAcc >= 1) { this.noiseAcc -= 1; this.stepNoise(); }
    }

    let out;
    switch (w) {
      case 0: out = 0; break;
      case TRI: out = p < 0.5 ? 4 * p - 1 : 3 - 4 * p; break;
      case SAW: out = 2 * p - 1 - polyBlep(p, dt); break;
      case PUL: {
        const pw = this.pw;
        out = (p < pw ? 1 : -1) + polyBlep(p, dt) - polyBlep((p - pw + 1) % 1, dt);
        break;
      }
      case NOI: out = this.noiseOut; break;
      default: {
        // Combined waveforms: the chip ANDs the 12-bit outputs together.
        let bits = 0xfff;
        if (w & TRI) bits &= Math.floor((p < 0.5 ? p * 2 : 2 - p * 2) * 4095);
        if (w & SAW) bits &= Math.floor(p * 4095);
        if (w & PUL) bits &= p < this.pw ? 0xfff : 0;
        if (w & NOI) bits &= Math.floor((this.noiseOut + 1) * 2047);
        out = bits / 2047.5 - 1;
      }
    }
    return out * this.env;
  }
}

class SidDemoProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.voices = [new Voice(), new Voice(), new Voice()];
    this.song = null;
    this.row = 0;
    this.rowFrame = 0;
    this.totalFrames = 0;
    this.samplesPerFrame = sampleRate / FRAME_HZ;
    this.untilFrame = 0;
    // Filter (Chamberlin state-variable, 12 dB/oct like the SID's).
    this.low = 0; this.band = 0; this.f = 0.1; this.damp = 0.7;
    // Output stage: DC blocker and a gentle low-pass.
    this.dcX = 0; this.dcY = 0; this.lp = 0;
    this.port.onmessage = (e) => this.receive(e.data);
  }

  receive(msg) {
    switch (msg.t) {
      case 'song':
        this.song = msg.song;
        this.row = 0;
        this.rowFrame = 0;
        this.totalFrames = 0;
        this.untilFrame = 0;
        for (const v of this.voices) { v.inst = null; v.setGate(false); v.env = 0; v.wave = 0; }
        break;
      case 'mute':
        this.voices[msg.voice].muted = msg.muted;
        break;
    }
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
    if (inst.hr) v.env = 0; // hard restart: every note gets a clean attack
    v.setGate(true);
  }

  // One step of the music driver, called once per 50 Hz frame.
  frame() {
    const song = this.song;
    if (!song) return;

    if (this.rowFrame === 0) {
      for (let t = 0; t < 3; t++) {
        const ev = song.tracks[t][this.row];
        if (!ev) continue;
        if (ev.n < 0) this.voices[t].setGate(false);
        else this.noteOn(this.voices[t], ev);
      }
    }

    for (const v of this.voices) this.updateVoice(v);

    const fl = song.filter;
    const sweep = 0.5 - 0.5 * Math.cos((2 * Math.PI * this.totalFrames) / fl.period);
    const cutoff = Math.min(fl.lo + (fl.hi - fl.lo) * sweep, sampleRate / 7);
    this.f = 2 * Math.sin((Math.PI * cutoff) / sampleRate);
    this.damp = 1 / fl.res;

    this.report(cutoff);

    // The song repeats until the tune's length is up, as a SID tune loops
    // until Songlengths says it's over.
    this.totalFrames++;
    if (this.totalFrames >= song.frames) {
      this.port.postMessage({ t: 'end' });
      this.song = null;
      for (const v of this.voices) v.setGate(false);
      return;
    }
    this.rowFrame++;
    if (this.rowFrame >= song.speed) {
      this.rowFrame = 0;
      this.row = (this.row + 1) % song.rows;
    }

    // Hard restart: gate off a couple of frames before the next note, so
    // repeated notes are articulated instead of smeared together.
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
    v.hz = midiHz(note);
    v.wave = step.w;
    if (inst.pws) {
      v.pw += inst.pws * v.pwDir;
      if (v.pw > inst.pwMax) { v.pw = inst.pwMax; v.pwDir = -1; }
      if (v.pw < inst.pwMin) { v.pw = inst.pwMin; v.pwDir = 1; }
    }
    if (inst.len && f === inst.len) v.setGate(false);
    v.frames++;
  }

  report(cutoff) {
    const voices = this.voices.map((v) => [
      v.gate && v.wave ? Math.round(v.pitch) : -1,
      v.wave,
      v.gate ? 1 : 0,
      v.muted ? 0 : v.env,
      v.pw,
    ]);
    this.port.postMessage({ t: 'frame', voices, frame: this.totalFrames, cutoff });
  }

  process(_inputs, outputs) {
    const out = outputs[0];
    const left = out[0];
    const right = out[1];
    const [v1, v2, v3] = this.voices;
    const mask = this.song ? this.song.filter.mask : 0;
    for (let i = 0; i < left.length; i++) {
      if (--this.untilFrame <= 0) {
        this.frame();
        this.untilFrame += this.samplesPerFrame;
      }

      let dry = 0, wet = 0;
      // Muted voices keep running, so unmuting doesn't restart them.
      const s1 = v1.sample() * (v1.muted ? 0 : 1);
      const s2 = v2.sample() * (v2.muted ? 0 : 1);
      const s3 = v3.sample() * (v3.muted ? 0 : 1);
      if (mask & 1) wet += s1; else dry += s1;
      if (mask & 2) wet += s2; else dry += s2;
      if (mask & 4) wet += s3; else dry += s3;

      this.low += this.f * this.band;
      const high = wet - this.low - this.damp * this.band;
      this.band += this.f * high;

      const x = (dry + this.low) * 0.18;
      const y = x - this.dcX + 0.995 * this.dcY;
      this.dcX = x;
      this.dcY = y;
      this.lp += (y - this.lp) * 0.75;

      left[i] = this.lp;
      if (right) right[i] = this.lp;
    }
    return true;
  }
}

registerProcessor('sid-demo', SidDemoProcessor);
