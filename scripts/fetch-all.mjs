import { fetchAir } from './fetch-air.mjs';
import { fetchSea } from './fetch-sea.mjs';
import { fetchNews } from './fetch-news.mjs';
import { writeSnapshot } from './lib/util.mjs';

const results = await Promise.allSettled([fetchAir(), fetchSea(), fetchNews()]);

const nameOf = ['air', 'sea', 'news'];
results.forEach((r, i) => {
  if (r.status === 'fulfilled' && r.value) {
    try {
      writeSnapshot(`${nameOf[i]}.json`, r.value);
    } catch (err) {
      process.stdout.write(`${nameOf[i]}: write failed: ${err.message}\n`);
    }
  } else if (r.status === 'rejected') {
    process.stdout.write(`${nameOf[i]}: ${r.reason && r.reason.message}\n`);
  }
});