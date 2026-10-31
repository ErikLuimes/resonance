// Wires up the page: the interactive Resonance window and its demo
// player, the voice scopes, the HVSC search sample, keyboard shortcuts,
// the latest GitHub release, and scroll effects.

import { DemoPlayer } from './player.js';
import { VoiceMeter, drawVisualizer, drawScope, VOICE_COLORS } from './visualizer.js';
import { noteName, waveName } from './tune.js';
import { TuneSearch, highlight, formatLength } from './search.js';

const REPO = 'ErikLuimes/resonance';

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const escapeHtml = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const icon = (id, cls = 'i') => `<svg class="${cls}"><use href="#${id}"/></svg>`;
const setIcon = (svg, id) => svg.querySelector('use').setAttribute('href', `#${id}`);

const player = new DemoPlayer();
const meter = new VoiceMeter();

// ---------------------------------------------------------------------------
// The window: drawn at a fixed design size and scaled to fit, switching to
// a compact layout (no sidebar or table) on narrow screens.

const stage = $('#stage');
const mac = $('#mac');

function fitStage() {
  const width = stage.clientWidth;
  const compact = width < 760;
  const designWidth = compact ? 640 : 1240;
  const designHeight = compact ? 760 : 780;
  const scale = Math.min(width / designWidth, 1);
  mac.classList.toggle('compact', compact);
  mac.style.width = `${designWidth}px`;
  mac.style.height = `${designHeight}px`;
  mac.style.setProperty('--s', scale);
  stage.style.height = `${designHeight * scale}px`;
  drawStill();
}
new ResizeObserver(fitStage).observe(stage);

// Real tunes from HVSC, with their header fields and Songlengths entries.
const playlist = [
  ['Commando', 'Rob Hubbard', '1985 Elite', 236, 19],
  ['Monty on the Run', 'Rob Hubbard', '1985 Gremlin Graphics', 350, 19],
  ['Sanxion', 'Rob Hubbard', '1986 Thalamus', 334, 2],
  ['Parallax', 'Martin Galway', '1986 Ocean', 683, 5],
  ['International Karate', 'Rob Hubbard', '1986 System 3', 645, 1],
  ['Shades', 'Chris Hülsbeck', "1986 64'er/Markt & Technik", 298, 1],
  ['Spellbound', 'Rob Hubbard', '1986 MAD/Mastertronic', 341, 13],
  ['Cybernoid II', 'Jeroen Tel', '1988 Hewson', 346, 2],
  ['Last Ninja 2', 'Matt Gray', '1988 System 3', 267, 13],
  ['Supremacy', 'Jeroen Tel', '1991 Virgin', 231, 3],
].map(([title, author, released, length, songs]) => ({ title, author, released, length, songs, song: 1, sids: 1, type: 'PSID' }));

const tbody = $('[data-playlist]');
let selectedRow = null;
let playlistSeed = null; // the generated tune last played from the playlist

function renderPlaylist(newIndex = -1) {
  const current = player.tune?.seed;
  tbody.innerHTML = playlist
    .map((row, i) => {
      const isCurrent = row.seed && row.seed === current && playlistSeed === current;
      const cls = [i === selectedRow && 'is-selected', isCurrent && 'is-current', i === newIndex && 'is-new'].filter(Boolean).join(' ');
      const num = isCurrent ? icon(player.isPlaying ? 'i-speaker-wave' : 'i-speaker') : i + 1;
      const songs = row.songs > 1 ? `${row.song}/${row.songs}` : '1';
      return `<tr data-row="${i}" class="${cls}">
        <td class="num-cell muted-cell">${num}</td>
        <td class="t-title">${escapeHtml(row.title)}</td>
        <td>${escapeHtml(row.author)}</td>
        <td>${escapeHtml(row.released)}</td>
        <td class="tabular">${formatLength(row.length)}</td>
        <td class="tabular">${songs}</td>
        <td>${row.sids}</td>
        <td>${row.type}</td>
      </tr>`;
    })
    .join('');
  $('[data-playlist-count]').textContent = playlist.length;
}

tbody.addEventListener('click', (e) => {
  const tr = e.target.closest('tr');
  if (!tr) return;
  selectedRow = Number(tr.dataset.row);
  renderPlaylist();
});

tbody.addEventListener('dblclick', (e) => {
  const tr = e.target.closest('tr');
  if (!tr) return;
  const row = playlist[Number(tr.dataset.row)];
  if (row.seed) {
    playlistSeed = row.seed;
    player.load(row.seed);
  } else {
    banner(`Resonance plays ${row.title} from your HVSC folder. This page can only make up its own tunes — try Surprise Me.`);
  }
});

// Loading and error capsules float over the top of the playlist, as in the app.
function banner(text) {
  const slot = $('.banner-slot');
  slot.replaceChildren();
  const el = document.createElement('div');
  el.className = 'banner glass';
  el.textContent = text;
  slot.append(el);
  setTimeout(() => el.classList.add('out'), 3600);
  setTimeout(() => el.remove(), 4000);
}

const repeatModes = [
  { name: 'Off', icon: 'i-repeat' },
  { name: 'All', icon: 'i-repeat' },
  { name: 'One', icon: 'i-repeat-1' },
];
let repeat = 0;

const actions = {
  surprise: () => {
    const dice = $('[data-dice]');
    dice.classList.remove('wiggle');
    void dice.getBoundingClientRect();
    dice.classList.add('wiggle');
    playlistSeed = null;
    player.surprise();
  },
  add: () => banner('In Resonance, this adds SID files, folders or M3U playlists. You can drop them on the window, too.'),
  inspector: (button) => {
    const content = $('.mac-content');
    const hidden = content.classList.toggle('no-inspector');
    button.title = hidden ? 'Show the inspector' : 'Hide the inspector';
  },
  shuffle: (button) => {
    const on = button.getAttribute('aria-pressed') !== 'true';
    button.setAttribute('aria-pressed', on);
    button.title = `Shuffle: ${on ? 'On' : 'Off'}`;
  },
  repeat: (button) => {
    repeat = (repeat + 1) % repeatModes.length;
    const mode = repeatModes[repeat];
    setIcon($('[data-repeat-icon]'), mode.icon);
    button.setAttribute('aria-pressed', repeat !== 0);
    button.title = `Repeat: ${mode.name}`;
    button.setAttribute('aria-label', button.title);
  },
  play: () => player.toggle(),
  next: () => { playlistSeed = null; player.next(); },
  prev: () => player.previous(),
  'next-sub': () => player.stepSubtune(1),
  'prev-sub': () => player.stepSubtune(-1),
  keep: () => {
    const tune = player.tune;
    if (!tune || playlist.some((r) => r.seed === tune.seed)) return;
    playlist.push({
      title: tune.title, author: tune.author, released: tune.released,
      length: tune.lengthSecs, songs: 3, song: tune.subtune, sids: 1, type: 'WEB', seed: tune.seed,
    });
    renderPlaylist(playlist.length - 1);
    $('.mac-table-wrap').scrollTop = 1e6;
    updateUI();
  },
};

mac.addEventListener('click', (e) => {
  const button = e.target.closest('[data-act]');
  if (button) actions[button.dataset.act]?.(button);

  const item = e.target.closest('[data-sidebar]');
  if (item && item.dataset.sidebar !== 'playlist') {
    banner(`${item.textContent.trim()} opens the HVSC browser in the app. Try the search sample further down.`);
  }
});

// The progress bar explains why it can't scrub, like the app's popover.
const popover = $('[data-scrub-popover]');
$('[data-progress]').addEventListener('click', (e) => {
  e.stopPropagation();
  popover.hidden = !popover.hidden;
});
document.addEventListener('click', (e) => {
  if (!popover.hidden && !popover.contains(e.target)) popover.hidden = true;
});

const volume = $('[data-volume]');
volume.addEventListener('input', () => {
  player.setVolume(Number(volume.value));
  volume.style.setProperty('--v', `${volume.value * 100}%`);
});

for (const el of $$('[data-demo-toggle], [data-demo-start]')) {
  el.addEventListener('click', () => player.toggle());
}

// ---------------------------------------------------------------------------
// State → UI

const formatTime = (secs) => formatLength(secs);
const textOf = (sel, text) => { for (const el of $$(sel)) if (el.textContent !== text) el.textContent = text; };

function updateUI() {
  const tune = player.tune;
  const playing = player.isPlaying;
  document.documentElement.classList.toggle('playing', playing);

  setIcon($('[data-play-icon]'), playing ? 'i-pause' : 'i-play');
  $('[data-act="play"]').setAttribute('aria-label', playing ? 'Pause' : 'Play');
  setIcon($('[data-demo-icon]'), playing ? 'i-pause' : 'i-play');
  textOf('[data-demo-label]', playing ? 'Pause the demo' : tune ? 'Resume the demo' : 'Hear the demo');
  $('[data-demo-start]').classList.toggle('is-hidden', !!tune);

  const fromPlaylist = tune && playlistSeed === tune.seed;
  $('[data-np-badge]').hidden = !tune || fromPlaylist;
  textOf('[data-np-title]', tune ? tune.title : 'Not Playing');
  textOf('[data-np-author]', tune ? tune.author : '');
  textOf('[data-np-duration]', tune ? formatTime(tune.lengthSecs) : '--:--');

  $('[data-subtunes]').hidden = !tune;
  $('[data-scrub-subtunes]').hidden = !tune;
  if (tune) {
    textOf('[data-np-song]', `Song ${tune.subtune}/${player.subtunes}`);
    $('[data-act="prev-sub"]').disabled = tune.subtune <= 1;
    $('[data-act="next-sub"]').disabled = tune.subtune >= player.subtunes;
  }

  $('[data-insp-empty]').hidden = !!tune;
  $('[data-insp-details]').hidden = !tune;
  if (tune) {
    $('[data-np-source]').innerHTML = fromPlaylist
      ? `${icon('i-list')}Playlist`
      : `${icon('i-dice-fill')}Surprise Me`;
    textOf('[data-np-title2]', tune.title);
    textOf('[data-np-author2]', tune.author);
    textOf('[data-np-released]', tune.released);
    textOf('[data-np-song2]', `${tune.subtune} of ${player.subtunes}`);
    textOf('[data-np-length]', formatTime(tune.lengthSecs));
    textOf('[data-np-key]', tune.key);
    textOf('[data-np-bpm]', `${tune.bpm} BPM`);
    const kept = playlist.some((r) => r.seed === tune.seed);
    const keep = $('[data-act="keep"]');
    keep.disabled = kept;
    keep.innerHTML = kept ? `${icon('i-check')}<span>In Playlist</span>` : `${icon('i-add-list')}<span>Add to Playlist</span>`;
  }

  renderPlaylist();
}

player.addEventListener('change', updateUI);

// ---------------------------------------------------------------------------
// Animation: visualizer, scopes, progress and the aurora, every frame while
// the demo plays. Paused, everything holds still (the app's TimelineView
// pauses too).

const vizCanvas = $('[data-viz]');
const scopes = $$('[data-scope]');
const voiceCards = $$('.voice-card');
const aurora = $('.aurora');
const glow = $('.stage-glow');
const visible = { stage: true, voices: false };

function drawStill() {
  drawVisualizer(vizCanvas, meter, player.voices);
  scopes.forEach((canvas, i) => drawScope(canvas, player.voices[i], meter.levels[i], VOICE_COLORS[i], player.muted[i]));
}

let lastText = 0;
function frame(now) {
  requestAnimationFrame(frame);
  if (!player.isPlaying) return;

  meter.update(player.voices.map((v) => v[3]), player.seq, now);
  if (visible.stage) drawVisualizer(vizCanvas, meter, player.voices);

  if (visible.voices) {
    player.voices.forEach((v, i) => {
      drawScope(scopes[i], v, meter.levels[i], VOICE_COLORS[i], player.muted[i]);
      voiceCards[i].style.setProperty('--lv', player.muted[i] ? 0 : meter.levels[i].toFixed(3));
    });
  }

  for (const el of [aurora, glow]) {
    el.style.setProperty('--l1', meter.levels[0].toFixed(3));
    el.style.setProperty('--l2', meter.levels[1].toFixed(3));
    el.style.setProperty('--l3', meter.levels[2].toFixed(3));
  }

  $('[data-np-progress]').style.width = `${player.progress * 100}%`;

  if (now - lastText > 120) {
    lastText = now;
    textOf('[data-np-elapsed]', formatTime(player.elapsed));
    textOf('[data-np-filter]', `LP ${Math.round(player.cutoff).toLocaleString('en')} Hz`);
    player.voices.forEach((v, i) => {
      textOf(`[data-note="${i}"]`, (v[2] && v[0] >= 0 && noteName(v[0])) || '·');
      textOf(`[data-wave="${i}"]`, waveName(v[1]) || '—');
    });
  }
}
requestAnimationFrame(frame);

// Only draw what's on screen.
const visibility = new IntersectionObserver((entries) => {
  for (const entry of entries) visible[entry.target.dataset.visible] = entry.isIntersecting;
});
stage.dataset.visible = 'stage';
$('#voices').dataset.visible = 'voices';
visibility.observe(stage);
visibility.observe($('#voices'));

// Per-voice mute.
for (const button of $$('[data-mute]')) {
  button.addEventListener('click', () => {
    const voice = Number(button.dataset.mute);
    const muted = !player.muted[voice];
    player.setMuted(voice, muted);
    button.setAttribute('aria-pressed', muted);
    button.querySelector('span').textContent = muted ? 'Muted' : 'Mute';
    setIcon(button.querySelector('svg'), muted ? 'i-mute' : 'i-speaker-wave');
    voiceCards[voice].classList.toggle('is-muted', muted);
    if (!player.isPlaying) drawStill();
  });
}

// ---------------------------------------------------------------------------
// Keyboard: light up the matching shortcut, and let a few plain keys drive
// the demo (browsers keep most ⌘ combinations for themselves).

function shortcutFor(e) {
  const cmd = e.metaKey || e.ctrlKey;
  const { key, code, altKey: alt, shiftKey: shift } = e;
  const arrowH = key === 'ArrowLeft' || key === 'ArrowRight';
  if (code === 'Space' && !cmd && !alt) return 'play';
  if (cmd && !alt && key === '.') return 'stop';
  if (cmd && alt && arrowH) return 'subtune';
  if (arrowH) return 'track';
  if (cmd && shift && code === 'KeyR') return 'surprise';
  if (!cmd && !alt && code === 'KeyR') return 'surprise';
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
  const id = shortcutFor(e);
  if (id) flash(id);
  if (e.metaKey || e.ctrlKey || e.altKey || e.repeat) return;
  const target = e.target;
  if (target.closest?.('input, textarea, select, [contenteditable]')) return;

  if (e.code === 'Space') {
    if (target.closest?.('button, a, summary')) return;
    if (!visible.stage && !player.tune) return;
    e.preventDefault();
    player.toggle();
  } else if (e.code === 'KeyR' && !e.shiftKey) {
    actions.surprise();
  } else if (e.key === 'ArrowRight' && player.tune) {
    actions.next();
  } else if (e.key === 'ArrowLeft' && player.tune) {
    actions.prev();
  }
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
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: 'application/vnd.github+json' },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const release = await res.json();
    const assets = release.assets || [];
    const asset = [/\.dmg$/i, /\.zip$/i, /\.pkg$/i].map((rx) => assets.find((a) => rx.test(a.name))).find(Boolean);
    const version = release.tag_name || release.name;
    const when = release.published_at ? ` · released ${relativeDate(new Date(release.published_at))}` : '';
    const size = asset ? ` · ${(asset.size / 1_048_576).toFixed(1)} MB` : '';
    status.innerHTML = `Version <strong>${escapeHtml(version)}</strong>${when}${size} · <a href="${escapeHtml(release.html_url)}">release notes</a>`;
    textOf('[data-release-line]', `Free and open source · ${version}`);
    for (const a of $$('a[data-download]')) a.href = asset ? asset.browser_download_url : release.html_url;
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
// The library's search sample, loaded when the section comes near.

const searchInput = $('[data-search]');
const resultsEl = $('[data-results]');
let searcher = null;
let searchLoad = null;

function loadSearch() {
  searchLoad ??= fetch('assets/hvsc-sample.json')
    .then((r) => r.json())
    .then((data) => {
      searcher = new TuneSearch(data);
      $('[data-search-foot]').textContent =
        `A ${searcher.tunes.length.toLocaleString('en')}-tune sample of HVSC's MUSICIANS folder, ranked in your browser the way the app ranks it.`;
      runSearch();
    })
    .catch(() => { resultsEl.innerHTML = '<p class="search-hint">The sample couldn\'t be loaded.</p>'; });
  return searchLoad;
}

function runSearch() {
  if (!searcher) return;
  const query = searchInput.value;
  if (!query.trim()) {
    resultsEl.innerHTML = '<p class="search-hint">Type a title, a composer or a year.</p>';
    return;
  }
  const { total, results } = searcher.search(query);
  if (!total) {
    resultsEl.innerHTML = `<p class="search-hint">No tunes match “${escapeHtml(query)}”.</p>`;
    return;
  }
  const rows = results.map(({ tune, field, marks }) => `
    <div class="sr-row">
      <span>${highlight(tune.title, field === 'title' && marks)}</span>
      <span class="sr-author">${highlight(tune.author, field === 'author' && marks)}</span>
      <span class="sr-rel">${highlight(tune.released, field === 'released' && marks)}</span>
      <span class="sr-num">${tune.songs}</span>
      <span class="sr-num sr-len">${formatLength(tune.length)}</span>
    </div>`).join('');
  const more = total > results.length ? ` — showing the best ${results.length}` : '';
  resultsEl.innerHTML = `
    <div class="sr-head"><span>Title</span><span>Author</span><span class="sr-rel">Released</span><span class="sr-num">Songs</span><span class="sr-num sr-len">Length</span></div>
    ${rows}
    <div class="sr-count">${total.toLocaleString('en')} ${total === 1 ? 'tune' : 'tunes'}${more}</div>`;
  resultsEl.scrollTop = 0;
}

let searchFrame = 0;
searchInput.addEventListener('input', () => {
  cancelAnimationFrame(searchFrame);
  searchFrame = requestAnimationFrame(runSearch);
});
searchInput.addEventListener('focus', loadSearch, { once: true });
for (const chip of $$('[data-q]')) {
  chip.addEventListener('click', () => {
    searchInput.value = chip.dataset.q;
    loadSearch().then(runSearch);
  });
}
searchInput.value = 'hubbard';
new IntersectionObserver((entries, observer) => {
  if (entries.some((e) => e.isIntersecting)) {
    loadSearch();
    observer.disconnect();
  }
}, { rootMargin: '600px 0px' }).observe($('#library'));

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

fitStage();
updateUI();
