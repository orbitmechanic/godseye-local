// Minimal CSV parser handling quoted fields and CRLF.
export function parseCSV(text) {
  const rows = [];
  let row = [];
  let field = '';
  let inQuotes = false;

  for (let i = 0; i < text.length; i += 1) {
    const c = text[i];
    const n = text[i + 1];

    if (inQuotes) {
      if (c === '"' && n === '"') { field += '"'; i += 1; }
      else if (c === '"') { inQuotes = false; }
      else { field += c; }
      continue;
    }

    if (c === '"') { inQuotes = true; }
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\r') { /* skip */ }
    else if (c === '\n') {
      row.push(field); field = '';
      if (row.some((v) => v.trim() !== '')) rows.push(row);
      row = [];
    }
    else { field += c; }
  }
  if (field.length > 0) { row.push(field); rows.push(row); }

  return rows;
}

// Convert CSV text + column config to a GeoJSON FeatureCollection.
// columns: { lat, lon, name } are expected column names.
export function csvToGeoJSON(text, columns) {
  const rows = parseCSV(text);
  if (rows.length === 0) return { type: 'FeatureCollection', features: [] };

  const header = rows[0].map((h) => h.trim());
  const dataRows = rows.slice(1);

  const idx = (key) => {
    const name = columns && columns[key];
    return header.indexOf(name);
  };

  const latIdx = idx('lat');
  const lonIdx = idx('lon');
  const nameIdx = idx('name');

  if (latIdx < 0 || lonIdx < 0) {
    throw new Error(`CSV needs "${columns?.lat}" and "${columns?.lon}" columns; found: ${header.join(',')}`);
  }

  const features = [];
  for (const r of dataRows) {
    const lat = parseFloat(r[latIdx]);
    const lon = parseFloat(r[lonIdx]);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;

    const props = {};
    header.forEach((h, i) => {
      const v = r[i];
      if (v === undefined || v === '') return;
      const num = Number(v);
      props[h] = Number.isFinite(num) && !Number.isNaN(v) ? num : v;
    });
    if (nameIdx >= 0) props.name = r[nameIdx];

    features.push({
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [lon, lat] },
      properties: props
    });
  }

  return { type: 'FeatureCollection', features };
}