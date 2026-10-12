# Ithildin

A local-first geospatial dashboard on a 3D globe — **a native Godot 4 rewrite
of the CesiumJS web app this repo began as** (history preserved; the GitHub
repo was renamed from `godseye-local`). Toggle live-ish snapshot layers (air
traffic, sea traffic, geopolitical events/news from GDELT) and drop in your
*own* data — housing prices, property tax rates, reforestation effort,
whatever — by editing one prettyfied JSON file.

Nothing is real-time and nothing leaves your machine. Daily snapshots are
downloaded on demand by tools you run; the dashboard reads whatever snapshots
are in `data/snapshots/`. The basemap is bundled offline imagery, so the core
app works with no network at all.

## Quick start

```
godot --path .            # or open the project in the Godot 4.7 editor
```

Controls: left-drag rotates the globe, wheel zooms, **⌂** (or boot) jumps to a
north-up 1 000 km view over your network location (keyless `ipwho.is` lookup,
config fallback). Press `/` and paste a GeoJSON/CSV/RSS URL, then Ctrl+Enter,
to load it as a temporary ad-hoc layer. Click any marker or cluster bubble for
details (clusters zoom in).

To pull real snapshot data (air / sea / news):

```
godot --headless --path . -s tools/fetch_news.gd   # GDELT, no key needed
godot --headless --path . -s tools/fetch_air.gd    # OpenSky: every airborne state (~8-12k)
godot --headless --path . -s tools/fetch_sea.gd    # AIS Hub (needs free username)
godot --headless --path . -s tools/fetch_all.gd    # all three
```

They write prettyfied GeoJSON snapshots to `data/snapshots/`.

## The config — where everything is tuned

All tuning happens in human-readable prettyfied JSON under `data/config/`:

- **`app.json`** — globe defaults: imagery (`nasa` | `osm`, both bundled
  offline textures), home camera view, UI flags.
- **`feeds.json`** — the list of layers/feeds. Add, remove, restyle, or point
  any feed at a new URL. This is the file to edit.
- **`secrets.json`** (copy from `secrets.example.json`) — optional free-tier
  API keys; not committed.

### Feed schema (`feeds.json`)

```jsonc
{
  "id": "my-feed",                  // unique id
  "name": "My feed",                // shown in the UI
  "type": "geojson",                // geojson | csv | rss
  "url": "data/snapshots/my.json",  // data file (path under the project, or http(s) URL)
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

`tools/fetch_news.gd` downloads the prior day's GDELT 2.0 event export
(`data.gdeltproject.org/gdeltv2/`, keyless), filters per `feeds.json`, and
writes a prettyfied GeoJSON snapshot to `data/snapshots/news.json`. Each event
becomes a colored globe pin (green = cooperation, red/orange = conflict) and a
row in the news pane; click through to the source article.

## Ad-hoc layers from the app

Press `/` while the app is focused, paste a GeoJSON/CSV/RSS URL, and hit
`Ctrl+Enter` — it loads as a temporary layer (not saved to config).

## Adding your own datasets

Any dataset with coordinates works: find a shapefile/GIS source, convert to
GeoJSON or CSV, place it under `data/` (or fetch it into `data/snapshots/`),
and add an entry to `feeds.json`. Examples: county property-tax rates, median
home price by ZIP, tree-planting site polygons, wildfire perimeters, transit
routes.

## Privacy / attack surface

- Runs entirely on your machine; no accounts required for the core flows.
- The app itself only makes two outbound calls, both keyless and optional:
  the `ipwho.is` home-location lookup (Home button / boot) and any URLs *you*
  paste into the scratchpad or configure. The fetch tools contact the public
  data APIs listed above.
- Your datasets and config stay local; nothing is uploaded.
- Optional free keys (OpenSky, AIS Hub) are stored in `secrets.json`, which is
  gitignored.

## What changed in the Godot port

- The globe is a hand-built equirectangular sphere with two **bundled offline
  basemaps**: Natural Earth II (stitched from the tiles that shipped inside
  Cesium — `tools/build_globe_textures.gd`) and NASA GIBS Blue Marble
  (`tools/build_blue_marble.gd`, one-time download at build time). No tile
  streaming, no Cesium ion, no terrain — the tradeoff for a self-contained
  native binary; `esri`/`nasa`/`osm` config values now select bundled textures.
- Markers are shader-billboarded quads with constant pixel size (MultiMesh's
  instance API is unreliable in 4.7) managed game-engine style: the full
  snapshot lives in CPU-side typed arrays, the geometry is chunked into
  24x12 sphere tiles, and each camera move culls the tiles outside the
  visible limb — ~15% of chunks (and their triangles) reach the GPU, and
  clustering/picking iterate only the points in visible tiles. The 5000-state
  Cesium-era cap is gone; the layer renders the whole fleet (~8-12k) at
  interactive framerates. Screen-space clustering above 300 points and
  nearest-projected picking match the Cesium behavior.
- The browser fetch scripts are headless GDScript tools (`tools/fetch_*.gd`).
- Exclusive single-layer mode (one feed resident at a time) is unchanged.

## Development

```
godot --headless --path . --quit-after 240          # boot smoke test
godot --headless --path . res://tests/Probe.tscn    # logic probe (~45 assertions)
godot --path . res://tests/Shot.tscn                # scripted UI states for review
```

## License

MIT
