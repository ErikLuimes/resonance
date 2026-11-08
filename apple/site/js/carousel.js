// A carousel of screenshots, on Embla (js/vendor). Drag it, swipe it, or swipe
// with two fingers on a trackpad. It moves on by itself while it's on screen
// and the page is in front, and hovering doesn't change that. The pill under
// the current screenshot fills up until the next, and the button beside the
// pills says whether it's running. Choosing a screenshot stops it, so it stays
// put to be read. With reduced motion it starts stopped.
import EmblaCarousel from './vendor/embla-carousel.esm.js';
import { WheelGesturesPlugin } from './vendor/embla-carousel-wheel-gestures.esm.js';

const DWELL_MS = 5000;
const PAUSE_ICON = '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 2h2v8H3zM7 2h2v8H7z"/></svg>';
const PLAY_ICON = '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3.5 2l6 4-6 4z"/></svg>';

export function setUpCarousel(figure, stillMotion) {
  const slides = [...figure.querySelectorAll(':scope > img')];
  const viewport = document.createElement('div');
  viewport.className = 'carousel-viewport';
  const track = document.createElement('div');
  track.className = 'carousel-track';
  viewport.append(track);
  for (const img of slides) {
    // All of them load early, so a swipe never shows a half-loaded picture.
    img.loading = 'eager';
    img.draggable = false;
    const slide = document.createElement('div');
    slide.className = 'carousel-slide';
    slide.append(img);
    track.append(slide);
  }
  figure.append(viewport);

  const embla = EmblaCarousel(viewport, { loop: true }, [WheelGesturesPlugin({ forceWheelAxis: 'x' })]);

  const controls = document.createElement('div');
  controls.className = 'carousel-controls';
  const toggle = document.createElement('button');
  toggle.type = 'button';
  toggle.className = 'carousel-toggle';
  const pills = slides.map((img, i) => {
    const pill = document.createElement('button');
    pill.type = 'button';
    pill.className = 'carousel-pill';
    pill.setAttribute('aria-label', `Screenshot ${i + 1} of ${slides.length}`);
    pill.addEventListener('click', () => embla.scrollTo(i, stillMotion.matches));
    return pill;
  });
  controls.append(toggle, ...pills);
  // Below the picture: screenshots have controls of their own to be mistaken for.
  figure.after(controls);

  let running = false;
  let elapsed = 0;
  let advancing = false;
  let held = false;
  let visible = false;
  let frame = 0;
  let last = 0;

  const paint = () => {
    const current = embla.selectedScrollSnap();
    pills.forEach((pill, i) => {
      const on = i === current;
      pill.setAttribute('aria-current', on);
      pill.style.setProperty('--progress', on ? (running ? elapsed / DWELL_MS : 1) : 0);
    });
  };
  const setRunning = (on) => {
    running = on;
    elapsed = 0;
    figure.classList.toggle('is-stopped', !on);
    toggle.innerHTML = on ? PAUSE_ICON : PLAY_ICON;
    toggle.setAttribute('aria-label', on ? 'Stop moving through the screenshots' : 'Keep moving through the screenshots');
    toggle.title = on ? 'Stop' : 'Play';
    paint();
  };
  const tick = (now) => {
    frame = 0;
    if (!visible || document.hidden || !running || figure.closest('[hidden]')) return;
    frame = requestAnimationFrame(tick);
    // A long gap means the page was away: don't count it.
    const step = Math.min(now - last, 100);
    last = now;
    if (held) return;
    elapsed += step;
    if (elapsed >= DWELL_MS) {
      elapsed = 0;
      advancing = true;
      embla.scrollNext();
      advancing = false;
    }
    paint();
  };
  const wake = () => {
    if (frame || !visible || document.hidden || !running || figure.closest('[hidden]')) return;
    last = performance.now();
    frame = requestAnimationFrame(tick);
  };

  embla.on('select', () => {
    const current = embla.selectedScrollSnap();
    slides.forEach((img, i) => img.setAttribute('aria-hidden', i !== current));
    if (!advancing && running) setRunning(false);
    paint();
  });
  embla.on('pointerDown', () => { held = true; });
  embla.on('pointerUp', () => { held = false; });

  toggle.addEventListener('click', () => {
    setRunning(!running);
    if (running) {
      advancing = true;
      embla.scrollNext(stillMotion.matches);
      advancing = false;
      wake();
    }
  });
  controls.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowLeft') embla.scrollPrev(stillMotion.matches);
    else if (event.key === 'ArrowRight') embla.scrollNext(stillMotion.matches);
    else return;
    event.preventDefault();
  });

  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    wake();
  }, { threshold: 0.35 }).observe(figure);
  document.addEventListener('visibilitychange', wake);

  slides.forEach((img, i) => img.setAttribute('aria-hidden', i !== 0));
  setRunning(!stillMotion.matches);
  return { wake, reInit: () => embla.reInit() };
}
