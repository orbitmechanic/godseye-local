extends Node
## Boot flow, mirroring src/main.js: load config -> init globe -> wire UI ->
## load enabled feeds (exclusive single-layer boot) -> network-location home.

@onready var globe: Node3D = $Globe
@onready var loader: Node = $Loader
@onready var geo: Node = $Geo
@onready var ui: CanvasLayer = $UI


func _ready() -> void:
	geo.loader = loader
	ui.loader = loader
	ui.globe = globe
	globe.geo = geo

	App.status("loading config…")
	if App.load_config() != OK:
		App.status("config error: check data/config/app.json and data/config/feeds.json")
		return
	globe.setup(App.app_config)
	ui.setup(App.feeds)
	App.feed_toggled.connect(_on_feed_toggled)

	await _boot_feeds()
	globe.reset_home()


func _boot_feeds() -> void:
	var booted := false
	for feed in App.feeds:
		if feed.get("enabled", true) == false:
			continue
		var id := String(feed.get("id", ""))
		var name := String(feed.get("name", id))
		App.status("loading %s…" % name)
		var res: Dictionary = await loader.load_feed(feed)
		if not res.ok:
			App.status("%s failed: %s" % [name, res.error])
			continue
		App.cache_parsed(id, res.geojson)
		var count := (res.geojson.get("features", []) as Array).size()
		ui.set_count(id, count)
		if not booted:
			# Exclusive single-layer mode: only the FIRST enabled feed is made
			# resident on the globe, so a cold start keeps local memory minimal.
			booted = true
			App.set_feed_visible(id, true)
		if feed.get("newsFeed") == true:
			ui.render_news(feed, res.geojson)
	App.status("ready")


func _on_feed_toggled(feed_id: String, visible: bool) -> void:
	if visible:
		var feed: Dictionary = App.find_feed(feed_id)
		var geojson: Dictionary = App.parsed_cache.get(feed_id, {})
		if not geojson.is_empty():
			globe.points.set_data(feed, geojson)
		else:
			globe.points.clear()
	else:
		# Turning a feed OFF fully destroys its geometry, like the web app's
		# ds.remove(ds, true): hidden feeds cost ~zero resident memory.
		globe.points.clear()
	ui.sync_checkboxes(App.visible_feed_id)
