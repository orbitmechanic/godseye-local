// Resolve an approximate "where is this machine on the network" position
// without any API key. GIBS/other imagery needs no key, and neither does this.
// Strategy: (1) browser geolocation (GPS/net tri-lat, best), (2) IP-based
// keyless lookup via ipwho.is, (3) configured homeView fallback.
// Resolved position is cached so repeated Home clicks don't refire the prompt.

let cached = null; // { longitude, latitude, source }

export async function resolveNetworkLocation(homeConfig) {
  if (cached) return cached;

  const fallback = {
    longitude: (homeConfig && homeConfig.longitude) || -95,
    latitude: (homeConfig && homeConfig.latitude) || 35,
    source: 'config'
  };

  // 1) Precise browser location (optional; user may decline - then we keep going).
  const viaBrowser = () =>
    new Promise((resolve) => {
      if (typeof navigator === 'undefined' || !navigator.geolocation) return resolve(null);
      const timer = setTimeout(() => resolve(null), 5000); // don't hang boot on the prompt
      navigator.geolocation.getCurrentPosition(
        (pos) => {
          clearTimeout(timer);
          resolve({ longitude: pos.coords.longitude, latitude: pos.coords.latitude, source: 'browser' });
        },
        () => {
          clearTimeout(timer);
          resolve(null);
        },
        { timeout: 5000, maximumAge: 600000 }
      );
    });

  // 2) Keyless IP geolocation (approximate to city/region level, no prompt).
  const viaIp = async () => {
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 4000);
      const res = await fetch('https://ipwho.is/', { signal: ctrl.signal });
      clearTimeout(timer);
      if (!res.ok) return null;
      const j = await res.json();
      if (!j || !Number.isFinite(j.latitude) || !Number.isFinite(j.longitude)) return null;
      return { longitude: j.longitude, latitude: j.latitude, source: 'ip' };
    } catch {
      return null;
    }
  };

  cached = (await viaBrowser()) || (await viaIp()) || fallback;
  return cached;
}

export function getHomePos() {
  return cached;
}
