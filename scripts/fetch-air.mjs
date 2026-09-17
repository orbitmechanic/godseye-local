import { readSecrets, writeSnapshot } from './lib/util.mjs';

// OpenSky Network live state vectors -> GeoJSON snapshot.
// Anonymous access is often rate-limited; set username/password in
// public/config/secrets.json for reliable (free-tier) access.
export async function fetchAir() {
  const secrets = readSecrets();
  const { username, password } = (secrets.opensky || {});

  const url = username && password
    ? `https://${encodeURIComponent(username)}:${encodeURIComponent(password)}@opensky-network.org/api/states/all`
    : 'https://opensky-network.org/api/states/all';

  let res;
  try {
    res = await fetch(url, { signal: AbortSignal.timeout(45000) });
  } catch (err) {
    console.warn('air: network error:', err.message);
    return null;
  }

  if (res.status === 401 || res.status === 403) {
    console.warn(`air: OpenSky returned ${res.status} (anonymous access limited). Add a free opensky account to secrets.json, or keep the sample layer.`);
    return null;
  }
  if (!res.ok) {
    console.warn(`air: OpenSky HTTP ${res.status}`);
    return null;
  }

  const { time, states } = await res.json();
  if (!states) return null;

  // [icao24, callsign, originCountry, timePos, lastContact, lon, lat, baroAlt, onGround, vel, trueTrack, vertRate, sensors, geoAlt, squawk, spi, positionSource, category]
  const features = states
    .filter((s) => s[5] != null && s[6] != null)
    .map((s) => ({
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [round(s[5], 4), round(s[6], 4)] },
      properties: {
        callsign: (s[1] || '').trim() || null,
        originCountry: s[2] || null,
        altitude: s[7] != null ? Math.round(s[7]) : (s[13] != null ? Math.round(s[13]) : null),
        velocity: s[9] != null ? round(s[9], 1) : null,
        track: s[10] != null ? Math.round(s[10]) : null,
        onGround: s[8] === true,
        category: s[17] != null ? s[17] : null
      }
    }))
    .sort((a, b) => (b.properties.altitude || 0) - (a.properties.altitude || 0))
    .slice(0, 5000);

  console.log(`air: OpenSky snapshot ${new Date(time * 1000).toISOString()}`);
  return {
    type: 'FeatureCollection',
    features,
    meta: { source: 'opensky', fetchedAt: new Date().toISOString(), asOf: time * 1000 }
  };
}

function round(v, d) {
  const f = Math.pow(10, d);
  return Math.round(v * f) / f;
}

// eslint-disable-next-line no-unused-vars
const main = async () => {
  const g = await fetchAir();
  if (g) writeSnapshot('air.json', g);
};
if (import.meta.url === `file://${process.argv[1]}`) main();