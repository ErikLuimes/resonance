// Wires up the page: the tour of the app, "The chip" section's silent
// scopes, keyboard shortcuts, the latest GitHub release, the app's videos,
// and scroll effects.

import { VoiceMeter, drawScope, VOICE_COLORS } from './visualizer.js?v=20261104h';
import { noteName, waveName, seedFor } from './tune.js?v=20261104h';
import { SilentChip } from './chip.js?v=20261104h';

const REPO = 'ErikLuimes/resonance';

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const escapeHtml = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const textOf = (sel, text) => { for (const el of $$(sel)) if (el.textContent !== text) el.textContent = text; };
const stillMotion = matchMedia('(prefers-reduced-motion: reduce)');
// Whether the videos play with sound (see Sound, below).
let soundOn = false;

// ---------------------------------------------------------------------------
// The tour: a film of the real app in chapters. Each plays once, then the
// next starts; a tab picks one. Until a chapter's video exists, its
// placeholder stands in for a few seconds.

const CHAPTERS = [
  { slug: 'smart-playlists', title: 'Smart Playlists', text: 'Say what you\'d like to hear, and get the playlist.' },
  { slug: 'sounds-like', title: 'Sounds Like', text: 'Play a tune, and see the ones in HVSC that sound most like it.' },
  { slug: 'now-playing', title: 'Now Playing', text: 'Halo, Particles, Radial and the Sound Map, driven by the chip itself.' },
  { slug: 'library', title: 'All of HVSC', text: '60,000 tunes, composers by name, one search for everything.' },
  { slug: 'playlists', title: 'Your playlists', text: 'Favorites, playlists, and drag and drop from anywhere.' },
];
const PLACEHOLDER_SECS = 6;

const tourVideo = $('[data-tour-video]');
const tourMedia = tourVideo.closest('.media');
const tourTabs = $('[data-tour-tabs]');
tourTabs.innerHTML = CHAPTERS.map((c, i) => `
  <button type="button" role="tab" class="tour-tab" data-chapter="${i}" aria-selected="false">
    <span>${escapeHtml(c.title)}</span><i class="tour-bar"><b></b></i>
  </button>`).join('');
const tabButtons = $$('[data-chapter]', tourTabs);
let chapter = -1;
let tourVisible = false;
let placeholderTimer = 0;

function showChapter(i) {
  chapter = (i + CHAPTERS.length) % CHAPTERS.length;
  const c = CHAPTERS[chapter];
  textOf('[data-tour-title]', c.title);
  textOf('[data-tour-text]', c.text);
  textOf('[data-tour-placeholder]', c.title);
  tabButtons.forEach((b, n) => {
    b.setAttribute('aria-selected', n === chapter);
    b.style.setProperty('--fill', n < chapter ? 1 : 0);
  });
  tourMedia.classList.remove('is-ready');
  clearTimeout(placeholderTimer);
  tourVideo.poster = `media/${c.slug}.jpg`;
  tourVideo.innerHTML = `<source src="media/${c.slug}.mp4" type="video/mp4">`;
  tourVideo.load();
  tourVideo.muted = !soundOn;
  // No video yet: count the placeholder's seconds down instead.
  placeholderTimer = setTimeout(() => {
    if (!tourMedia.classList.contains('is-ready') && tourVisible && !document.hidden && !stillMotion.matches) showChapter(chapter + 1);
  }, PLACEHOLDER_SECS * 1000);
  if (tourVisible && !document.hidden && !stillMotion.matches) tourVideo.play().catch(() => {});
}

tourVideo.addEventListener('loadeddata', () => {
  tourMedia.classList.add('is-ready');
  clearTimeout(placeholderTimer);
});
tourVideo.addEventListener('ended', () => showChapter(chapter + 1));
for (const b of tabButtons) b.addEventListener('click', () => showChapter(Number(b.dataset.chapter)));
if (stillMotion.matches) tourVideo.controls = true;

// The current tab fills with the chapter's progress.
function tourFrame() {
  requestAnimationFrame(tourFrame);
  const tab = tabButtons[chapter];
  if (!tab) return;
  const progress = tourMedia.classList.contains('is-ready') && tourVideo.duration
    ? tourVideo.currentTime / tourVideo.duration
    : 0;
  tab.style.setProperty('--fill', progress.toFixed(3));
}
requestAnimationFrame(tourFrame);

// Visible means at least 30% on screen; isIntersecting alone stays true
// down to the last pixel, so a tour scrolled away kept playing.
new IntersectionObserver(([entry]) => {
  tourVisible = entry.intersectionRatio >= 0.3;
  if (chapter < 0) showChapter(0);
  else if (tourVisible && !document.hidden && !stillMotion.matches) tourVideo.play().catch(() => {});
  else tourVideo.pause();
}, { threshold: [0, 0.3] }).observe($('#tour'));

// ---------------------------------------------------------------------------
// The chip: three scopes and readouts, animated by a silent stand-in tune
// while the section is on screen.

const chip = new SilentChip(['MUSICIANS/H/Hubbard_Rob/Commando.sid', 'MUSICIANS/T/Tel_Jeroen/Cybernoid_II.sid',
  'MUSICIANS/G/Galway_Martin/Arkanoid.sid', 'MUSICIANS/D/Daglish_Ben/The_Last_Ninja.sid'].map(seedFor));
const meter = new VoiceMeter();
const scopes = $$('[data-scope]');
const voiceCards = $$('.voice-card');
let chipVisible = false;
let chipClock = null;
let lastText = 0;

function chipFrame(now) {
  requestAnimationFrame(chipFrame);
  if (!chipVisible) { chipClock = null; return; }
  // Reduced motion: one still frame of the tune, drawn once.
  if (stillMotion.matches && chip.seq > 0 && chipClock !== null) return;
  chipClock = chip.advance(chipClock, now);
  if (stillMotion.matches) for (let i = 0; i < 40; i++) chip.frame();
  meter.update(chip.state.map((v) => v[3]), chip.seq, now);
  chip.state.forEach((v, i) => {
    drawScope(scopes[i], v, meter.levels[i], VOICE_COLORS[i], false);
    voiceCards[i].style.setProperty('--lv', meter.levels[i].toFixed(3));
  });
  if (now - lastText > 120) {
    lastText = now;
    chip.state.forEach((v, i) => {
      textOf(`[data-note="${i}"]`, (v[2] && v[0] >= 0 && noteName(v[0])) || '·');
      textOf(`[data-wave="${i}"]`, waveName(v[1]) || '—');
    });
  }
}
requestAnimationFrame(chipFrame);
new IntersectionObserver(([entry]) => { chipVisible = entry.isIntersecting; }).observe($('#voices'));

// ---------------------------------------------------------------------------
// Keyboard: light up the matching shortcut.

function shortcutFor(e) {
  const cmd = e.metaKey || e.ctrlKey;
  const { key, code, altKey: alt, shiftKey: shift } = e;
  const arrowH = key === 'ArrowLeft' || key === 'ArrowRight';
  if (e.ctrlKey && e.metaKey && alt && code === 'KeyP') return 'miniplayer';
  if (code === 'Space' && !cmd && !alt) return 'play';
  if (cmd && !alt && key === '.') return 'stop';
  if (cmd && alt && arrowH) return 'subtune';
  if (cmd && arrowH) return 'track';
  if (cmd && shift && code === 'KeyR') return 'surprise';
  if (cmd && shift && code === 'KeyF') return 'nowplaying';
  if (cmd && (key === 'ArrowUp' || key === 'ArrowDown')) return 'volume';
  if (cmd && alt && code === 'KeyS') return 'shuffle';
  if (cmd && !shift && code === 'KeyO') return 'add';
  if (cmd && key === ',') return 'settings';
  return null;
}

const pressTimers = {};
function flash(id) {
  const row = $(`[data-shortcut="${id}"]`);
  if (!row) return;
  row.classList.add('is-pressed');
  clearTimeout(pressTimers[id]);
  pressTimers[id] = setTimeout(() => row.classList.remove('is-pressed'), 650);
}

addEventListener('keydown', (e) => {
  if (e.target.closest?.('input, textarea, select, [contenteditable]')) return;
  const id = shortcutFor(e);
  if (id) flash(id);
});

// ---------------------------------------------------------------------------
// Latest release from GitHub. Falls back to building from source while
// there's no public release (or the API is unreachable or rate-limited).

function relativeDate(date) {
  const days = Math.round((date - Date.now()) / 86_400_000);
  const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
  if (Math.abs(days) < 30) return rtf.format(days, 'day');
  if (Math.abs(days) < 365) return rtf.format(Math.round(days / 30), 'month');
  return rtf.format(Math.round(days / 365), 'year');
}

async function loadRelease() {
  const status = $('[data-release-status]');
  try {
    // Not releases/latest: that skips pre-releases (an alpha should still be
    // the download) and can be the "fingerprints" release, whose zip is the
    // app's fingerprint set. The newest release with a build of the app wins.
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=30`, {
      headers: { Accept: 'application/vnd.github+json' },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const appAsset = (release) => {
      const assets = (release.assets || []).filter((a) => !/^fingerprints/i.test(a.name));
      return [/\.dmg$/i, /\.zip$/i, /\.pkg$/i].map((rx) => assets.find((a) => rx.test(a.name))).find(Boolean);
    };
    const release = (await res.json()).find((r) => !r.draft && r.tag_name !== 'fingerprints' && appAsset(r));
    if (!release) throw new Error('no build yet');
    const asset = appAsset(release);
    const version = release.tag_name || release.name;
    const when = (release.prerelease ? ' · pre-release' : '')
      + (release.published_at ? ` · released ${relativeDate(new Date(release.published_at))}` : '');
    const size = asset ? ` · ${(asset.size / 1_048_576).toFixed(1)} MB` : '';
    status.innerHTML = `Version <strong>${escapeHtml(version)}</strong>${when}${size} · <a href="${escapeHtml(release.html_url)}">release notes</a>`;
    textOf('[data-release-line]', `Free and open source · ${version}`);
    // A release that isn't final says so on the button: "Download alpha".
    const stage = /-(alpha|beta)\b/i.exec(version)?.[1].toLowerCase();
    const label = stage ? `Download ${stage}` : null;
    for (const a of $$('a[data-download]')) {
      a.href = asset ? asset.browser_download_url : release.html_url;
      if (label) a.querySelector('[data-download-label]').textContent = label;
    }
  } catch {
    status.innerHTML = 'There\'s no public build yet — <a href="#build">build it from source</a> in a few minutes.';
    const [heroButton, downloadButton] = $$('a[data-download]');
    heroButton.href = '#download';
    heroButton.querySelector('[data-download-label]').textContent = 'Get Resonance';
    downloadButton.href = '#build';
    downloadButton.querySelector('[data-download-label]').textContent = 'Build from source';
  }
}
loadRelease();

// ---------------------------------------------------------------------------
// Scroll reveal, the nav's current section, tile spotlights, copy buttons.

const revealer = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    entry.target.classList.add('in');
    revealer.unobserve(entry.target);
  }
}, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
for (const el of $$('[data-reveal]')) {
  const siblings = $$(':scope > [data-reveal]', el.parentElement);
  el.style.transitionDelay = `${Math.min(siblings.indexOf(el), 5) * 70}ms`;
  revealer.observe(el);
}

// The app's videos: shown from their poster or first frame (a placeholder
// until then), playing only while at least 35% on screen (the ratio, not
// isIntersecting, which stays true until the last pixel leaves). With
// reduced motion they wait for a click on their controls.
const onScreen = new Map();
const videos = new IntersectionObserver((entries) => {
  for (const { target, intersectionRatio } of entries) {
    const shown = intersectionRatio >= 0.35;
    onScreen.set(target, shown);
    if (shown && !document.hidden && !stillMotion.matches) target.play().catch(() => {});
    else target.pause();
  }
}, { threshold: [0, 0.35] });
for (const video of $$('video[data-video]')) {
  const ready = () => video.closest('.media').classList.add('is-ready');
  video.addEventListener('loadeddata', ready, { once: true });
  if (video.poster) {
    const poster = new Image();
    poster.onload = ready;
    poster.src = video.poster;
  }
  if (stillMotion.matches) video.controls = true;
  videos.observe(video);
}

// Integrations: the list switches the screenshot. A screenshot shows once it
// has loaded; until then, or with no file yet, the placeholder.
for (const img of $$('.media-still img')) {
  const ready = () => img.closest('.media').classList.add('is-ready');
  if (img.complete && img.naturalWidth) ready();
  else img.addEventListener('load', ready, { once: true });
}
// A carousel of screenshots: the next every few seconds while it's on
// screen, not under the pointer or keyboard focus, and the page is in front.
// With reduced motion it stays on the first until a dot is clicked.
for (const figure of $$('[data-carousel]')) {
  const slides = $$('img', figure);
  let current = 0;
  const dots = document.createElement('div');
  dots.className = 'carousel-dots';
  const buttons = slides.map((img, i) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.setAttribute('aria-label', `Screenshot ${i + 1} of ${slides.length}`);
    button.addEventListener('click', () => show(i));
    dots.append(button);
    return button;
  });
  figure.append(dots);
  function show(i) {
    current = (i + slides.length) % slides.length;
    slides.forEach((img, n) => {
      img.classList.toggle('is-current', n === current);
      img.setAttribute('aria-hidden', n !== current);
    });
    buttons.forEach((b, n) => b.setAttribute('aria-current', n === current));
  }
  show(0);
  // All of them load early, so a cross-fade never shows a half-loaded picture.
  for (const img of slides) img.loading = 'eager';
  let visible = false;
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; }, { threshold: 0.35 }).observe(figure);
  let paused = false;
  figure.addEventListener('pointerenter', () => { paused = true; });
  figure.addEventListener('pointerleave', () => { paused = false; });
  figure.addEventListener('focusin', () => { paused = true; });
  figure.addEventListener('focusout', () => { paused = false; });
  setInterval(() => {
    if (visible && !paused && !document.hidden && !stillMotion.matches && !figure.closest('[hidden]')) show(current + 1);
  }, 4500);
}

for (const list of $$('[data-integrations] [role="tablist"]')) {
  const tabs = $$('[role="tab"]', list);
  const select = (tab, focus = false) => {
    for (const other of tabs) {
      const on = other === tab;
      other.setAttribute('aria-selected', on);
      other.tabIndex = on ? 0 : -1;
      document.getElementById(other.getAttribute('aria-controls')).hidden = !on;
    }
    if (focus) tab.focus();
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(tab));
    tab.addEventListener('keydown', (event) => {
      const step = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[event.key];
      if (!step) return;
      event.preventDefault();
      select(tabs[(i + step + tabs.length) % tabs.length], true);
    });
  });
}

// Sound: every video starts muted (browsers only autoplay muted video);
// the Sound button on any of them turns sound on for all, and only the one
// playing is heard.
const allVideos = $$('video');
for (const media of $$('.media')) {
  media.insertAdjacentHTML('beforeend', `
    <button type="button" class="media-sound" data-sound aria-pressed="false">
      <svg class="i i-fill"><use href="#i-mute"/></svg><span>Sound on</span>
    </button>`);
}
function setSound(on) {
  soundOn = on;
  for (const v of allVideos) v.muted = !on;
  for (const b of $$('[data-sound]')) {
    b.setAttribute('aria-pressed', on);
    b.querySelector('use').setAttribute('href', on ? '#i-speaker-loud' : '#i-mute');
    b.querySelector('span').textContent = on ? 'Sound off' : 'Sound on';
  }
}
for (const b of $$('[data-sound]')) {
  b.addEventListener('click', () => {
    setSound(!soundOn);
    const video = b.closest('.media').querySelector('video');
    if (soundOn && video.paused) video.play().catch(() => {});
  });
}
for (const v of allVideos) {
  v.addEventListener('play', () => {
    if (!soundOn) return;
    for (const other of allVideos) if (other !== v) other.pause();
  });
}

// A hidden tab plays nothing; back in view, what's on screen plays again.
document.addEventListener('visibilitychange', () => {
  for (const v of $$('video')) {
    const shown = v === tourVideo ? tourVisible : onScreen.get(v);
    if (document.hidden || !shown || stillMotion.matches) v.pause();
    else v.play().catch(() => {});
  }
});

const navLinks = $$('.nav-links a');
const spy = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    for (const link of navLinks) link.setAttribute('aria-current', link.hash === `#${entry.target.id}`);
  }
}, { rootMargin: '-45% 0px -50% 0px' });
for (const section of $$('main > section[id]')) spy.observe(section);

for (const tile of $$('.tile')) {
  tile.addEventListener('pointermove', (e) => {
    const r = tile.getBoundingClientRect();
    tile.style.setProperty('--mx', `${e.clientX - r.left}px`);
    tile.style.setProperty('--my', `${e.clientY - r.top}px`);
  });
}

for (const button of $$('.copy')) {
  button.addEventListener('click', async () => {
    const code = button.parentElement.querySelector('code').innerText;
    try {
      await navigator.clipboard.writeText(code);
      button.classList.add('done');
      button.querySelector('span').textContent = 'Copied';
      setTimeout(() => {
        button.classList.remove('done');
        button.querySelector('span').textContent = 'Copy';
      }, 1800);
    } catch {
      button.querySelector('span').textContent = 'Select & copy';
    }
  });
}

textOf('[data-year]', String(new Date().getFullYear()));

// Everything is wired up: the page's fallback can stand down.
window.resonanceReady = true;

