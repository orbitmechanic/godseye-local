extends Node3D
## Native replacement for Cesium's Viewer: an offline-textured sphere built
## from a hand-mapped equirectangular UV grid, an orbit camera rig with drag
## rotate / wheel zoom / fly-to, and click routing to PointCloud picking.

signal point_picked(props: Dictionary, feed: Dictionary)
signal cluster_zoomed(lat: float, lon: float, alt_km: float)
signal view_changed

const EARTH_R_KM := 6371.0
const LAT_STEPS := 90
const LON_STEPS := 180
const MIN_DIST := 1.06
const MAX_DIST := 9.0

var camera: Camera3D
var points: PointCloud
var app_config: Dictionary = {}
var geo: Node = null

var view_lon := 0.0
var view_lat := 0.0
var dist_units := 1.94
var _target := {}
var _dragging := false
var _drag_moved := 0.0


func setup(config: Dictionary) -> void:
	app_config = config
	_build_globe_mesh(String(config.get("imagery", "esri")))
	camera = Camera3D.new()
	camera.fov = 70.0
	add_child(camera)
	camera.current = true
	points = PointCloud.new()
	add_child(points)
	var home: Dictionary = config.get("homeView", {})
	set_view(float(home.get("longitude", -95.0)), float(home.get("latitude", 35.0)),
		float(home.get("height", 6000000.0)) / (EARTH_R_KM * 1000.0), true)


func latlon_to_xyz(lat: float, lon: float) -> Vector3:
	return PointCloud._latlon_to_unit(lat, lon)


func set_view(lon: float, lat: float, dist: float, snap := false) -> void:
	dist = clampf(dist, MIN_DIST, MAX_DIST)
	if snap:
		view_lon = wrapf(lon, -180.0, 180.0)
		view_lat = clampf(lat, -89.9, 89.9)
		dist_units = dist
		_target = {}
		_apply_camera()
		_refresh_overlays()
	else:
		_target = {lon = lon, lat = lat, dist = dist}


func request_view(lon: float, lat: float, alt_km: float) -> void:
	set_view(lon, lat, (EARTH_R_KM + alt_km) / EARTH_R_KM)


func reset_home() -> void:
	# North-up over the resolved network location at 1000 km, like the web app.
	var home: Dictionary = app_config.get("homeView", {})
	set_view(float(home.get("longitude", -95.0)), float(home.get("latitude", 35.0)),
		(EARTH_R_KM + 1000.0) / EARTH_R_KM)
	if geo != null:
		var pos: Dictionary = await geo.resolve_network_location(home)
		set_view(float(pos.get("longitude", home.get("longitude", -95.0))),
			float(pos.get("latitude", home.get("latitude", 35.0))),
			(EARTH_R_KM + 1000.0) / EARTH_R_KM)


func world_per_px(dist: float) -> float:
	return 2.0 * dist * tan(deg_to_rad(camera.fov) * 0.5) / viewport_height()


func viewport_height() -> float:
	return get_viewport().get_visible_rect().size.y


func viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size


func fly_to_point(lat: float, lon: float) -> void:
	request_view(lon, lat, 1200.0)


func pick_at(screen: Vector2) -> Dictionary:
	# Prefer cluster bubbles, then individual markers (like the Cesium version).
	for c in _cluster_cells():
		if Vector2(c.x, c.y).distance_to(screen) < 12.0:
			var dir: Vector3 = c.dir
			var latlon := _xyz_to_latlon(dir)
			return {kind = "cluster", lat = latlon.y, lon = latlon.x}
	var i := points.pick(camera, viewport_size(), screen)
	if i >= 0:
		return {kind = "point", index = i, props = points.props_of_instance(i)}
	return {}


func cluster_cells_public() -> Array:
	return _cluster_cells()


func _cluster_cells() -> Array:
	if points == null or not points.clustered():
		return []
	return points.cluster_cells(camera, viewport_size())


func _process(delta: float) -> void:
	if _target.is_empty():
		return
	var w := 1.0 - exp(-8.0 * delta)
	var tl := _shortest_angle(view_lon, float(_target.lon))
	view_lon = wrapf(view_lon + tl * w, -180.0, 180.0)
	view_lat = lerpf(view_lat, float(_target.lat), w)
	dist_units = lerpf(dist_units, float(_target.dist), w)
	if absf(tl) < 0.01 and absf(view_lat - float(_target.lat)) < 0.01 \
			and absf(dist_units - float(_target.dist)) < 0.001:
		view_lon = wrapf(float(_target.lon), -180.0, 180.0)
		view_lat = clampf(float(_target.lat), -89.9, 89.9)
		dist_units = float(_target.dist)
		_target = {}
	_apply_camera()
	_refresh_overlays()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_drag_moved = 0.0
			else:
				_dragging = false
				if _drag_moved < 6.0:
					_handle_click(event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_target = {lon = view_lon, lat = view_lat, dist = clampf(dist_units * 0.85, MIN_DIST, MAX_DIST)}
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_target = {lon = view_lon, lat = view_lat, dist = clampf(dist_units / 0.85, MIN_DIST, MAX_DIST)}
	elif event is InputEventMouseMotion and _dragging:
		var rel: Vector2 = event.relative
		_drag_moved += absf(rel.x) + absf(rel.y)
		var sens := 0.18 * clampf(dist_units, 1.0, 3.0)
		set_view_raw(view_lon - rel.x * sens, view_lat + rel.y * sens)


func set_view_raw(lon: float, lat: float) -> void:
	_target = {}
	view_lon = wrapf(lon, -180.0, 180.0)
	view_lat = clampf(lat, -89.9, 89.9)
	_apply_camera()
	_refresh_overlays()


func _handle_click(screen: Vector2) -> void:
	var res := pick_at(screen)
	match res.get("kind", ""):
		"point":
			point_picked.emit(res.props, points.feed)
		"cluster":
			var alt := (dist_units - 1.0) * EARTH_R_KM * 0.55
			request_view(float(res.lon), float(res.lat), maxf(alt, 150.0))
			cluster_zoomed.emit(float(res.lat), float(res.lon), alt)
		_:
			pass


func _apply_camera() -> void:
	if camera == null:
		return
	var pos := latlon_to_xyz(view_lat, view_lon) * dist_units
	camera.global_position = pos
	if absf(view_lat) > 89.0:
		camera.look_at_from_position(pos, Vector3.ZERO,
			latlon_to_xyz(80.0 if view_lat > 0.0 else -80.0, view_lon) * dist_units - pos)
	else:
		camera.look_at_from_position(pos, Vector3.ZERO, Vector3.UP)


func _refresh_overlays() -> void:
	if points == null:
		return
	points.refresh(camera, viewport_height())
	view_changed.emit()


func _shortest_angle(from: float, to: float) -> float:
	var d := fmod(to - from, 360.0)
	if d > 180.0:
		d -= 360.0
	elif d < -180.0:
		d += 360.0
	return d


static func _xyz_to_latlon(p: Vector3) -> Vector2:
	# Returns Vector2(lat, lon) in degrees for a unit-ish vector.
	var n := p.normalized()
	var lat := rad_to_deg(asin(clampf(n.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(n.x, -n.z))
	return Vector2(lat, lon)


func _build_globe_mesh(imagery: String) -> void:
	var sphere := MeshInstance3D.new()
	sphere.name = "GlobeMesh"
	sphere.mesh = _sphere_mesh()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var tex := _globe_texture(imagery)
	if tex != null:
		mat.albedo_texture = tex
	else:
		mat.albedo_color = Color(0.06, 0.09, 0.14)
	sphere.material_override = mat
	add_child(sphere)


func _sphere_mesh() -> ArrayMesh:
	# Hand-built so lat/lon -> UV is exactly what PointCloud assumes:
	# u = (lon + 180) / 360, v = (90 - lat) / 180.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var vert_count := (LAT_STEPS + 1) * (LON_STEPS + 1)
	for li in LAT_STEPS + 1:
		var lat := 90.0 - 180.0 * float(li) / float(LAT_STEPS)
		for lo in LON_STEPS + 1:
			var lon := -180.0 + 360.0 * float(lo) / float(LON_STEPS)
			st.set_uv(Vector2((lon + 180.0) / 360.0, (90.0 - lat) / 180.0))
			st.add_vertex(latlon_to_xyz(lat, lon))
	for li in LAT_STEPS:
		for lo in LON_STEPS:
			var a := li * (LON_STEPS + 1) + lo
			var b := a + 1
			var c := a + (LON_STEPS + 1)
			var d := c + 1
			st.add_index(a)
			st.add_index(c)
			st.add_index(b)
			st.add_index(b)
			st.add_index(c)
			st.add_index(d)
	var mesh := st.commit()
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert(verts.size() == vert_count)
	return mesh


func _globe_texture(imagery: String) -> Texture2D:
	var candidates: Array = []
	match imagery:
		"nasa":
			candidates = [
				"res://assets/imagery/blue_marble.jpg",
				"res://assets/imagery/natural_earth_ii.jpg",
			]
		"osm":
			candidates = [
				"res://assets/imagery/natural_earth_ii.jpg",
				"res://assets/imagery/blue_marble.jpg",
			]
		_:
			candidates = [
				"res://assets/imagery/natural_earth_ii.jpg",
				"res://assets/imagery/blue_marble.jpg",
			]
	for path in candidates:
		if ResourceLoader.exists(path):
			var tex := load(path) as Texture2D
			if tex != null:
				return tex
	return null
