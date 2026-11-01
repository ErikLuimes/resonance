// Wires up the page: the interactive Resonance window and its demo
// player, the voice scopes, the HVSC search sample, keyboard shortcuts,
// the latest GitHub release, and scroll effects.

import { DemoPlayer } from './player.js';
import { VoiceMeter, drawVisualizer, drawScope, VOICE_COLORS } from './visualizer.js';
import { noteName, waveName } from './tune.js';
import { TuneSearch, highlight, formatLength } from './search.js';
import { TUNES, PLAYLIST_SIZE, COMPOSER_NOTES } from './hvsc-tunes.js';

const REPO = 'ErikLuimes/resonance';

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const escapeHtml = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const icon = (id, cls = 'i') => `<svg class="${cls}"><use href="#${id}"/></svg>`;
const setIcon = (svg, id) => svg.querySelector('use').setAttribute('href', `#${id}`);

const player = new DemoPlayer(TUNES);
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

// Real tunes from HVSC (see hvsc-tunes.js); kept surprises join them.
const playlist = TUNES.slice(0, PLAYLIST_SIZE);
player.playlist = playlist;

const tbody = $('[data-playlist]');
let selectedRow = null;

// Rows are only rebuilt when one is added: replacing them between the two
// clicks of a double-click would lose it.
function renderPlaylist(newIndex = -1) {
  tbody.innerHTML = playlist
    .map((tune, i) => `<tr data-row="${i}" class="${i === newIndex ? 'is-new' : ''}">
        <td class="num-cell muted-cell"></td>
        <td class="t-title">${escapeHtml(tune.title)}</td>
        <td>${escapeHtml(tune.author)}</td>
        <td>${escapeHtml(tune.released)}</td>
        <td class="tabular">${formatLength(tune.lengths[tune.start - 1])}</td>
        <td class="tabular">${tune.songs > 1 ? `${tune.start}/${tune.songs}` : '1'}</td>
        <td>${tune.chips}</td>
        <td>${tune.format}</td>
      </tr>`)
    .join('');
  $('[data-playlist-count]').textContent = playlist.length;
  updateRows();
}

function updateRows() {
  const current = player.tune && player.source === 'playlist' ? player.row : -1;
  for (const tr of tbody.rows) {
    const i = Number(tr.dataset.row);
    tr.classList.toggle('is-selected', i === selectedRow);
    tr.classList.toggle('is-current', i === current);
    tr.cells[0].innerHTML = i === current ? icon(player.isPlaying ? 'i-speaker-wave' : 'i-speaker') : i + 1;
  }
}

tbody.addEventListener('click', (e) => {
  const tr = e.target.closest('tr');
  if (!tr) return;
  selectedRow = Number(tr.dataset.row);
  updateRows();
});

tbody.addEventListener('dblclick', (e) => {
  const tr = e.target.closest('tr');
  if (tr) player.playRow(Number(tr.dataset.row));
});

// Loading and error capsules float over the top of the playlist, as in the app.
function banner(text, secs = 3.6) {
  const slot = $('.banner-slot');
  slot.replaceChildren();
  const el = document.createElement('div');
  el.className = 'banner glass';
  el.textContent = text;
  slot.append(el);
  setTimeout(() => el.classList.add('out'), secs * 1000);
  setTimeout(() => el.remove(), secs * 1000 + 400);
}

const repeatModes = [
  { name: 'Off', icon: 'i-repeat' },
  { name: 'All', icon: 'i-repeat' },
  { name: 'One', icon: 'i-repeat-1' },
];
let repeat = 0;

const fileName = (path) => path.slice(path.lastIndexOf('/') + 1);

const actions = {
  surprise: () => {
    const dice = $('[data-dice]');
    dice.classList.remove('wiggle');
    void dice.getBoundingClientRect();
    dice.classList.add('wiggle');
    player.surprise();
  },
  add: () => banner('In Resonance, this adds SID files, folders or M3U playlists. You can drop them on the window, too.'),
  inspector: (button) => {
    const content = $('.mac-content');
    const hidden = content.classList.toggle('no-inspector');
    button.title = hidden ? 'Show the inspector' : 'Hide the inspector';
  },
  shuffle: (button) => {
    player.shuffle = !player.shuffle;
    button.setAttribute('aria-pressed', player.shuffle);
    button.title = `Shuffle: ${player.shuffle ? 'On' : 'Off'}`;
  },
  repeat: (button) => {
    repeat = (repeat + 1) % repeatModes.length;
    const mode = repeatModes[repeat];
    player.repeat = mode.name.toLowerCase();
    setIcon($('[data-repeat-icon]'), mode.icon);
    button.setAttribute('aria-pressed', repeat !== 0);
    button.title = `Repeat: ${mode.name}`;
    button.setAttribute('aria-label', button.title);
  },
  play: () => (!player.tune && selectedRow !== null ? player.playRow(selectedRow) : player.toggle()),
  next: () => player.next(),
  prev: () => player.previous(),
  'next-sub': () => player.stepSubtune(1),
  'prev-sub': () => player.stepSubtune(-1),
  keep: () => {
    const entry = player.entry;
    if (!entry || playlist.some((t) => t.path === entry.path)) return;
    playlist.push(entry);
    renderPlaylist(playlist.length - 1);
    $('.mac-table-wrap').scrollTop = 1e6;
    updateUI();
  },
  'all-tunes': () => banner(`In Resonance, Show All Tunes opens ${player.tune.composer}'s folder in the HVSC browser.`),
  more: (button) => {
    const folded = $('[data-cc-note]').classList.toggle('is-folded');
    button.textContent = folded ? 'More' : 'Less';
  },
  reveal: (button) => banner(`In Resonance, this shows ${button.textContent} in the HVSC browser.`),
  finder: () => banner(`In Resonance, this shows ${fileName(player.tune.path)} in Finder.`),
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

// The header's released field in words, as the app's inspector puts it:
// "1985 Gremlin Graphics" → "Released 1985 by Gremlin Graphics". A year
// with fewer than three digits ("19??") and "<?>" say nothing.
function releasedLine(field) {
  const [first = '', ...rest] = field.trim().split(' ');
  const isYear = first !== '' && /^[\d?/-]+$/.test(first);
  const year = isYear && (first.match(/\d/g) || []).length >= 3 ? first : null;
  const by = [isYear ? rest.join(' ') : field.trim()].find((s) => s !== '' && s !== '<?>');
  if (year && by) return `Released ${year} by ${by}`;
  if (year) return `Released ${year}`;
  return by ? `Released by ${by}` : '';
}
const textOf = (sel, text) => { for (const el of $$(sel)) if (el.textContent !== text) el.textContent = text; };

// STIL text, with the tunes it names ("/MUSICIANS/V/Vaca_Ramiro/Turrican.sid")
// shortened to their file names; composers' tunes link to the browser.
function stilText(text) {
  return escapeHtml(text).replace(/\/(?:MUSICIANS|GAMES|DEMOS)\/[^\s"(),;]+?\.sid/g, (path) =>
    path.startsWith('/MUSICIANS/')
      ? `<button type="button" class="accent-link" data-act="reveal" title="Show ${fileName(path)} in the library">${fileName(path)}</button>`
      : fileName(path));
}

// A STIL block as the app's inspector words it: "Cover of … by …",
// "Original by …", "Also known as …", then its comment. A block can cover
// several pieces, a line each; one performer for them all is named once.
function stilBlock(block, songs) {
  const parts = [];
  if (block.subtune > 0 && songs > 1) parts.push(`<small class="dim">Song ${block.subtune}</small>`);
  if (block.title) {
    const titles = block.title.split('\n');
    const bys = (block.artist ?? block.author ?? '').split('\n');
    const pairs = bys.length === titles.length && new Set(bys).size > 1;
    const cover = (title, by) => `<p><span class="dim">Cover of</span> ${stilText(title)}</p>${by ? `<p class="dim">by ${escapeHtml(by)}</p>` : ''}`;
    if (pairs) {
      titles.forEach((title, i) => parts.push(cover(title, bys[i])));
    } else {
      const by = new Set(bys).size === 1 ? bys[0] : bys.join('\n');
      parts.push(cover(titles.join('\n'), by));
    }
    if (block.artist && block.author) parts.push(`<p class="dim">written by ${escapeHtml(block.author)}</p>`);
  } else if (block.author) {
    parts.push(`<p><span class="dim">Original by</span> ${escapeHtml(block.author)}</p>`);
  }
  if (block.name) parts.push(`<p class="dim">Also known as ${escapeHtml(block.name)}</p>`);
  if (block.comment) parts.push(`<p class="${block.title || block.name ? 'stil-gap' : ''}">${stilText(block.comment)}</p>`);
  return `<div class="stil-block">${parts.join('')}</div>`;
}

const SID_MODELS = { 1: ['6581', 'MOS 6581'], 2: ['8580', 'MOS 8580'], 3: ['Either', 'Plays on the 6581 or the 8580'] };
// Notes longer than this start folded to four lines, like the app's card.
const FOLD_LENGTH = 240;

// The composer card, STIL's notes and the specs change with the tune or
// subtune, not every update: rebuilding them would fold the card again.
let shownTune = null;

function showTune(tune) {
  const key = `${tune.path}#${tune.subtune}`;
  if (key === shownTune) return;
  const sameFile = shownTune?.startsWith(`${tune.path}#`);
  shownTune = key;

  if (!sameFile) {
    const initials = tune.composer.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
    textOf('[data-cc-initials]', (initials.length > 1 ? [initials[0], initials.at(-1)] : initials).map((w) => w[0]).join('').toUpperCase());
    textOf('[data-cc-name]', tune.composer);
    textOf('[data-cc-sub]', tune.composerSub ?? '');
    $('[data-cc-sub]').hidden = !tune.composerSub;
    $('[data-act="all-tunes"]').title = `Show all tunes by ${tune.composer}`;
    const note = COMPOSER_NOTES[tune.path.slice(0, tune.path.lastIndexOf('/') + 1)] ?? '';
    const noteEl = $('[data-cc-note]');
    noteEl.innerHTML = stilText(note);
    noteEl.hidden = !note;
    noteEl.classList.toggle('is-folded', note.length > FOLD_LENGTH);
    const more = $('[data-act="more"]');
    more.hidden = note.length <= FOLD_LENGTH;
    more.textContent = 'More';

    const [sid, sidHelp] = SID_MODELS[tune.sid] ?? ['—', 'Not specified in the file'];
    textOf('[data-spec-format]', tune.format);
    textOf('[data-spec-sid]', sid);
    $('[data-spec-sid]').parentElement.title = sidHelp;
    textOf('[data-spec-clock]', tune.pal ? 'PAL' : 'NTSC');
    textOf('[data-spec-chips]', String(tune.chips));
    $('[data-act="finder"]').title = `Show ${fileName(tune.path)} in Finder`;
  }

  // What STIL says about this subtune: the file's comment, then the
  // whole tune's blocks before the subtune's own.
  const blocks = (tune.stil?.blocks ?? [])
    .filter((b) => b.subtune === 0 || b.subtune === tune.subtune)
    .sort((a, b) => a.subtune - b.subtune);
  const comment = tune.stil?.comment;
  $('[data-about]').hidden = !comment && !blocks.length;
  $('[data-about-body]').innerHTML =
    (comment ? `<p>${stilText(comment)}</p>` : '') + blocks.map((b) => stilBlock(b, tune.songs)).join('');
}

let toldStandIn = false;

function updateUI() {
  const tune = player.tune;
  const playing = player.isPlaying;
  document.documentElement.classList.toggle('playing', playing);

  setIcon($('[data-play-icon]'), playing ? 'i-pause' : 'i-play');
  $('[data-act="play"]').setAttribute('aria-label', playing ? 'Pause' : 'Play');
  setIcon($('[data-demo-icon]'), playing ? 'i-pause' : 'i-play');
  textOf('[data-demo-label]', playing ? 'Pause the demo' : tune ? 'Resume the demo' : 'Hear the demo');
  $('[data-demo-start]').classList.toggle('is-hidden', !!tune);

  const fromPlaylist = player.source === 'playlist';
  $('[data-np-badge]').hidden = !tune || fromPlaylist;
  textOf('[data-np-title]', tune ? tune.title : 'Not Playing');
  textOf('[data-np-author]', tune ? tune.author : '');
  textOf('[data-np-duration]', tune ? formatTime(tune.lengthSecs) : '--:--');
  if (!tune) {
    $('[data-np-progress]').style.width = '0';
    textOf('[data-np-elapsed]', formatTime(0));
  }

  const hasSubtunes = !!tune && tune.songs > 1;
  $('[data-subtunes]').hidden = !hasSubtunes;
  $('[data-scrub-subtunes]').hidden = !hasSubtunes;
  if (hasSubtunes) {
    textOf('[data-np-song]', `Song ${tune.subtune}/${tune.songs}`);
    $('[data-act="prev-sub"]').disabled = tune.subtune <= 1;
    $('[data-act="next-sub"]').disabled = tune.subtune >= tune.songs;
  }

  $('[data-insp-empty]').hidden = !!tune;
  $('[data-insp-details]').hidden = !tune;
  if (tune) {
    const source = $('[data-np-source]');
    source.classList.toggle('is-surprise', !fromPlaylist);
    source.innerHTML = fromPlaylist
      ? `${icon('i-list')}From Playlist`
      : `${icon('i-dice-fill')}Surprise Me`;
    textOf('[data-np-title2]', tune.title);
    textOf('[data-np-released]', releasedLine(tune.released));
    textOf('[data-np-length]', formatTime(tune.lengthSecs));
    $('[data-np-song2]').parentElement.hidden = !hasSubtunes;
    textOf('[data-np-song2]', `Song ${tune.subtune} of ${tune.songs}`);
    // Add to Playlist until it's kept, then a label saying so; neither
    // while it plays from the playlist anyway.
    const kept = playlist.some((t) => t.path === tune.path);
    $('[data-act="keep"]').hidden = kept;
    $('[data-np-kept]').hidden = !kept || fromPlaylist;
    showTune(tune);

    if (!toldStandIn) {
      toldStandIn = true;
      banner("This page can't play SID files, so you're hearing a stand-in. The details are the real tune's.", 6);
    }
  }

  updateRows();
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
renderPlaylist();
updateUI();
