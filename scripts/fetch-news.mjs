import { access, mkdir, readFile, writeFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractFirstZipEntry, fetchTextWithGzip } from './lib/zip.mjs';

function splitLine(line) {
  return line.split('\t').map((c) => c.trim());
}

const GDELT = 'https://data.gdeltproject.org/gdeltv2/';

async function masterListPath() {
  const dir = path.join(process.cwd(), '.cache');
  await mkdir(dir, { recursive: true });
  return path.join(dir, 'gdelt-masterfilelist.txt');
}

// Cached master index; refresh if older than `ttlMs`.
async function getMasterIndex(ttlMs = 12 * 3600 * 1000) {
  const file = await masterListPath();
  try {
    const st = await stat(file);
    if (Date.now() - st.mtimeMs < ttlMs) return (await readFile(file, 'utf8')).split('\n');
  } catch { /* nothing cached */ }
  const text = await fetchTextWithGzip(GDELT + 'masterfilelist.txt');
  await writeFile(file, text);
  return text.split('\n');
}

// Pick YYYYMMDDHHMMSS export slices for a target calendar day.
function slicesForDay(index, day) {
  const urls = [];
  for (const line of index) {
    const m = /(\d{8})\d{4,}00\.export\.CSV\.zip/.exec(line);
    if (!m) continue;
    if (m[1] === day) {
      const url = li2url(line);
      if (url) urls.push(url);
    }
  }
  return urls.sort();
}

function li2url(line) {
  const match = /(https?:\/\/[^\s]+export\.CSV\.zip)/.exec(line);
  return match ? match[1] : null;
}

async function fetchResult(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(120000) });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  return extractFirstZipEntry(buf, '.CSV');
}

async function pool(urls, concurrency, worker) {
  const results = [];
  let i = 0;
  async function run() {
    while (i < urls.length) {
      const idx = i;
      i += 1;
      try {
        results.push(await worker(urls[idx], idx));
      } catch (err) {
        results.push({ url: urls[idx], error: err.message });
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, urls.length) }, run));
  return results;
}

// GDELT export files are TAB-delimited, 61 columns, NO header row.
// Layout (0-indexed): SQLDATE=1, Actor1Name=6, Actor2Name=16, QuadClass=29,
// NumMentions=31, AvgTone=34, ActionGeo_{FullName,CountryCode,Lat,Lon}=52,53,56,57,
// DATEADDED=59, SOURCEURL=60. DATEADDED (D) is a 14-digit timestamp; relative
// offsets below were validated against real slices.
const OFFSET = Object.freeze({
  day: 1,           // SQLDATE
  actor1Name: 6,
  actor2Name: 16,
  quad: -30,        // QuadClass
  mentions: -28,    // NumMentions
  tone: -25,        // AvgTone
  place: -7,        // ActionGeo_FullName
  country: -6,      // ActionGeo_CountryCode
  lat: -3,          // ActionGeo_Lat
  lon: -2           // ActionGeo_Long
});
const OFFSET_URL = 1; // SOURCEURL = DATEADDED + 1

function idx(D, k) {
  return k < 0 ? D + k : k;
}

function filterRow(D, r, { keywords, minMentions, quadMode }) {
  const eventId = r[0];
  if (!eventId) return null;
  const quad = parseInt(r[idx(D, OFFSET.quad)] || '0', 10);
  const mentions = parseInt(r[idx(D, OFFSET.mentions)] || '0', 10);
  if (!mentions || mentions < minMentions) return null;

  const actor1 = r[OFFSET.actor1Name] || '';
  const actor2 = r[OFFSET.actor2Name] || '';
  const place = r[idx(D, OFFSET.place)] || '';
  if (keywords.length && !keywords.some((k) => actor1.toLowerCase().includes(k) || actor2.toLowerCase().includes(k) || place.toLowerCase().includes(k))) {
    return null;
  }
  if (quadMode === 'conflict' && quad < 3) return null;
  if (quadMode === 'cooperation' && quad > 2) return null;

  const lat = parseFloat(r[idx(D, OFFSET.lat)]);
  const lon = parseFloat(r[idx(D, OFFSET.lon)]);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;

  const y = r[OFFSET.day] || '';
  return {
    id: eventId,
    feature: {
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [round(lon, 4), round(lat, 4)] },
      properties: {
        actor1: actor1 || null,
        actor2: actor2 || null,
        quadClass: quad,
        tone: Number.isFinite(parseFloat(r[idx(D, OFFSET.tone)])) ? round(parseFloat(r[idx(D, OFFSET.tone)]), 2) : null,
        mentions,
        date: y ? `${y.slice(0, 4)}-${y.slice(4, 6)}-${y.slice(6, 8)}` : null,
        country: r[idx(D, OFFSET.country)] || null,
        place: place || null,
        sourceUrl: r[D + OFFSET_URL] || null
      }
    }
  };
}

export async function fetchNews() {
  const feeds = JSON.parse(await readFile(path.join(process.cwd(), 'public', 'config', 'feeds.json'), 'utf8'));
  const feed = feeds.find((f) => f.source?.type === 'gdelt');
  const src = (feed && feed.source) || {};

  const keywords = (src.keywords || []).map((k) => String(k).toLowerCase());
  const minMentions = Number(src.minMentions || 0);
  const maxResults = Number(src.maxResults || 1500);
  const quadMode = src.quadClass || 'all';

  process.stdout.write('news: loading GDELT master index …\n');
  const index = await getMasterIndex();
  const exportsList = index.filter((l) => l.includes('export.CSV.zip'));

  // Choose the target day (lagDays back), falling back to prior days.
  let chosen = null;
  for (let lag = Number(src.lagDays || 1); lag <= Number(src.lagDays || 1) + 3; lag += 1) {
    const day = isoDate(lag);
    const urls = slicesForDay(exportsList, day);
    if (urls.length >= 6) { chosen = { day, urls }; break; }
    process.stdout.write(`news: ${day} only has ${urls.length} slices — looking earlier\n`);
  }
  if (!chosen || chosen.urls.length === 0) {
    throw new Error('news: no GDELT slices found in master index');
  }

  process.stdout.write(`news: fetching ${chosen.urls.length} slices for ${chosen.day} …\n`);
  const results = await pool(chosen.urls, 6, async (url) => fetchResult(url));

  const seenId = new Set();
  const features = [];
  let loaded = 0;
  for (const r of results) {
    if (r.error) { process.stdout.write(`news: slice error: ${r.url} (${r.error})\n`); continue; }
    loaded += 1;
    const text = r.toString('utf8');
    for (let line of text.split('\n')) {
      if (!line.trim()) continue;
      const row = splitLine(line);
      let D = -1;
      for (let i = Math.min(row.length - 1, 60); i >= 0; i -= 1) {
        if (/^\d{14}$/.test(row[i].trim())) { D = i; break; }
      }
      if (D < 0) continue;
      const hit = filterRow(D, row, { keywords, minMentions, quadMode });
      if (hit && !seenId.has(hit.id)) {
        seenId.add(hit.id);
        features.push(hit.feature);
      }
    }
  }

  features.sort((a, b) => b.properties.mentions - a.properties.mentions);
  const capped = features.slice(0, maxResults);

  const counts = { 1: 0, 2: 0, 3: 0, 4: 0 };
  for (const f of capped) counts[f.properties.quadClass] += 1;
  process.stdout.write(
    `news: ${loaded} slices loaded, ${capped.length} events kept | ` +
    `coop ${counts[1]}/${counts[2]} · conflict ${counts[3]}/${counts[4]}\n`
  );

  return {
    type: 'FeatureCollection',
    features: capped,
    meta: { source: 'gdelt', day: chosen.day, fetchedAt: new Date().toISOString() }
  };
}

// Kept for CLI direct-run parity.
export async function run() {
  const g = await fetchNews();
  if (g) {
    const { writeFile: wf } = await import('node:fs/promises');
    await wf(path.join(process.cwd(), 'public', 'data', 'snapshots', 'news.json'), JSON.stringify(g, null, 2));
    process.stdout.write(`news: wrote public/data/snapshots/news.json (${g.features.length} points)\n`);
  }
}

function round(v, d) {
  const f = Math.pow(10, d);
  return Math.round(v * f) / f;
}

function pad(n) {
  return String(n).padStart(2, '0');
}

function isoDate(daysAgo) {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - daysAgo);
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}`;
}

const main = async () => {
  if (import.meta.url === `file://${process.argv[1]}`) await run();
};
main();