import './cesium-base-url.js';
import 'cesium/Build/Cesium/Widgets/widgets.css';
import './style.css';

import { loadConfig } from './config.js';
import { initGlobe, addFeed, cacheParsed } from './layers.js';
import { setupUI, onCountUpdate, renderNewsFanout, showInfo, setStatus } from './ui.js';
import { loadFeed } from './loader.js';

async function main() {
  setStatus('loading config…');
  let appConfig;
  let feeds;
  try {
    ({ appConfig, feeds } = await loadConfig());
  } catch (err) {
    setStatus(`config error: ${err.message}`);
    return;
  }

  const viewer = initGlobe(appConfig, {
    onCountUpdate,
    onPick: (props, feed) => showInfo(props, feed)
  });

  await setupUI({ feeds, viewer });

  let booted = false;
  for (const feed of feeds) {
    if (feed.enabled === false) continue;
    setStatus(`loading ${feed.name}…`);
    try {
      const { geojson } = await loadFeed(feed);
      cacheParsed(feed, geojson);
      if (!booted) {
        // Exclusive single-layer mode: only the FIRST enabled feed is loaded
        // into the globe resident, so a cold start keeps local memory minimal
        // (large air/sea feeds stay out until the user flips one on).
        booted = true;
        await addFeed(feed, geojson);
      }
      if (feed.newsFeed) renderNewsFanout({ feed, geojson });
      else {
        onCountUpdate({ id: feed.id, name: feed.name, count: geojson.features.length });
      }
    } catch (err) {
      setStatus(`${feed.name} failed: ${err.message}`);
    }
  }

  setStatus('ready');
}

main();