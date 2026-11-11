// Wires up the page: the tour of the app, "The chip" section's silent
// scopes, keyboard shortcuts, the latest GitHub release, the app's videos,
// and scroll effects.

import { VoiceMeter, drawScope, VOICE_COLORS } from './visualizer.js?v=20261108c';
import { setUpCarousel } from './carousel.js?v=20261108e';
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
  { slug: 'now-playing', title: 'Now Playing', text: 'Twelve visualizers, driven by the chip itself.' },
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

// Visualizers: three featured in the whole Now Playing window, taking turns
// like the tour. Until one's video exists its picture stands in, for a few
// seconds. The nine below are bare recordings; one plays at a time, the one
// under the pointer (or, without one, the one in the middle of the screen).

const FEATURED = [
  { slug: 'vis-ink', title: 'Ink', text: 'Each voice pours a stream of dye in its color into dark water; every note is a puff, and the three curl into each other.' },
  { slug: 'vis-silicon', title: 'Silicon', text: 'The tune\'s SID in 3D with the lid off, its die drawn from the chip\'s own mask layers, at work.' },
  { slug: 'vis-notes', title: 'Notes', text: 'The tune as sheet music running into the distance, a ball hopping from note to note.' },
];
const vzVideo = $('[data-vz-video]');
const vzMedia = vzVideo.closest('.media');
const vzTabs = $('[data-vz-tabs]');
vzTabs.innerHTML = FEATURED.map((f, i) => `
  <button type="button" role="tab" class="tour-tab" data-featured="${i}" aria-selected="false">
    <span>${escapeHtml(f.title)}</span><i class="tour-bar"><b></b></i>
  </button>`).join('');
const vzButtons = $$('[data-featured]', vzTabs);
let featured = -1;
let vzVisible = false;
let vzHasVideo = false;
// When the current picture's seconds started counting (no video yet).
let vzStarted = 0;
let vzProgress = 0;

const vzPlaying = () => vzVisible && !document.hidden && !stillMotion.matches;

function showFeatured(i) {
  featured = (i + FEATURED.length) % FEATURED.length;
  const shown = featured;
  const f = FEATURED[featured];
  textOf('[data-vz-title]', f.title);
  textOf('[data-vz-text]', f.text);
  textOf('[data-vz-placeholder]', f.title);
  vzButtons.forEach((b, n) => {
    b.setAttribute('aria-selected', n === featured);
    b.style.setProperty('--fill', 0);
  });
  vzMedia.classList.remove('is-ready', 'has-video');
  vzHasVideo = false;
  vzStarted = performance.now();
  vzProgress = 0;
  vzVideo.poster = `media/${f.slug}.jpg`;
  vzVideo.innerHTML = `<source src="media/${f.slug}.mp4" type="video/mp4">`;
  vzVideo.load();
  vzVideo.muted = !soundOn;
  // The picture shows until the video has a frame.
  const poster = new Image();
  poster.onload = () => { if (featured === shown) vzMedia.classList.add('is-ready'); };
  poster.src = vzVideo.poster;
  if (vzPlaying()) vzVideo.play().catch(() => {});
}
vzVideo.addEventListener('loadeddata', () => { vzHasVideo = true; vzMedia.classList.add('is-ready', 'has-video'); });
vzVideo.addEventListener('ended', () => showFeatured(featured + 1));
for (const b of vzButtons) b.addEventListener('click', () => showFeatured(Number(b.dataset.featured)));
if (stillMotion.matches) vzVideo.controls = true;

function vzFrame(now) {
  requestAnimationFrame(vzFrame);
  const tab = vzButtons[featured];
  if (!tab) return;
  if (vzHasVideo) {
    vzProgress = vzVideo.duration ? vzVideo.currentTime / vzVideo.duration : 0;
  } else if (vzPlaying()) {
    vzProgress = (now - vzStarted) / (PLACEHOLDER_SECS * 1000);
    if (vzProgress >= 1) { showFeatured(featured + 1); return; }
  } else {
    // Off screen the picture's count holds where it was.
    vzStarted = now - vzProgress * PLACEHOLDER_SECS * 1000;
  }
  tab.style.setProperty('--fill', vzProgress.toFixed(3));
}
requestAnimationFrame(vzFrame);

new IntersectionObserver(([entry]) => {
  vzVisible = entry.intersectionRatio >= 0.3;
  onScreen.set(vzVideo, vzVisible);
  if (featured < 0) showFeatured(linkedFeatured() ?? 0);
  else if (vzPlaying()) vzVideo.play().catch(() => {});
  else vzVideo.pause();
}, { threshold: [0, 0.3] }).observe($('#vz-stage'));

const tiles = $$('video[data-vz-tile]');
const canHover = matchMedia('(hover: hover)');
let hoveredTile = null;
let centeredTile = null;
// The tile a shared link opened on plays until the pointer picks another.
let linkedTile = null;
function playTiles() {
  const chosen = (canHover.matches ? hoveredTile : centeredTile) ?? linkedTile;
  for (const t of tiles) {
    const play = t === chosen && !document.hidden && !stillMotion.matches;
    onScreen.set(t, play);
    if (play) t.play().catch(() => {});
    else t.pause();
  }
}
// Without a pointer: the tile crossing the middle tenth of the screen.
const middle = new IntersectionObserver((entries) => {
  for (const { target, isIntersecting } of entries) {
    if (isIntersecting) centeredTile = target;
    else if (centeredTile === target) centeredTile = null;
  }
  playTiles();
}, { rootMargin: '-45% 0px -45% 0px' });
for (const t of tiles) {
  const media = t.closest('.media');
  const poster = new Image();
  poster.onload = () => media.classList.add('is-ready');
  poster.src = t.poster;
  t.addEventListener('loadeddata', () => media.classList.add('is-ready'), { once: true });
  const card = t.closest('.vz-tile');
  card.addEventListener('pointerenter', () => { hoveredTile = t; linkedTile = null; playTiles(); });
  card.addEventListener('pointerleave', () => { if (hoveredTile === t) hoveredTile = null; playTiles(); });
  if (stillMotion.matches) t.controls = true;
  middle.observe(t);
}

// A visualizer's own link: its page (v/<slug>/, which link previews read)
// sends people here with #vis-<slug>. Share copies that page's address, or
// opens the system's share sheet on a phone.
function linkedFeatured() {
  const i = FEATURED.findIndex((f) => `#${f.slug}` === location.hash);
  return i < 0 ? null : i;
}
// Straight there, once the page is laid out: smooth scrolling from the top
// of a long page gets cut short as the images above it load.
function jumpTo(el) {
  const go = () => el.scrollIntoView({ block: 'center', behavior: 'instant' });
  if (document.readyState === 'complete') go();
  else addEventListener('load', go, { once: true });
}
function openLinked() {
  const i = linkedFeatured();
  if (i !== null) {
    showFeatured(i);
    jumpTo($('#vz-stage'));
    return;
  }
  const card = location.hash.startsWith('#vis-') && document.getElementById(location.hash.slice(1));
  if (!card) return;
  linkedTile = $('video', card);
  jumpTo(card);
  playTiles();
}
addEventListener('hashchange', openLinked);
if (location.hash.startsWith('#vis-')) openLinked();

// The clipboard, or the older copy command where a browser refuses that
// (a page without focus, an old Safari).
async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const field = Object.assign(document.createElement('textarea'), { value: text, readOnly: true });
    field.style.cssText = 'position:fixed; opacity:0; pointer-events:none';
    document.body.append(field);
    field.select();
    let copied = false;
    try { copied = document.execCommand('copy'); } catch {}
    field.remove();
    return copied;
  }
}
const phoneShare = 'share' in navigator && matchMedia('(pointer: coarse)').matches;
async function share(button, slug, title) {
  const url = new URL(`v/${slug}/`, document.baseURI).href;
  if (phoneShare) {
    try { await navigator.share({ title: `${title}, a Resonance visualizer`, url }); } catch {}
    return;
  }
  if (!(await copy(url))) {
    // Nothing would take it: show it to copy by hand.
    prompt('The link to this visualizer:', url);
    return;
  }
  button.textContent = 'Link copied';
  button.dataset.copied = '';
  clearTimeout(button.copiedTimer);
  button.copiedTimer = setTimeout(() => {
    button.textContent = 'Share';
    delete button.dataset.copied;
  }, 1800);
}
for (const b of $$('[data-share]')) {
  b.addEventListener('click', () => share(b, b.dataset.share, $('h3', b.closest('.vz-tile')).textContent));
}
const featuredShare = $('[data-share-featured]');
featuredShare.addEventListener('click', () => {
  const f = FEATURED[Math.max(featured, 0)];
  share(featuredShare, f.slug.replace(/^vis-/, ''), f.title);
});

// Integrations: the list switches the screenshot. A screenshot shows once it
// has loaded; until then, or with no file yet, the placeholder.
for (const img of $$('.media-still img')) {
  const ready = () => img.closest('.media').classList.add('is-ready');
  if (img.complete && img.naturalWidth) ready();
  else img.addEventListener('load', ready, { once: true });
}
const carousels = new Map($$('[data-carousel]').map((figure) => [figure, setUpCarousel(figure, stillMotion)]));

for (const list of $$('[data-integrations] [role="tablist"]')) {
  const tabs = $$('[role="tab"]', list);
  const select = (tab, focus = false) => {
    for (const other of tabs) {
      const on = other === tab;
      other.setAttribute('aria-selected', on);
      other.tabIndex = on ? 0 : -1;
      document.getElementById(other.getAttribute('aria-controls')).hidden = !on;
    }
    // A carousel can't measure itself while its panel is hidden.
    const shown = document.getElementById(tab.getAttribute('aria-controls')).querySelector('[data-carousel]');
    if (shown) {
      carousels.get(shown).reInit();
      carousels.get(shown).wake();
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

