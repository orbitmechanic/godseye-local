let appConfig = null;
let feeds = [];

export async function loadConfig() {
  const [app, feedList] = await Promise.all([
    fetch('/config/app.json').then((r) => r.json()),
    fetch('/config/feeds.json').then((r) => r.json())
  ]);
  appConfig = app;
  feeds = feedList;
  return { appConfig, feeds };
}

export function getApp() {
  return appConfig;
}

export function getFeeds() {
  return feeds;
}

export function findFeed(id) {
  return feeds.find((f) => f.id === id);
}