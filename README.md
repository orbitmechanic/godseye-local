# Godseye Local

A local-first geospatial dashboard on a 3D globe. Toggle live-ish snapshot layers
(air traffic, sea traffic, geopolitical events/news from GDELT) and drop in your
*own* data — housing prices, property tax rates, reforestation effort, whatever —
by editing one prettyfied JSON file.

Nothing is real-time and nothing leaves your machine. Daily snapshots are
downloaded on demand by scripts you run (`npm run fetch`); the dashboard reads
whatever snapshots are in `public/data/snapshots/`.

## Quick start

```
npm install
npm run dev          # -> http://127.0.0.1:5173
```

To pull real snapshot data (air / sea / news):

```
npm run fetch:news              # GDELT, no key needed
npm run fetch:air               # OpenSky Network (add free key for reliability)
npm run fetch:sea               # AIS Hub (add free key)
npm run fetch                   # all three
```

## The config — where everything is tuned

All tuning happens in human-readable prettyfied JSON under `public/config/`:

- **`app.json`** — globe defaults: imagery (`nasa` | `osm`), home camera view, UI flags.
- **`feeds.json`** — the list of layers/feeds. Add, remove, restyle, or point any
  feed at a new URL. This is the file to edit.
- **`secrets.json`** (copy from `secrets.example.json`) — optional free-tier API
  keys; not committed.

### Feed schema (`feeds.json`)

```jsonc
{
  "id": "my-feed",                  // unique id
  "name": "My feed",                // shown in the UI
  "type": "geojson",                // geojson | csv | rss
  "url": "data/snapshots/my.json",  // data file (served from public/)
  "sampleUrl": "data/samples/my.geojson", // fallback if url is missing
  "enabled": true,
  "clickable": true,                // show info card on click
  "newsFeed": true,                 // also list items in the NEWS pane
  "columns": { "lat": "lat", "lon": "lon", "name": "place" }, // csv only
  "style": {
    "color": "#22d3ee",
    "size": 5,
    "sizeBy": "altitude",           // optional: scale size by a numeric property
    "sizeMin": 2, "sizeMax": 10,
    "outline": true,
    "colorByProperty": "quadClass", // optional: color by a property value map
    "colors": { "1": "#34d399", "4": "#f87171" },
    "legend": { "1": "Cooperation", "4": "Conflict" }
  },
  "popup": [                        // what to show in the click card
    { "label": "Callsign", "property": "callsign" },
    { "label": "Article", "property": "sourceUrl", "url": true }
  ],
  "source": { "type": "gdelt", "keywords": [], "minMentions": 5, "maxResults": 1500, "quadClass": "all", "lagDays": 1 }
}
```

Supported feed types:

- **geojson** — any GeoJSON `FeatureCollection` of points. 
- **csv** — lat/lon columns specified in `columns`; all other columns become popup properties.
- **rss** — any RSS/Atom feed with `geo:lat`/`geo:long` per item (or a feed-level `geo` in the feed object).

The `source.gdelt` block tunes the news snapshot: keywords filter actor/place
names, `minMentions` drops weak events, `quadClass` picks cooperation (1–2) vs
conflict (3–4) vs `all`, `lagDays` allows a delay (day-of lag is fine).

### GDELT news feed

`npm run fetch:news` downloads the prior day's GDELT 2.0 event export
(`data.gdeltproject.org/gdeltv2/`, keyless), filters per `feeds.json`, and writes
a prettyfied GeoJSON snapshot to `public/data/snapshots/news.json`. Each event
becomes a colored globe pin (green = cooperation, red/orange = conflict) and a
row in the news pane; click through to the source article.

## Ad-hoc layers from the app

Press `/` while the app is focused, paste a GeoJSON/CSV/RSS URL, and hit
`Ctrl+Enter` — it loads as a temporary layer (not saved to config).

## Adding your own datasets

Any dataset with coordinates works: find a shapefile/GIS source, convert to
GeoJSON or CSV, place it under `public/data/` (or fetch it into
`public/data/snapshots/`), and add an entry to `feeds.json`. Examples: county
property-tax rates, median home price by ZIP, tree-planting site polygons,
wildfire perimeters, transit routes.

## Privacy / attack surface

- Runs entirely on `127.0.0.1`. No accounts required for the core flows.
- Snapshot scripts only make outbound HTTPS (HTTP for GDELT) calls to public APIs when you run `npm run fetch`.
- Your datasets and config stay local; nothing is uploaded.
- Optional free keys (OpenSky, AIS Hub) are stored in `secrets.json`, which is gitignored.

## License

MIT