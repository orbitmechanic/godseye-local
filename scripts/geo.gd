extends Node
## Resolve an approximate "where is this machine on the network" position
## without any API key. Ported from src/geo.js, minus the browser geolocation
## step (Godot has no geolocation prompt; keyless IP lookup + config fallback
## remain).
##
## Loader node must be injected — main.gd wires it.

var loader: Node = null
var _cached: Dictionary = {}


func resolve_network_location(home_config: Dictionary) -> Dictionary:
	if not _cached.is_empty():
		return _cached
	var fallback := {
		longitude = float(home_config.get("longitude", -95.0)),
		latitude = float(home_config.get("latitude", 35.0)),
		source = "config",
	}
	if loader == null:
		_cached = fallback
	else:
		var via: Dictionary = await _via_ip()
		_cached = via if not via.is_empty() else fallback
	return _cached


func _via_ip() -> Dictionary:
	# Keyless IP geolocation (approximate to city/region level).
	var res: Dictionary = await loader.http_get("https://ipwho.is/", PackedStringArray(), 4.0)
	if not res.get("ok", false):
		return {}
	var data: Variant = JSON.parse_string(String(res.get("text", "")))
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	var j: Dictionary = data
	if not (j.get("latitude") is float or j.get("latitude") is int):
		return {}
	if not (j.get("longitude") is float or j.get("longitude") is int):
		return {}
	return {
		longitude = float(j["longitude"]),
		latitude = float(j["latitude"]),
		source = "ip",
	}
