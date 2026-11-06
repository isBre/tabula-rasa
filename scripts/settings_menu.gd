extends Control
## Simple menu (Esc): personal settings (remembered), agents, world, spending, actions.

const SETTINGS_PATH := "user://settings.cfg"

var main   # main.gd
var _built := false
var _syncing := false
var _controls := {}
var _confirm: ConfirmationDialog


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


func open() -> void:
	if not _built:
		_build()
	_sync()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Personal settings saved on this computer, applied at startup.
static func load_personal(player, ui) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	ui.ui_scale = float(cfg.get_value("ui", "scale", 1.0))
	ui.apply_scale()
	player.mouse_sens = 0.0022 * float(cfg.get_value("controls", "mouse", 1.0))
	player.base_fov = float(cfg.get_value("controls", "fov", 75.0))
	player.bob_amount = 0.035 if bool(cfg.get_value("controls", "bob", true)) else 0.0


func _save_personal(section: String, key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value(section, key, value)
	cfg.save(SETTINGS_PATH)


func _build() -> void:
	_built = true
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(480, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.09, 0.95)
	sb.border_color = Color(0.3, 0.8, 1.0, 0.35)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "Tabula Rasa"
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	_section(vb, "Interfaccia e controlli")
	_slider(vb, "ui_scale", "Dimensione interfaccia", 0.7, 1.6, 0.05, func(v):
		main.ui.set_ui_scale(v), "%.2f")
	_slider(vb, "mouse", "Sensibilità mouse", 0.4, 2.5, 0.05, func(v):
		main.player.mouse_sens = 0.0022 * v
		_save_personal("controls", "mouse", v), "%.2f")
	_slider(vb, "fov", "Campo visivo", 60.0, 100.0, 1.0, func(v):
		main.player.base_fov = v
		_save_personal("controls", "fov", v), "%d°")
	_check(vb, "bob", "Oscillazione della camera", func(on):
		main.player.bob_amount = 0.035 if on else 0.0
		_save_personal("controls", "bob", on))

	_section(vb, "Agenti")
	_check(vb, "autonomy", "Lavorano anche da soli (autonomia)", func(on): main.team.autonomy = on)
	_check(vb, "follow", "Ti raggiungono quando ti allontani", func(on): main.team.set_follow(on))
	_spin(vb, "budget", "Tetto di spesa ($)", 0.0, 100.0, 0.5, func(v): main.team.set_budget(v))

	_section(vb, "Mondo")
	_slider(vb, "time", "Ora del giorno", 0.0, 24.0, 0.25, func(v): main.env.set_values({"time_of_day": v}), "%05.2f")
	_spin(vb, "cycle", "Giorno completo in (min, 0 = fermo)", 0.0, 120.0, 1.0, func(v): main.env.set_values({"cycle_minutes": v}))
	var row := _row(vb, "Terreno")
	var opt := OptionButton.new()
	for g in main.env.GROUNDS.keys():
		opt.add_item(g)
	opt.item_selected.connect(func(i):
		if not _syncing:
			main.env.set_values({"ground": opt.get_item_text(i)}))
	row.add_child(opt)
	_controls["ground"] = opt

	vb.add_child(HSeparator.new())
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 8)
	vb.add_child(buttons)
	_button(buttons, "Riprendi", close)
	_button(buttons, "Salva mondo", func(): main.save_world("mondo", true))
	_button(buttons, "Annulla modifica", func(): main._undo())
	_button(buttons, "Reset totale", func(): _confirm.popup_centered())
	_button(buttons, "Esci", func():
		main.save_world(main.AUTOSAVE, false)
		get_tree().quit())
	_confirm = ConfirmationDialog.new()
	_confirm.title = "Reset totale"
	_confirm.dialog_text = "Svuotare il mondo e cancellare la memoria degli agenti, la lavagna e la cronologia?\nIl mondo attuale verrà salvato in saves/prima_del_reset.json."
	_confirm.ok_button_text = "Azzera tutto"
	_confirm.cancel_button_text = "Annulla"
	_confirm.confirmed.connect(func():
		main.full_reset()
		close())
	add_child(_confirm)
	var hint := Label.new()
	hint.text = "Esc per tornare al gioco · /aiuto in chat per tutti i comandi"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)


func _sync() -> void:
	_syncing = true
	_controls["ui_scale"].value = main.ui.ui_scale
	_controls["mouse"].value = main.player.mouse_sens / 0.0022
	_controls["fov"].value = main.player.base_fov
	_controls["bob"].button_pressed = main.player.bob_amount > 0.0
	_controls["autonomy"].button_pressed = main.team.autonomy
	_controls["follow"].button_pressed = main.team.follow
	_controls["budget"].value = main.team.budget_usd
	_controls["time"].value = main.env.time_of_day
	_controls["cycle"].value = main.env.cycle_minutes
	var opt: OptionButton = _controls["ground"]
	for i in opt.item_count:
		if opt.get_item_text(i) == main.env.ground:
			opt.select(i)
	_syncing = false


func _section(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.45, 0.85, 1.0))
	l.add_theme_font_size_override("font_size", 15)
	parent.add_child(l)


func _row(parent: Control, text: String) -> HBoxContainer:
	var hb := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = 230
	l.add_theme_font_size_override("font_size", 14)
	hb.add_child(l)
	parent.add_child(hb)
	return hb


func _slider(parent: Control, key: String, text: String, lo: float, hi: float, step: float, on_change: Callable, fmt: String) -> void:
	var hb := _row(parent, text)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var val := Label.new()
	val.custom_minimum_size.x = 48
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_size_override("font_size", 14)
	s.value_changed.connect(func(v):
		val.text = fmt % v
		if not _syncing:
			on_change.call(v))
	hb.add_child(s)
	hb.add_child(val)
	_controls[key] = s


func _check(parent: Control, key: String, text: String, on_change: Callable) -> void:
	var hb := _row(parent, text)
	var c := CheckButton.new()
	c.toggled.connect(func(on):
		if not _syncing:
			on_change.call(on))
	hb.add_child(c)
	_controls[key] = c


func _spin(parent: Control, key: String, text: String, lo: float, hi: float, step: float, on_change: Callable) -> void:
	var hb := _row(parent, text)
	var sp := SpinBox.new()
	sp.min_value = lo
	sp.max_value = hi
	sp.step = step
	sp.value_changed.connect(func(v):
		if not _syncing:
			on_change.call(v))
	hb.add_child(sp)
	_controls[key] = sp


func _button(parent: Control, text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(action)
	parent.add_child(b)
