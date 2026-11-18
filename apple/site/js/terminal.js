// Resonance in the terminal: the recordings, and the sections that explain the
// terminal app. The tunes come from js/terminal-data.js, made from the running
// app by make-data.py (kept outside this repo).

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

const esc = (text) => String(text).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const print = (tune) => tune.f
  ? `<span class="fp">${tune.f.map((h, i) => `<i style="--h:${h};--c:${TRAITS[i][3]}"></i>`).join('')}</span>`
  : '<span class="fp none">·········</span>';

// ----- The recordings -----
// They play on their own, muted and looping (browsers only autoplay muted
// video); with reduced motion they wait for a press of play instead. Sound,
// as on the home page: one button turns it on for both, and only the one
// playing is heard.
const videos = [...document.querySelectorAll('[data-tm-video]')];
for (const video of videos) {
  if (!reduceMotion) continue;
  video.removeAttribute('autoplay');
  video.pause();
  video.controls = true;
}
let soundOn = false;
function setSound(on) {
  soundOn = on;
  for (const video of videos) video.muted = !on;
  for (const b of document.querySelectorAll('[data-sound]')) {
    b.setAttribute('aria-pressed', String(on));
    b.querySelector('use').setAttribute('href', on ? '#i-speaker-loud' : '#i-mute');
    b.querySelector('span').textContent = on ? 'Sound off' : 'Sound on';
  }
  // Muted again, the one paused for the other plays on, as both did at first.
  if (!on && !reduceMotion) for (const video of videos) video.play().catch(() => {});
}
for (const b of document.querySelectorAll('[data-sound]')) {
  b.addEventListener('click', () => {
    setSound(!soundOn);
    if (!soundOn) return;
    // Both were playing muted; now only this one is heard.
    const video = b.closest('.tm-media').querySelector('video');
    for (const other of videos) if (other !== video) other.pause();
    if (video.paused) video.play().catch(() => {});
  });
}
for (const video of videos) {
  video.addEventListener('play', () => {
    if (!soundOn) return;
    for (const other of videos) if (other !== video) other.pause();
  });
}
// ----- Fingerprints, explained on one tune -----
{
  const index = DATA.favorites.find((i) => DATA.tunes[i].t === 'Commando') ?? DATA.favorites[0];
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
  };
  schemes.addEventListener('click', (event) => { const b = event.target.closest('button'); if (b) show(b.dataset.scheme); });
  show('normal');
}
