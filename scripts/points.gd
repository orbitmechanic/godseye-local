class_name PointCloud
extends Node3D
## Globe markers with game-engine-style view management. ALL points stay in
## CPU-side typed arrays (the master buffer — the full fleet, however large).
## Rendering geometry is chunked into 15°x15° sphere tiles (child meshes of
## shader-billboarded quads), and every camera change culls tiles outside the
## visible cap, so drawn triangles track the view, not the world. Clustering
## and picking iterate only the points inside currently-visible tiles, and the
## cluster overlay rebuilds at most every third view event (it is a visual
## layer; a few frames of bubble lag is imperceptible).
##
## Replaces Cesium's CustomDataSource/PointGraphics + clustering.

const EARTH_R_KM := 6371.0
const LIFT := 0.00035  # world units (unit sphere): keeps quads off the surface mesh
const CLUSTER_AFTER := 300
const CLUSTER_RANGE := 40.0
const TILE_COLS := 24
const TILE_ROWS := 12
const TILE_LON := 360.0 / TILE_COLS
const TILE_LAT := 180.0 / TILE_ROWS
const TILE_MARGIN_RAD := deg_to_rad(12.0)  # tile half-diagonal slack
const CLUSTER_EVERY := 3

const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform;

uniform float u_half_tan = 0.35;
uniform float u_viewport_h = 900.0;

varying vec4 tint;

void vertex() {
	// NORMAL carries the unit direction of the point on the sphere; UV2.x is
	// the pixel size, UV2.y the world radius (surface + altitude + lift).
	// VERTEX.xy carries the quad corner (-0.5..0.5); POSITION is write-only
	// under skip_vertex_transform, so the billboard must be assembled in
	// view space and projected manually.
	vec3 center = NORMAL * UV2.y;
	vec4 view = VIEW_MATRIX * MODEL_MATRIX * vec4(center, 1.0);
	float dist = length(view.xyz);
	float world_size = UV2.x * 2.0 * dist * u_half_tan / u_viewport_h;
	view.xy += VERTEX.xy * world_size;
	POSITION = PROJECTION_MATRIX * view;
	tint = COLOR;
}

void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float a = clamp((1.0 - d) / 0.22, 0.0, 1.0) * tint.a;
	if (a < 0.02) {
		discard;
	}
	ALBEDO = tint.rgb;
	ALPHA = a;
}
"""

var feed: Dictionary = {}
var geojson: Dictionary = {}

# Master buffer: one entry per GeoJSON Point feature, regardless of view.
var _count := 0
var _dirs: PackedVector3Array = PackedVector3Array()
var _rs: PackedFloat64Array = PackedFloat64Array()
var _px: PackedFloat32Array = PackedFloat32Array()
var _cols: Array[Color] = []
var _feature_of: PackedInt32Array = PackedInt32Array()
var _tile_of: PackedInt32Array = PackedInt32Array()

# Sphere tiles.
var _tile_points: Array[PackedInt32Array] = []
var _tile_dirs: PackedVector3Array = []
var _tile_nodes: Array[MeshInstance3D] = []
var _visible_tiles: PackedInt32Array = PackedInt32Array()

var _mat := ShaderMaterial.new()
var _cluster_cache: Array = []
var _cluster_tick := 0


func _ready() -> void:
	var shader := Shader.new()
	shader.code = SHADER
	_mat.shader = shader
	_mat.render_priority = 2


func clear() -> void:
	_count = 0
	_dirs.clear()
	_rs.clear()
	_px.clear()
	_cols.clear()
	_feature_of.clear()
	_tile_of.clear()
	_visible_tiles.clear()
	_cluster_cache.clear()
	_cluster_tick = 0
	feed = {}
	geojson = {}
	for t in _tile_nodes.size():
		var node := _tile_nodes[t]
		if node != null:
			_tile_nodes[t] = null
			remove_child(node)
			node.free()
	_tile_nodes.clear()
	_tile_points.clear()
	_tile_dirs.clear()


func set_data(feed_dict: Dictionary, geo: Dictionary) -> void:
	clear()
	feed = feed_dict
	geojson = geo
	var features: Array = geo.get("features", [])
	var style: Dictionary = feed_dict.get("style", {})
	var size_ramp := _size_ramp(features, style)

	var default_col := _css_color(String(style.get("color", "#22d3ee")), Color(0.13, 0.83, 0.93))
	var base_size := float(style.get("size", 5))

	for fi in features.size():
		var f: Dictionary = features[fi]
		var geometry: Variant = f.get("geometry")
		if typeof(geometry) != TYPE_DICTIONARY:
			continue
		if String((geometry as Dictionary).get("type", "")) != "Point":
			continue
		var coords: Variant = (geometry as Dictionary).get("coordinates")
		if typeof(coords) != TYPE_ARRAY or (coords as Array).size() < 2:
			continue
		var lon := float(coords[0])
		var lat := float(coords[1])
		var alt_m := float(coords[2]) if coords.size() > 2 else 0.0
		var props: Dictionary = f.get("properties", {})

		_dirs.append(_latlon_to_unit(lat, lon))
		_rs.append((EARTH_R_KM * 1000.0 + alt_m) / (EARTH_R_KM * 1000.0) + LIFT)
		_px.append(_size_for(props, style, size_ramp, base_size))
		_cols.append(_color_for(props, style, default_col))
		_feature_of.append(fi)
		_tile_of.append(_tile_index(lat, lon))

	_count = _dirs.size()
	_bucket_tiles()
	refresh_placeholder_uniforms()


func refresh(cam: Camera3D, viewport_height: float) -> void:
	if cam == null:
		return
	_mat.set_shader_parameter("u_half_tan", tan(deg_to_rad(cam.fov) * 0.5))
	_mat.set_shader_parameter("u_viewport_h", maxf(viewport_height, 1.0))
	update_culling(cam)


## O(#tiles) per camera move: hide every tile further from the sub-camera
## point than the limb angle plus one tile half-diagonal.
func update_culling(cam: Camera3D) -> void:
	_cluster_tick += 1
	_visible_tiles.clear()
	if cam == null or _count == 0:
		return
	var d := cam.global_position.length()
	var cap_angle := acos(clampf(1.0 / maxf(d, 1.0001), 0.0, 1.0))
	var limit := cos(cap_angle + TILE_MARGIN_RAD)
	var cam_dir := cam.global_position.normalized()
	for t in _tile_nodes.size():
		var node := _tile_nodes[t]
		if node == null:
			continue
		if cam_dir.dot(_tile_dirs[t]) >= limit:
			node.visible = true
			_visible_tiles.append(t)
		else:
			node.visible = false


func world_pos(i: int) -> Vector3:
	return _dirs[i] * _rs[i]


func screen_px(i: int) -> float:
	return _px[i]


func props_of_instance(i: int) -> Dictionary:
	var features: Array = geojson.get("features", [])
	var fi := _feature_of[i]
	return features[fi].get("properties", {})


func cluster_cells(cam: Camera3D, viewport_size: Vector2, force := false) -> Array:
	# Screen-space grid buckets over VISIBLE tiles only, mirroring Cesium's
	# clustering: returns [{x, y, count, dir}] with count >= 2.
	if _count == 0 or cam == null or _count <= CLUSTER_AFTER:
		_cluster_cache = []
		return _cluster_cache
	if not force and not _cluster_cache.is_empty() and _cluster_tick % CLUSTER_EVERY != 0:
		return _cluster_cache
	var cells := {}
	for t in _visible_tiles:
		for i in _tile_points[t]:
			var sp := _project(cam, world_pos(i), viewport_size)
			if sp.is_empty():
				continue
			var key := int(sp.x / CLUSTER_RANGE) * 100000 + int(sp.y / CLUSTER_RANGE)
			if not cells.has(key):
				cells[key] = {sum = Vector2.ZERO, n = 0, dir = Vector3.ZERO}
			var c: Dictionary = cells[key]
			c.sum += Vector2(sp.x, sp.y)
			c.n += 1
			c.dir += _dirs[i]
	var out: Array = []
	for key in cells:
		var c: Dictionary = cells[key]
		if int(c.n) < 2:
			continue
		out.append({
			x = (c.sum.x / c.n), y = (c.sum.y / c.n), count = c.n,
			dir = (c.dir / c.n).normalized(),
		})
	_cluster_cache = out
	return out


func pick(cam: Camera3D, viewport_size: Vector2, screen: Vector2) -> int:
	if _count == 0 or cam == null:
		return -1
	var best := -1
	var best_d := 12.0
	for t in _visible_tiles:
		for i in _tile_points[t]:
			var sp := _project(cam, world_pos(i), viewport_size)
			if sp.is_empty():
				continue
			var d := Vector2(sp.x, sp.y).distance_to(screen)
			var radius := _px[i] * 0.5 + 5.0
			if d < minf(best_d, radius):
				best_d = d
				best = i
	return best


func clustered() -> bool:
	return _count > CLUSTER_AFTER


func _tile_index(lat: float, lon: float) -> int:
	var col := clampi(int(floor((lon + 180.0) / TILE_LON)), 0, TILE_COLS - 1)
	var row := clampi(int(floor((90.0 - lat) / TILE_LAT)), 0, TILE_ROWS - 1)
	return row * TILE_COLS + col


func _bucket_tiles() -> void:
	_tile_points.resize(TILE_COLS * TILE_ROWS)
	_tile_dirs.resize(TILE_COLS * TILE_ROWS)
	_tile_nodes.resize(TILE_COLS * TILE_ROWS)
	for i in TILE_COLS * TILE_ROWS:
		_tile_points[i] = PackedInt32Array()
		_tile_nodes[i] = null
	for i in _count:
		var t := _tile_of[i]
		_tile_points[t].append(i)
	for t in TILE_COLS * TILE_ROWS:
		if _tile_points[t].is_empty():
			continue
		var row := t / TILE_COLS
		var col := t % TILE_COLS
		var lat := 90.0 - (float(row) + 0.5) * TILE_LAT
		var lon := -180.0 + (float(col) + 0.5) * TILE_LON
		_tile_dirs[t] = _latlon_to_unit(maxf(lat, -89.9), lon)
		var node := MeshInstance3D.new()
		node.name = "Tile_%d_%d" % [row, col]
		node.mesh = _quad_mesh(_tile_points[t])
		node.material_override = _mat
		add_child(node)
		_tile_nodes[t] = node
		_visible_tiles.append(t)  # all live until the first camera cull


func _quad_mesh(indices: PackedInt32Array) -> ArrayMesh:
	# Static per tile: 4 verts + 2 tris per point. Per-vertex payload:
	# POSITION = corner (-0.5..0.5), UV = circle coords (0..1),
	# UV2 = (pixel size, world radius), NORMAL = unit sphere dir, COLOR = tint.
	var n := indices.size()
	var verts := n * 4
	var v_pos := PackedVector3Array()
	var v_uv := PackedVector2Array()
	var v_uv2 := PackedVector2Array()
	var v_nrm := PackedVector3Array()
	var v_col := PackedColorArray()
	v_pos.resize(verts)
	v_uv.resize(verts)
	v_uv2.resize(verts)
	v_nrm.resize(verts)
	v_col.resize(verts)
	var corners: Array[Vector2] = [
		Vector2(-0.5, 0.5), Vector2(0.5, 0.5), Vector2(0.5, -0.5), Vector2(-0.5, -0.5)
	]
	var uvs: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for qi in n:
		var i := indices[qi]
		var base := qi * 4
		for k in 4:
			v_pos[base + k] = Vector3(corners[k].x, corners[k].y, 0.0)
			v_uv[base + k] = uvs[k]
			v_uv2[base + k] = Vector2(_px[i], _rs[i])
			v_nrm[base + k] = _dirs[i]
			v_col[base + k] = _cols[i]
	var idx := PackedInt32Array()
	idx.resize(n * 6)
	for qi in n:
		var b := qi * 4
		var o := qi * 6
		idx[o] = b
		idx[o + 1] = b + 1
		idx[o + 2] = b + 2
		idx[o + 3] = b
		idx[o + 4] = b + 2
		idx[o + 5] = b + 3
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v_pos
	arrays[Mesh.ARRAY_TEX_UV] = v_uv
	arrays[Mesh.ARRAY_TEX_UV2] = v_uv2
	arrays[Mesh.ARRAY_NORMAL] = v_nrm
	arrays[Mesh.ARRAY_COLOR] = v_col
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func refresh_placeholder_uniforms() -> void:
	# Defaults until the first refresh() with a live camera.
	_mat.set_shader_parameter("u_half_tan", 0.35)
	_mat.set_shader_parameter("u_viewport_h", 900.0)


func _project(cam: Camera3D, pos: Vector3, viewport_size: Vector2) -> Dictionary:
	# Empty dict when not drawable: behind the camera, outside the viewport,
	# or occluded by the globe itself (camera->point segment crosses the sphere).
	if cam.to_local(pos).z >= 0.0:
		return {}
	if _segment_hits_globe(cam.global_position, pos):
		return {}
	var p := cam.unproject_position(pos)
	if p.x < -20.0 or p.y < -20.0 or p.x > viewport_size.x + 20.0 or p.y > viewport_size.y + 20.0:
		return {}
	return {x = p.x, y = p.y}


static func _segment_hits_globe(from: Vector3, to: Vector3, radius: float = 1.0) -> bool:
	# Does the open segment from..to pass through the unit sphere (centered at
	# origin) before reaching `to`? `to` lies on/above the surface.
	var d := to - from
	var a := d.dot(d)
	if a <= 0.0:
		return false
	var b := 2.0 * from.dot(d)
	var c := from.dot(from) - radius * radius
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return false
	var t0 := (-b - sqrt(disc)) / (2.0 * a)
	return t0 > 0.0001 and t0 < 0.9999


static func _latlon_to_unit(lat: float, lon: float) -> Vector3:
	# Right-handed north-up mapping: +lat -> +Y, east -> screen-right when
	# looking at the sphere from outside (x = -cos(lat) * sin(lon)).
	var phi := deg_to_rad(lat)
	var theta := deg_to_rad(lon)
	return Vector3(-cos(phi) * sin(theta), sin(phi), -cos(phi) * cos(theta))


func _size_ramp(features: Array, style: Dictionary) -> Dictionary:
	if not style.has("sizeBy"):
		return {}
	var mn := INF
	var mx := -INF
	for f in features:
		var props: Dictionary = f.get("properties", {})
		var v: Variant = _as_num(props.get(style.sizeBy))
		if v != null:
			mn = minf(mn, v)
			mx = maxf(mx, v)
	if mn == INF:
		return {min = 0.0, max = 1.0}
	return {min = mn, max = mx}


func _size_for(props: Dictionary, style: Dictionary, ramp: Dictionary, base: float) -> float:
	var size := base
	if not ramp.is_empty() and ramp.max > ramp.min and style.has("sizeBy"):
		var v: Variant = _as_num(props.get(style.sizeBy))
		if v != null:
			var lo := float(style.get("sizeMin", 2))
			var hi := float(style.get("sizeMax", 10))
			size = lo + ((v - ramp.min) / (ramp.max - ramp.min)) * (hi - lo)
	return maxf(1.5, size)


func _color_for(props: Dictionary, style: Dictionary, fallback: Color) -> Color:
	if style.has("colorByProperty") and style.has("colors"):
		var key := _key_str(props.get(style.colorByProperty))
		var colors: Dictionary = style.colors
		if colors.has(key):
			return _css_color(String(colors[key]), fallback)
	return fallback


static func _as_num(v) -> Variant:
	if v is int or v is float:
		return float(v)
	if v is String and String(v).is_valid_float():
		return String(v).to_float()
	return null


static func _key_str(v) -> String:
	if v is float:
		var f: float = v
		if is_equal_approx(f, roundf(f)):
			return str(int(roundf(f)))
		return str(f)
	return str(v)


static func _css_color(s: String, fallback: Color) -> Color:
	var t := s.strip_edges()
	if t.begins_with("#"):
		t = t.substr(1)
	match t.length():
		6:
			var r := t.substr(0, 2).hex_to_int()
			var g := t.substr(2, 2).hex_to_int()
			var b := t.substr(4, 2).hex_to_int()
			return Color8(r, g, b)
		3:
			return Color8(
				t.substr(0, 1).hex_to_int() * 17,
				t.substr(1, 1).hex_to_int() * 17,
				t.substr(2, 1).hex_to_int() * 17
			)
	return fallback
