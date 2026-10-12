// Light/dark toggle: follows the system until picked, then remembers the choice.
(() => {
  const root = document.documentElement;
  const button = document.querySelector('.theme-toggle');
  if (!button) return;
  const isDark = () => root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
  const sun = '<path d="M12 3v2M12 19v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M3 12h2M19 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z"/>';
  const moon = '<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5Z"/>';
  const render = () => {
    const dark = isDark();
    button.querySelector('svg').innerHTML = dark ? sun : moon;
    button.setAttribute('aria-label', dark ? 'Switch to light mode' : 'Switch to dark mode');
  };
  button.addEventListener('click', () => {
    const next = isDark() ? 'light' : 'dark';
    root.dataset.theme = next;
    try { localStorage.setItem('songtide-theme', next); } catch (_) {}
    render();
  });
  render();
})();

// Count downloads: the buttons point at /download (a redirect), which Analytics' automatic file
// download tracking doesn't recognise.
document.addEventListener('click', (e) => {
  const link = e.target.closest('a[href="/download"]');
  if (link && typeof gtag === 'function') gtag('event', 'file_download', { file_name: 'Songtide.dmg', link_text: link.textContent.trim() });
});

// FAQ: one answer open at a time (browsers without the details "name" grouping).
document.querySelectorAll('.faq details').forEach((d, _, all) => d.addEventListener('toggle', () => {
  if (d.open) all.forEach((other) => { if (other !== d) other.open = false; });
}));


// Screenshot carousel: slides with the arrows, the captions under it (tabs) or by dragging, and moves
// on by itself every few seconds (any of those restarts the wait; no moving with Reduce Motion).
(() => {
  const tabs = [...document.querySelectorAll('.showcase-tabs [role="tab"]')];
  const viewport = document.querySelector('.showcase-viewport');
  const track = document.querySelector('.showcase-track');
  if (!tabs.length || !viewport || !track) return;
  const gap = 48;
  const autoplay = !matchMedia('(prefers-reduced-motion: reduce)').matches;
  let current = 0;
  let timer = null;
  const restart = () => {
    clearInterval(timer);
    if (autoplay) timer = setInterval(() => { if (!document.hidden && !drag) show(current + 1, false); }, 6000);
  };
  const place = (offset = 0) => {
    track.style.transform = `translateX(calc(${-current} * (100% + ${gap}px) + ${offset}px))`;
  };
  const show = (index, picked = true) => {
    current = (index + tabs.length) % tabs.length;
    tabs.forEach((tab, i) => {
      const selected = i === current;
      tab.setAttribute('aria-selected', String(selected));
      tab.tabIndex = selected ? 0 : -1;
    });
    place();
    if (picked) restart();
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => show(i));
    tab.addEventListener('keydown', (e) => {
      const step = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (!step) return;
      show(current + step);
      tabs[current].focus();
    });
  });
  document.querySelector('.showcase-arrow.prev')?.addEventListener('click', () => show(current - 1));
  document.querySelector('.showcase-arrow.next')?.addEventListener('click', () => show(current + 1));

  // Dragging: the track follows the pointer; letting go past a fifth of the width, or with a
  // flick, moves one screenshot that way, otherwise it springs back.
  let drag = null;
  viewport.addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || e.target.closest('button')) return;
    drag = { x: e.clientX, y: e.clientY, t: performance.now(), dx: 0, horizontal: null, id: e.pointerId };
  });
  viewport.addEventListener('pointermove', (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (drag.horizontal === null) {
      if (Math.abs(dx) < 6 && Math.abs(dy) < 6) return;
      drag.horizontal = Math.abs(dx) > Math.abs(dy);
      if (!drag.horizontal) { drag = null; return; } // a vertical swipe scrolls the page
      viewport.setPointerCapture(e.pointerId);
      viewport.classList.add('dragging');
      track.classList.add('dragging');
    }
    drag.dx = dx;
    place(dx);
  });
  const end = (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const { dx, t, horizontal } = drag;
    drag = null;
    viewport.classList.remove('dragging');
    track.classList.remove('dragging');
    if (!horizontal) return;
    const speed = Math.abs(dx) / Math.max(1, performance.now() - t);
    const far = Math.abs(dx) > viewport.clientWidth * 0.2 || (speed > 0.5 && Math.abs(dx) > 30);
    show(far ? current - Math.sign(dx) : current);
  };
  viewport.addEventListener('pointerup', end);
  viewport.addEventListener('pointercancel', end);
  show(0);
})();
