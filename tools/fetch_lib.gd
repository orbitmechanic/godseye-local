extends Node
## Shared plumbing for the headless snapshot fetchers:
##   godot --headless --path . -s tools/fetch_news.gd
## Ported from scripts/*.mjs + scripts/lib/*.mjs (Node -> GDScript).

const GDELT := "https://data.gdeltproject.org/gdeltv2/"
const MASTER_CACHE := "res://.cache/gdelt-masterfilelist.txt"

# GDELT export files are TAB-delimited, 61 columns, NO header row. Offsets are
# relative to the DATEADDED field (the last 14-digit timestamp in the row),
# exactly as validated in the original web app.
const OFFSET := {
	day = 1,             # SQLDATE (absolute)
	actor1Name = 6,      # absolute
	actor2Name = 16,     # absolute
	quad = -30,          # QuadClass
	mentions = -28,      # NumMentions
	tone = -25,          # AvgTone
	place = -7,          # ActionGeo_FullName
	country = -6,        # ActionGeo_CountryCode
	lat = -3,            # ActionGeo_Lat
	lon = -2,            # ActionGeo_Long
	url = 1,             # SOURCEURL = DATEADDED + 1
}


func http_get(url: String, headers: PackedStringArray = PackedStringArray(), timeout: float = 45.0) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = timeout
	add_child(req)
	req.request(url, headers)
	var args: Array = await req.request_completed
	req.queue_free()
	if int(args[0]) != HTTPRequest.RESULT_SUCCESS:
		return {ok = false, code = 0, bytes = PackedByteArray(), error = "transport error %s" % args[0]}
	var code := int(args[1])
	if code < 200 or code >= 300:
		return {ok = false, code = code, bytes = PackedByteArray(), error = "HTTP %s" % code}
	return {ok = true, code = code, bytes = args[3], error = ""}


func read_secrets() -> Dictionary:
	var path := "res://data/config/secrets.json"
	if not FileAccess.file_exists(path):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if typeof(data) == TYPE_DICTIONARY else {}


func read_feeds() -> Array:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/feeds.json"))
	return data if typeof(data) == TYPE_ARRAY else []


func write_snapshot(name: String, geojson: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute("res://data/snapshots")
	var file := FileAccess.open("res://data/snapshots/" + name, FileAccess.WRITE)
	file.store_string(JSON.stringify(geojson, "  "))
	file.close()
	print("wrote data/snapshots/%s (%d points)" % [name, (geojson.get("features", []) as Array).size()])


func iso_date(days_ago: int) -> String:
	var t := Time.get_unix_time_from_system() - float(days_ago) * 86400.0
	var d := Time.get_datetime_dict_from_unix_time(int(t))
	return "%04d%02d%02d" % [d.year, d.month, d.day]


func round_to(v: float, digits: int) -> float:
	var f := pow(10.0, digits)
	return roundf(v * f) / f


# --------------------------------------------------------------------- air
func fetch_air() -> Variant:
	var secrets := read_secrets()
	var opensky: Dictionary = secrets.get("opensky", {})
	var username := String(opensky.get("username", ""))
	var password := String(opensky.get("password", ""))
	var url := "https://opensky-network.org/api/states/all"
	var headers := PackedStringArray()
	if username != "" and password != "":
		headers.append("Authorization: Basic " + Marshalls.utf8_to_base64(username + ":" + password))

	var res := await http_get(url, headers, 45.0)
	if not res.ok:
		if int(res.code) == 401 or int(res.code) == 403:
			print("air: OpenSky returned %s (anonymous access limited). Add a free opensky account to data/config/secrets.json, or keep the sample layer." % res.code)
		else:
			print("air: %s" % res.error)
		return null

	var payload: Variant = JSON.parse_string(res.bytes.get_string_from_utf8())
	if typeof(payload) != TYPE_DICTIONARY:
		return null
	var states: Variant = (payload as Dictionary).get("states")
	if typeof(states) != TYPE_ARRAY:
		return null

	var features: Array = []
	for s in states:
		if typeof(s) != TYPE_ARRAY or s.size() < 15:
			continue
		if s[5] == null or s[6] == null:
			continue
		var props := {
			callsign = String(s[1]).strip_edges() if s[1] != null else null,
			originCountry = s[2],
			altitude = null,
			velocity = round_to(float(s[9]), 1) if s[9] != null else null,
			track = int(roundf(float(s[10]))) if s[10] != null else null,
			onGround = bool(s[8]) == true,
			category = s[17] if s.size() > 17 else null,
		}
		if s[7] != null:
			props.altitude = int(roundf(float(s[7])))
		elif s.size() > 13 and s[13] != null:
			props.altitude = int(roundf(float(s[13])))
		features.append({
			type = "Feature",
			geometry = {type = "Point", coordinates = [round_to(float(s[5]), 4), round_to(float(s[6]), 4)]},
			properties = props,
		})
	features.sort_custom(func(a, b): return _alt_of(a) > _alt_of(b))
	if features.size() > 5000:
		features.resize(5000)
	print("air: OpenSky snapshot (%d states)" % features.size())
	return {
		type = "FeatureCollection",
		features = features,
		meta = {source = "opensky", fetchedAt = Time.get_datetime_string_from_system(true)},
	}


func _alt_of(f) -> float:
	return float(f.properties.altitude) if f.properties.altitude != null else 0.0


# --------------------------------------------------------------------- sea
func fetch_sea() -> Variant:
	var secrets := read_secrets()
	var username := String((secrets.get("aishub", {}) as Dictionary).get("username", ""))
	if username == "":
		print("sea: no aishub.username in secrets.json — skipping. Sample layer stays active.")
		return null
	var url := "https://data.aishub.net/ws.php?username=%s&format=1&output=json" % username.uri_encode()
	var res := await http_get(url, PackedStringArray(), 45.0)
	if not res.ok:
		print("sea: %s" % res.error)
		return null
	var payload: Variant = JSON.parse_string(res.bytes.get_string_from_utf8())
	if typeof(payload) != TYPE_DICTIONARY:
		return null
	var ships: Variant = (payload as Dictionary).get("data", (payload as Dictionary).get("LIST"))
	if typeof(ships) != TYPE_ARRAY:
		return null
	var features: Array = []
	for s in ships:
		if typeof(s) != TYPE_DICTIONARY:
			continue
		var lon := String(s.get("LON", "")).to_float()
		var lat := String(s.get("LAT", "")).to_float()
		if lon == 0.0 or lat == 0.0:
			continue
		features.append({
			type = "Feature",
			geometry = {type = "Point", coordinates = [round_to(lon, 4), round_to(lat, 4)]},
			properties = {
				name = s.get("NAME", s.get("name", s.get("SHIPNAME", null))),
				mmsi = s.get("MMSI"),
				type = s.get("TYPE"),
				destination = s.get("DESTINATION", s.get("destination", null)),
				speed = round_to(float(s.get("SPEED", 0)), 1) if s.get("SPEED") != null else null,
				heading = int(roundf(float(s.get("HEADING", 0)))) if s.get("HEADING") != null else null,
				flag = s.get("FLAG", s.get("flag", null)),
			}
		})
	print("sea: AISHub snapshot (%d vessels)" % features.size())
	return {
		type = "FeatureCollection",
		features = features,
		meta = {source = "aishub", fetchedAt = Time.get_datetime_string_from_system(true)},
	}


# -------------------------------------------------------------------- news
func _master_index() -> PackedStringArray:
	var ttl := 12.0 * 3600.0
	if FileAccess.file_exists(MASTER_CACHE):
		var age := Time.get_unix_time_from_system() - FileAccess.get_modified_time(MASTER_CACHE)
		if age < ttl:
			return FileAccess.get_file_as_string(MASTER_CACHE).split("\n")
	var res := await http_get(GDELT + "masterfilelist.txt", PackedStringArray(), 180.0)
	if not res.ok:
		push_error("news: master index fetch failed: %s" % res.error)
		return PackedStringArray()
	DirAccess.make_dir_recursive_absolute("res://.cache")
	var file := FileAccess.open(MASTER_CACHE, FileAccess.WRITE)
	file.store_buffer(res.bytes)
	file.close()
	return res.bytes.get_string_from_utf8().split("\n")


func _slices_for_day(index_lines: PackedStringArray, day: String) -> Array:
	var re := RegEx.new()
	re.compile("(\\d{8})\\d{4,}00\\.export\\.CSV\\.zip")
	var re_url := RegEx.new()
	re_url.compile("https?://[^\\s]+export\\.CSV\\.zip")
	var urls: Array = []
	for line in index_lines:
		var m := re.search(line)
		if m == null or m.get_string(1) != day:
			continue
		var mu := re_url.search(line)
		if mu != null:
			urls.append(mu.get_string())
	urls.sort()
	return urls


func _at(row: PackedStringArray, i: int) -> String:
	if i < 0 or i >= row.size():
		return ""
	return row[i]


func _filter_row(row: PackedStringArray, opts: Dictionary) -> Variant:
	var d := -1
	for i in range(mini(row.size() - 1, 60), -1, -1):
		var v := row[i].strip_edges()
		if v.length() == 14 and v.is_valid_int():
			d = i
			break
	if d < 0:
		return null
	var event_id := row[0]
	if event_id == "":
		return null
	var quad := String(_at(row, d + OFFSET.quad)).to_int()
	var mentions := String(_at(row, d + OFFSET.mentions)).to_int()
	if mentions == 0 or mentions < int(opts.min_mentions):
		return null
	var actor1 := _at(row, OFFSET.actor1Name)
	var actor2 := _at(row, OFFSET.actor2Name)
	var place := _at(row, d + OFFSET.place)
	var keywords: Array = opts.keywords
	if keywords.size() > 0:
		var a1 := actor1.to_lower()
		var a2 := actor2.to_lower()
		var pl := place.to_lower()
		var hit := false
		for k in keywords:
			if a1.contains(String(k)) or a2.contains(String(k)) or pl.contains(String(k)):
				hit = true
				break
		if not hit:
			return null
	var quad_mode := String(opts.quad_mode)
	if quad_mode == "conflict" and quad < 3:
		return null
	if quad_mode == "cooperation" and quad > 2:
		return null
	var lat_s := _at(row, d + OFFSET.lat)
	var lon_s := _at(row, d + OFFSET.lon)
	if not lat_s.is_valid_float() or not lon_s.is_valid_float():
		return null
	var lat := lat_s.to_float()
	var lon := lon_s.to_float()
	var y := _at(row, OFFSET.day)
	var date_str := ""
	if y.length() >= 8:
		date_str = "%s-%s-%s" % [y.substr(0, 4), y.substr(4, 2), y.substr(6, 2)]
	var tone_v := _at(row, d + OFFSET.tone)
	var country_v := _at(row, d + OFFSET.country)
	var props := {
		actor1 = actor1 if actor1 != "" else null,
		actor2 = actor2 if actor2 != "" else null,
		quadClass = quad,
		tone = round_to(tone_v.to_float(), 2) if tone_v.is_valid_float() else null,
		mentions = mentions,
		date = date_str if date_str != "" else null,
		country = country_v if country_v != "" else null,
		place = place if place != "" else null,
		sourceUrl = _at(row, d + OFFSET.url),
	}
	return {
		id = event_id,
		feature = {
			type = "Feature",
			geometry = {type = "Point", coordinates = [round_to(lon, 4), round_to(lat, 4)]},
			properties = props,
		}
	}


func fetch_news() -> Variant:
	var feeds := read_feeds()
	var src := {}
	for f in feeds:
		if (f.get("source", {}) as Dictionary).get("type", "") == "gdelt":
			src = f.source
			break
	var opts := {
		keywords = (src.get("keywords", []) as Array).map(func(k): return String(k).to_lower()),
		min_mentions = int(src.get("minMentions", 0)),
		max_results = int(src.get("maxResults", 1500)),
		quad_mode = String(src.get("quadClass", "all")),
		lag = int(src.get("lagDays", 1)),
	}

	print("news: loading GDELT master index …")
	var index_lines := await _master_index()
	if index_lines.is_empty():
		return null

	var chosen := {}
	for lag in range(int(opts.lag), int(opts.lag) + 4):
		var day := iso_date(lag)
		var urls := _slices_for_day(index_lines, day)
		if urls.size() >= 6:
			chosen = {day = day, urls = urls}
			break
		print("news: %s only has %d slices — looking earlier" % [day, urls.size()])
	if chosen.is_empty():
		push_error("news: no GDELT slices found in master index")
		return null

	print("news: fetching %d slices for %s …" % [(chosen.urls as Array).size(), chosen.day])
	var features: Array = []
	var seen := {}
	var loaded := 0
	var zip_path := "user://gdelt_slice.zip"
	for url in chosen.urls:
		var res := await http_get(String(url), PackedStringArray(), 120.0)
		if not res.ok:
			print("news: slice error: %s (%s)" % [url, res.error])
			continue
		var file := FileAccess.open(zip_path, FileAccess.WRITE)
		file.store_buffer(res.bytes)
		file.close()
		var reader := ZIPReader.new()
		if reader.open(zip_path) != OK:
			print("news: bad zip %s" % url)
			continue
		var csv_name := ""
		for fname in reader.get_files():
			if String(fname).ends_with(".CSV") or String(fname).ends_with(".csv"):
				csv_name = fname
				break
		if csv_name == "":
			reader.close()
			continue
		var csv_text := reader.read_file(csv_name).get_string_from_utf8()
		reader.close()
		loaded += 1
		for line in csv_text.split("\n"):
			if line.strip_edges() == "":
				continue
			var hit: Variant = _filter_row(line.split("\t"), opts)
			if hit != null and not seen.has(hit.id):
				seen[hit.id] = true
				features.append(hit.feature)
	print("news: %d slices loaded, %d events kept raw" % [loaded, features.size()])

	features.sort_custom(func(a, b): return a.properties.mentions > b.properties.mentions)
	if features.size() > int(opts.max_results):
		features.resize(int(opts.max_results))

	var counts := {1: 0, 2: 0, 3: 0, 4: 0}
	for f in features:
		var q := int(f.properties.quadClass)
		if counts.has(q):
			counts[q] += 1
	print("news: %d events | coop %d/%d · conflict %d/%d" % [
		features.size(), counts[1], counts[2], counts[3], counts[4]
	])
	return {
		type = "FeatureCollection",
		features = features,
		meta = {source = "gdelt", day = chosen.day, fetchedAt = Time.get_datetime_string_from_system(true)},
	}
