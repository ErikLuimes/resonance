// Resonance Remote's page: sections fade in as they scroll into view, and
// the recordings play only while they're on screen.

document.documentElement.classList.add('js');
window.resonanceReady = true;

const reveal = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (entry.isIntersecting) {
      entry.target.classList.add('in');
      reveal.unobserve(entry.target);
    }
  }
}, { rootMargin: '0px 0px -8% 0px' });
document.querySelectorAll('[data-reveal]').forEach((el) => reveal.observe(el));

const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
const playing = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    const video = entry.target;
    if (entry.isIntersecting && !reduceMotion) video.play().catch(() => {});
    else video.pause();
  }
}, { threshold: 0.15 });
document.querySelectorAll('video[data-vis]').forEach((video) => playing.observe(video));

document.querySelectorAll('[data-year]').forEach((el) => { el.textContent = String(new Date().getFullYear()); });
