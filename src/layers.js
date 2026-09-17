import {
  Viewer,
  Color,
  Cartesian3,
  CustomDataSource,
  PointGraphics,
  UrlTemplateImageryProvider,
  ScreenSpaceEventHandler,
  ScreenSpaceEventType
} from 'cesium';

let viewer = null;
const layers = new Map(); // feedId -> { feed, ds, count }
const propStore = new Map(); // entityId -> plain properties object
let onCount = null;
let onPick = null;

function makeImagery(providerName) {
  if (providerName === 'osm') {
    return new UrlTemplateImageryProvider({
      url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      maximumLevel: 19,
      credit: '© OpenStreetMap contributors'
    });
  }
  // NASA GIBS Blue Marble (EPSG:3857), no key required. Cesium's WMTS provider
  // in 1.145 does not substitute {Layer}/{Format} in REST paths, so use the
  // literal template with UrlTemplateImageryProvider instead.
  return new UrlTemplateImageryProvider({
    url: 'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/BlueMarble_NextGeneration/default/GoogleMapsCompatible_Level8/{z}/{y}/{x}.jpeg',
    maximumLevel: 8,
    credit: 'NASA GIBS'
  });
}

export function initGlobe(appConfig, { onCountUpdate, onPick: pickCb }) {
  onCount = onCountUpdate;
  onPick = pickCb;

  viewer = new Viewer('map', {
    baseLayer: false,
    animation: false,
    timeline: false,
    geocoder: false,
    homeButton: false,
    sceneModePicker: false,
    baseLayerPicker: false,
    navigationHelpButton: false,
    fullscreenButton: false,
    infoBox: false,
    selectionIndicator: false
  });

  viewer.imageryLayers.addImageryProvider(makeImagery(appConfig.imagery || 'nasa'), 0);
  viewer.scene.globe.baseColor = Color.fromCssColorString('#05070c');
  viewer.scene.skyBox.show = false;

  const imgLayer = viewer.imageryLayers.get(0);
  const provider = imgLayer.imageryProvider;
  provider.errorEvent.addEventListener((err) => {
    console.warn('imagery error:', (err && (err.message || err)) || err);
  });
  viewer.scene.renderError.addEventListener((_scene, err) => {
    console.error('scene render error:', err && err.message);
  });

  const home = appConfig.homeView || { longitude: -95, latitude: 35, height: 6000000 };
  viewer.camera.setView({
    destination: Cartesian3.fromDegrees(home.longitude, home.latitude, home.height)
  });

  const handler = new ScreenSpaceEventHandler(viewer.scene.canvas);
  handler.setInputAction((click) => {
    const picked = viewer.scene.pick(click.position);
    const entity = picked && picked.id;
    if (entity && onPick && propStore.has(entity.id)) {
      const props = propStore.get(entity.id);
      const layer = layers.get((entity.id || '').split('|')[0]);
      if (layer) onPick(props, layer.feed);
    }
  }, ScreenSpaceEventType.LEFT_CLICK);

  return viewer;
}

function pointStyle(feed, props, sizeByStat) {
  const style = feed.style || {};
  const color = (() => {
    if (style.colorByProperty && style.colors) {
      const key = String(props[style.colorByProperty]);
      if (style.colors[key]) return Color.fromCssColorString(style.colors[key]);
    }
    return style.color ? Color.fromCssColorString(style.color) : Color.fromCssColorString('#22d3ee');
  })();

  let size = style.size || 5;
  if (style.sizeBy && sizeByStat && sizeByStat.max > sizeByStat.min) {
    const v = Number(props[style.sizeBy]);
    if (Number.isFinite(v)) {
      const lo = style.sizeMin ?? 2;
      const hi = style.sizeMax ?? 10;
      size = lo + ((v - sizeByStat.min) / (sizeByStat.max - sizeByStat.min)) * (hi - lo);
    }
  }

  return {
    pixelSize: Math.max(1.5, size),
    color,
    outlineColor: Color.fromCssColorString('#05070c'),
    outlineWidth: style.outline ? 1 : 0,
    disableDepthTestDistance: Number.POSITIVE_INFINITY
  };
}

export async function addFeed(feed, geojson) {
  removeFeed(feed.id);

  const ds = new CustomDataSource(feed.id);
  const sizeByStat = { min: Infinity, max: -Infinity };

  if (feed.style && feed.style.sizeBy) {
    for (const f of geojson.features) {
      const v = Number(f.properties && f.properties[feed.style.sizeBy]);
      if (Number.isFinite(v)) {
        if (v < sizeByStat.min) sizeByStat.min = v;
        if (v > sizeByStat.max) sizeByStat.max = v;
      }
    }
    if (!Number.isFinite(sizeByStat.min)) { sizeByStat.min = 0; sizeByStat.max = 1; }
  }

  for (let i = 0; i < geojson.features.length; i += 1) {
    const f = geojson.features[i];
    const geo = f.geometry;
    if (!geo || geo.type !== 'Point') continue;
    const [lng, lat, alt = 0] = geo.coordinates;
    const props = f.properties || {};
    const entityId = `${feed.id}|${i}`;

    const entity = ds.entities.add({
      id: entityId,
      position: Cartesian3.fromDegrees(lng, lat, alt),
      point: pointStyle(feed, props, sizeByStat),
      properties: props
    });
    propStore.set(entityId, props);
  }

  if (geojson.features.length > 300) {
    ds.clustering.enabled = true;
    ds.clustering.pixelRange = 40;
    ds.clustering.minimumClusterSize = 2;
    ds.clustering.clusterEvent.addEventListener((_clusteredEntities, cluster) => {
      try {
        cluster.label.text = String(_clusteredEntities.length);
        cluster.label.font = '11px monospace';
        cluster.label.fillColor = Color.WHITE;
        cluster.label.disableDepthTestDistance = Number.POSITIVE_INFINITY;
        cluster.point = new PointGraphics({
          color: Color.fromCssColorString('#22d3ee'),
          pixelSize: 12 + Math.min(10, _clusteredEntities.length),
          outlineColor: Color.BLACK,
          outlineWidth: 2,
          disableDepthTestDistance: Number.POSITIVE_INFINITY
        });
      } catch (err) {
        // never let a styling error break the render loop
        console.warn('cluster styling failed:', err);
      }
    });
  }

  viewer.dataSources.add(ds);
  layers.set(feed.id, { feed, ds, count: ds.entities.values.length });
  if (onCount) onCount(feed);
}

export function removeFeed(feedId) {
  const layer = layers.get(feedId);
  if (layer) {
    viewer.dataSources.remove(layer.ds, true);
    layers.delete(feedId);
  }
  for (const key of [...propStore.keys()]) {
    if (key.startsWith(`${feedId}|`)) propStore.delete(key);
  }
}

export function setFeedVisible(feedId, visible) {
  const layer = layers.get(feedId);
  if (layer) layer.ds.show = visible;
}

export function getFeatureEntity(feedId, index) {
  const layer = layers.get(feedId);
  return layer ? layer.ds.entities.getById(`${feedId}|${index}`) : undefined;
}

export function flyToEntity(feedId, index) {
  const entity = getFeatureEntity(feedId, index);
  if (entity) viewer.zoomTo(entity);
}

export function forceSceneRender() {
  viewer.scene.requestRender();
}