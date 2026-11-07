extends CanvasLayer
## HUD, chat with the agent and the player's code console.

signal player_message(text: String)
signal run_code_requested(code: String)

const HELP := "WASD muovi · Spazio salta · Shift corri · F volo (Spazio/C su e giù)\nInvio chat (@Nome per un agente) · Tab console codice · B costruzione · X elimina · Ctrl+Z annulla · Esc menu\n/aiuto per i comandi"

const CODE_TEMPLATE := """extends Node3D
# Questo script diventa un oggetto 4 m davanti a te.

var t := 0.0

func _ready():
	var m := MeshInstance3D.new()
	m.mesh = TorusMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#ff8a3d")
	mat.emission_enabled = true
	mat.emission = Color("#ff8a3d")
	m.mesh.material = mat
	add_child(m)

func _process(delta):
	t += delta
	rotation.x = t
	rotation.y = t * 0.7
"""

var author_colors := {
	"Tu": "#ffffff",
	"Sistema": "#ffcf6c",
	"Azione": "#7d8799",
	"Pensiero": "#6d7585",
}

var chat_log: RichTextLabel
var chat_input: LineEdit
var code_panel: PanelContainer
var code_edit: CodeEdit
var code_output: Label
var status_panel: PanelContainer
const HUD_MUTED := Color(0.62, 0.67, 0.74)
const HUD_BUSY := Color(1.0, 0.82, 0.48)
var _hud_right: Dictionary
var _hud_left: Dictionary
var _hud_key := ""
var menu      # settings_menu.gd
var main      # main.gd
var ui_scale := 1.0   # user preference on top of the screen's own scale (Retina = 2x)

const SETTINGS_PATH := "user://settings.cfg"
var photo_panel: PanelContainer
var photo_rect: TextureRect
var photo_label: Label
var _photo_t := 0.0


func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		ui_scale = float(cfg.get_value("ui", "scale", 1.0))
		if cfg.has_section_key("chat", "filter") and cfg.get_value("chat", "filter") is Dictionary:
			chat_filter.merge(cfg.get_value("chat", "filter"), true)
	apply_scale()
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# --- status panels: builders top right (with time and spending), NPCs top left
	_hud_right = _hud_panel(root, false)
	_hud_left = _hud_panel(root, true)

	var cross := Label.new()
	cross.text = "+"
	cross.anchor_left = 0.5
	cross.anchor_right = 0.5
	cross.anchor_top = 0.5
	cross.anchor_bottom = 0.5
	cross.offset_left = -6
	cross.offset_top = -14
	cross.add_theme_font_size_override("font_size", 22)
	cross.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cross)

	# --- chat
	var chat_panel := PanelContainer.new()
	chat_panel.anchor_top = 1.0
	chat_panel.anchor_bottom = 1.0
	chat_panel.offset_left = 16
	chat_panel.offset_right = 16 + 430
	chat_panel.offset_top = -16 - 230
	chat_panel.offset_bottom = -16
	chat_panel.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(chat_panel)
	var vb := VBoxContainer.new()
	chat_panel.add_child(vb)
	# filters: what the chat shows besides the conversation with you
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 4)
	vb.add_child(chips)
	var show_l := Label.new()
	show_l.text = "Mostra"
	show_l.add_theme_font_size_override("font_size", 11)
	show_l.add_theme_color_override("font_color", HUD_MUTED)
	chips.add_child(show_l)
	for k in CHAT_KINDS:
		var c := Button.new()
		c.text = CHAT_KINDS[k]
		c.toggle_mode = true
		c.focus_mode = Control.FOCUS_NONE
		c.add_theme_font_size_override("font_size", 11)
		c.add_theme_stylebox_override("normal", _chip_style(false))
		c.add_theme_stylebox_override("hover", _chip_style(false))
		c.add_theme_stylebox_override("pressed", _chip_style(true))
		c.add_theme_stylebox_override("hover_pressed", _chip_style(true))
		c.add_theme_color_override("font_color", HUD_MUTED)
		c.add_theme_color_override("font_pressed_color", Color.WHITE)
		c.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
		c.button_pressed = chat_filter[k]
		c.toggled.connect(func(on): set_chat_filter(k, on))
		chips.add_child(c)
		_chips[k] = c
	chat_log = RichTextLabel.new()
	chat_log.bbcode_enabled = true
	chat_log.scroll_following = true
	chat_log.selection_enabled = true
	chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_log.add_theme_font_size_override("normal_font_size", 13)
	chat_log.add_theme_font_size_override("bold_font_size", 13)
	chat_log.add_theme_font_size_override("italics_font_size", 12)
	vb.add_child(chat_log)
	chat_input = LineEdit.new()
	chat_input.placeholder_text = "Invio per scrivere (@Nome per un agente) · Esc menu e comandi"
	chat_input.add_theme_font_size_override("font_size", 13)
	chat_input.text_submitted.connect(_on_chat_submitted)
	vb.add_child(chat_input)

	# --- code console
	code_panel = PanelContainer.new()
	code_panel.anchor_left = 1.0
	code_panel.anchor_right = 1.0
	code_panel.anchor_bottom = 1.0
	code_panel.offset_left = -620
	code_panel.offset_right = -16
	code_panel.offset_top = 150
	code_panel.offset_bottom = -16
	code_panel.add_theme_stylebox_override("panel", _panel_style())
	code_panel.visible = false
	root.add_child(code_panel)
	var cvb := VBoxContainer.new()
	code_panel.add_child(cvb)
	var title := Label.new()
	title.text = "Console GDScript · Ctrl/Cmd+Invio per eseguire · Esc per chiudere"
	title.add_theme_color_override("font_color", Color(0.6, 0.9, 1.0))
	cvb.add_child(title)
	code_edit = CodeEdit.new()
	code_edit.text = CODE_TEMPLATE
	code_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	code_edit.gutters_draw_line_numbers = true
	code_edit.auto_brace_completion_enabled = true
	code_edit.indent_automatic = true
	code_edit.add_theme_font_size_override("font_size", 15)
	code_edit.syntax_highlighter = _highlighter()
	cvb.add_child(code_edit)
	var hb := HBoxContainer.new()
	cvb.add_child(hb)
	var run_btn := Button.new()
	run_btn.text = "Esegui"
	run_btn.focus_mode = Control.FOCUS_NONE
	run_btn.pressed.connect(func(): run_code_requested.emit(code_edit.text))
	hb.add_child(run_btn)
	var close_btn := Button.new()
	close_btn.text = "Chiudi"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(_close_all)
	hb.add_child(close_btn)
	# --- last photo taken by an agent
	photo_panel = PanelContainer.new()
	photo_panel.anchor_left = 1.0
	photo_panel.anchor_right = 1.0
	photo_panel.anchor_top = 1.0
	photo_panel.anchor_bottom = 1.0
	photo_panel.offset_left = -16 - 360
	photo_panel.offset_right = -16
	photo_panel.offset_top = -16 - 240
	photo_panel.offset_bottom = -16
	photo_panel.add_theme_stylebox_override("panel", _panel_style())
	photo_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	photo_panel.visible = false
	root.add_child(photo_panel)
	var pvb := VBoxContainer.new()
	photo_panel.add_child(pvb)
	photo_label = Label.new()
	photo_label.add_theme_font_size_override("font_size", 14)
	pvb.add_child(photo_label)
	photo_rect = TextureRect.new()
	photo_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	photo_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	photo_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	photo_rect.custom_minimum_size = Vector2(336, 189)
	pvb.add_child(photo_rect)

	code_output = Label.new()
	code_output.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	code_output.custom_minimum_size = Vector2(0, 60)
	code_output.add_theme_font_size_override("font_size", 13)
	cvb.add_child(code_output)


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.04, 0.07, 0.72)
	sb.border_color = Color(0.3, 0.8, 1.0, 0.25)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	return sb


func _highlighter() -> CodeHighlighter:
	var hl := CodeHighlighter.new()
	hl.number_color = Color("#b5cea8")
	hl.symbol_color = Color("#abc8ff")
	hl.function_color = Color("#66e6ff")
	hl.member_variable_color = Color("#bce0ff")
	for k in ["extends", "func", "var", "const", "if", "elif", "else", "for", "while", "in", "return", "and", "or", "not", "true", "false", "null", "self", "match", "pass", "break", "continue", "signal", "await", "static", "class_name", "@onready", "@export"]:
		hl.add_keyword_color(k, Color("#ff7085"))
	hl.add_color_region("#", "", Color("#7a8290"), true)
	hl.add_color_region("\"", "\"", Color("#ffeca1"))
	return hl


## Kinds of chat lines that can be hidden (the conversation with the player always shows).
const CHAT_KINDS := {"squadra": "Squadra", "azioni": "Azioni", "pensieri": "Pensieri", "sistema": "Sistema"}
const CHAT_KEEP := 400
var chat_filter := {"squadra": true, "azioni": false, "pensieri": false, "sistema": true}
var _chat_entries: Array = []   # [author, text], also the hidden ones
var _chips := {}


func _chip_style(on: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.3, 0.8, 1.0, 0.28) if on else Color(1, 1, 1, 0.05)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 1
	sb.content_margin_bottom = 2
	return sb


static func chat_kind(author: String) -> String:
	if author == "Azione":
		return "azioni"
	if author == "Pensiero":
		return "pensieri"
	if author == "Sistema":
		return "sistema"
	if "→" in author:
		return "squadra"
	return ""   # you, and agents talking to you


func add_chat(author: String, text: String) -> void:
	_chat_entries.append([author, text])
	if _chat_entries.size() > CHAT_KEEP:
		_chat_entries = _chat_entries.slice(_chat_entries.size() - CHAT_KEEP)
	if _shown(author):
		_chat_line(author, text)


func _shown(author: String) -> bool:
	var k := chat_kind(author)
	return k == "" or chat_filter.get(k, true)


func _chat_line(author: String, text: String) -> void:
	var color: String = author_colors.get(author.get_slice(" ", 0), "#dddddd")
	var safe := text.replace("[", "[lb]")
	if author in ["Azione", "Pensiero"]:
		chat_log.append_text("[color=%s][i]%s[/i][/color]\n" % [color, safe])
	else:
		chat_log.append_text("[color=%s][b]%s:[/b][/color] %s\n" % [color, author, safe])


## Shows or hides a kind of messages (old ones too) and remembers the choice.
func set_chat_filter(kind: String, on: bool) -> void:
	if chat_filter.get(kind) == on:
		return
	chat_filter[kind] = on
	if _chips.has(kind) and _chips[kind].button_pressed != on:
		_chips[kind].set_pressed_no_signal(on)
	chat_log.clear()
	for e in _chat_entries:
		if _shown(e[0]):
			_chat_line(e[0], e[1])
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("chat", "filter", chat_filter)
	cfg.save(SETTINGS_PATH)


func show_photo(author: String, img: Image) -> void:
	photo_rect.texture = ImageTexture.create_from_image(img)
	photo_label.text = "Foto scattata da " + author
	photo_label.add_theme_color_override("font_color", Color.from_string(author_colors.get(author, "#ffffff"), Color.WHITE))
	photo_panel.visible = true
	_photo_t = 9.0


func _process(delta: float) -> void:
	if _photo_t > 0.0:
		_photo_t -= delta
		if _photo_t <= 0.0:
			photo_panel.visible = false


func set_author_color(author: String, color: Color) -> void:
	author_colors[author] = "#" + color.to_html(false)


## Scales all the 2D interface: the screen's density (2x on Retina) times the user's choice.
func apply_scale() -> void:
	get_window().content_scale_factor = DisplayServer.screen_get_scale() * ui_scale


func set_ui_scale(value: float) -> void:
	ui_scale = clampf(value, 0.5, 2.5)
	apply_scale()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("ui", "scale", ui_scale)
	cfg.save(SETTINGS_PATH)


func _hud_label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _hud_rule() -> Control:
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, 0.08)
	r.custom_minimum_size = Vector2(0, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## One status panel: a header (title and a value on the right), a row per agent, a footer.
func _hud_panel(root: Control, left: bool) -> Dictionary:
	var panel := PanelContainer.new()
	if left:
		panel.offset_left = 16
		panel.offset_right = 16 + 240
	else:
		panel.anchor_left = 1.0
		panel.anchor_right = 1.0
		panel.offset_left = -16 - 270
		panel.offset_right = -16
	panel.offset_top = 14
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := _panel_style()
	st.bg_color = Color(0.03, 0.04, 0.07, 0.6)
	st.content_margin_left = 14
	st.content_margin_right = 14
	st.content_margin_top = 10
	st.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", st)
	root.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(col)
	var head := HBoxContainer.new()
	col.add_child(head)
	var title := _hud_label(13 if left else 20, HUD_MUTED if left else Color(0.95, 0.97, 1.0))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var value := _hud_label(13, HUD_MUTED)
	value.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(value)
	col.add_child(_hud_rule())
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 5)
	col.add_child(grid)
	var rule := _hud_rule()
	col.add_child(rule)
	var footer := _hud_label(12, HUD_MUTED)
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(footer)
	return {"panel": panel, "title": title, "value": value, "grid": grid, "rule": rule, "footer": footer}


func _hud_rows(grid: GridContainer, rows: Array) -> void:
	if grid.get_child_count() != rows.size() * 3:
		for c in grid.get_children():
			grid.remove_child(c)
			c.queue_free()
		for i in rows.size():
			var dot := ColorRect.new()
			dot.custom_minimum_size = Vector2(7, 7)
			dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			grid.add_child(dot)
			var nm := _hud_label(14, Color.WHITE)
			nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(nm)
			var st := _hud_label(13, HUD_MUTED)
			st.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			st.custom_minimum_size.x = 100
			st.clip_text = true
			st.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			grid.add_child(st)
	for i in rows.size():
		var a: Array = rows[i]
		var dot: ColorRect = grid.get_child(i * 3)
		var nm: Label = grid.get_child(i * 3 + 1)
		var st: Label = grid.get_child(i * 3 + 2)
		dot.color = a[1]
		nm.text = a[0]
		nm.add_theme_color_override("font_color", Color(a[1]).lightened(0.25))
		var busy: bool = a[2] != ""
		st.text = a[2] if busy else "in ascolto"
		st.add_theme_color_override("font_color", HUD_BUSY if busy else Color(HUD_MUTED, 0.6))


## Updates the status panels. d = {time, spend, over, agents: [[name, color, status]],
## footer, npcs: [[name, color, status]], npc_footer}. Rebuilt only when something changed.
func set_hud(d: Dictionary) -> void:
	var key := str(d)
	if key == _hud_key:
		return
	_hud_key = key
	var r: Dictionary = _hud_right
	r.title.text = d.time
	r.value.text = d.spend
	r.value.add_theme_color_override("font_color", Color(1, 0.48, 0.48) if d.over else HUD_MUTED)
	_hud_rows(r.grid, d.agents)
	r.footer.text = d.footer
	var l: Dictionary = _hud_left
	var npcs: Array = d.npcs
	l.panel.visible = not npcs.is_empty()
	l.title.text = "NPC"
	l.value.text = "%d nel mondo" % npcs.size()
	_hud_rows(l.grid, npcs)
	l.footer.text = d.npc_footer


func show_code_result(ok: bool, text: String) -> void:
	code_output.text = text
	code_output.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6) if ok else Color(1.0, 0.5, 0.5))


func _on_chat_submitted(text: String) -> void:
	chat_input.clear()
	chat_input.release_focus()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	text = text.strip_edges()
	if text != "":
		player_message.emit(text)


func _close_all() -> void:
	var f := get_viewport().gui_get_focus_owner()
	if f:
		f.release_focus()
	code_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k: Key = event.keycode
	if k == KEY_ESCAPE:
		if menu and menu.visible:
			menu.close()
		elif get_viewport().gui_get_focus_owner() != null or code_panel.visible:
			_close_all()
		elif main and main.build.active and (main.build.grabbed or main.build.selected_id != ""):
			return  # build mode uses Esc to cancel / deselect
		elif menu:
			menu.open()
		get_viewport().set_input_as_handled()
	elif (k == KEY_ENTER or k == KEY_KP_ENTER) and code_edit.has_focus() and (event.ctrl_pressed or event.meta_pressed):
		run_code_requested.emit(code_edit.text)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if get_viewport().gui_get_focus_owner() != null:
		return
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			chat_input.grab_focus()
			get_viewport().set_input_as_handled()
		KEY_TAB:
			code_panel.visible = true
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			code_edit.grab_focus()
			get_viewport().set_input_as_handled()
