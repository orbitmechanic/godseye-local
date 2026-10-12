class_name CSV
extends RefCounted
## Minimal CSV parser handling quoted fields and CRLF. Ported from src/csv.js.


static func parse(text: String) -> Array:
	var rows: Array = []
	var row: Array = []
	var field := ""
	var in_quotes := false
	var i := 0
	while i < text.length():
		var c := text[i]
		var n := "" if i + 1 >= text.length() else text[i + 1]
		if in_quotes:
			if c == "\"" and n == "\"":
				field += "\""
				i += 1
			elif c == "\"":
				in_quotes = false
			else:
				field += c
		elif c == "\"":
			in_quotes = true
		elif c == ",":
			row.append(field)
			field = ""
		elif c == "\r":
			pass
		elif c == "\n":
			row.append(field)
			field = ""
			if _row_has_content(row):
				rows.append(row)
			row = []
		else:
			field += c
		i += 1
	if field.length() > 0:
		row.append(field)
		rows.append(row)
	return rows


static func to_geojson(text: String, columns: Dictionary) -> Dictionary:
	# Returns {ok: bool, geojson: Dictionary, error: String}.
	var rows := parse(text)
	var empty := {"type": "FeatureCollection", "features": []}
	if rows.is_empty():
		return {ok = true, geojson = empty, error = ""}

	var header: Array = []
	for h in rows[0]:
		header.append(String(h).strip_edges())
	var data_rows := rows.slice(1)

	var lat_idx := header.find(String(columns.get("lat", "")))
	var lon_idx := header.find(String(columns.get("lon", "")))
	var name_idx := header.find(String(columns.get("name", "")))
	if lat_idx < 0 or lon_idx < 0:
		return {
			ok = false, geojson = empty,
			error = "CSV needs \"%s\" and \"%s\" columns; found: %s" % [
				columns.get("lat", ""), columns.get("lon", ""), ", ".join(PackedStringArray(header))
			]
		}

	var features: Array = []
	for r in data_rows:
		var lat := _parse_f(r[lat_idx])
		var lon := _parse_f(r[lon_idx])
		if not is_finite(lat) or not is_finite(lon):
			continue
		var props := {}
		for col_i in header.size():
			var key: String = header[col_i]
			if key == "" or col_i >= r.size():
				continue
			var v := String(r[col_i])
			if v == "":
				continue
			props[key] = v.to_float() if _is_numeric(v) else v
		if name_idx >= 0 and name_idx < r.size():
			props["name"] = String(r[name_idx])
		features.append({
			"type": "Feature",
			"geometry": {"type": "Point", "coordinates": [lon, lat]},
			"properties": props
		})
	return {ok = true, geojson = {"type": "FeatureCollection", "features": features}, error = ""}


static func _row_has_content(row: Array) -> bool:
	for v in row:
		if String(v).strip_edges() != "":
			return true
	return false


static func _parse_f(v) -> float:
	var t := String(v).strip_edges()
	if not t.is_valid_float():
		return NAN
	return t.to_float()


static func _is_numeric(s: String) -> bool:
	return s.strip_edges().is_valid_float()
