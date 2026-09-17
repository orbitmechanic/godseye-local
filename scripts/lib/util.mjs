import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// Reads optional secrets.json; missing/empty is fine — feeds just get skipped.
export function readSecrets() {
  try {
    return JSON.parse(readFileSync(join(root, 'public', 'config', 'secrets.json'), 'utf8'));
  } catch {
    return {};
  }
}

export function readFeedsConfig() {
  return JSON.parse(readFileSync(join(root, 'public', 'config', 'feeds.json'), 'utf8'));
}

export function writeSnapshot(name, geojson) {
  const dir = join(root, 'public', 'data', 'snapshots');
  writeFileSync(join(dir, name), JSON.stringify(geojson, null, 2)); // prettyfied on purpose
  console.log(`wrote public/data/snapshots/${name} (${geojson.features.length} points)`);
}

function pad(n) {
  return String(n).padStart(2, '0');
}

export function isoDate(daysAgo = 0) {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - daysAgo);
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}`;
}