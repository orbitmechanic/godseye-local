extends Node
## Central registry: app config, feed definitions, parsed-snapshot cache and
## the exclusive single-layer visibility rule (one feed resident at a time).

signal status_changed(text: String)
signal feed_toggled(feed_id: String, visible: bool)
signal layer_count_changed(feed_id: String, count: int)

const EARTH_RADIUS_KM := 6371.0

var app_config: Dictionary = {}
var feeds: Array = []
var parsed_cache: Dictionary = {}  # feed_id -> geojson Dictionary
var visible_feed_id: String = ""
var status_text := ""


func load_config() -> Error:
	var app_text := FileAccess.get_file_as_string("res://data/config/app.json")
	var feeds_text := FileAccess.get_file_as_string("res://data/config/feeds.json")
	var app_data: Variant = JSON.parse_string(app_text)
	var feeds_data: Variant = JSON.parse_string(feeds_text)
	if typeof(app_data) != TYPE_DICTIONARY:
		push_error("app.json missing or invalid")
		return ERR_CANT_OPEN
	if typeof(feeds_data) != TYPE_ARRAY:
		push_error("feeds.json missing or not an array")
		return ERR_CANT_OPEN
	app_config = app_data
	feeds = feeds_data
	return OK


func find_feed(id: String) -> Dictionary:
	for feed in feeds:
		if feed.get("id", "") == id:
			return feed
	return {}


func cache_parsed(feed_id: String, geojson: Dictionary) -> void:
	parsed_cache[feed_id] = geojson


func set_feed_visible(feed_id: String, visible: bool) -> void:
	if visible:
		visible_feed_id = feed_id
	elif visible_feed_id == feed_id:
		visible_feed_id = ""
	feed_toggled.emit(feed_id, visible)


func status(text: String) -> void:
	status_text = text
	status_changed.emit(text)
