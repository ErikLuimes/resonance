// The chip section's drawing, after Resonance's VisualizerView.swift and
// SIDVoice.swift: per-voice levels with fast attack and slow release, and a
// stylised scope of each voice's waveform.

import { TRI, SAW, PUL, NOI } from './tune.js';

export const VOICE_COLORS = ['#3FD0E8', '#9B6BFF', '#FF9A3C'];

/** Frame-rate independent smoothing, tuned at 30 fps like the app's. */
export class VoiceMeter {
  constructor() {
    this.levels = [0, 0, 0];
    this.peaks = [0, 0, 0];
    this.lastUpdate = null;
    this.lastSeq = null;
  }

  update(input, seq, now) {
    const dt = this.lastUpdate === null ? 0 : Math.min((now - this.lastUpdate) / 1000, 0.25);
    this.lastUpdate = now;
    const frames = dt * 30;
    const decay = Math.pow(0.92, frames);
    const peakDecay = Math.pow(0.985, frames);
    // Only take new values from new player frames; otherwise just decay.
    const fresh = seq !== this.lastSeq;
    this.lastSeq = seq;
    for (let i = 0; i < 3; i++) {
      const next = fresh ? Math.min(Math.max(input[i] ?? 0, 0), 1) : 0;
      this.levels[i] = next > this.levels[i] ? next : this.levels[i] * decay;
      this.peaks[i] = this.levels[i] > this.peaks[i] ? this.levels[i] : this.peaks[i] * peakDecay;
    }
  }

  reset() {
    this.levels = [0, 0, 0];
    this.peaks = [0, 0, 0];
    this.lastUpdate = null;
  }
}

/** Sizes a canvas's backing store to its CSS box; returns its CSS size. */
export function fitCanvas(canvas) {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx, w, h };
}

// One cycle of a SID waveform at phase p (0…1), between -1 and 1.
function waveAt(wave, p, pw, noise) {
  switch (wave) {
    case TRI: return p < 0.5 ? 4 * p - 1 : 3 - 4 * p;
    case SAW: return 2 * p - 1;
    case PUL: return p < pw ? 1 : -1;
    case NOI: return noise;
    case 0: return 0;
    default: {
      let bits = 0xfff;
      if (wave & TRI) bits &= Math.floor((p < 0.5 ? p * 2 : 2 - p * 2) * 4095);
      if (wave & SAW) bits &= Math.floor(p * 4095);
      if (wave & PUL) bits &= p < pw ? 0xfff : 0;
      if (wave & NOI) bits &= Math.floor((noise + 1) * 2047);
      return bits / 2047.5 - 1;
    }
  }
}

/**
 * A stylised oscilloscope of one voice: its waveform drawn from the
 * driver's state (not measured audio), more cycles for higher notes,
 * scaled by the envelope.
 */
export function drawScope(canvas, voice, level, color, muted) {
  const { ctx, w, h } = fitCanvas(canvas);
  ctx.clearRect(0, 0, w, h);
  const mid = h / 2;

  ctx.strokeStyle = 'rgba(255, 255, 255, 0.06)';
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let gx = 0; gx <= w; gx += w / 8) { ctx.moveTo(gx, 0); ctx.lineTo(gx, h); }
  ctx.moveTo(0, mid); ctx.lineTo(w, mid);
  ctx.stroke();

  const wave = voice ? voice[1] : 0;
  const amp = muted ? 0 : level * (h * 0.38);
  const note = voice && voice[0] >= 0 ? voice[0] : 60;
  const cycles = Math.min(Math.max(Math.pow(2, (note - 48) / 12) * 1.5, 1), 7);
  const pw = voice ? voice[4] : 0.5;

  ctx.lineWidth = 2;
  ctx.lineJoin = 'round';
  ctx.strokeStyle = muted ? 'rgba(255, 255, 255, 0.18)' : color;
  ctx.shadowColor = color;
  ctx.shadowBlur = muted ? 0 : 12;
  ctx.beginPath();
  const steps = Math.max(Math.floor(w), 64);
  let noise = 0;
  for (let i = 0; i <= steps; i++) {
    const x = (i / steps) * w;
    const p = ((i / steps) * cycles) % 1;
    if (i % 3 === 0) noise = Math.random() * 2 - 1;
    const y = mid - waveAt(wave, p, pw, noise) * amp;
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  }
  ctx.stroke();
  ctx.shadowBlur = 0;
}
