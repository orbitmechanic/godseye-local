extends Node
## Visual states for --write-movie capture: fixed frame budgets per state.
## Frames land at: s1 ~45, s2 ~135, s3 ~225, s4 ~315, s5 ~405 (of ~460).

const DIR := "/tmp/opencode/"
const HOLD := 90


func _touch(name: String) -> void:
	var f := FileAccess.open(DIR + name, FileAccess.WRITE)
	f.store_string("1")
	f.close()


func _hold_for(name: String) -> void:
	_touch(name + ".ready")
	while not FileAccess.file_exists(DIR + name + ".taken"):
		await get_tree().process_frame


func _wait(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.get_node("Geo")._cached = {longitude = -95.0, latitude = 35.0, source = "probe"}
	add_child(main)
	for i in 900:
		await get_tree().process_frame
		if String(App.status_text) == "ready":
			break
	var globe: Node3D = main.globe
	var ui: Node = main.ui

	globe.set_view(-95.0, 35.0, 1.94, true)
	var diag := FileAccess.open(DIR + "shot_diag.txt", FileAccess.WRITE)
	diag.store_string("feed=%s count=%d mesh=%s vis=%s in_tree=%s\n" % [
		String(globe.points.feed.get("id", "")), globe.points._count,
		str(globe.points.mesh != null), str(globe.points.visible),
		str(globe.points.is_inside_tree()),
	])
	diag.store_string("vp_h=%f uht=%s uvh=%s\n" % [
		globe.viewport_height(),
		str(globe.points._mat.get_shader_parameter("u_half_tan")),
		str(globe.points._mat.get_shader_parameter("u_viewport_h")),
	])
	diag.close()
	await _hold_for("s1")

	globe.set_view(-95.0, 35.0, 1.157, true)
	await _hold_for("s2")

	App.set_feed_visible("news", true)
	globe.set_view(15.0, 28.0, 1.94, true)
	await _hold_for("s3")

	var news: Dictionary = App.find_feed("news")
	var props: Dictionary = (App.parsed_cache["news"].features[0] as Dictionary).properties
	ui.show_info(props, news)
	await _hold_for("s4")

	var sphere: MeshInstance3D = globe.get_node("GlobeMesh")
	sphere.material_override.albedo_texture = load("res://assets/imagery/blue_marble.jpg")
	globe.set_view(140.0, 35.0, 1.94, true)
	await _hold_for("s5")

	get_tree().quit(0)
