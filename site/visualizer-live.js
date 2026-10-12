// The gallery's visualizer shot comes alive: Songtide's real visualizer engine (Butterchurn, MIT;
// see /vendor/LICENSES.txt) drawn over the screenshot's visual area, dancing to a made-up beat
// and shuffling visuals. Calm on purpose: half speed, a soft beat, a new visual every 20 seconds.
// Fetched once the page is idle and drawn from just before it scrolls into view; it warms up
// fast (several steps a frame) until the first bright frame. A single still frame for reduced motion.
(() => {
  const frame = document.querySelector('.live-viz');
  if (!frame) return;
  const canvas = frame.querySelector('canvas');
  // The screenshot's visual area is black (like the app before music starts); live visuals fade in
  // over it. With reduced motion, one bright frame is drawn and left still.
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;

  const load = (src) => new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src; s.onload = resolve; s.onerror = reject;
    document.head.appendChild(s);
  });

  let visualizer, presets, names, visible = false, started = false, lastSwap = 0, odd = false, frames = 0, shown = false;
  // Some visuals start black or stay dark: check brightness on a tiny copy now and then, show the
  // live canvas only while there's something to see, and skip a visual that stays dark.
  const probe = document.createElement('canvas');
  probe.width = probe.height = 8;
  const probeCtx = probe.getContext('2d', { willReadFrequently: true });
  const brightness = () => {
    probeCtx.drawImage(canvas, 0, 0, 8, 8); // right after a render, while the frame is still there
    const d = probeCtx.getImageData(0, 0, 8, 8).data;
    let sum = 0;
    for (let i = 0; i < d.length; i += 4) sum += d[i] * 0.3 + d[i + 1] * 0.59 + d[i + 2] * 0.11;
    return sum / 64;
  };
  const left = new Uint8Array(1024), right = new Uint8Array(1024), mono = new Uint8Array(1024);
  const bpm = 96;

  // A beat: a thump on every beat, a lighter one in between, a slow swell under it all.
  const signal = (t) => {
    const beat = (t * bpm / 60) % 1, half = (t * bpm / 30) % 1;
    const kick = Math.exp(-beat * 5) * 0.75, hat = Math.exp(-half * 14) * 0.2;
    const swell = 0.5 + 0.5 * Math.sin(t * 0.35);
    for (let i = 0; i < 1024; i++) {
      const v = 128
        + 90 * kick * Math.sin(i / (6 + 10 * beat))
        + 40 * hat * (Math.random() - 0.5) * 2
        + 26 * swell * Math.sin(i / 23 + t * 2.1)
        + 14 * Math.sin(i / 3.7 - t * 5);
      left[i] = right[i] = mono[i] = Math.max(0, Math.min(255, v | 0));
    }
  };

  const size = () => {
    const ratio = Math.min(devicePixelRatio || 1, 1.5); // plenty for a gallery image, easy on the GPU
    const w = Math.round(canvas.clientWidth * ratio), h = Math.round(canvas.clientHeight * ratio);
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w; canvas.height = h;
      visualizer?.setRendererSize(w, h);
    }
  };

  const shuffle = (blend) => {
    visualizer.loadPreset(presets[names[Math.floor(Math.random() * names.length)]], blend);
    lastSwap = performance.now();
  };

  const frameLoop = (now) => {
    // Before the first bright frame it warms up wherever the page is scrolled; after that it only
    // runs while on screen.
    if ((!visible && shown) || document.hidden) { started = false; return; }
    if (now - lastSwap > 20000) shuffle(4);
    // Every other frame: each render is one normal step, so this runs at half speed. Until the
    // first bright frame it fast-forwards instead (four steps a frame, still hidden).
    const warming = !canvas.classList.contains('on') && !shown;
    odd = !odd;
    if (odd || warming) {
      for (let step = 0; step < (warming ? 4 : 1); step++) {
        signal(now / 1000 + step / 60);
        visualizer.render({ audioLevels: { timeByteArray: mono, timeByteArrayL: left, timeByteArrayR: right } });
      }
      if (++frames % (warming ? 5 : 15) === 0) {
        // Dark moments fade out to plain black rather than a murky picture.
        const lit = brightness() > (shown ? 18 : 35); // a bright start; after that, only near-black hides
        canvas.classList.toggle('on', lit);
        if (lit) shown = true;
        if (still && shown) { started = false; return; } // one frame, no motion
        if (!lit && now - lastSwap > (shown ? 3500 : 1000)) shuffle(shown ? 1 : 0);
      }
    }
    requestAnimationFrame(frameLoop);
  };

  const run = () => {
    if (started || !visualizer || (!visible && shown) || document.hidden || (still && shown)) return;
    started = true;
    requestAnimationFrame(frameLoop);
  };

  const start = async () => {
    try {
      await load('/vendor/butterchurn.min.js');
      await load('/vendor/butterchurnPresets.min.js');
    } catch (_) { return; }
    const bc = window.butterchurn.default || window.butterchurn;
    presets = window.butterchurnPresets.getPresets();
    names = Object.keys(presets);
    size();
    // The engine only uses the AudioContext for timing; no sound is played.
    visualizer = bc.createVisualizer(new AudioContext(), canvas, { width: canvas.width, height: canvas.height, pixelRatio: 1 });
    shuffle(0);
    run();
    addEventListener('resize', size);
    document.addEventListener('visibilitychange', run);
  };

  const begin = () => { if (!frame.dataset.loading) { frame.dataset.loading = '1'; start(); } };
  // Fetch early, once the page has finished loading and is idle.
  if (window.requestIdleCallback) requestIdleCallback(begin, { timeout: 1500 }); else setTimeout(begin, 500);
  // Draw from well before it scrolls into view, so it's already going when it arrives.
  new IntersectionObserver((entries) => {
    visible = entries.some((e) => e.isIntersecting);
    if (visible) begin();
    run();
  }, { rootMargin: '600px' }).observe(frame);
})();
