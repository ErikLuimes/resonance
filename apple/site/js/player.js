// The demo player behind the page's Resonance window. It plays real HVSC
// tunes the way the app does — Surprise Me as a radio of random tunes, the
// playlist row by row with shuffle and repeat, subtunes, volume and
// per-voice mute — but what it plays is each tune's stand-in, composed in
// the browser and timed to the tune's Songlengths entry. Audio starts on
// the first click (browsers require a gesture), and pausing suspends the
// AudioContext.

import { composeTune, seedFor } from './tune.js';

const FRAME_HZ = 50;
// Resonance's default length for tunes Songlengths doesn't know.
const DEFAULT_LENGTH = 180;

export class DemoPlayer extends EventTarget {
  /** `tunes`: what Surprise Me picks from. */
  constructor(tunes) {
    super();
    this.tunes = tunes;
    this.ctx = null;
    this.node = null;
    this.gain = null;
    this.ready = null;
    this.state = 'stopped'; // 'playing' | 'paused' | 'stopped'
    // Which list Next and Previous walk: 'surprise' or 'playlist'.
    this.source = null;
    this.playlist = [];
    this.row = -1;
    this.shuffle = false;
    this.repeat = 'off'; // 'off' | 'all' | 'one'
    this.entry = null;
    // The playing tune: its HVSC entry, plus the subtune, its length and
    // the stand-in's key and tempo.
    this.tune = null;
    this.history = [];
    this.historyIndex = -1;
    this.heard = new Set();
    this.volume = 0.8;
    this.muted = [false, false, false];
    // Latest frame from the driver: per voice [note, wave, gate, env, pw].
    this.voices = [];
    this.seq = 0;
    this.frame = 0;
    this.cutoff = 0;
  }

  get isPlaying() { return this.state === 'playing'; }
  get elapsed() { return this.frame / FRAME_HZ; }
  get progress() { return this.tune ? Math.min(this.elapsed / this.tune.lengthSecs, 1) : 0; }

  // Must start inside a click handler: the AudioContext is created and
  // resumed synchronously, and the worklet module loads after.
  ensureAudio() {
    if (this.ready) return this.ready;
    const Context = window.AudioContext || window.webkitAudioContext;
    this.ctx = new Context({ latencyHint: 'interactive' });
    this.ctx.resume();
    this.ready = this.ctx.audioWorklet
      .addModule(new URL('./sid-worklet.js', import.meta.url))
      .then(() => {
        this.node = new AudioWorkletNode(this.ctx, 'sid-demo', { numberOfInputs: 0, outputChannelCount: [2] });
        this.gain = this.ctx.createGain();
        this.applyVolume();
        this.node.connect(this.gain).connect(this.ctx.destination);
        this.node.port.onmessage = (e) => this.receive(e.data);
        this.muted.forEach((muted, voice) => this.node.port.postMessage({ t: 'mute', voice, muted }));
      });
    return this.ready;
  }

  receive(msg) {
    if (msg.t === 'frame') {
      this.voices = msg.voices;
      this.frame = msg.frame;
      this.cutoff = msg.cutoff;
      this.seq++;
    } else if (msg.t === 'end') {
      this.advance();
    }
  }

  async load(entry, subtune = entry.start) {
    this.ensureAudio();
    await this.ready;
    const { key, bpm, song } = composeTune(seedFor(entry.path), subtune);
    const lengthSecs = entry.lengths[subtune - 1] || DEFAULT_LENGTH;
    song.frames = Math.round(lengthSecs * FRAME_HZ);
    this.entry = entry;
    this.tune = { ...entry, subtune, lengthSecs, key, bpm };
    this.heard.add(entry.path);
    this.frame = 0;
    this.node.port.postMessage({ t: 'song', song });
    await this.ctx.resume();
    this.state = 'playing';
    this.emit();
  }

  /** A random tune not heard since the page loaded, one subtune each. */
  surprise() {
    this.source = 'surprise';
    this.row = -1;
    let pool = this.tunes.filter((t) => !this.heard.has(t.path));
    if (!pool.length) {
      this.heard.clear();
      pool = this.tunes.filter((t) => t.path !== this.entry?.path);
    }
    const entry = pool[Math.floor(Math.random() * pool.length)];
    this.history = this.history.slice(0, this.historyIndex + 1);
    this.history.push(entry);
    this.historyIndex = this.history.length - 1;
    return this.load(entry);
  }

  playRow(row) {
    this.source = 'playlist';
    this.row = row;
    return this.load(this.playlist[row]);
  }

  async toggle() {
    if (!this.tune) return this.surprise();
    if (this.isPlaying) {
      this.state = 'paused';
      this.emit();
      await this.ctx.suspend();
    } else {
      this.state = 'playing';
      this.emit();
      await this.ctx.resume();
    }
  }

  stop() {
    this.state = 'stopped';
    this.source = null;
    this.row = -1;
    this.entry = null;
    this.tune = null;
    this.frame = 0;
    this.emit();
  }

  next() {
    if (this.source === 'playlist') {
      const rows = this.playlist.length;
      if (this.shuffle && rows > 1) {
        const other = Math.floor(Math.random() * (rows - 1));
        return this.playRow(other >= this.row ? other + 1 : other);
      }
      return this.playRow((this.row + 1) % rows);
    }
    if (this.historyIndex < this.history.length - 1) {
      this.historyIndex++;
      return this.load(this.history[this.historyIndex]);
    }
    return this.surprise();
  }

  // Restarts the tune a few seconds in, like Music; otherwise goes back.
  previous() {
    if (!this.tune) return this.surprise();
    if (this.elapsed >= 3) return this.load(this.entry, this.tune.subtune);
    if (this.source === 'playlist') return this.playRow(Math.max(this.row - 1, 0));
    if (this.historyIndex > 0) this.historyIndex--;
    return this.load(this.history[this.historyIndex]);
  }

  // When a tune ends: Surprise Me picks another; the playlist moves on and
  // stops after its last row, unless it repeats.
  advance() {
    if (this.repeat === 'one') return this.load(this.entry, this.tune.subtune);
    const last = this.row === this.playlist.length - 1;
    if (this.source === 'playlist' && last && !this.shuffle && this.repeat === 'off') return this.stop();
    return this.next();
  }

  get subtunes() { return this.tune?.songs ?? 1; }

  stepSubtune(delta) {
    if (!this.tune) return;
    const next = this.tune.subtune + delta;
    if (next < 1 || next > this.tune.songs) return;
    return this.load(this.entry, next);
  }

  setVolume(v) {
    this.volume = v;
    this.applyVolume();
    this.emit();
  }

  applyVolume() {
    if (this.gain) this.gain.gain.setTargetAtTime(this.volume * this.volume, this.ctx.currentTime, 0.02);
  }

  setMuted(voice, muted) {
    this.muted[voice] = muted;
    this.node?.port.postMessage({ t: 'mute', voice, muted });
    this.emit();
  }

  emit() {
    this.dispatchEvent(new Event('change'));
  }
}
