extends SceneTree
## godot --headless --path . -s tools/fetch_all.gd  (all three snapshots)

const FetchLib := preload("res://tools/fetch_lib.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var lib: Node = FetchLib.new()
	root.add_child(lib)
	var jobs := {
		air = func(): return await lib.fetch_air(),
		sea = func(): return await lib.fetch_sea(),
		news = func(): return await lib.fetch_news(),
	}
	for name in jobs:
		var g: Variant = await jobs[name].call()
		if g != null:
			lib.write_snapshot("%s.json" % name, g)
	quit(0)
