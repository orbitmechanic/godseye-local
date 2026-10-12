extends Node
func _ready() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	for i in 600:
		await get_tree().process_frame
		if String(App.status_text) == "ready":
			break
	for i in 600:
		await get_tree().process_frame
		main.globe.set_view(-95.0, 35.0, 1.94, true)
	get_tree().quit(0)
