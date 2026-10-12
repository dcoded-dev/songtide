// songtide.dcoded.dev: serves the static site (site/) and keeps a few anonymous daily counts.
//
// Counted, per day: first launches ("installs", sent once by the app the first time it opens on a
// Mac), update checks by app version (each installed copy checks once a day, so this
// is roughly the number of copies in use, and which versions they run), DMG downloads from the
// site, and updates the app downloads. Nothing about the person is kept: no IP address, no
// identifier, no cookie; just a running total per day.
//
// The totals are at /stats?key=… (the key is the STATS_KEY secret).

const BOTS = /bot|crawl|spider|slurp|preview|headless|monitor|curl|wget|python|go-http|java\//i;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/stats') return stats(url, env);
    if (url.pathname === '/installed') {
      const app = (request.headers.get('user-agent') || '').match(/^Songtide\/([\d.]+)/);
      if (request.method === 'POST' && app) ctx.waitUntil(count(env, 'install', app[1]).catch(() => {}));
      return new Response(null, { status: 204 });
    }
    const event = classify(request, url);
    if (event) ctx.waitUntil(count(env, event.kind, event.version).catch(() => {}));
    return env.ASSETS.fetch(request);
  },
};

/** What a request counts as, if anything. */
function classify(request, url) {
  if (request.method !== 'GET') return null;
  const agent = request.headers.get('user-agent') || '';
  // Songtide's updater identifies itself as "Songtide/<version> Sparkle/<version>".
  const app = agent.match(/^Songtide\/([\d.]+)/);
  if (url.pathname === '/appcast.xml') return app ? { kind: 'check', version: app[1] } : null;
  if (!url.pathname.startsWith('/releases/') || !/\.(dmg|delta)$/.test(url.pathname)) return null;
  // Only the start of a download, not every chunk of a resumed one.
  const range = request.headers.get('range');
  if (range && !/^bytes=0-/.test(range)) return null;
  if (app) return { kind: 'update', version: app[1] };
  // Homebrew downloads with curl, but a brew install is a person's download.
  if (!/^Homebrew\//.test(agent) && (BOTS.test(agent) || !agent)) return null;
  const release = url.pathname.match(/Songtide-([\d.]+)\.dmg$/);
  return release ? { kind: 'download', version: release[1] } : null;
}

async function count(env, kind, version) {
  const day = new Date().toISOString().slice(0, 10);
  await env.STATS.prepare(
    `INSERT INTO daily (day, kind, version, count) VALUES (?1, ?2, ?3, 1)
     ON CONFLICT (day, kind, version) DO UPDATE SET count = count + 1`
  ).bind(day, kind, version).run();
}

async function stats(url, env) {
  if (!env.STATS_KEY || url.searchParams.get('key') !== env.STATS_KEY) {
    return new Response('Not found', { status: 404 });
  }
  const { results } = await env.STATS.prepare(
    `SELECT day, kind, version, count FROM daily WHERE day >= date('now', '-30 days') ORDER BY day DESC`
  ).all();
  const days = new Map();
  const latestVersions = new Map();
  for (const row of results) {
    const totals = days.get(row.day) || { install: 0, check: 0, download: 0, update: 0 };
    totals[row.kind] = (totals[row.kind] || 0) + row.count;
    days.set(row.day, totals);
  }
  // The last full day (today's count is still growing), or today if that's all there is.
  const today = new Date().toISOString().slice(0, 10);
  const checkDays = [...new Set(results.filter((row) => row.kind === 'check').map((row) => row.day))];
  const latestDay = checkDays.find((day) => day < today) || checkDays[0];
  for (const row of results) {
    if (row.day === latestDay && row.kind === 'check') latestVersions.set(row.version, row.count);
  }
  if (url.searchParams.has('json')) {
    return Response.json({ days: Object.fromEntries(days), versions: Object.fromEntries(latestVersions), day: latestDay },
      { headers: { 'cache-control': 'no-store' } });
  }
  const sum = (kind, n) => [...days.values()].slice(0, n).reduce((total, d) => total + d[kind], 0);
  const rows = [...days].map(([day, d]) =>
    `<tr><td>${day}</td><td>${d.download}</td><td>${d.install}</td><td>${d.check}</td><td>${d.update}</td></tr>`).join('');
  // Newest version first, comparing each part as a number (1.1.10 after 1.1.9).
  const newer = (a, b) => {
    const x = a.split('.').map(Number), y = b.split('.').map(Number);
    for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] || 0) !== (y[i] || 0)) return (y[i] || 0) - (x[i] || 0);
    return 0;
  };
  const versions = [...latestVersions].sort((a, b) => newer(a[0], b[0]))
    .map(([version, n]) => `<tr><td>${version}</td><td>${n}</td></tr>`).join('');
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>Songtide stats</title>
<style>
  :root { color-scheme: light dark; --muted: #8a8494; --line: rgba(128,128,128,.25); --accent: #f2843c; }
  body { font: 15px -apple-system, system-ui, sans-serif; max-width: 760px; margin: 40px auto; padding: 0 16px; }
  h1 { font-size: 24px; margin: 0 0 4px; } p { color: var(--muted); margin: 0 0 28px; }
  .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin-bottom: 32px; }
  .tile { border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; }
  .tile b { display: block; font-size: 28px; font-variant-numeric: tabular-nums; color: var(--accent); }
  .tile span { color: var(--muted); font-size: 13px; }
  h2 { font-size: 16px; margin: 28px 0 8px; }
  table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
  th, td { text-align: left; padding: 7px 8px; border-bottom: 1px solid var(--line); }
  th { color: var(--muted); font-weight: 500; font-size: 13px; }
</style>
<h1>Songtide</h1>
<p>Anonymous daily totals for the last 30 days. Times are UTC.</p>
<div class="tiles">
  <div class="tile"><b>${latestDay ? days.get(latestDay).check : 0}</b><span>copies in use (update checks, ${latestDay || 'no data yet'})</span></div>
  <div class="tile"><b>${sum('download', 7)}</b><span>downloads, last 7 days</span></div>
  <div class="tile"><b>${sum('download', 30)}</b><span>downloads, last 30 days</span></div>
  <div class="tile"><b>${sum('install', 7)}</b><span>new installs (first opened), last 7 days</span></div>
  <div class="tile"><b>${sum('install', 30)}</b><span>new installs, last 30 days</span></div>
  <div class="tile"><b>${sum('update', 7)}</b><span>updates installed, last 7 days</span></div>
</div>
<h2>Versions in use (${latestDay || '—'})</h2>
<table><tr><th>Version</th><th>Copies</th></tr>${versions || '<tr><td colspan="2">No update checks yet</td></tr>'}</table>
<h2>By day</h2>
<table><tr><th>Day</th><th>Downloads</th><th>New installs</th><th>Update checks</th><th>Updates</th></tr>${rows || '<tr><td colspan="5">No data yet</td></tr>'}</table>`;
  return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'x-robots-tag': 'noindex' } });
}
