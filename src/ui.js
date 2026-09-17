import { flyToEntity } from './layers.js';
import { loadFeed } from './loader.js';
import { addFeed, setFeedVisible } from './layers.js';

const counts = new Map(); // feedId -> entity count
const newsIndex = new Map(); // row key -> { feedId, index }

export async function setupUI({ feeds, viewer }) {
  buildLayerList(feeds);
  startClock();
  bindScratchpad();
  bindInfoClose();
  setStatus('ready');
}

function buildLayerList(feeds) {
  const listEl = document.getElementById('layerList');
  listEl.innerHTML = '';

  for (const feed of feeds) {
    const row = document.createElement('label');
    row.className = 'layerRow';

    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = feed.enabled !== false;
    cb.addEventListener('change', () => {
      setFeedVisible(feed.id, cb.checked);
    });

    const sw = document.createElement('span');
    sw.className = 'swatch';
    sw.style.background = feed.style?.color || '#22d3ee';

    const name = document.createElement('span');
    name.className = 'lname';
    name.textContent = feed.name;

    const cnt = document.createElement('span');
    cnt.className = 'lcount';
    cnt.textContent = feedsEntryCount(feed.id);

    row.append(cb, sw, name, cnt);
    listEl.appendChild(row);
  }
}

function feedsEntryCount(feedId) {
  const n = counts.get(feedId);
  return n === undefined ? '—' : String(n);
}

export function onCountUpdate(feed) {
  counts.set(feed.id, feed.count ?? 0);
  const rows = [...document.querySelectorAll('#layerList .layerRow')];
  for (const row of rows) {
    const name = row.querySelector('.lname')?.textContent;
    if (name === feed.name) {
      row.querySelector('.lcount').textContent = String(counts.get(feed.id));
    }
  }
}

// Populate the news/events feed pane. Listens to a "newsFeed" feed's entities.
export function renderNewsFanout(payload) {
  const { feed, geojson } = payload;
  const listEl = document.getElementById('newsList');
  if (feed.newsFeed !== true) return;
  listEl.innerHTML = '';
  newsIndex.clear();

  const popupProps = feed.popup || [];
  const titleFor = (p) => {
    const actor = popupProps.find((x) => x.property === 'actor1');
    const tgt = popupProps.find((x) => x.property === 'actor2');
    const a = actor && p[actor.property];
    const b = tgt && p[tgt.property];
    return a && b ? `${a} ↔ ${b}` : p.name || p.title || feed.name;
  };

  geojson.features.forEach((f, index) => {
    const p = f.properties || {};
    const row = document.createElement('div');
    row.className = 'newsRow';

    const titleEl = document.createElement('div');
    titleEl.className = 't';
    titleEl.textContent = titleFor(p);

    const meta = document.createElement('div');
    meta.className = 'm';
    const cls = p.quadClass;
    const tone = p.tone !== undefined ? ` · tone ${p.tone}` : '';
    meta.textContent = `${p.date || ''}${tone}${cls ? ` · class ${cls}` : ''}`;

    row.append(titleEl, meta);
    row.addEventListener('click', () => {
      showInfo(p, feed);
      flyToEntity(feed.id, index);
    });

    newsIndex.set(`${feed.id}:${index}`, { feedId: feed.id, index });
    listEl.appendChild(row);
  });
}

export function showInfo(props, feed) {
  const info = document.getElementById('info');
  const body = document.getElementById('infoBody');
  info.classList.remove('hidden');

  const feedName = feed.name || '';
  const rows = (feed.popup || []).map((def) => {
    const v = props[def.property];
    if (v === undefined || v === null || v === '') return '';
    let html = `<div class="infoRow"><span class="k">${def.label}</span>`;
    if (def.url) {
      html += `<span class="v"><a href="${escapeAttr(v)}" target="_blank" rel="noopener">open</a></span>`;
    } else {
      html += `<span class="v">${escapeHtml(String(v))}</span>`;
    }
    return html + '</div>';
  }).join('');

  body.innerHTML = `
    <h3>${escapeHtml(feedName)}</h3>
    ${rows}
    ${legendHtml(feed)}
  `;
}

function legendHtml(feed) {
  const style = feed.style || {};
  if (!style.legend) return '';
  return `<div class="legend">${Object.entries(style.legend).map(
    ([k, label]) => `<div class="lg"><span class="swatch" style="background:${style.colors[k] || '#999'}"></span>${escapeHtml(label)}</div>`
  ).join('')}</div>`;
}

function bindInfoClose() {
  document.getElementById('infoClose').addEventListener('click', () => {
    document.getElementById('info').classList.add('hidden');
  });
}

function startClock() {
  const el = document.getElementById('clock');
  const tick = () => {
    const d = new Date();
    el.textContent = d.toISOString().replace('T', ' ').slice(0, 19) + 'Z';
  };
  tick();
  setInterval(tick, 1000);
}

function bindScratchpad() {
  const pad = document.getElementById('scratchpad');
  const ta = document.getElementById('scratch');
  let active = false;

  window.addEventListener('keydown', (e) => {
    if (!active && e.key === '/' && e.target === document.body) {
      e.preventDefault();
      active = true;
      pad.classList.add('active');
      ta.focus();
    } else if (active && e.key === 'Escape') {
      active = false;
      pad.classList.remove('active');
      ta.value = '';
    }
  });

  ta.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.ctrlKey) {
      e.preventDefault();
      const url = ta.value.trim();
      if (!url) return;
      ta.value = '';
      active = false;
      pad.classList.remove('active');
      addAdhocFeed(url);
    }
  });
}

async function addAdhocFeed(url) {
  const guessedType = /\.csv(\?|$)/i.test(url) ? 'csv' : /(\.xml|\.rss|\.rdf|feed=)/i.test(url) ? 'rss' : 'geojson';
  const feed = {
    id: 'adhoc-' + Math.random().toString(36).slice(2, 8),
    name: url.replace(/^https?:\/\//, '').slice(0, 42),
    type: guessedType,
    url,
    enabled: true,
    clickable: true
  };
  setStatus(`loading ad-hoc feed ${feed.name}…`);
  try {
    const { geojson } = await loadFeed(feed);
    await addFeed(feed, geojson);
    onCountUpdate({ id: feed.id, name: feed.name, count: geojson.features.length });
    setStatus(`ad-hoc feed loaded: ${feed.name} (${geojson.features.length})`);
  } catch (err) {
    setStatus(`ad-hoc feed failed: ${err.message}`);
  }
}

export function setStatus(text) {
  document.getElementById('statusText').textContent = text;
  document.title = `Godseye Local — ${text}`;
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function escapeAttr(s) {
  return String(s).replace(/"/g, '&quot;').replace(/&/g, '&amp;');
}