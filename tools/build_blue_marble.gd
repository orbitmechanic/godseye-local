extends SceneTree
## Build assets/imagery/blue_marble.jpg: download NASA GIBS BlueMarble
## NextGeneration Web Mercator tiles (z=3, 8x8), stitch them, then reproject
## Mercator -> equirectangular so globe.gd's UV mapping (u = (lon+180)/360,
## v = (90-lat)/180) maps it exactly. Keyless endpoint, same one the web app
## used as its "nasa" imagery source.
##
## Run: godot --headless --path . -s tools/build_blue_marble.gd

const Z := 3
const TILE_PX := 512
const OUT_W := 4096
const OUT_H := 2048


class Downloader extends Node:
	func get_bytes(url: String) -> Dictionary:
		var req := HTTPRequest.new()
		req.timeout = 60.0
		add_child(req)
		var err := req.request(url, PackedStringArray(["User-Agent: ithildin-texture-builder"]))
		if err != OK:
			req.queue_free()
			return {ok = false, bytes = PackedByteArray()}
		var args: Array = await req.request_completed
		req.queue_free()
		if int(args[0]) != HTTPRequest.RESULT_SUCCESS or int(args[1]) != 200:
			return {ok = false, bytes = PackedByteArray()}
		return {ok = true, bytes = args[3]}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var dl := Downloader.new()
	root.add_child(dl)
	var tiles_side := 1 << Z
	var merc := Image.create(tiles_side * TILE_PX, tiles_side * TILE_PX, false, Image.FORMAT_RGB8)
	var ok := 0
	for y in tiles_side:
		for x in tiles_side:
			var url := "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/BlueMarble_NextGeneration/default/GoogleMapsCompatible_Level8/%d/%d/%d.jpeg" % [Z, y, x]
			var res := await dl.get_bytes(url)
			if not res.ok:
				push_error("tile fetch failed: %s" % url)
				continue
			var img := Image.new()
			if img.load_jpg_from_buffer(res.bytes) != OK:
				push_error("decode failed: %s" % url)
				continue
			merc.blit_rect(img, Rect2i(0, 0, TILE_PX, TILE_PX), Vector2i(x * TILE_PX, y * TILE_PX))
			ok += 1
	if ok != tiles_side * tiles_side:
		push_error("missing tiles: %d/%d" % [ok, tiles_side * tiles_side])
		quit(1)
		return
	print("fetched %d/%d tiles, reprojecting…" % [ok, tiles_side * tiles_side])

	var src := merc.get_data()
	var sw := merc.get_width()
	var sh := merc.get_height()
	var out := PackedByteArray()
	out.resize(OUT_W * OUT_H * 3)
	for oy in OUT_H:
		var lat := 90.0 - 180.0 * float(oy) / float(OUT_H)
		var phi := deg_to_rad(clampf(lat, -85.0511, 85.0511))
		var v := 0.5 - asinh(tan(phi)) / (TAU)
		var sy := clampi(int(v * sh), 0, sh - 1)
		var row_base := sy * sw * 3
		var out_base := oy * OUT_W * 3
		for ox in OUT_W:
			var sx_off := (ox * sw / OUT_W) * 3
			out[out_base + ox * 3] = src[row_base + sx_off]
			out[out_base + ox * 3 + 1] = src[row_base + sx_off + 1]
			out[out_base + ox * 3 + 2] = src[row_base + sx_off + 2]
	var img_out := Image.create_from_data(OUT_W, OUT_H, false, Image.FORMAT_RGB8, out)
	var err := img_out.save_jpg("res://assets/imagery/blue_marble.jpg", 0.9)
	print("wrote assets/imagery/blue_marble.jpg (%dx%d, err=%s)" % [OUT_W, OUT_H, error_string(err)])
	quit(0 if err == OK else 1)
