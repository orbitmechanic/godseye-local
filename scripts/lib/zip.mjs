import { inflateRawSync } from 'node:zlib';

// Minimal ZIP reader for single/multi-file archives stored with
// method 0 (store) or 8 (deflate). Returns the raw uncompressed buffer
// of the first file whose name ends with the given suffix.
export function extractFirstZipEntry(buf, suffix = '') {
  // Locate End of Central Directory (EOCD) signature PK\x05\x06.
  let eocd = -1;
  const min = Math.max(0, buf.length - 65558);
  for (let i = buf.length - 22; i >= min; i -= 1) {
    if (buf[i] === 0x50 && buf[i + 1] === 0x4b && buf[i + 2] === 0x05 && buf[i + 3] === 0x06) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('zip: EOCD not found');

  const count = buf.readUInt16LE(eocd + 10);
  const cdOffset = buf.readUInt32LE(eocd + 16);
  if (count === 0) throw new Error('zip: empty archive');

  // Walk the central directory for the first matching entry.
  let p = cdOffset;
  let found = null;
  for (let i = 0; i < count; i += 1) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error('zip: bad central dir entry');
    const method = buf.readUInt16LE(p + 10);
    const csize = buf.readUInt32LE(p + 20);
    const usize = buf.readUInt32LE(p + 24);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const localOffset = buf.readUInt32LE(p + 42);
    const name = buf.toString('utf8', p + 46, p + 46 + nameLen);

    if (name.endsWith(suffix)) {
      found = { name, method, csize, usize, localOffset };
      break;
    }
    p += 46 + nameLen + extraLen + commentLen;
  }
  if (!found) throw new Error('zip: no matching entry');

  // Parse the local file header to skip its name/extra lengths.
  const lh = found.localOffset;
  const lNameLen = buf.readUInt16LE(lh + 26);
  const lExtraLen = buf.readUInt16LE(lh + 28);
  const dataStart = lh + 30 + lNameLen + lExtraLen;
  const data = buf.subarray(dataStart, dataStart + found.csize);

  if (found.method === 8) return inflateRawSync(data);
  if (found.method === 0) return data;
  throw new Error(`zip: unsupported method ${found.method}`);
}

// Downloads a gzip-compressible text file, decompressing Content-Encoding.
export async function fetchTextWithGzip(url) {
  const res = await fetch(url, {
    headers: { 'Accept-Encoding': 'gzip' },
    signal: AbortSignal.timeout(180000)
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const enc = (res.headers.get('content-encoding') || '').toLowerCase();
  const buf = Buffer.from(await res.arrayBuffer());
  if (enc.includes('gzip')) {
    const { gunzipSync } = await import('node:zlib');
    return gunzipSync(buf).toString('utf8');
  }
  return buf.toString('utf8');
}