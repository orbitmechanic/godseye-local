extends SceneTree
## godot --headless --path . -s tools/fetch_news.gd

const FetchLib := preload("res://tools/fetch_lib.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var lib: Node = FetchLib.new()
	root.add_child(lib)
	var g: Variant = await lib.fetch_news()
	if g != null:
		lib.write_snapshot("news.json", g)
	quit(0 if g != null else 1)
