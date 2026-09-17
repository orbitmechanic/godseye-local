import { gunzipSync } from 'node:zlib';
import { readFeedsConfig, writeSnapshot, isoDate } from './lib/util.mjs';
import { parseCSV } from './lib/csv.mjs';

// GDELT 2.0 daily "All Events" export -> filtered GeoJSON snapshot.
// Fully keyless. Fetches today-lagDays; walks back up to 3 days if a file is
// missing (data is published with some delay).
//
// Event column indexes (0-based) we use:
//   7 Actor1Name, 16 Actor2Name, 28 QuadClass,
//   30 NumMentions, 33 AvgTone, 49 ActionGeo_FullName,
//   50 ActionGeo_CountryCode, 52 ActionGeo_Lat, 53 ActionGeo_Long,
//   56 SOURCEURL, 1 Day
export async function fetchNews() {
  const feeds = readFeedsConfig();
  const feed = feeds.find((f) => f.source?.type === 'gdelt');
  const src = (feed && feed.source) || {};

  const keywords = (src.keywords || []).map((k) => k.toLowerCase());
  const minMentions = Number(src.minMentions || 0);
  const maxResults = Number(src.maxResults || 1500);
  const quadMode = src.quadClass || 'all';
  const maxLookback = 3;

  let result = null;
  for (let lag = Number(src.lagDays || 1); lag <= Number(src.lagDays || 1) + maxLookback; lag += 1) {
    const day = isoDate(lag);
    const url = `http://data.gdeltproject.org/gdeltv2/${day}.export.CSV.gz`;
    try {
      process.stdout.write(`news: fetching ${url} …\n`);
      const res = await fetch(url, { signal: AbortSignal.timeout(120000) });
      if (!res.ok) {
        process.stdout.write(`news: HTTP ${res.status} (${day}) — trying previous day\n`);
        continue;
      }
      const gz = Buffer.from(await res.arrayBuffer());
      const csv = gunzipSync(gz).toString('utf8');
      const rows = parseCSV(csv);
      result = build(rows, { keywords, minMentions, maxResults, quadMode, day });
      printSummary(result);
      return result;
    } catch (err) {
      process.stdout.write(`news: ${day} failed (${err.message}) — trying previous day\n`);
    }
  }
  return null;
}

function build(rows, { keywords, minMentions, maxResults, quadMode, day }) {
  const features = [];
  for (const r of rows) {
    const [GlobalEventID] = r;
    if (!GlobalEventID) continue;
    const actor1 = r[7] || '';
    const actor2 = r[16] || '';
    const quad = parseInt(r[28] || '0', 10);
    const mentions = parseInt(r[30] || '0', 10);
    if (!mentions) continue;

    const place = r[49] || '';
    const country = r[50] || '';

    if (mentions < minMentions) continue;
    if (keywords.length && !keywords.some((k) => actor1.toLowerCase().includes(k) || actor2.toLowerCase().includes(k) || place.toLowerCase().includes(k))) {
      continue;
    }
    if (quadMode === 'conflict' && quad < 3) continue;
    if (quadMode === 'cooperation' && quad > 2) continue;

    let lat = parseFloat(r[52]);
    let lon = parseFloat(r[53]);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;

    const y = r[1] || day;
    features.push({
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [round(lon, 4), round(lat, 4)] },
      properties: {
        actor1: actor1 || null,
        actor2: actor2 || null,
        quadClass: quad,
        tone: Number.isFinite(parseFloat(r[33])) ? round(parseFloat(r[33]), 2) : null,
        mentions,
        date: `${y.slice(0, 4)}-${y.slice(4, 6)}-${y.slice(6, 8)}`,
        country: country || null,
        place: place || null,
        sourceUrl: r[56] || null
      }
    });
  }

  features.sort((a, b) => b.properties.mentions - a.properties.mentions);
  return {
    type: 'FeatureCollection',
    features: features.slice(0, maxResults),
    meta: { source: 'gdelt', day, fetchedAt: new Date().toISOString() }
  };
}

function printSummary(g) {
  const counts = { 1: 0, 2: 0, 3: 0, 4: 0 };
  for (const f of g.features) counts[f.properties.quadClass] += 1;
  process.stdout.write(
    `news: ${g.features.length} events | coop verbal ${counts[1]} · coop material ${counts[2]} · conflict verbal ${counts[3]} · conflict material ${counts[4]}\n`
  );
}

function round(v, d) {
  const f = Math.pow(10, d);
  return Math.round(v * f) / f;
}

const main = async () => {
  const g = await fetchNews();
  if (g) writeSnapshot('news.json', g);
  else process.stdout.write('news: no GDELT snapshot available (offline?)\n');
};
if (import.meta.url === `file://${process.argv[1]}`) main();