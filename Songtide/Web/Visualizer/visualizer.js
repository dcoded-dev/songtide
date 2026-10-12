// Butterchurn (MilkDrop in WebGL), fed with Songtide's own audio. WebKit's Web Audio can't hear
// YouTube Music's stream, so Swift captures the audio natively and calls feed() ~60 times a second
// with 1,024 left and 1,024 right samples as unsigned bytes (128 = silence), base64-encoded.
(() => {
  const canvas = document.getElementById('canvas');
  const post = (message) => { try { window.webkit.messageHandlers.visualizer.postMessage(message); } catch (_) {} };
  addEventListener('error', (e) => post({ type: 'error', message: `${e.message} (${e.lineno}:${e.colno})` }));
  const bc = window.butterchurn.default || window.butterchurn;
  const presets = window.butterchurnPresets.getPresets();
  const names = Object.keys(presets).sort((a, b) => a.localeCompare(b));

  const size = () => {
    const ratio = window.devicePixelRatio || 1;
    return { width: Math.round(innerWidth * ratio), height: Math.round(innerHeight * ratio), ratio };
  };
  let s = size();
  canvas.width = s.width; canvas.height = s.height;
  // The visualizer only needs an AudioContext for timing; audio arrives through render().
  const visualizer = bc.createVisualizer(new AudioContext(), canvas, { width: s.width, height: s.height, pixelRatio: s.ratio });
  // Resizing the canvas clears it and rebuilds the renderer's buffers, which flickers if done on
  // every step of a drag; meanwhile the canvas just stretches (CSS), and it's resized once things
  // settle.
  let resizeTimer;
  const applySize = () => {
    const wasEmpty = !s.width || !s.height;
    s = size();
    if (s.width === canvas.width && s.height === canvas.height) return;
    canvas.width = s.width; canvas.height = s.height;
    visualizer.setRendererSize(s.width, s.height);
    // A new window can load the page before it has a size; a preset started on a 0×0 canvas stays
    // black, so start it again now that there's something to draw on.
    if (wasEmpty && s.width && s.height) load(index, 0);
  };
  addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    if (!s.width || !s.height) return applySize(); // first real size: straight away
    resizeTimer = setTimeout(applySize, 150);
  });

  const left = new Uint8Array(1024).fill(128);
  const right = new Uint8Array(1024).fill(128);
  const mono = new Uint8Array(1024).fill(128);
  window.feed = (b64) => {
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    left.set(bytes.subarray(0, 1024));
    right.set(bytes.subarray(1024, 2048));
    for (let i = 0; i < 1024; i++) mono[i] = (left[i] + right[i]) >> 1;
  };

  // While playback is paused the visualizer idles: dimmed and softened, it keeps drifting very
  // slowly: 12 frames a second, each a normal 60 fps step, so about a fifth of the speed (and GPU).
  let idle = false;
  let lastIdleFrame = 0;
  let index = Math.floor(Math.random() * names.length);
  let autoSeconds = 30; // 0 = never change on its own
  let lastChange = performance.now();
  post({ type: 'presets', names });
  const load = (i, blend = 2.0) => {
    index = (i + names.length) % names.length;
    visualizer.loadPreset(presets[names[index]], blend);
    lastChange = performance.now();
    post({ type: 'preset', name: names[index], index, count: names.length });
  };
  window.nextPreset = () => load(index + 1);
  window.previousPreset = () => load(index - 1);
  window.randomPreset = () => load(Math.floor(Math.random() * names.length));
  window.selectPreset = (name, blend = 2.0) => { const i = names.indexOf(name); if (i >= 0) load(i, blend); };
  window.setAutoChange = (seconds) => { autoSeconds = seconds; lastChange = performance.now(); };
  load(index, 0);

  canvas.style.transition = 'filter 0.9s ease, transform 0.9s ease';
  window.setFrozen = (on) => {
    idle = on;
    canvas.style.filter = on ? 'brightness(0.45) saturate(0.6) blur(2px)' : 'none';
    canvas.style.transform = on ? 'scale(1.02)' : 'none'; // keeps the blur's soft edges off-screen
    // (Idle audio comes from idleSignal(), not the last moment played.)
    lastChange = performance.now(); // no auto-shuffle straight after pausing or resuming
  };

  // Many presets only draw in response to sound and fade to black in silence, so idle frames get a
  // soft, slowly swelling tone instead: enough to keep a faint glow moving.
  const idleSignal = (t) => {
    const level = 10 + 6 * Math.sin(t * 0.4);
    for (let i = 0; i < 1024; i++) {
      const v = 128 + level * Math.sin(i / 18 + t * 1.3) + (level / 2) * Math.sin(i / 5 - t);
      left[i] = right[i] = mono[i] = Math.max(0, Math.min(255, Math.round(v)));
    }
  };

  const frame = (now) => {
    if (!idle && autoSeconds > 0 && now - lastChange > autoSeconds * 1000) window.randomPreset();
    if (!idle) {
      visualizer.render({ audioLevels: { timeByteArray: mono, timeByteArrayL: left, timeByteArrayR: right } });
    } else if (now - lastIdleFrame >= 1000 / 12) {
      lastIdleFrame = now;
      idleSignal(now / 1000);
      visualizer.render({ elapsedTime: 1 / 60, audioLevels: { timeByteArray: mono, timeByteArrayL: left, timeByteArrayR: right } });
    }
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
})();
