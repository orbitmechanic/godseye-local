import { readSecrets, writeSnapshot } from './lib/util.mjs';

// AIS Hub free-tier snapshot (vessels) -> GeoJSON. Needs a free AISHub account
// username in public/config/secrets.json; otherwise the sample layer is used.
export async function fetchSea() {
  const secrets = readSecrets();
  const username = (secrets.aishub || {}).username;
  if (!username) {
    console.warn('sea: no aishub.username in secrets.json — skipping. Sample layer stays active.');
    return null;
  }

  const url = `https://data.aishub.net/ws.php?username=${encodeURIComponent(username)}&format=1&output=json`;
  let res;
  try {
    res = await fetch(url, { signal: AbortSignal.timeout(45000) });
  } catch (err) {
    console.warn('sea: network error:', err.message);
    return null;
  }
  if (!res.ok) {
    console.warn(`sea: AISHub HTTP ${res.status}`);
    return null;
  }

  const payload = await res.json();
  const ships = payload?.data || payload?.LIST || [];
  if (!Array.isArray(ships) || ships.length === 0) return null;

  const features = ships
    .filter((s) => s != null && +s.LON && +s.LAT)
    .map((s) => ({
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [round(+s.LON, 4), round(+s.LAT, 4)] },
      properties: {
        name: (s.NAME || s.name || s.SHIPNAME || null),
        mmsi: s.MMSI != null ? s.MMSI : null,
        type: s.TYPE != null ? s.TYPE : null,
        destination: s.DESTINATION || s.destination || null,
        speed: s.SPEED != null ? round(+s.SPEED, 1) : null,
        heading: s.HEADING != null ? Math.round(+s.HEADING) : null,
        flag: s.FLAG || s.flag || null
      }
    }));

  console.log(`sea: AISHub snapshot (${features.length} vessels)`);
  return {
    type: 'FeatureCollection',
    features,
    meta: { source: 'aishub', fetchedAt: new Date().toISOString() }
  };
}

function round(v, d) {
  const f = Math.pow(10, d);
  return Math.round(v * f) / f;
}

const main = async () => {
  const g = await fetchSea();
  if (g) writeSnapshot('sea.json', g);
};
if (import.meta.url === `file://${process.argv[1]}`) main();