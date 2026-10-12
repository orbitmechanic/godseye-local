extends CanvasLayer
## Full port of the web UI: left panel (brand/clock/home, exclusive layer
## toggles, news fan-out list), right info card with popup/legend specs,
## "/" scratchpad for ad-hoc URL layers, bottom status bar, and a screen-space
## cluster overlay on top of the 3D globe.

const COL_EDGE := Color8(30, 42, 58)
const COL_TEXT := Color8(201, 226, 244)
const COL_DIM := Color8(91, 122, 148)
const COL_ACCENT := Color8(34, 211, 238)

var globe: Node3D = null
var loader: Node = null

var _layer_rows := {}
var _news_feed: Dictionary = {}
var _news_geo: Dictionary = {}

var _clock: Label
var _layers_box: VBoxContainer
var _news_box: VBoxContainer
var _info: PanelContainer
var _info_title: Label
var _info_body: VBoxContainer
var _scratch: PanelContainer
var _scratch_edit: LineEdit
var _status_label: Label
var _overlay: ClusterOverlay
var _root: Control


func _ready() -> void:
	layer = 1
	_build_root()


func setup(feeds: Array) -> void:
	_overlay.globe_ref = globe
	App.status_changed.connect(_on_status)
	globe.point_picked.connect(show_info)
	globe.view_changed.connect(_on_view_changed)
	build_layer_list(feeds)
	start_clock()


func start_clock() -> void:
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(_tick_clock)
	add_child(timer)
	_tick_clock()


func _tick_clock() -> void:
	_clock.text = Time.get_datetime_string_from_system(true).replace("T", " ") + "Z"


func build_layer_list(feeds: Array) -> void:
	for child in _layers_box.get_children():
		child.queue_free()
	_layer_rows.clear()
	for feed in feeds:
		_add_layer_row(feed)


func _add_layer_row(feed: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var cb := CheckBox.new()
	cb.button_pressed = feed.get("enabled", true) != false
	cb.toggled.connect(_on_layer_toggled.bind(String(feed.get("id", ""))))

	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(9, 9)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	swatch.color = _feed_color(feed)

	var name_label := Label.new()
	name_label.text = String(feed.get("name", feed.get("id", "?")))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_font_size_override("font_size", 12)

	var count_label := Label.new()
	count_label.text = "—"
	count_label.add_theme_font_size_override("font_size", 10)
	count_label.add_theme_color_override("font_color", COL_DIM)

	row.add_child(cb)
	row.add_child(swatch)
	row.add_child(name_label)
	row.add_child(count_label)
	_layers_box.add_child(row)
	_layer_rows[String(feed.get("id", ""))] = {cb = cb, count = count_label}


func _on_layer_toggled(on: bool, feed_id: String) -> void:
	if on:
		for other_id in _layer_rows:
			if other_id != feed_id:
				(_layer_rows[other_id].cb as CheckBox).set_pressed_no_signal(false)
	App.set_feed_visible(feed_id, on)


func sync_checkboxes(visible_feed_id: String) -> void:
	for id in _layer_rows:
		var cb: CheckBox = _layer_rows[id].cb
		cb.set_pressed_no_signal(id == visible_feed_id)


func set_count(feed_id: String, count: int) -> void:
	if _layer_rows.has(feed_id):
		(_layer_rows[feed_id].count as Label).text = str(count)


# ---------------------------------------------------------------- news pane
func render_news(feed: Dictionary, geojson: Dictionary) -> void:
	if feed.get("newsFeed") != true:
		return
	_news_feed = feed
	_news_geo = geojson
	for child in _news_box.get_children():
		child.queue_free()
	var features: Array = geojson.get("features", [])
	for index in features.size():
		var p: Dictionary = features[index].get("properties", {})
		var btn := Button.new()
		btn.flat = true
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 11)
		btn.add_theme_color_override("font_color", COL_TEXT)
		btn.add_theme_color_override("font_hover_color", Color8(232, 246, 255))
		btn.add_theme_stylebox_override("normal", _news_style(Color(1, 1, 1, 0.02)))
		btn.add_theme_stylebox_override("hover", _news_style(Color(0.13, 0.83, 0.93, 0.08)))
		btn.text = _news_title(p, feed)
		var meta := _news_meta(p)
		if meta != "":
			btn.text += "\n" + meta
		btn.pressed.connect(_on_news_clicked.bind(index))
		_news_box.add_child(btn)


func _on_news_clicked(index: int) -> void:
	var features: Array = _news_geo.get("features", [])
	var f: Dictionary = features[index]
	show_info(f.get("properties", {}), _news_feed)
	var coords: Variant = f.get("geometry", {}).get("coordinates")
	if coords is Array and (coords as Array).size() >= 2:
		globe.fly_to_point(float((coords as Array)[1]), float((coords as Array)[0]))


func _news_title(p: Dictionary, feed: Dictionary) -> String:
	var a := _s(p.get("actor1"))
	var b := _s(p.get("actor2"))
	if a != "" and b != "":
		return "%s ↔ %s" % [a, b]
	var n := _s(p.get("name"))
	if n != "":
		return n
	var t := _s(p.get("title"))
	if t != "":
		return t
	return String(feed.get("name", ""))


func _news_meta(p: Dictionary) -> String:
	var parts := PackedStringArray()
	var date_s := _s(p.get("date"))
	if date_s != "":
		parts.append(date_s)
	if p.get("tone") != null:
		parts.append("tone %s" % _fmt(p.tone))
	if p.get("quadClass") != null:
		parts.append("class %s" % _fmt(p.quadClass))
	return " · ".join(parts)


# ---------------------------------------------------------------- info card
func show_info(props: Dictionary, feed: Dictionary) -> void:
	_info.visible = true
	_info_title.text = String(feed.get("name", ""))
	for child in _info_body.get_children():
		child.queue_free()
	for def in (feed.get("popup", []) as Array):
		var v: Variant = props.get(def.property)
		if v == null or _fmt(v) == "":
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var key := Label.new()
		key.text = String(def.get("label", def.property))
		key.custom_minimum_size = Vector2(110, 0)
		key.add_theme_font_size_override("font_size", 11)
		key.add_theme_color_override("font_color", COL_DIM)
		row.add_child(key)
		if def.get("url") == true:
			var link := LinkButton.new()
			link.text = "open"
			link.uri = String(v)
			link.add_theme_font_size_override("font_size", 11)
			link.add_theme_color_override("font_color", COL_ACCENT)
			link.add_theme_color_override("font_hover_color", COL_TEXT)
			link.button_up.connect(OS.shell_open.bind(String(v)))
			row.add_child(link)
		else:
			var val := Label.new()
			val.text = _fmt(v)
			val.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			val.add_theme_font_size_override("font_size", 11)
			row.add_child(val)
		_info_body.add_child(row)
	_add_legend(feed)


func _add_legend(feed: Dictionary) -> void:
	var style: Dictionary = feed.get("style", {})
	if not style.has("legend"):
		return
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var colors: Dictionary = style.get("colors", {})
	var legend: Dictionary = style.legend
	for key in legend:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(9, 9)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		sw.color = _hex(String(colors.get(key, "#999999")), Color8(153, 153, 153))
		var lbl := Label.new()
		lbl.text = String(legend[key])
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.add_theme_color_override("font_color", COL_DIM)
		row.add_child(sw)
		row.add_child(lbl)
		box.add_child(row)
	_info_body.add_child(box)


# -------------------------------------------------------------- scratchpad
func _open_scratchpad() -> void:
	_scratch.visible = true
	_scratch_edit.text = ""
	_scratch_edit.grab_focus()


func _close_scratchpad() -> void:
	_scratch.visible = false
	_scratch_edit.text = ""
	_scratch_edit.release_focus()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SLASH and not event.ctrl_pressed and not event.alt_pressed and not _scratch.visible:
			_open_scratchpad()
			get_viewport().set_input_as_handled()


func _on_scratch_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			_close_scratchpad()
		elif (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER) and event.ctrl_pressed:
			_submit_scratch()


func _submit_scratch() -> void:
	var url := _scratch_edit.text.strip_edges()
	if url == "":
		return
	_close_scratchpad()
	add_adhoc_feed(url)


func add_adhoc_feed(url: String) -> void:
	var csv_re := RegEx.create_from_string("(?i)\\.csv(\\?|$)")
	var rss_re := RegEx.create_from_string("(?i)(\\.xml|\\.rss|\\.rdf|feed=)")
	var guessed := "geojson"
	if csv_re != null and csv_re.search(url) != null:
		guessed = "csv"
	elif rss_re != null and rss_re.search(url) != null:
		guessed = "rss"
	var name := url.replace("https://", "").replace("http://", "")
	if name.length() > 42:
		name = name.substr(0, 42)
	var feed := {
		id = "adhoc-%06x" % (randi() % 0xFFFFFF),
		name = name,
		type = guessed,
		url = url,
		enabled = true,
		clickable = true,
	}
	App.status("loading ad-hoc feed %s…" % name)
	var res: Dictionary = await loader.load_feed(feed)
	if not res.ok:
		App.status("ad-hoc feed failed: %s" % res.error)
		return
	App.feeds.append(feed)
	App.cache_parsed(feed.id, res.geojson)
	_add_layer_row(feed)
	var n := (res.geojson.get("features", []) as Array).size()
	set_count(feed.id, n)
	App.set_feed_visible(feed.id, true)
	App.status("ad-hoc feed loaded: %s (%d)" % [name, n])


# ---------------------------------------------------------------- status
func _on_status(text: String) -> void:
	_status_label.text = text
	DisplayServer.window_set_title("Ithildin — %s" % text)


func _on_view_changed() -> void:
	_overlay.queue_redraw()


# ---------------------------------------------------------------- overlay
class ClusterOverlay extends Control:
	var globe_ref: Node = null

	func _draw() -> void:
		if globe_ref == null:
			return
		var font := ThemeDB.fallback_font
		for c in globe_ref.cluster_cells_public():
			var center := Vector2(float(c.x), float(c.y))
			var n := int(c.count)
			var r := 7.0 + minf(6.0, float(n) / 60.0)
			draw_circle(center, r + 2.0, Color8(5, 7, 12))
			draw_circle(center, r, Color(0.13, 0.83, 0.93, 0.95))
			var txt := str(n)
			var ts := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11)
			draw_string(font, center + Vector2(-ts.x / 2.0, 4.0), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color.WHITE)


# ---------------------------------------------------------------- skeleton
func _build_root() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_overlay = ClusterOverlay.new()
	_overlay.name = "ClusterOverlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_overlay)

	_build_side()
	_build_info()
	_build_scratch()
	_build_status()


func _build_side() -> void:
	var side := PanelContainer.new()
	side.name = "Side"
	side.anchor_bottom = 1.0
	side.offset_left = 10.0
	side.offset_top = 10.0
	side.offset_right = 310.0
	side.offset_bottom = -30.0
	side.add_theme_stylebox_override("panel", _panel_style())
	_root.add_child(side)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	side.add_child(box)

	var brand := HBoxContainer.new()
	brand.add_theme_constant_override("separation", 8)
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.color = COL_ACCENT
	var word := Label.new()
	word.text = "ITHILDIN"
	word.add_theme_font_size_override("font_size", 13)
	word.add_theme_color_override("font_color", Color8(232, 246, 255))
	_clock = Label.new()
	_clock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_clock.add_theme_font_size_override("font_size", 11)
	_clock.add_theme_color_override("font_color", COL_DIM)
	var home_btn := Button.new()
	home_btn.text = "⌂"
	home_btn.tooltip_text = "North-up over your network location at 1000 km"
	home_btn.pressed.connect(_on_home_pressed)
	brand.add_child(dot)
	brand.add_child(word)
	brand.add_child(_clock)
	brand.add_child(home_btn)
	box.add_child(brand)

	var pulse := Timer.new()
	pulse.wait_time = 1.2
	pulse.autostart = true
	pulse.timeout.connect(func(): dot.visible = not dot.visible)
	add_child(pulse)

	box.add_child(_header("LAYERS"))
	_layers_box = VBoxContainer.new()
	_layers_box.add_theme_constant_override("separation", 2)
	box.add_child(_layers_box)

	box.add_child(_header("NEWS / EVENTS"))
	var news_scroll := ScrollContainer.new()
	news_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	news_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	news_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_news_box = VBoxContainer.new()
	_news_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	news_scroll.add_child(_news_box)
	box.add_child(news_scroll)


func _on_home_pressed() -> void:
	globe.reset_home()


func _build_info() -> void:
	_info = PanelContainer.new()
	_info.name = "Info"
	_info.anchor_left = 1.0
	_info.anchor_right = 1.0
	_info.offset_left = -334.0
	_info.offset_right = -14.0
	_info.offset_top = 14.0
	_info.offset_bottom = 14.0
	_info.visible = false
	_info.add_theme_stylebox_override("panel", _panel_style())
	_root.add_child(_info)

	var info_box := VBoxContainer.new()
	info_box.add_theme_constant_override("separation", 4)
	_info.add_child(info_box)
	var head := HBoxContainer.new()
	_info_title = Label.new()
	_info_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_title.add_theme_font_size_override("font_size", 13)
	_info_title.add_theme_color_override("font_color", Color8(232, 246, 255))
	var close_btn := Button.new()
	close_btn.text = "×"
	close_btn.flat = true
	close_btn.add_theme_color_override("font_color", COL_DIM)
	close_btn.pressed.connect(func(): _info.visible = false)
	head.add_child(_info_title)
	head.add_child(close_btn)
	info_box.add_child(head)
	_info_body = VBoxContainer.new()
	_info_body.add_theme_constant_override("separation", 2)
	info_box.add_child(_info_body)


func _build_scratch() -> void:
	_scratch = PanelContainer.new()
	_scratch.name = "Scratch"
	_scratch.anchor_top = 1.0
	_scratch.anchor_bottom = 1.0
	_scratch.offset_left = 320.0
	_scratch.offset_right = 700.0
	_scratch.offset_top = -76.0
	_scratch.offset_bottom = -30.0
	_scratch.visible = false
	_scratch.add_theme_stylebox_override("panel", _panel_style())
	_root.add_child(_scratch)
	_scratch_edit = LineEdit.new()
	_scratch_edit.placeholder_text = "Paste a URL (GeoJSON, CSV, RSS) — hit Ctrl+Enter to add it as a layer"
	_scratch_edit.add_theme_font_size_override("font_size", 12)
	_scratch_edit.gui_input.connect(_on_scratch_gui_input)
	_scratch.add_child(_scratch_edit)


func _build_status() -> void:
	var status_panel := PanelContainer.new()
	status_panel.name = "StatusBar"
	status_panel.anchor_right = 1.0
	status_panel.anchor_top = 1.0
	status_panel.anchor_bottom = 1.0
	status_panel.offset_top = -20.0
	status_panel.add_theme_stylebox_override("panel", _status_style())
	_root.add_child(status_panel)
	_status_label = Label.new()
	_status_label.text = "loading config…"
	_status_label.add_theme_font_size_override("font_size", 10)
	_status_label.add_theme_color_override("font_color", COL_DIM)
	status_panel.add_child(_status_label)


func _header(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", COL_DIM)
	return lbl


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.035, 0.055, 0.086, 0.92)
	sb.border_color = COL_EDGE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


func _status_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.027, 0.047, 0.9)
	sb.border_color = COL_EDGE
	sb.border_width_top = 1
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	return sb


func _news_style(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = COL_EDGE
	sb.border_width_left = 2
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _feed_color(feed: Dictionary) -> Color:
	var style: Dictionary = feed.get("style", {})
	return _hex(String(style.get("color", "#22d3ee")), COL_ACCENT)


func _hex(s: String, fallback: Color) -> Color:
	return PointCloud._css_color(s, fallback)


func _fmt(v) -> String:
	if v is float:
		var f: float = v
		if is_equal_approx(f, roundf(f)) and absf(f) < 1e15:
			return str(int(roundf(f)))
		return String.num(f, 2)
	return str(v)


static func _s(v) -> String:
	if v == null:
		return ""
	return String(v)
