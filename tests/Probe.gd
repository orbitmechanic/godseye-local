extends Node
## Headless probe: boots the real Main scene, then asserts ported logic.
## Run: godot --headless --path . -s tests/Probe.gd   (exit 0 + all PASS)

var fails := 0


func ok(cond: bool, label: String, detail := "") -> void:
	if cond:
		print("PASS %s" % label)
	else:
		fails += 1
		print("FAIL %s %s" % [label, detail])


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame

	# Let the boot flow (async feed loading) finish.
	for i in 300:
		await get_tree().process_frame
		if String(App.status_text) == "ready":
			break

	var globe: Node3D = main.globe
	var points: PointCloud = globe.points

	# --- config -------------------------------------------------------------
	ok(App.feeds.size() == 4, "feeds.json loaded", "got %d" % App.feeds.size())
	ok(String(App.app_config.get("imagery", "")) == "esri", "app.json imagery key")

	# --- globe math -----------------------------------------------------------
	var p: Vector3 = globe.latlon_to_xyz(35.0, -95.0)
	ok(absf(p.length() - 1.0) < 1e-6, "latlon_to_xyz unit length", str(p.length()))
	var roundtrip: Vector2 = globe._xyz_to_latlon(p)
	ok(absf(roundtrip.x - 35.0) < 1e-3 and absf(roundtrip.y + 95.0) < 1e-3,
		"latlon->xyz->latlon roundtrip", str(roundtrip))
	var pole: Vector3 = globe.latlon_to_xyz(90.0, 0.0)
	ok(pole.distance_to(Vector3.UP) < 1e-6, "north pole is +Y")
	# Handedness guard: viewed from outside with north up, east must project
	# to the right of the central meridian (a mirror-image globe passes every
	# other geometry test but fails this one).
	var probe_cam := Camera3D.new()
	add_child(probe_cam)
	probe_cam.position = Vector3(0, 0, -2.0)
	probe_cam.look_at(Vector3.ZERO, Vector3.UP)
	var right := probe_cam.global_transform.basis.x
	var east: Vector3 = globe.latlon_to_xyz(0.0, 45.0) - globe.latlon_to_xyz(0.0, 0.0)
	ok(right.dot(east) > 0.5, "east projects to screen-right (non-mirrored)",
		str(right.dot(east)))
	var south_to_north: Vector3 = globe.latlon_to_xyz(45.0, 0.0) - globe.latlon_to_xyz(0.0, 0.0)
	ok(probe_cam.global_transform.basis.y.dot(south_to_north) > 0.5, "north is up",
		str(probe_cam.global_transform.basis.y.dot(south_to_north)))
	probe_cam.queue_free()
	var tex := load("res://assets/imagery/natural_earth_ii.jpg") as Texture2D
	ok(tex != null and tex.get_width() == 2 * tex.get_height(),
		"stitched texture is 2:1 equirectangular")

	# --- exclusive boot -------------------------------------------------------
	ok(App.visible_feed_id == "air", "first enabled feed (air) resident", App.visible_feed_id)
	ok(points._count > 0, "air sample rendered", str(points._count))
	ok(points.feed.get("id", "") == "air", "point layer bound to air feed")

	# --- style port: colorByProperty + sizeBy ramp ----------------------------
	var news_geo: Dictionary = App.parsed_cache.get("news", {})
	ok(not news_geo.is_empty(), "news snapshot parsed")
	if not news_geo.is_empty():
		var news_feed: Dictionary = App.find_feed("news")
		points.set_data(news_feed, news_geo)
		var n: int = news_geo.features.size()
		ok(points._count == n, "news feature -> instance mapping", "%d/%d" % [points._count, n])
		var min_px := INF
		var max_px := -INF
		for i in points._px.size():
			min_px = minf(min_px, points._px[i])
			max_px = maxf(max_px, points._px[i])
		ok(absf(min_px - 2.0) < 1e-3 and absf(max_px - 9.0) < 1e-3,
			"sizeBy ramp hits sizeMin..sizeMax", "%f..%f" % [min_px, max_px])
		var legend := {1: Color(0.2, 0.83, 0.6), 2: Color(0.29, 0.87, 0.5),
			3: Color(0.98, 0.57, 0.24), 4: Color(0.97, 0.44, 0.44)}
		var mismatch := 0
		for i in range(clampi(n, 0, 200)):
			var q := int(points.props_of_instance(i).get("quadClass", 0))
			var expected: Color = legend[q]
			var dcol := points._cols[i] - expected
			if dcol.r * dcol.r + dcol.g * dcol.g + dcol.b * dcol.b > 0.01:
				mismatch += 1
		ok(mismatch == 0, "quadClass color map", "%d mismatches" % mismatch)
		var mentions := 0
		var prev := INF
		var sorted := true
		for f in news_geo.features:
			var m := int(f.properties.mentions)
			if m < prev:
				pass
			elif m > prev:
				sorted = false
			prev = m
			mentions += m
		ok(sorted, "news sorted by mentions desc")
		ok(mentions > 0, "mentions parsed from GDELT data")

	# --- occlusion + projection ----------------------------------------------
	globe.points.clear()
	var synthetic := {"type": "FeatureCollection", "features": [
		{"type": "Feature", "geometry": {"type": "Point", "coordinates": [0.0, 0.0]},
			"properties": {"name": "near"}},
		{"type": "Feature", "geometry": {"type": "Point", "coordinates": [180.0, 0.0]},
			"properties": {"name": "far"}},
	]}
	var feed2 := {id = "synth", name = "synth", style = {}}
	globe.points.set_data(feed2, synthetic)
	globe.set_view(0.0, 0.0, 2.0, true)
	await get_tree().process_frame
	var cam: Camera3D = globe.camera
	var vs := Vector2(1400, 900)
	var sp0: Dictionary = globe.points._project(cam, globe.points.world_pos(0), vs)
	ok(not sp0.is_empty(), "front hemisphere point projects")
	ok(globe.points._project(cam, globe.points.world_pos(1), vs).is_empty(),
		"back hemisphere point hidden")
	var hit: int = globe.points.pick(cam, vs, Vector2(sp0.x, sp0.y))
	ok(hit == 0, "center pick finds near point", str(hit))
	globe.set_view(180.0, 0.0, 2.0, true)
	var sp1: Dictionary = globe.points._project(cam, globe.points.world_pos(1), vs)
	ok(not sp1.is_empty(), "back point becomes front after turning the globe")
	var hit2: int = globe.points.pick(cam, vs, Vector2(sp1.x, sp1.y))
	ok(hit2 == 1, "turning the globe re-targets the pick", str(hit2))

	# --- clustering ------------------------------------------------------------
	var many := {"type": "FeatureCollection", "features": []}
	for i in 500:
		many.features.append({
			"type": "Feature",
			"geometry": {"type": "Point",
				"coordinates": [-95.0 + float(i % 10) * 0.001, 35.0 + float(i / 10) * 0.001]},
			"properties": {"name": "p%d" % i},
		})
	var feed3 := {id = "many", name = "many", style = {}}
	globe.points.set_data(feed3, many)
	ok(globe.points.clustered(), "500 points triggers clustering")
	globe.set_view(-95.0, 35.0, 1.1, true)
	var cells: Array = globe.points.cluster_cells(globe.camera, Vector2(1400, 900))
	var total := 0
	for c in cells:
		total += int(c.count)
	ok(cells.size() >= 1 and total > 100, "cluster cells cover the dense patch",
		"%d cells, %d points" % [cells.size(), total])

	# --- csv port -------------------------------------------------------------
	var csv_text := FileAccess.get_file_as_string("res://data/samples/housing-sample.csv")
	var conv: Dictionary = CSV.to_geojson(csv_text, {lat = "lat", lon = "lon", name = "place"})
	ok(conv.ok and (conv.geojson.features as Array).size() >= 10, "csv -> geojson", conv.error)
	var first: Dictionary = (conv.geojson.features as Array)[0]
	ok(first.properties.medianPriceUsd is float, "csv numeric property typed",
		type_string(typeof(first.properties.medianPriceUsd)))
	ok(String(first.properties.get("name", "")) != "", "csv name column mapped")
	var bad := CSV.to_geojson(csv_text, {lat = "nope", lon = "nope2"})
	ok(not bad.ok, "csv missing columns errors")

	# --- rss port -------------------------------------------------------------
	var rss_text := """<?xml version="1.0"?><rss><channel>
	<item><title>A</title><link>http://x</link><geo:lat>48.85</geo:lat><geo:long>2.35</geo:long></item>
	<item><title>B</title></item>
	</channel></rss>"""
	var rss: Dictionary = main.loader._rss_to_geojson(rss_text, {geo = {lat = 10.0, lng = 20.0}})
	ok((rss.features as Array).size() == 2, "rss items parsed", str(rss.features.size()))
	var c0: Array = rss.features[0].geometry.coordinates
	ok(absf(c0[0] - 2.35) < 1e-4 and absf(c0[1] - 48.85) < 1e-4, "georss coordinates")
	var c1: Array = rss.features[1].geometry.coordinates
	ok(absf(c1[1] - 10.0) < 1e-4, "feed-level geo fallback")

	# --- feed state: exclusivity ----------------------------------------------
	App.set_feed_visible("news", true)
	ok(App.visible_feed_id == "news", "exclusive: turning news on")
	App.set_feed_visible("sea", true)
	ok(App.visible_feed_id == "sea", "exclusive: turning sea on tears down others")
	ok(points.feed.get("id", "") == "sea" or points._count == 0,
		"exclusive: only one layer resident", String(points.feed.get("id", "")))
	App.set_feed_visible("sea", false)
	ok(App.visible_feed_id == "" and points._count == 0, "turning off frees the layer")

	# --- gdelt row port ---------------------------------------------------------
	var cols := PackedStringArray()
	cols.resize(61)
	for i in cols.size():
		cols[i] = ""
	cols[0] = "769228563"
	cols[6] = "UNITED STATES"
	cols[16] = "CHINA"
	cols[31] = "12"   # mentions: D-29? use relative math below instead
	cols[33] = "7"
	cols[36] = "-3.5"
	cols[52] = "BEIJING, CHINA"
	cols[54] = "CN"
	cols[57] = "39.90"
	cols[58] = "116.40"
	cols[59] = "20261010120000"  # D (14 digits)
	cols[60] = "https://example.com/article"
	cols[1] = "20261010"  # OFFSET.day = 1
	# Relative positions from D=59: quad=-30 -> 29, mentions=-28 -> 31, tone=-25 -> 34,
	# place=-7 -> 52, country=-6 -> 53, lat=-3 -> 56, lon=-2 -> 57, url=+1 -> 60.
	cols[29] = "4"
	cols[31] = "12"
	cols[34] = "-3.5"
	cols[53] = "CN"
	cols[56] = "39.90"
	cols[57] = "116.40"
	var lib: Node = load("res://tools/fetch_lib.gd").new()
	add_child(lib)
	var row: Variant = lib._filter_row(cols, {keywords = [], min_mentions = 5, quad_mode = "all"})
	ok(row != null, "gdelt row kept")
	if row != null:
		var fp: Dictionary = row.feature.properties
		ok(fp.quadClass == 4 and fp.mentions == 12, "gdelt offsets quad/mentions")
		ok(absf(row.feature.geometry.coordinates[0] - 116.40) < 1e-3, "gdelt lon")
		ok(absf(row.feature.geometry.coordinates[1] - 39.90) < 1e-3, "gdelt lat")
		ok(str(fp.sourceUrl) == "https://example.com/article", "gdelt source url")
		ok(str(fp.date) == "2026-10-10", "gdelt date", str(fp.date))
		ok(str(fp.actor1) == "UNITED STATES", "gdelt actor1")

	# --- helpers --------------------------------------------------------------
	var iso: String = lib.iso_date(0)
	ok(iso.length() == 8 and iso.is_valid_int(), "iso_date yyyymmdd", iso)
	lib.free()
	ok(PointCloud._key_str(4.0) == "4", "float key normalized for color map")
	var c := PointCloud._css_color("#22d3ee", Color.BLACK)
	ok(absf(c.r - 34.0 / 255.0) < 0.01, "css hex color parse", str(c))
	ok(PointCloud._css_color("bogus", Color.RED) == Color.RED, "css color fallback")

	print("PROBE %s (%d failures)" % ["OK" if fails == 0 else "FAILED", fails])
	get_tree().quit(0 if fails == 0 else 1)
