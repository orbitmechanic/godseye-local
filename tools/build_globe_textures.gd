extends SceneTree
## Stitch the salvaged NaturalEarthII tile pyramid (the offline basemap that
## shipped inside Cesium) into one 2048x1024 equirectangular JPEG that
## globe.gd's hand-mapped UVs (u = (lon+180)/360, v = (90-lat)/180) accept
## verbatim. Tiles are 256 px; level 2 is 8x4 with a South-West tile origin.
##
## Run: godot --headless --path . -s tools/build_globe_textures.gd

const TILE := 256
const LEVEL := 2
const COLS := 1 << (LEVEL + 1)
const ROWS := 1 << LEVEL


func _initialize() -> void:
	var out := Image.create(TILE * COLS, TILE * ROWS, false, Image.FORMAT_RGB8)
	var loaded := 0
	for x in COLS:
		for y in ROWS:
			var path := "res://_salvage/NaturalEarthII/%d/%d/%d.jpg" % [LEVEL, x, y]
			var tile := Image.new()
			var buf := FileAccess.get_file_as_bytes(path)
			if buf.is_empty():
				push_error("missing tile %s" % path)
				continue
			if tile.load_jpg_from_buffer(buf) != OK:
				push_error("bad tile %s" % path)
				continue
			out.blit_rect(tile, Rect2i(0, 0, TILE, TILE), Vector2i(x * TILE, (ROWS - 1 - y) * TILE))
			loaded += 1
	if loaded != COLS * ROWS:
		push_error("only %d tiles stitched" % loaded)
		quit(1)
		return
	var err := out.save_jpg("res://assets/imagery/natural_earth_ii.jpg", 0.92)
	print("stitched %d tiles -> assets/imagery/natural_earth_ii.jpg (%dx%d, err=%s)" % [
		loaded, out.get_width(), out.get_height(), error_string(err)
	])
	quit(0 if err == OK else 1)
