// The demo player behind the page's Resonance window: Surprise Me as a
// radio of generated tunes, with history for Previous, subtunes, volume
// and per-voice mute. Audio starts on the first click (browsers require a
// gesture), and pausing suspends the AudioContext.

import { composeTune, SUBTUNES } from './tune.js';

export class DemoPlayer extends EventTarget {
  constructor() {
    super();
    this.ctx = null;
    this.node = null;
    this.gain = null;
    this.ready = null;
    this.state = 'stopped'; // 'playing' | 'paused' | 'stopped'
    this.tune = null;
    this.history = [];
    this.historyIndex = -1;
    this.volume = 0.8;
    this.muted = [false, false, false];
    // Latest frame from the driver: per voice [note, wave, gate, env, pw].
    this.voices = [];
    this.seq = 0;
    this.row = 0;
    this.rows = 1;
    this.cutoff = 0;
    this.surprises = 0;
  }

  get isPlaying() { return this.state === 'playing'; }
  get elapsed() { return this.tune ? (this.row / this.rows) * this.tune.lengthSecs : 0; }
  get progress() { return this.tune ? this.row / this.rows : 0; }

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
      this.row = msg.row;
      this.rows = msg.rows;
      this.cutoff = msg.cutoff;
      this.seq++;
    } else if (msg.t === 'end') {
      // Like the app's Surprise Me radio: when a tune ends, the next one plays.
      this.next();
    }
  }

  async load(seed, subtune = 1) {
    this.ensureAudio();
    await this.ready;
    this.tune = composeTune(seed, subtune);
    this.row = 0;
    this.rows = this.tune.song.rows;
    this.node.port.postMessage({ t: 'song', song: this.tune.song });
    await this.ctx.resume();
    this.state = 'playing';
    this.emit();
  }

  surprise() {
    const seed = 1 + Math.floor(Math.random() * 99999);
    this.history = this.history.slice(0, this.historyIndex + 1);
    this.history.push(seed);
    this.historyIndex = this.history.length - 1;
    this.surprises++;
    return this.load(seed);
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

  next() {
    if (this.historyIndex < this.history.length - 1) {
      this.historyIndex++;
      return this.load(this.history[this.historyIndex]);
    }
    return this.surprise();
  }

  // Restarts the tune a few seconds in, like Music; otherwise goes back.
  previous() {
    if (!this.tune) return this.surprise();
    if (this.elapsed < 3 && this.historyIndex > 0) this.historyIndex--;
    return this.load(this.history[this.historyIndex]);
  }

  get hasSubtunes() { return !!this.tune; }
  get subtune() { return this.tune?.subtune ?? 1; }
  get subtunes() { return SUBTUNES; }

  stepSubtune(delta) {
    if (!this.tune) return;
    const next = this.tune.subtune + delta;
    if (next < 1 || next > SUBTUNES) return;
    return this.load(this.tune.seed, next);
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
