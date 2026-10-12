extends Node
## Feed data loading: local res:// files or remote http(s) URLs, in the three
## supported formats (geojson | csv | rss). Ported from src/loader.js.

const CSV := preload("res://scripts/csv.gd")


func http_get(url: String, headers: PackedStringArray = PackedStringArray(), timeout: float = 45.0) -> Dictionary:
	# Returns {ok: bool, code: int, text: String, error: String}.
	var req := HTTPRequest.new()
	req.timeout = timeout
	add_child(req)
	req.request(url, headers)
	var args: Array = await req.request_completed
	req.queue_free()
	var result := int(args[0])
	var code := int(args[1])
	var body: PackedByteArray = args[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {ok = false, code = code, text = "", error = "GET %s -> transport error %s" % [url, result]}
	if code < 200 or code >= 300:
		return {ok = false, code = code, text = "", error = "GET %s -> %s" % [url, code]}
	return {ok = true, code = code, text = body.get_string_from_utf8(), error = ""}


func load_feed(feed: Dictionary) -> Dictionary:
	# Mirrors loader.js: try feed.url, then feed.sampleUrl.
	# Returns {ok, geojson: Dictionary, url: String, error: String}.
	var errors := PackedStringArray()
	for key in ["url", "sampleUrl"]:
		var url := String(feed.get(key, ""))
		if url == "":
			continue
		var res := await _load_url(feed, url)
		if res.ok:
			return res
		errors.append("%s: %s" % [url, res.error])
	return {
		ok = false, geojson = {}, url = "",
		error = " | ".join(errors) if errors.size() > 0 else "no url configured"
	}


func _fetch_text(url: String) -> Dictionary:
	if url.begins_with("http://") or url.begins_with("https://"):
		return await http_get(url)
	var path := url if url.begins_with("res://") else "res://" + url
	if not FileAccess.file_exists(path):
		return {ok = false, code = 404, text = "", error = "GET %s -> missing" % url}
	return {ok = true, code = 200, text = FileAccess.get_file_as_string(path), error = ""}


func _load_url(feed: Dictionary, url: String) -> Dictionary:
	var res := await _fetch_text(url)
	if not res.ok:
		return {ok = false, geojson = {}, url = url, error = res.error}
	var geojson: Variant
	match String(feed.get("type", "geojson")):
		"csv":
			var conv: Dictionary = CSV.to_geojson(res.text, feed.get("columns", {}))
			if not conv.ok:
				return {ok = false, geojson = {}, url = url, error = conv.error}
			geojson = conv.geojson
		"rss":
			geojson = _rss_to_geojson(res.text, feed)
		_:
			geojson = JSON.parse_string(res.text)
	if typeof(geojson) != TYPE_DICTIONARY or not (geojson as Dictionary).has("features"):
		return {ok = false, geojson = {}, url = url, error = "not a FeatureCollection"}
	if typeof((geojson as Dictionary).get("features")) != TYPE_ARRAY:
		return {ok = false, geojson = {}, url = url, error = "not a FeatureCollection"}
	return {ok = true, geojson = geojson, url = url, error = ""}


func _rss_to_geojson(text: String, feed: Dictionary) -> Dictionary:
	# GeoRSS subset: <item><title/><link/><pubDate/> and optional <geo:lat>/<geo:long>.
	# Falls back to the feed-level `geo` {lat, lng} block. Ported from loader.js.
	var parser := XMLParser.new()
	if parser.open_buffer(text.to_utf8_buffer()) != OK:
		return {"type": "FeatureCollection", "features": []}
	var feed_geo: Variant = feed.get("geo")
	var features: Array = []
	var in_item := false
	var tag := ""
	var buf := ""
	var item := {}
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				tag = parser.get_node_name()
				buf = ""
				if tag == "item":
					in_item = true
					item = {}
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if in_item:
					buf += parser.get_node_data()
			XMLParser.NODE_ELEMENT_END:
				var name := parser.get_node_name()
				if not in_item:
					continue
				match name:
					"title", "link", "pubDate":
						item[name] = buf.strip_edges()
					"geo:lat", "geo:long":
						if name == "geo:lat":
							item["_lat"] = buf.strip_edges()
						else:
							item["_lng"] = buf.strip_edges()
					"item":
						var lat := String(item.get("_lat", "")).to_float()
						var lng := String(item.get("_lng", "")).to_float()
						var has_coord := String(item.get("_lat", "")) != "" and String(item.get("_lng", "")) != ""
						if not has_coord and feed_geo is Dictionary:
							lat = float((feed_geo as Dictionary).get("lat", 0.0))
							lng = float((feed_geo as Dictionary).get("lng", 0.0))
							has_coord = true
						if has_coord:
							features.append({
								"type": "Feature",
								"geometry": {"type": "Point", "coordinates": [lng, lat]},
								"properties": {
									title = item.get("title", ""),
									link = item.get("link", ""),
									pubDate = item.get("pubDate", ""),
								}
							})
						in_item = false
	return {"type": "FeatureCollection", "features": features}
