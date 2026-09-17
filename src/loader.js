import { parseCSV, csvToGeoJSON } from './csv.js';

async function fetchText(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`GET ${url} -> ${res.status}`);
  return res.text();
}

// Tries the primary url first; if it 404s, falls back to sampleUrl.
function resolveURL(feed) {
  if (feed.type === 'rss') return feed.url;
  return feed.url;
}

async function loadGeoJSON(url) {
  const text = await fetchText(url);
  return JSON.parse(text);
}

function loadCSV(feed, url) {
  return fetchText(url).then((text) => csvToGeoJSON(text, feed.columns || {}));
}

async function loadRSS(feed) {
  const text = await fetchText(feed.url);
  const doc = new DOMParser().parseFromString(text, 'text/xml');
  const items = Array.from(doc.querySelectorAll('item'));

  const feedGeo = feed.geo || null;
  const features = [];

  for (const item of items) {
    const title = (item.getElementsByTagName('title')[0]?.textContent || '').trim();
    const link = (item.getElementsByTagName('link')[0]?.textContent || '').trim();
    const pubDate = (item.getElementsByTagName('pubDate')[0]?.textContent || '').trim();

    // GeoRSS: <geo:lat>/<geo:long>
    const latRaw = item.getElementsByTagName('geo:lat')[0]?.textContent;
    const lngRaw = item.getElementsByTagName('geo:long')[0]?.textContent;

    let lat = latRaw !== undefined ? parseFloat(latRaw) : NaN;
    let lng = lngRaw !== undefined ? parseFloat(lngRaw) : NaN;

    if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
      if (!feedGeo) continue;
      lat = feedGeo.lat;
      lng = feedGeo.lng;
    }

    features.push({
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [lng, lat] },
      properties: { title, link, pubDate }
    });
  }

  return { type: 'FeatureCollection', features };
}

export async function loadFeed(feed) {
  const errors = [];

  // Primary URL first.
  for (const url of [feed.url, feed.sampleUrl]) {
    if (!url) continue;
    try {
      let geojson;
      if (feed.type === 'csv') geojson = await loadCSV(feed, url);
      else if (feed.type === 'rss') geojson = await loadRSS(feed);
      else geojson = await loadGeoJSON(url);

      if (!geojson || !Array.isArray(geojson.features)) {
        throw new Error('not a FeatureCollection');
      }
      return { geojson, url };
    } catch (err) {
      errors.push(`${url}: ${err.message}`);
    }
  }

  throw new Error(errors.join(' | '));
}

export { parseCSV };