// Resonance in the terminal: the page's terminal, which works, and the sections
// that explain it. The tunes come from js/terminal-data.js, made from the running
// app by design/site-cli/make-data.py.

document.documentElement.classList.add('js');
window.resonanceReady = true;

const reveal = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (entry.isIntersecting) { entry.target.classList.add('in'); reveal.unobserve(entry.target); }
  }
}, { rootMargin: '0px 0px -8% 0px' });
document.querySelectorAll('[data-reveal]').forEach((el) => reveal.observe(el));
document.querySelectorAll('[data-year]').forEach((el) => { el.textContent = String(new Date().getFullYear()); });

const DATA = window.TERMINAL_DATA;
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

// The nine traits, in the fingerprint's order, with the app's colors for them.
const TRAITS = [
  ['Nt', 'Notes', 'How busy the melody is.', 'var(--t-white)'],
  ['Ar', 'Arpeggios', 'Chords played as fast runs of notes, the sound of the machine.', 'var(--t-cyan)'],
  ['Vb', 'Vibrato', 'Notes that waver, like a singer holding one.', 'var(--t-cyan)'],
  ['Fl', 'Filter', 'The filter opening and closing: sweeps, squelch and warmth.', 'var(--t-violet)'],
  ['Rm', 'Ring modulation', 'Bells and metal, from one voice multiplying another.', 'var(--t-orange)'],
  ['Sy', 'Hard sync', 'Sharp, tearing leads, from one voice restarting another.', 'var(--t-orange)'],
  ['Dg', 'Digi samples', 'Sampled drums, guitars and speech, squeezed through the volume knob.', 'var(--t-red)'],
  ['Nz', 'Noise', 'Drums, hi-hats and explosions.', 'var(--t-orange)'],
  ['Pw', 'Pulse width', 'A slow shimmer, from a square wave changing shape.', 'var(--t-green)'],
];
const MIX = [['Pulse', 'var(--t-cyan)'], ['Noise', 'var(--t-orange)'], ['Tri', 'var(--t-green)'], ['Saw', 'var(--t-violet)']];
const VOICES = ['var(--t-cyan)', 'var(--t-green)', 'var(--t-orange)'];
const BLOCKS = ' ▁▂▃▄▅▆▇█';
const ROWS = 18;

const esc = (text) => String(text).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const clock = (secs) => `${Math.floor(secs / 60)}:${String(Math.floor(secs % 60)).padStart(2, '0')}`;
const print = (tune) => tune.f
  ? `<span class="fp">${tune.f.map((h, i) => `<i style="--h:${h};--c:${TRAITS[i][3]}"></i>`).join('')}</span>`
  : '<span class="fp none">·········</span>';

// ----- The terminal -----
const KEYS = {
  normal: { move: '↑ ↓', like: 'l', scrub: '← →' },
  vim: { move: 'j k', like: 'L', scrub: 'h l' },
  emacs: { move: '⌃N ⌃P', like: 'l', scrub: '⌃B ⌃F' },
};
const state = {
  stack: [{ kind: 'playlist', rows: DATA.favorites.map((i) => [i, null]), at: 0 }],
  playing: { tune: DATA.favorites.find((i) => DATA.tunes[i].t === 'Commando') ?? DATA.favorites[0], from: 0, elapsed: 74, paused: false },
  favorites: new Set(DATA.favorites),
  panel: true,
  scheme: 'normal',
  say: null,
  touched: false,
  scrub: null,   // Seconds: the point being chosen with t.
  seek: null,    // { to, at }: a scrub on its way, the playhead catching up.
  typing: false, // In the search line.
  help: false,   // All keys, over the panes.
};
const term = document.getElementById('term');
const screen = term.querySelector('[data-screen]');
const view = () => state.stack[state.stack.length - 1];
const under = () => view().rows[view().at]?.[0];
const canHop = (index) => (DATA.like[index] || []).length >= ROWS;

function panelHtml(index) {
  const tune = DATA.tunes[index];
  const alike = (DATA.like[index] || []).slice(0, 4);
  const mix = tune.m || [];
  return `
    <div class="t-h">This tune</div>
    <div style="margin-top:1.5em"><b>${esc(tune.t)}</b></div>
    <div class="m cut">${esc(tune.a || 'Unknown')}</div>
    <div class="m cut">${esc(tune.r)}<span style="margin-left:2ch">${clock(tune.s)}</span></div>
    <div style="margin-top:1.5em"><b>Sound</b></div>
    <div style="min-height:3em">${tune.f ? esc(tune.d || '') : 'No fingerprint yet.'}</div>
    <div class="fp-big${tune.f ? '' : ' none'}">${TRAITS.map((t, i) => `<i style="--h:${tune.f ? tune.f[i] : 0};--c:${t[3]}"></i>`).join('')}</div>
    <div class="fp-names">${TRAITS.map((t) => `<span>${t[0]}</span>`).join('')}</div>
    ${mix.length ? `<div class="t-mix">${mix.map((share, i) => `<i style="flex:${share};--c:${MIX[i][1]}"></i>`).join('')}</div>
    <div class="t-mixnames">${mix.map((share, i) => share ? `<span style="color:${MIX[i][1]}">${MIX[i][0]} ${share}</span>` : '').join('')}</div>` : ''}
    ${tune.v ? `<div class="t-voices">${tune.v.map((levels, v) => `<span class="m">V${v + 1} </span><span style="color:${VOICES[v]}">${[...levels].map((l) => BLOCKS[l]).join('')}</span>`).join('\n')}\n<span class="m">   start${' '.repeat(Math.max(1, tune.v[0].length - 8))}end</span></div>` : ''}
    ${alike.length ? `<div style="margin-top:1.5em"><b>Sounds like</b><span class="m">   ${KEYS[state.scheme].like} for more</span></div>
    ${alike.map(([i, score]) => `<div class="t-alike">${print(DATA.tunes[i])}<span class="cut">${esc(DATA.tunes[i].t)}</span><span>${score}%</span></div>`).join('')}` : ''}`;
}

// The keys at the bottom, as the app chooses them for where you are.
function keysHtml() {
  if (state.say) return `<span class="say">${esc(state.say)}</span>`;
  const keys = KEYS[state.scheme];
  const kind = view().kind;
  let list;
  if (state.scrub !== null) list = [[keys.scrub, '5 s', 'ahead'], ['⇧', '30 s', 'far'], ['0–9', 'jump', 'half'], ['↵', 'go there', 'go'], ['esc', 'cancel', 'cancel']];
  else if (state.typing) list = [['type', 'to search', ''], ['↵', 'go to the list', 'done'], ['esc', 'back', 'back']];
  else if (kind === 'playlist') list = [['↵', 'play', 'play'], ['p', 'pause', 'pause'], ['t', 'scrub', 'scrub'], [keys.like, 'find similar', 'like'], ['/', 'search', 'search'], ['i', state.panel ? 'hide panel' : 'show panel', 'panel'], ['?', 'all keys', 'help']];
  else list = [[keys.move, 'move', 'down'], ['↵', 'play', 'play'], [keys.like, 'find similar', 'like'], ['f', 'favorite', 'favorite'], ['esc', 'back', 'back'], ['i', state.panel ? 'hide panel' : 'show panel', 'panel'], ['?', 'all keys', 'help'], ['q', 'quit', 'quit']];
  return list.map(([key, name, act]) => `<button type="button" data-act="${act}"><b>${key}</b>${name}</button>`).join('');
}

// All keys, as the app's ? shows them (help_lines in apple/cli/src/tui.rs).
function helpHtml() {
  const pick = (normal, vim, emacs) => ({ normal, vim, emacs }[state.scheme]);
  const lines = [
    [pick('↑ ↓  j k', 'j k  ↑ ↓', '⌃N ⌃P  j k  ↑ ↓'), 'Move'],
    [pick('PgUp PgDn Home End', '⌃U ⌃D  gg G', '⌥V ⌃V  ⌥< ⌥>'), 'Page up or down, top, end'],
    [pick('Tab  ← →', 'Tab  h l', 'Tab  ⌃B ⌃F'), 'Sidebar or list'],
    ['↵', 'Open, or play from here'],
    [pick('/', '/', '/  ⌃S'), 'Search the collection'],
    ['p  . ,', 'Pause or resume; next or previous tune'],
    [pick('t  ← →  ↵', 't  h l  ↵', 't  ⌃B ⌃F  ↵'), 'Scrub: choose a point and jump to it'],
    ['r  S  T', 'Surprise Me; Home: shuffle, Top 100'],
    ['␣', 'Mark a tune'],
    [pick('l', 'L', 'l'), 'Find similar tunes; Esc goes back'],
    [pick('d', 'D', 'd'), 'Sound Drift from this tune'],
    ['f  a', 'Add to Favorites, or to a playlist'],
    ['n', 'New playlist, with what\'s marked'],
    [pick('x', 'x  dd', 'x  ⌃D'), 'Take out of this playlist'],
    ['⇧↑ ⇧↓  K J', 'Move a tune in the playlist'],
    ['o', 'Find files: add or play them'],
    ['s', 'Show in the Resonance window'],
    ['i', 'Hide or show the panel beside the list'],
    ['v  u', 'Visuals, or Under the hood: the tracker'],
    ['?  c', 'This help, or the credits'],
    ['q', 'Quit; the music plays on'],
  ];
  const set = pick('Normal', 'Vim', 'Emacs');
  const read = ['Notes', 'Arpeggios', 'Vibrato', 'Filter', 'Ring modulation', 'Hard sync', 'Digi samples', 'Noise, mostly drums', 'Pulse-width sweeps'];
  return `<div class="t-help">
    <div class="t-help-top"><span>${LOGO}</span><span>${set} keys, chosen with --keys</span></div>
    <div class="t-help-keys">${lines.map(([keys, what]) => `<span>${keys}</span><span class="cut">${what}</span>`).join('')}<span>Set RESONANCE_KEYS, or use --keys, to change these.</span></div>
    <div class="t-help-read"><div><b>Reading a fingerprint</b></div>
      ${TRAITS.map((t, i) => `<div><i style="--c:${t[3]}"></i><span class="m">${t[0]}</span> ${read[i]}</div>`).join('')}
      <p>Taller means more of it. Tunes that sound alike look alike.</p>
      <p>The panel also shows the waveforms used, and each voice's loudness from the start of the tune to the end</p></div>
  </div>`;
}
const LOGO = '<i style="color:var(--t-cyan);font-style:normal">•</i><i style="color:var(--t-violet);font-style:normal">●</i><i style="color:var(--t-orange);font-style:normal">•</i> RESONANCE';

function draw() {
  const v = view();
  const now = DATA.tunes[state.playing.tune];
  const of = v.kind === 'like' ? DATA.tunes[v.of] : null;
  const heading = of ? `Sounds like ${esc(of.t)}`
    : v.kind === 'search' ? `Search: ${esc(v.text)}${state.typing ? '▏' : ''}` : esc(DATA.playlist);
  const none = v.kind === 'search' ? `<div class="t-more">${v.text ? 'Nothing by that name on this page. The real one searches all 63,165.' : 'A title or a composer.'}</div>` : '';
  const rows = v.rows.map(([index, score], n) => {
    const tune = DATA.tunes[index];
    const at = n === v.at;
    return `<div class="t-row${at ? ' at' : ''}${index === state.playing.tune ? ' playing' : ''}" data-row="${n}">
      <span class="ac">${at ? '❯' : ''}</span><span class="ring">${index === state.playing.tune ? '●' : '○'}</span>
      <span class="title"><span class="cut">${esc(tune.t)}</span>${at ? `<span class="t-chip"><b>${KEYS[state.scheme].like}</b> find similar</span>` : ''}</span>
      <span class="cut">${esc(tune.a)}</span>${print(tune)}<span>${score === null ? clock(tune.s) : score + '%'}</span></div>`;
  }).join('');
  screen.innerHTML = `
    <div class="t-now"><span class="grow"><span class="cut"><span class="m">♪ </span><b>${esc(now.t)}</b>${now.a ? ` · ${esc(now.a)}` : ''}</span><span class="m">${esc(now.r)}</span><span class="m state" data-state></span>${state.favorites.has(state.playing.tune) ? '<span style="color:var(--t-red)">♡</span>' : ''}</span>
      <span class="t-logo">${LOGO}</span></div>
    <div class="t-time"><span class="t-track" data-track></span><span class="pct" data-pct></span><span data-clock></span></div>
    <div class="t-panes" style="${state.panel ? '' : 'grid-template-columns:29ch minmax(0,1fr)'}">
      <div class="t-pane lib">
        <div class="t-h">Library</div>
        <ul class="t-list"><li>Search</li><li>Describe</li><li>Recently Played</li></ul>
        <div class="t-h">Playlists</div>
        <ul class="t-list"><li class="on"><b>${esc(DATA.playlist)}</b><span>${DATA.favorites.length}</span></li><li>My Playlist<span>12</span></li><li>From the 2020s<span>25</span></li><li>HVSC Top 100<span>100</span></li><li>Late Night<span>31</span></li></ul>
        <div class="t-h">HVSC <span class="m"> 63,165 tunes</span></div>
        <ul class="t-list wide"><li>Home<span>v85</span></li><li>Musicians<span>58,220</span></li><li>Demos<span>3,318</span></li><li>Games<span>1,627</span></li></ul>
      </div>
      <div class="t-pane" ${state.panel ? '' : 'style="border-right:1px solid"'}>
        <div class="t-h focus">${heading}</div>
        <div class="t-cols"><span></span><span></span><span>TITLE</span><span>COMPOSER</span>${of ? print(of) : '<span>SOUND</span>'}<span>${of ? 'MATCH' : 'LENGTH'}</span></div>
        ${rows || none}
      </div>
      ${state.help ? helpHtml() : ''}
      ${state.panel ? `<div class="t-pane side">${under() === undefined ? '<div class="t-h">This tune</div>' : panelHtml(under())}</div>` : ''}
    </div>
    <div class="t-keys">${keysHtml()}</div>`;
  tick(0);
}

// Only the time moves between key presses.
function tick(step) {
  const playing = state.playing;
  const length = DATA.tunes[playing.tune].s || 1;
  if (!playing.paused && !state.seek) playing.elapsed += step;
  if (playing.elapsed >= length) {
    const list = state.stack[playing.from] ? state.stack[playing.from].rows : state.stack[0].rows;
    const next = (list.findIndex(([i]) => i === playing.tune) + 1) % list.length;
    state.playing = { ...playing, tune: list[next][0], elapsed: 0 };
    return draw();
  }
  if (state.seek) {
    // The emulation runs flat out to the point chosen, as the real one does.
    state.seek.at += step * 60;
    if (state.seek.at >= state.seek.to) { playing.elapsed = state.seek.to; state.seek = null; }
  }
  const played = state.seek ? state.seek.at : playing.elapsed;
  const shown = state.scrub !== null ? state.scrub : played;
  bar();
  screen.querySelector('[data-pct]').textContent = `${Math.round(shown / length * 100)}%`;
  screen.querySelector('[data-clock]').textContent = `${clock(shown)} / ${clock(length)}`;
  screen.querySelector('[data-state]').textContent = playing.paused ? 'paused' : '';
}

// The bar, as progress() in apple/cli/src/viz.rs draws it: ▰ in the accent for
// what's played, with a glint two cells wide running along it every 40; ▰ in
// gray up to a point chosen to scrub to; ▱ for what's left; a white ● for the
// playhead, or the point being chosen.
let heard = 0;
function bar() {
  const track = screen.querySelector('[data-track]');
  if (!track) return;
  const cell = parseFloat(getComputedStyle(track).fontSize) * 0.602;
  const width = Math.max(1, Math.floor(track.clientWidth / cell));
  const total = DATA.tunes[state.playing.tune].s || 1;
  const cells = (seconds) => Math.round(width * Math.min(1, Math.max(0, seconds / total)));
  const choosing = state.scrub !== null ? state.scrub : state.seek ? state.seek.to : null;
  const played = cells(state.seek ? state.seek.at : state.playing.elapsed);
  const chosen = choosing === null ? played : cells(choosing);
  const accent = Math.min(played, chosen), gray = Math.max(played, chosen);
  const mark = choosing === null ? played : chosen;
  const head = choosing !== null || played > 0 ? Math.min(Math.max(mark - 1, 0), width - 1) : -1;
  const glint = heard % 40;
  let html = '';
  for (let column = 0; column < width; column++) {
    if (column === head) html += '<i class="h">●</i>';
    else if (column >= gray) html += '<i>▱</i>';
    else if (column >= accent) html += '<i>▰</i>';
    else if ((((column - glint) % 40) + 40) % 40 < 2) html += '<i class="g">▰</i>';
    else html += '<i class="p">▰</i>';
  }
  track.innerHTML = html;
}
// The glint moves with the music: a cell for each reading of the voices, 20 a second.
if (!reduceMotion) setInterval(() => { if (!state.playing.paused && !document.hidden) { heard += 1; bar(); } }, 50);
addEventListener('resize', bar);

let saying;
function say(text) {
  state.say = text;
  clearTimeout(saying);
  saying = setTimeout(() => { state.say = null; draw(); }, 4200);
}

// The tunes this page knows in full: the playlist's, and the ones that sound like them.
const KNOWN = DATA.tunes.map((tune, i) => (tune.d !== undefined ? i : -1)).filter((i) => i >= 0);
const length = () => DATA.tunes[state.playing.tune].s || 1;
function play(tune, from) {
  state.playing = { tune, from, elapsed: 0, paused: false };
  state.seek = null;
  state.scrub = null;
}
function search(text) {
  const v = view();
  const words = text.toLowerCase().split(/\s+/).filter(Boolean);
  v.text = text;
  v.at = 0;
  v.rows = !words.length ? [] : KNOWN.filter((i) => {
    const hay = `${DATA.tunes[i].t} ${DATA.tunes[i].a}`.toLowerCase();
    return words.every((word) => hay.includes(word));
  }).slice(0, ROWS).map((i) => [i, null]);
}

function act(name) {
  const v = view();
  if (state.help) { state.help = false; draw(); return true; }
  if (!v.rows.length && ['down', 'up', 'top', 'end'].includes(name)) return true;
  if (state.say) { state.say = null; clearTimeout(saying); }
  switch (name) {
    case 'down': v.at = (v.at + 1) % v.rows.length; break;
    case 'up': v.at = (v.at + v.rows.length - 1) % v.rows.length; break;
    case 'top': v.at = 0; break;
    case 'end': v.at = v.rows.length - 1; break;
    case 'play': if (under() !== undefined) play(under(), state.stack.length - 1); break;
    case 'next': case 'previous': {
      const list = (state.stack[state.playing.from] || state.stack[0]).rows;
      const n = list.findIndex(([i]) => i === state.playing.tune) + (name === 'next' ? 1 : list.length - 1);
      play(list[n % list.length][0], state.playing.from);
      break;
    }
    case 'surprise': play(KNOWN[Math.floor(Math.random() * KNOWN.length)], 0); break;
    // Scrubbing: t, then a point, then ↵.
    case 'scrub': state.scrub = state.playing.elapsed; break;
    case 'ahead': state.scrub = Math.min(length(), state.scrub + 5); break;
    case 'behind': state.scrub = Math.max(0, state.scrub - 5); break;
    case 'far': state.scrub = Math.min(length(), state.scrub + 30); break;
    case 'near': state.scrub = Math.max(0, state.scrub - 30); break;
    case 'half': state.scrub = length() / 2; break;
    case 'start': state.scrub = 0; break;
    case 'finish': state.scrub = length(); break;
    case 'go': state.seek = { to: state.scrub, at: state.scrub > state.playing.elapsed ? state.playing.elapsed : 0 }; state.scrub = null; break;
    case 'cancel': state.scrub = null; break;
    case 'search': state.stack.push({ kind: 'search', text: '', rows: [], at: 0 }); state.typing = true; break;
    case 'done': state.typing = false; break;
    case 'pause': state.playing.paused = !state.playing.paused; break;
    case 'like':
      if (under() === undefined) break;
      if (canHop(under())) state.stack.push({ kind: 'like', of: under(), rows: DATA.like[under()].slice(0, ROWS), at: 0 });
      else say('That\'s as far as this page goes. The real one keeps hopping, through all 63,165.');
      break;
    case 'back': if (state.stack.length > 1) state.stack.pop(); state.typing = false; break;
    case 'favorite': { const tune = under() ?? state.playing.tune; state.favorites.has(tune) ? state.favorites.delete(tune) : state.favorites.add(tune); break; }
    case 'panel': state.panel = !state.panel; break;
    case 'visuals': document.getElementById('visuals').scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth' }); break;
    case 'help': state.help = true; break;
    case 'quit': say('In the real one, q quits and the music plays on. Here there\'s nothing to quit.'); break;
    default: return false;
  }
  draw();
  return true;
}

// Keys, by set, as apple/cli/src/keys.rs has them. Vim's gg and dd, marking and
// the playlist keys are left to the real thing.
function actFor(event) {
  const key = event.key;
  const emacs = state.scheme === 'emacs' && event.ctrlKey;
  if (event.metaKey || event.altKey || (event.ctrlKey && !emacs)) return null;
  if (state.typing) return { Enter: 'done', Escape: 'back', ArrowDown: 'done' }[key] || null;
  if (state.scrub !== null) {
    if (/^[0-9]$/.test(key)) return 'tenth';
    if (emacs) return { b: 'behind', f: 'ahead' }[key];
    const back = event.shiftKey ? 'near' : 'behind', on = event.shiftKey ? 'far' : 'ahead';
    const own = state.scheme === 'vim' ? { h: back, l: on, H: 'near', L: 'far' } : {};
    return own[key] || { ArrowLeft: back, ArrowRight: on, Home: 'start', End: 'finish', Enter: 'go', Escape: 'cancel', t: 'cancel', q: 'cancel', p: 'pause' }[key];
  }
  if (emacs) return { n: 'down', p: 'up', s: 'search' }[key];
  const shared = { ArrowDown: 'down', ArrowUp: 'up', j: 'down', k: 'up', Home: 'top', End: 'end', Enter: 'play', p: 'pause', '.': 'next', ',': 'previous', r: 'surprise', t: 'scrub', '/': 'search', Escape: 'back', f: 'favorite', v: 'visuals', i: 'panel', '?': 'help', q: 'quit' };
  const own = { normal: { l: 'like', L: 'like' }, vim: { L: 'like', G: 'end' }, emacs: { l: 'like', L: 'like' } }[state.scheme];
  return own[key] || shared[key];
}
term.addEventListener('keydown', (event) => {
  state.touched = true;
  if (state.typing && !event.metaKey && !event.ctrlKey && !event.altKey && (event.key.length === 1 || event.key === 'Backspace')) {
    event.preventDefault();
    search(event.key === 'Backspace' ? view().text.slice(0, -1) : view().text + event.key);
    return draw();
  }
  if (state.help && !event.metaKey && !['Shift', 'Control', 'Alt', 'Meta', 'Tab'].includes(event.key)) { event.preventDefault(); return act('close'); }
  const name = actFor(event);
  if (!name || (name === 'back' && state.stack.length === 1)) return;
  event.preventDefault();
  // A digit goes to that tenth of the tune.
  if (name === 'tenth') { state.scrub = length() * Number(event.key) / 10; return draw(); }
  act(name);
});
term.addEventListener('pointerdown', () => { state.touched = true; });
screen.addEventListener('click', (event) => {
  const button = event.target.closest('[data-act]');
  const row = event.target.closest('[data-row]');
  if (state.help) act('close');
  else if (button) act(button.dataset.act);
  else if (event.target.closest('.t-chip')) act('like');
  else if (row) { view().at = Number(row.dataset.row); draw(); }
  term.focus({ preventScroll: true });
});
screen.addEventListener('dblclick', (event) => { if (event.target.closest('[data-row]')) act('play'); });

draw();
setInterval(() => tick(0.25), 250);
// Until someone takes over, the cursor wanders down the list.
if (!reduceMotion) setInterval(() => { if (!state.touched && !document.hidden && document.activeElement !== term) act('down'); }, 2600);

// The accent, as System Settings would give it.
const accents = document.querySelector('[data-accents]');
accents.addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button) return;
  accents.querySelectorAll('button').forEach((b) => b.setAttribute('aria-pressed', String(b === button)));
  document.documentElement.style.setProperty('--t-accent', button.style.getPropertyValue('--c'));
});

// ----- Fingerprints, explained on one tune -----
{
  const index = state.playing.tune;
  const tune = DATA.tunes[index];
  const bars = document.querySelector('[data-print]');
  const names = document.querySelector('[data-print-names]');
  const sayEl = document.querySelector('[data-print-say]');
  document.querySelector('[data-print-of]').textContent = `${tune.t} · ${tune.a} · ${tune.r}`;
  bars.innerHTML = TRAITS.map((t, i) => `<button type="button" aria-pressed="false" aria-label="${t[1]}" style="--h:${tune.f[i]};--c:${t[3]}"><i></i></button>`).join('');
  names.innerHTML = TRAITS.map((t) => `<span>${t[0]}</span>`).join('');
  const choose = (i) => {
    bars.querySelectorAll('button').forEach((b, n) => b.setAttribute('aria-pressed', String(n === i)));
    names.querySelectorAll('span').forEach((s, n) => s.classList.toggle('on', n === i));
    sayEl.innerHTML = `<strong>${TRAITS[i][1]}</strong>${TRAITS[i][2]}`;
  };
  bars.querySelectorAll('button').forEach((b, i) => {
    b.addEventListener('pointerenter', () => choose(i));
    b.addEventListener('focus', () => choose(i));
    b.addEventListener('click', () => choose(i));
  });
  choose(tune.f.indexOf(Math.max(...tune.f.slice(1))));
  document.querySelector('[data-print-alike]').innerHTML = DATA.like[index].slice(0, 4).map(([i, score]) =>
    `<li>${print(DATA.tunes[i])}<span><em>${esc(DATA.tunes[i].t)}</em> · ${esc(DATA.tunes[i].a)}</span><span>${score}%</span></li>`).join('');
}

// ----- Keys, by set -----
{
  const TABLE = [
    ['Move', '↑ ↓|j k', 'j k', '⌃N ⌃P'],
    ['Page up, down', 'PgUp PgDn', '⌃U ⌃D|⌃B ⌃F', '⌥V ⌃V'],
    ['Top, end', 'Home End', 'gg G', '⌥< ⌥>'],
    ['Sidebar, list', '← →', 'h l', '⌃B ⌃F'],
    ['Search', '/', '/', '/|⌃S'],
    ['Take out of a playlist', 'x', 'x|dd', 'x|⌃D'],
    ['Sounds Like', 'l', 'L', 'l'],
    ['Sound Drift', 'd', 'D', 'd'],
  ];
  const list = document.querySelector('[data-keys]');
  const schemes = document.querySelector('[data-schemes]');
  const show = (scheme) => {
    const column = { normal: 1, vim: 2, emacs: 3 }[scheme];
    list.innerHTML = TABLE.map((row) => `<li>${row[0]}<span>${row[column].split(/[| ]/).map((k) => `<kbd>${k}</kbd>`).join('')}</span></li>`).join('');
    schemes.querySelectorAll('button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.scheme === scheme)));
    state.scheme = scheme;
    draw();
  };
  schemes.addEventListener('click', (event) => { const b = event.target.closest('button'); if (b) show(b.dataset.scheme); });
  show('normal');
}
