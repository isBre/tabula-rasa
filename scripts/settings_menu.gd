extends Control
## Simple menu (Esc): personal settings (remembered), agents, world, spending, actions.

const SETTINGS_PATH := "user://settings.cfg"

var main   # main.gd
var _built := false
var _syncing := false
var _controls := {}
var _confirm: ConfirmationDialog
var _remove_confirm: ConfirmationDialog
var _removing := ""
var _editing := ""
var _agent_list: VBoxContainer
var _lock_icon: Texture2D
var _full_only: Array = []   # form controls hidden when editing a built-in agent (models only)
var _add_button: Button
var _form: VBoxContainer
var _form_title: Label
var _form_sub: Label
var _form_head_style: StyleBoxFlat
var _tabs: TabContainer
var _style_tab: VBoxContainer
var _costs_tab: VBoxContainer
var _f_name: LineEdit
var _f_kind: OptionButton
var _f_role: TextEdit
var _f_color: ColorPickerButton
var _f_model: OptionButton
var _f_model_player: OptionButton
var _f_build: CheckBox
var _f_model_perm: CheckBox
var _f_see: CheckBox
var _f_error: Label
var _f_skin: OptionButton
var _f_hair_style: OptionButton
var _f_hair: ColorPickerButton
var _f_pants: ColorPickerButton
var _f_hat: OptionButton
var _f_height: HSlider


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


func open() -> void:
	if not _built:
		_build()
	_sync()
	_refresh_agents()
	_refresh_style()
	_refresh_costs()
	if _form:
		_close_form()
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
	panel.custom_minimum_size = Vector2(640, 560)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.09, 0.96)
	sb.border_color = Color(0.3, 0.8, 1.0, 0.35)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "Tabula Rasa"
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var tabs := TabContainer.new()
	_tabs = tabs
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.custom_minimum_size = Vector2(0, 430)
	vb.add_child(tabs)
	var settings_tab := _tab(tabs, "Impostazioni")
	var agents_tab := _tab(tabs, "Agenti")
	_style_tab = _tab(tabs, "Stile")
	_costs_tab = _tab(tabs, "Costi")
	var commands_tab := _tab(tabs, "Comandi")

	_section(settings_tab, "Interfaccia e controlli")
	_slider(settings_tab, "ui_scale", "Dimensione interfaccia", 0.7, 1.6, 0.05, func(v):
		main.ui.set_ui_scale(v), "%.2f")
	_slider(settings_tab, "mouse", "Sensibilità mouse", 0.4, 2.5, 0.05, func(v):
		main.player.mouse_sens = 0.0022 * v
		_save_personal("controls", "mouse", v), "%.2f")
	_slider(settings_tab, "fov", "Campo visivo", 60.0, 100.0, 1.0, func(v):
		main.player.base_fov = v
		_save_personal("controls", "fov", v), "%d°")
	_check(settings_tab, "bob", "Oscillazione della camera", func(on):
		main.player.bob_amount = 0.035 if on else 0.0
		_save_personal("controls", "bob", on))

	_section(settings_tab, "Chat: cosa mostrare oltre alla conversazione con te")
	for k in main.ui.CHAT_KINDS:
		var desc: String = {"squadra": "Squadra (gli agenti che parlano tra loro)", "azioni": "Azioni (ogni strumento che usano)", "pensieri": "Pensieri (le loro note interne)", "sistema": "Messaggi di sistema"}[k]
		_check(settings_tab, "chat_" + k, desc, func(on): main.ui.set_chat_filter(k, on))

	_section(settings_tab, "Squadra")
	_check(settings_tab, "autonomy", "Agenti: lavorano anche da soli", func(on): main.team.autonomy = on)
	_check(settings_tab, "npc_autonomy", "NPC: vivono anche da soli", func(on): main.team.npc_autonomy = on)
	_check(settings_tab, "follow", "Ti raggiungono quando ti allontani", func(on): main.team.set_follow(on))

	_section(settings_tab, "Mondo")
	_slider(settings_tab, "time", "Ora del giorno", 0.0, 24.0, 0.25, func(v): main.env.set_values({"time_of_day": v}), "%05.2f")
	_spin(settings_tab, "cycle", "Giorno completo in (min, 0 = fermo)", 0.0, 120.0, 1.0, func(v): main.env.set_values({"cycle_minutes": v}))
	var row := _row(settings_tab, "Terreno")
	var opt := OptionButton.new()
	for g in main.env.GROUNDS.keys():
		opt.add_item(g)
	opt.item_selected.connect(func(i):
		if not _syncing:
			main.env.set_values({"ground": opt.get_item_text(i)}))
	row.add_child(opt)
	_controls["ground"] = opt

	_build_agents_tab(agents_tab)
	_build_commands_tab(commands_tab)

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
	_remove_confirm = ConfirmationDialog.new()
	_remove_confirm.title = "Rimuovi agente"
	_remove_confirm.ok_button_text = "Rimuovi"
	_remove_confirm.cancel_button_text = "Annulla"
	_remove_confirm.confirmed.connect(func():
		var err: String = main.team.remove_agent(_removing)
		main.ui.add_chat("Sistema", err if err != "" else "%s ha lasciato il mondo." % _removing)
		_refresh_agents())
	add_child(_remove_confirm)
	var hint := Label.new()
	hint.text = "Esc per tornare al gioco"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)


## A tab page: a scrollable column.
func _tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(sc)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	sc.add_child(margin)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)
	return col


# ---------------------------------------------------------------- agents tab

func _build_agents_tab(tab: VBoxContainer) -> void:
	_agent_list = VBoxContainer.new()
	_agent_list.add_theme_constant_override("separation", 6)
	tab.add_child(_agent_list)
	var add := Button.new()
	add.text = "+ Nuovo agente o NPC"
	add.focus_mode = Control.FOCUS_NONE
	add.pressed.connect(func(): _open_form(""))
	tab.add_child(add)
	_add_button = add

	# create / edit form
	_form = VBoxContainer.new()
	_form.add_theme_constant_override("separation", 6)
	_form.visible = false
	tab.add_child(_form)
	var head := PanelContainer.new()
	_form_head_style = StyleBoxFlat.new()
	_form_head_style.bg_color = Color(1, 1, 1, 0.06)
	_form_head_style.set_corner_radius_all(6)
	_form_head_style.border_width_left = 4
	_form_head_style.content_margin_left = 10
	_form_head_style.content_margin_right = 10
	_form_head_style.content_margin_top = 6
	_form_head_style.content_margin_bottom = 6
	head.add_theme_stylebox_override("panel", _form_head_style)
	_form.add_child(head)
	var hh := HBoxContainer.new()
	hh.add_theme_constant_override("separation", 10)
	head.add_child(hh)
	var back := Button.new()
	back.text = "← Indietro"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_close_form)
	hh.add_child(back)
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(tv)
	_form_title = Label.new()
	_form_title.add_theme_font_size_override("font_size", 18)
	tv.add_child(_form_title)
	_form_sub = Label.new()
	_form_sub.add_theme_font_size_override("font_size", 12)
	_form_sub.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	tv.add_child(_form_sub)
	var r := _row(_form, "Nome")
	_f_name = LineEdit.new()
	_f_name.placeholder_text = "es. Oste, Guardia, Giardiniere"
	_f_name.max_length = 20
	_f_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(_f_name)
	_full_only.append(r)
	r = _row(_form, "Tipo")
	_full_only.append(r)
	_f_kind = OptionButton.new()
	_f_kind.fit_to_longest_item = false
	_f_kind.clip_text = true
	_f_kind.add_item("Costruttore (fa parte della squadra)")
	_f_kind.add_item("NPC (vive nel mondo, non costruisce)")
	_f_kind.item_selected.connect(func(i):
		_f_build.button_pressed = i == 0
		_f_model_perm.button_pressed = i == 0)
	_f_kind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(_f_kind)
	var l := Label.new()
	l.text = "Ruolo e personalità"
	l.add_theme_font_size_override("font_size", 14)
	_form.add_child(l)
	_full_only.append(l)
	_f_role = TextEdit.new()
	_f_role.custom_minimum_size = Vector2(0, 90)
	_f_role.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_f_role.placeholder_text = "Chi è, cosa fa, come parla. Es.: l'oste della taverna, burbero ma generoso, conosce tutti i pettegolezzi del villaggio."
	_form.add_child(_f_role)
	_full_only.append(_f_role)
	r = _row(_form, "Colore")
	_full_only.append(r)
	_f_color = ColorPickerButton.new()
	_f_color.custom_minimum_size = Vector2(80, 28)
	_f_color.edit_alpha = false
	r.add_child(_f_color)
	r = _row(_form, "Modello")
	_f_model = _model_picker(false)
	r.add_child(_f_model)
	r = _row(_form, "Quando gli scrivi tu")
	_f_model_player = _model_picker(true)
	r.add_child(_f_model_player)
	_f_build = _perm_box(_form, "Può costruire e modificare il mondo")
	_f_model_perm = _perm_box(_form, "Può creare modelli (laboratorio)")
	_f_see = _perm_box(_form, "Può vedere (foto e ispezioni, costano di più)")
	_full_only.append_array([_f_build, _f_model_perm, _f_see])

	# appearance (every agent, built-in ones too: it's only cosmetic)
	var al := Label.new()
	al.text = "Aspetto"
	al.add_theme_color_override("font_color", Color(0.45, 0.85, 1.0))
	al.add_theme_font_size_override("font_size", 14)
	_form.add_child(al)
	r = _row(_form, "Carnagione")
	_f_skin = OptionButton.new()
	var skins: Array = main.team.BodyScript.SKINS
	for i in skins.size():
		_f_skin.add_icon_item(_swatch(Color(skins[i])), "tono %d" % (i + 1))
		_f_skin.set_item_metadata(i, skins[i])
	r.add_child(_f_skin)
	r = _row(_form, "Capelli")
	_f_hair_style = OptionButton.new()
	for h in ["corti", "lunghi", "cresta", "calvo"]:
		_f_hair_style.add_item(h)
		_f_hair_style.set_item_metadata(_f_hair_style.item_count - 1, h)
	r.add_child(_f_hair_style)
	_f_hair = ColorPickerButton.new()
	_f_hair.custom_minimum_size = Vector2(60, 28)
	_f_hair.edit_alpha = false
	r.add_child(_f_hair)
	r = _row(_form, "Pantaloni")
	_f_pants = ColorPickerButton.new()
	_f_pants.custom_minimum_size = Vector2(60, 28)
	_f_pants.edit_alpha = false
	r.add_child(_f_pants)
	r = _row(_form, "Cappello")
	_f_hat = OptionButton.new()
	for h in [["nessuno", "nessuno"], ["berretto", "berretto"], ["cilindro", "cilindro"], ["cuoco", "da cuoco"], ["paglia", "di paglia"], ["corona", "corona"]]:
		_f_hat.add_item(h[1])
		_f_hat.set_item_metadata(_f_hat.item_count - 1, h[0])
	r.add_child(_f_hat)
	r = _row(_form, "Altezza")
	_f_height = HSlider.new()
	_f_height.min_value = 0.8
	_f_height.max_value = 1.2
	_f_height.step = 0.01
	_f_height.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_f_height.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.add_child(_f_height)
	_f_error = Label.new()
	_f_error.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
	_f_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_form.add_child(_f_error)
	var fb := HBoxContainer.new()
	fb.add_theme_constant_override("separation", 8)
	_form.add_child(fb)
	_button(fb, "Salva", _save_form)
	_button(fb, "Annulla", _close_form)


func _close_form() -> void:
	for i in _tabs.get_tab_count():
		_tabs.set_tab_disabled(i, false)
	_form.visible = false
	_add_button.visible = true
	_agent_list.visible = true


func _swatch(c: Color) -> Texture2D:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)


func _form_look() -> Dictionary:
	return {
		"skin": str(_f_skin.get_item_metadata(_f_skin.selected)),
		"hair": "#" + _f_hair.color.to_html(false),
		"hair_style": str(_f_hair_style.get_item_metadata(_f_hair_style.selected)),
		"pants": "#" + _f_pants.color.to_html(false),
		"hat": str(_f_hat.get_item_metadata(_f_hat.selected)),
		"height": snappedf(_f_height.value, 0.01),
	}


func _model_picker(with_same: bool) -> OptionButton:
	var o := OptionButton.new()
	o.fit_to_longest_item = false
	o.clip_text = true
	if with_same:
		o.add_item("stesso modello")
		o.set_item_metadata(0, "")
	for id in main.team.MODEL_CHOICES:
		o.add_item(main.team.MODEL_CHOICES[id])
		o.set_item_metadata(o.item_count - 1, id)
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return o


func _pick(o: OptionButton, value: String) -> void:
	for i in o.item_count:
		if str(o.get_item_metadata(i)) == value:
			o.select(i)
			return
	o.select(0)


func _perm_box(parent: Control, text: String) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.focus_mode = Control.FOCUS_NONE
	c.button_pressed = true
	parent.add_child(c)
	return c


func _note(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	parent.add_child(l)
	return l


func _refresh_agents() -> void:
	if _agent_list == null:
		return
	for c in _agent_list.get_children():
		c.queue_free()
	for b in main.team.brains:
		_agent_list.add_child(_agent_row(b))


func _agent_row(b) -> Control:
	var card := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(1, 1, 1, 0.04)
	st.set_corner_radius_all(6)
	st.content_margin_left = 12
	st.content_margin_right = 8
	st.content_margin_top = 6
	st.content_margin_bottom = 6
	st.border_color = b.color
	st.border_width_left = 3
	card.add_theme_stylebox_override("panel", st)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	card.add_child(hb)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 0)
	hb.add_child(info)
	if b.hidden:
		info.modulate = Color(1, 1, 1, 0.4)
	var title := HBoxContainer.new()
	title.add_theme_constant_override("separation", 6)
	info.add_child(title)
	var name_l := Label.new()
	var extra := PackedStringArray()
	if b.is_lead:
		extra.append("lead")
	if b.is_reviewer:
		extra.append("critico")
	if not b.can_build:
		extra.append("NPC")
	if b.hidden:
		extra.append("nascosto")
	name_l.text = b.agent_name + ("  (%s)" % ", ".join(extra) if not extra.is_empty() else "")
	name_l.add_theme_color_override("font_color", b.color.lightened(0.2))
	name_l.add_theme_font_size_override("font_size", 15)
	title.add_child(name_l)
	if not b.is_custom:
		var lock := TextureRect.new()
		lock.texture = _lock()
		lock.custom_minimum_size = Vector2(12, 12)
		lock.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lock.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		lock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		lock.tooltip_text = "Agente predefinito: puoi cambiarne il modello o nasconderlo, non modificarlo o rimuoverlo"
		lock.mouse_filter = Control.MOUSE_FILTER_STOP
		title.add_child(lock)
	var perms := PackedStringArray()
	perms.append("costruisce" if b.can_build else "non costruisce")
	if b.can_model:
		perms.append("crea modelli")
	if b.can_see:
		perms.append("vede")
	var models: String = main.team.model_label(b.model)
	if b.model_for_player != "" and b.model_for_player != b.model:
		models += " (%s quando gli scrivi tu%s)" % [main.team.model_label(b.model_for_player), ", solo per pianificare" if main.team.strong_plan_only else ""]
	var detail := Label.new()
	detail.text = "%s  ·  %s" % [models, ", ".join(perms)]
	detail.add_theme_font_size_override("font_size", 12)
	detail.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	detail.clip_text = true
	detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	detail.tooltip_text = detail.text
	detail.mouse_filter = Control.MOUSE_FILTER_PASS
	info.add_child(detail)
	_small_button(hb, "Mostra" if b.hidden else "Nascondi", func():
		main.team.set_hidden(b, not b.hidden)
		_refresh_agents())
	_small_button(hb, "Modifica", func(): _open_form(b.agent_name))
	if b.is_custom:
		_small_button(hb, "Rimuovi", func():
			_removing = b.agent_name
			_remove_confirm.dialog_text = "Rimuovere %s dal mondo? Non si può annullare." % b.agent_name
			_remove_confirm.popup_centered())
	else:
		var spacer := Control.new()   # keeps the buttons aligned with the custom agents' rows
		spacer.custom_minimum_size.x = 84
		hb.add_child(spacer)
	return card


## A small padlock drawn once (no icon files in the project): marks built-in agents.
func _lock() -> Texture2D:
	if _lock_icon:
		return _lock_icon
	var n := 24
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Color(1, 1, 1, 0.55)
	for y in n:
		for x in n:
			var body := x >= 4 and x <= 19 and y >= 10 and y <= 22
			var dx := x - 11.5
			var dy := y - 10.0
			var r := sqrt(dx * dx + dy * dy)
			var shackle := y <= 10 and r >= 4.5 and r <= 7.0
			var hole := x >= 10 and x <= 13 and y >= 14 and y <= 18
			if (body and not hole) or shackle:
				img.set_pixel(x, y, c)
	_lock_icon = ImageTexture.create_from_image(img)
	return _lock_icon


func _small_button(parent: Control, text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size.x = 84
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(action)
	parent.add_child(b)


## Opens the form: "" = new agent; a custom agent = full edit; a built-in one = models only.
func _open_form(agent_name: String) -> void:
	_editing = agent_name
	_f_error.text = ""
	var b = main.team.find_brain(agent_name) if agent_name != "" else null
	var full: bool = b == null or b.is_custom
	_form_title.text = "Nuovo agente o NPC" if b == null else b.agent_name
	_form_sub.text = "Scegli nome, ruolo, modello, permessi e aspetto" if b == null else ("Modifica · ruolo, modello, permessi e aspetto" if full else "Agente predefinito · puoi cambiare modello e aspetto")
	var accent: Color = Color(0.45, 0.85, 1.0) if b == null else b.color
	_form_title.add_theme_color_override("font_color", accent.lightened(0.2))
	_form_head_style.border_color = accent
	_f_name.text = "" if b == null else b.agent_name
	_f_name.editable = b == null
	_f_role.text = "" if b == null else b.role
	_f_role.editable = full
	_f_color.color = Color.from_string(main.team.PALETTE[main.team.brains.size() % main.team.PALETTE.size()], Color.WHITE) if b == null else b.color
	_f_color.disabled = not full
	_pick(_f_model, "claude-haiku-5-5" if b == null else b.model)
	_pick(_f_model_player, "" if b == null else b.model_for_player)
	var n: int = main.team.brains.size()
	var body_script = main.team.BodyScript
	var lk: Dictionary = b.body.full_look() if b != null else {
		"skin": body_script.SKINS[n % body_script.SKINS.size()], "hair": body_script.HAIRS[(n * 3 + 1) % body_script.HAIRS.size()],
		"hair_style": "corti", "pants": body_script.PANTS[(n * 5 + 2) % body_script.PANTS.size()], "hat": "nessuno", "height": 1.0}
	_pick(_f_skin, str(lk.skin))
	_pick(_f_hair_style, str(lk.hair_style))
	_pick(_f_hat, str(lk.hat))
	_f_hair.color = Color(str(lk.hair))
	_f_pants.color = Color(str(lk.pants))
	_f_height.value = float(lk.height)
	_f_kind.select(0 if b == null or b.can_build else 1)
	_f_kind.disabled = not full
	for pair in [[_f_build, "can_build"], [_f_model_perm, "can_model"], [_f_see, "can_see"]]:
		pair[0].button_pressed = true if b == null else b.get(pair[1])
		pair[0].disabled = not full
	for c in _full_only:
		c.visible = full
	_f_name.get_parent().visible = b == null   # an existing agent's name is in the header
	_form.visible = true
	_add_button.visible = false
	# while editing an agent, stay on this tab (Salva or Indietro to leave)
	for i in _tabs.get_tab_count():
		_tabs.set_tab_disabled(i, i != _tabs.current_tab)
	var sc := _form.get_parent()
	while sc != null and not sc is ScrollContainer:
		sc = sc.get_parent()
	if sc:
		sc.scroll_vertical = 0
	_agent_list.visible = false
	if b == null:
		_f_name.grab_focus()
	elif full:
		_f_role.grab_focus()


func _save_form() -> void:
	var team = main.team
	var model_id := str(_f_model.get_item_metadata(_f_model.selected))
	var for_player := str(_f_model_player.get_item_metadata(_f_model_player.selected))
	var b = team.find_brain(_editing) if _editing != "" else null
	if b != null and not b.is_custom:
		team.set_models(b, model_id, for_player)
		team.set_look(b, _form_look())
		main.ui.add_chat("Sistema", "%s aggiornato: %s." % [b.agent_name, team.model_label(model_id)])
	else:
		var def := {
			"role": _f_role.text.strip_edges(),
			"color": "#" + _f_color.color.to_html(false),
			"model": model_id,
			"model_for_player": for_player,
			"can_build": _f_build.button_pressed,
			"can_model": _f_model_perm.button_pressed,
			"can_see": _f_see.button_pressed,
			"look": _form_look(),
		}
		if def.role == "":
			_f_error.text = "Scrivi il ruolo e la personalità: è quello che l'agente sa di sé."
			return
		if b == null:
			def["name"] = _f_name.text.strip_edges()
			var err: String = team.spawn_agent(def, true)
			if err != "":
				_f_error.text = err
				return
			var nb = team.brains[-1]
			main.ui.add_chat("Sistema", "%s è entrato nel mondo%s." % [nb.agent_name, " (NPC)" if not nb.can_build else ""])
			for other in team.brains:
				if other != nb:
					other.add_context("[Il giocatore ha aggiunto %s%s, con questo ruolo: %s]" % [nb.agent_name, " (un NPC: non costruisce)" if not nb.can_build else "", nb.role])
			if team.api_key != "":
				nb.queue_event("[Sei appena entrato nel mondo, creato dal giocatore. Presentati in una frase con say, nel tuo personaggio.]")
		else:
			var err: String = team.update_agent(b.agent_name, def)
			if err != "":
				_f_error.text = err
				return
			main.ui.add_chat("Sistema", "%s aggiornato." % b.agent_name)
	_close_form()
	_refresh_agents()


# ---------------------------------------------------------------- costs tab

## Spending of this session and of every session in logs/usage.csv, plus the cost options.
func _refresh_costs() -> void:
	if _costs_tab == null:
		return
	for c in _costs_tab.get_children():
		c.queue_free()
	var team = main.team
	var tab := _costs_tab

	_section(tab, "Tetto di spesa")
	var head := Label.new()
	head.add_theme_font_size_override("font_size", 16)
	tab.add_child(head)
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size.y = 8
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab.add_child(bar)
	var show_budget := func():
		head.text = "$%.3f spesi in questa sessione" % team.spent_usd + (" su un tetto di $%.2f" % team.budget_usd if team.budget_usd > 0.0 else " (nessun tetto)")
		bar.visible = team.budget_usd > 0.0
		bar.max_value = maxf(team.budget_usd, 0.01)
		bar.value = minf(team.spent_usd, team.budget_usd)
	show_budget.call()
	var brow := _row(tab, "Tetto di spesa ($, 0 = nessuno)")
	var spin := SpinBox.new()
	spin.min_value = 0.0
	spin.max_value = 100.0
	spin.step = 0.5
	spin.value = team.budget_usd
	spin.value_changed.connect(func(v):
		team.set_budget(v)
		show_budget.call())
	brow.add_child(spin)
	_note(tab, "Raggiunto il tetto, gli agenti si fermano e l'autonomia si spegne. Il tetto viene ricordato; la spesa riparte da zero a ogni avvio. In chat: /budget N e /costi.")

	_section(tab, "Questa sessione")
	if team.usage.is_empty():
		_note(tab, "Nessuna chiamata all'API in questa sessione.")
	else:
		var rows: Array = []
		var names: Array = team.usage.keys()
		names.sort_custom(func(a, b): return team.usage[a]["usd"] > team.usage[b]["usd"])
		for n in names:
			var r: Dictionary = team.usage[n]
			var ctx: int = r["input"] + r["cache_write"] + r["cache_read"]
			rows.append([n, "$%.3f" % r["usd"], _pct(r["usd"], team.spent_usd), str(r["calls"]),
				"$%.4f" % (r["usd"] / maxf(r["calls"], 1)), _k(int(ctx / maxf(r["calls"], 1))), _k(r["output"]), str(r["images"])])
		_grid(tab, ["Agente", "Spesa", "Quota", "Chiamate", "$/chiamata", "Contesto medio", "Output", "Foto"], rows)
		var mrows: Array = []
		for m in team.usage_by_model:
			var mr: Dictionary = team.usage_by_model[m]
			mrows.append([team.model_label(m), "$%.3f" % mr["usd"], _pct(mr["usd"], team.spent_usd), str(mr["calls"])])
		_grid(tab, ["Modello", "Spesa", "Quota", "Chiamate"], mrows)
		_output_table(tab, "In cosa va l'output di questa sessione", team.output_by_kind, team.spent_usd)

	_section(tab, "Come risparmiare")
	var hb := _row(tab, "Modello forte solo per pianificare")
	var chk := CheckButton.new()
	chk.button_pressed = team.strong_plan_only
	chk.toggled.connect(func(on):
		team.set_strong_plan_only(on)
		_refresh_agents())
	hb.add_child(chk)
	_note(tab, "Per gli agenti con un modello diverso \"quando gli scrivi tu\" (l'Architetto usa Sonnet): acceso, il modello forte legge la richiesta, fa il piano e delega, poi i passi successivi del turno (costruire, misurare, correggere) passano al modello base. Spento, il modello forte fa tutto il turno, fino a %d chiamate." % preload("res://scripts/agent_brain.gd").MAX_STEPS)
	_note(tab, "Altre cose che fanno spendere, nelle altre schede: l'autonomia (Impostazioni > Squadra: con l'autonomia accesa ogni agente fa un turno da solo dopo 50-90 s di silenzio), il modello di ogni agente e il permesso di vedere (Agenti: foto e ispezioni costano di più).")

	var entries: Array = team.read_usage_log()
	_section(tab, "Storico (tutte le sessioni, logs/usage.csv)")
	if entries.is_empty():
		_note(tab, "Ancora nessuna chiamata registrata.")
	else:
		var total := 0.0
		var by_day := {}
		var by_agent := {}
		var by_model := {}
		var images := 0
		for e in entries:
			total += e["usd"]
			images += e["images"]
			var day: String = str(e["time"]).left(10)
			by_day[day] = by_day.get(day, 0.0) + e["usd"]
			var a: Dictionary = by_agent.get(e["agent"], {"usd": 0.0, "calls": 0})
			a["usd"] += e["usd"]
			a["calls"] += 1
			by_agent[e["agent"]] = a
			var m: Dictionary = by_model.get(e["model"], {"usd": 0.0, "calls": 0})
			m["usd"] += e["usd"]
			m["calls"] += 1
			by_model[e["model"]] = m
		var today := Time.get_date_string_from_system()
		var big := Label.new()
		big.add_theme_font_size_override("font_size", 16)
		big.text = "$%.2f in tutto · $%.3f oggi · %d chiamate · %d immagini" % [total, by_day.get(today, 0.0), entries.size(), images]
		tab.add_child(big)
		var days: Array = by_day.keys()
		days.sort()
		days.reverse()
		var drows: Array = []
		for d in days.slice(0, 7):
			drows.append([d, "$%.3f" % by_day[d]])
		_grid(tab, ["Giorno", "Spesa"], drows)
		var arows: Array = []
		var anames: Array = by_agent.keys()
		anames.sort_custom(func(x, y): return by_agent[x]["usd"] > by_agent[y]["usd"])
		for n in anames:
			arows.append([n, "$%.3f" % by_agent[n]["usd"], _pct(by_agent[n]["usd"], total), str(by_agent[n]["calls"])])
		_grid(tab, ["Agente", "Spesa", "Quota", "Chiamate"], arows)
		var mrows2: Array = []
		for m in by_model:
			mrows2.append([team.model_label(m), "$%.3f" % by_model[m]["usd"], _pct(by_model[m]["usd"], total), str(by_model[m]["calls"])])
		_grid(tab, ["Modello", "Spesa", "Quota", "Chiamate"], mrows2)
		var hist_kinds := {}
		var split_calls := 0
		var split_spend := 0.0
		for e in entries:
			if e["out_kinds"].is_empty():
				continue
			split_calls += 1
			split_spend += e["usd"]
			var price: float = team.output_price(e["model"], e["input"] + e["cache_write"] + e["cache_read"])
			for k in e["out_kinds"]:
				var rec: Dictionary = hist_kinds.get(k, {"tokens": 0, "usd": 0.0})
				rec["tokens"] += e["out_kinds"][k]
				rec["usd"] += e["out_kinds"][k] * price
				hist_kinds[k] = rec
		if split_calls == 0:
			_note(tab, "La divisione dell'output per tipo (messaggi, pensieri, codice...) si registra dalle prossime chiamate.")
		else:
			_output_table(tab, "In cosa va l'output (storico, %d chiamate registrate con il dettaglio)" % split_calls, hist_kinds, split_spend)
		_note(tab, "Sono stime fatte dal gioco con i prezzi qui sotto: il conto vero è nella Console Anthropic. Se lì vedi molto di più, la differenza viene da altro che usa la stessa API key.")

	_section(tab, "Prezzi usati per le stime ($ per milione di token)")
	var prows: Array = []
	for m in team.PRICES:
		var pr: Array = team.PRICES[m]
		prows.append([team.model_label(m), "%.2f" % pr[0], "%.2f" % pr[1], "%.3f" % pr[2], "%.3f" % pr[3]])
	_grid(tab, ["Modello", "Input", "Output", "Scrittura cache", "Lettura cache"], prows)
	_note(tab, "Ogni chiamata rilegge prompt, strumenti e conversazione (circa 20.000 token), quasi sempre dalla cache, che costa un decimo. La cache dura 5 minuti: dopo una pausa più lunga la prima chiamata la riscrive. Haiku costa 5 volte tanto sopra i 100.000 token di contesto. Prezzi da verificare sulla pagina ufficiale (scripts/team.gd).")

	var refresh := Button.new()
	refresh.text = "Aggiorna"
	refresh.focus_mode = Control.FOCUS_NONE
	refresh.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	refresh.pressed.connect(_refresh_costs)
	tab.add_child(refresh)


## Estimated split of the output tokens by kind, with its share of all the spending.
func _output_table(parent: Control, title: String, kinds: Dictionary, spend: float) -> void:
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 14)
	parent.add_child(l)
	if kinds.is_empty():
		_note(parent, "Ancora nessun output registrato.")
		return
	var tokens := 0
	var usd := 0.0
	for k in kinds:
		tokens += kinds[k]["tokens"]
		usd += kinds[k]["usd"]
	var keys: Array = kinds.keys()
	keys.sort_custom(func(a, b): return kinds[a]["usd"] > kinds[b]["usd"])
	var rows: Array = []
	for k in keys:
		rows.append([str(main.team.OUTPUT_KINDS.get(k, k)), _k(kinds[k]["tokens"]), _pct(kinds[k]["tokens"], tokens),
			"$%.3f" % kinds[k]["usd"], _pct(kinds[k]["usd"], spend)])
	_grid(parent, ["Tipo", "Token", "% dell'output", "Spesa", "% della spesa totale"], rows)
	_note(parent, "L'output vale il %s della spesa ($%.3f su $%.3f). Stima: l'API dà solo il totale dei token generati, che qui è diviso in proporzione alla lunghezza di ogni parte della risposta. Il resto della spesa è input: prompt, strumenti, conversazione e foto riletti a ogni chiamata." % [_pct(usd, spend), usd, spend])


func _grid(parent: Control, header: Array, rows: Array) -> void:
	var g := GridContainer.new()
	g.columns = header.size()
	g.add_theme_constant_override("h_separation", 16)
	g.add_theme_constant_override("v_separation", 2)
	for h in header:
		var l := Label.new()
		l.text = h
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", Color(0.45, 0.85, 1.0, 0.8))
		g.add_child(l)
	for r in rows:
		for v in r:
			var l := Label.new()
			l.text = str(v)
			l.add_theme_font_size_override("font_size", 13)
			g.add_child(l)
	parent.add_child(g)


static func _pct(part: float, whole: float) -> String:
	return "%d%%" % roundi(100.0 * part / whole) if whole > 0.0 else "-"


static func _k(n: int) -> String:
	return "%.1fk" % (n / 1000.0) if n >= 1000 else str(n)


# ---------------------------------------------------------------- style tab

## The shared palette, by group (it grows when the agents add colors).
func _refresh_style() -> void:
	if _style_tab == null:
		return
	for c in _style_tab.get_children():
		c.queue_free()
	_note(_style_tab, "Palette comune a tutti i mondi · passa sopra un colore per vedere a cosa serve")
	var groups := {}
	for n in Shapes.PALETTE:
		var g := str(Shapes.PALETTE[n].get("group", "altro"))
		if not groups.has(g):
			groups[g] = []
		groups[g].append(n)
	for g in groups:
		_section(_style_tab, g.left(1).to_upper() + g.substr(1))
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 14)
		grid.add_theme_constant_override("v_separation", 6)
		_style_tab.add_child(grid)
		for n in groups[g]:
			var e: Dictionary = Shapes.PALETTE[n]
			var item := HBoxContainer.new()
			item.add_theme_constant_override("separation", 6)
			item.custom_minimum_size.x = 175
			item.tooltip_text = "%s · %s%s" % [e.color, str(e.get("description", "")), " · luminoso" if e.has("glow") else ""]
			item.mouse_filter = Control.MOUSE_FILTER_STOP
			var sw := PanelContainer.new()
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(str(e.color))
			sb.set_corner_radius_all(4)
			sb.border_color = Color(1, 1, 1, 0.25)
			sb.set_border_width_all(1)
			if e.has("glow"):
				sb.shadow_color = Color(str(e.color), 0.6)
				sb.shadow_size = 4
			sw.add_theme_stylebox_override("panel", sb)
			sw.custom_minimum_size = Vector2(20, 20)
			sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
			item.add_child(sw)
			var l := Label.new()
			l.text = n.replace("_", " ")
			l.add_theme_font_size_override("font_size", 13)
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			item.add_child(l)
			grid.add_child(item)


# ---------------------------------------------------------------- commands tab

const KEYS := [
	["Movimento", [
		["W A S D", "muoversi"], ["Spazio", "saltare (tieni premuto per saltare più in alto)"], ["Shift", "correre"],
		["F", "volo on/off · Spazio e C per salire e scendere"],
	]],
	["Gioco", [
		["Invio", "scrivere in chat (@Nome per un agente, @tutti a tutti)"], ["Tab", "console GDScript (Ctrl/Cmd+Invio esegue)"],
		["X", "elimina l'oggetto nel mirino"], ["P", "autonomia degli agenti on/off"], ["Ctrl/Cmd+Z", "annulla l'ultima modifica"],
		["Esc", "menu · chiude i pannelli aperti"],
	]],
	["Modalità costruzione (B)", [
		["Clic", "seleziona l'oggetto nel mirino"], ["G", "afferra: segue il mirino, clic per posarlo, Esc annulla"],
		["R · Shift+R", "ruota di 15°"], ["Rotellina", "ruota (con Shift scala)"], ["+ · -", "scala"],
		["C", "duplica e afferra la copia"], ["X", "elimina"],
	]],
	["Comandi in chat", [
		["@Nome messaggio", "parla a un agente (senza @ risponde il lead)"],
		["/agenti", "elenca la squadra"], ["/nuovo Nome: ruolo", "crea un agente (o dal menu Agenti)"], ["/rimuovi Nome", "rimuove un agente creato da te"],
		["/salva nome · /carica nome", "salvataggi con nome"], ["/salvataggi", "elenca i salvataggi"],
		["/annulla · /storia · /ripristina N", "cronologia del mondo"],
		["/blueprint nome descrizione", "salva l'oggetto mirato come modello riusabile"], ["/piazza nome · /blueprints", "piazza o elenca i blueprint"],
		["/ora H · /ciclo min", "ora del giorno e durata del ciclo (0 = fermo)"], ["/terreno tipo", "griglia, prato, sabbia, neve, pietra, terra"], ["/nebbia 0-1", "densità della nebbia"],
		["/costi · /budget $", "spesa stimata e tetto"], ["/segui", "gli agenti ti raggiungono on/off"], ["/ui 1.2", "dimensione dell'interfaccia"],
		["/auto", "autonomia on/off"], ["/clear", "gli agenti dimenticano la conversazione"], ["/reset", "svuota il mondo"],
		["/azzera", "reset totale (mondo, memoria, lavagna, cronologia)"], ["/aiuto", "questo elenco in chat"],
	]],
]


func _build_commands_tab(tab: VBoxContainer) -> void:
	for group in KEYS:
		_section(tab, group[0])
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 16)
		grid.add_theme_constant_override("v_separation", 4)
		tab.add_child(grid)
		for pair in group[1]:
			var k := Label.new()
			k.text = pair[0]
			k.custom_minimum_size.x = 210
			k.add_theme_font_size_override("font_size", 13)
			k.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
			grid.add_child(k)
			var d := Label.new()
			d.text = pair[1]
			d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			d.custom_minimum_size.x = 340
			d.add_theme_font_size_override("font_size", 13)
			grid.add_child(d)


func _sync() -> void:
	_syncing = true
	_controls["ui_scale"].value = main.ui.ui_scale
	_controls["mouse"].value = main.player.mouse_sens / 0.0022
	_controls["fov"].value = main.player.base_fov
	_controls["bob"].button_pressed = main.player.bob_amount > 0.0
	_controls["autonomy"].button_pressed = main.team.autonomy
	_controls["npc_autonomy"].button_pressed = main.team.npc_autonomy
	for k in main.ui.CHAT_KINDS:
		_controls["chat_" + k].button_pressed = main.ui.chat_filter[k]
	_controls["follow"].button_pressed = main.team.follow
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
