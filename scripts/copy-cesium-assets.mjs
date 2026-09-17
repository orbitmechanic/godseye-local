import { mkdirSync, existsSync, cpSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = join(root, 'node_modules', 'cesium', 'Build', 'Cesium');
const dest = join(root, 'public', 'cesium-assets');

if (!existsSync(src)) {
  console.error('cesium not installed — run `npm install` first.');
  process.exit(1);
}

mkdirSync(dest, { recursive: true });
for (const d of ['Workers', 'Assets', 'ThirdParty', 'Widgets']) {
  const from = join(src, d);
  if (existsSync(from)) cpSync(from, join(dest, d), { recursive: true, force: true });
}
console.log('copied Cesium assets -> public/cesium-assets/');