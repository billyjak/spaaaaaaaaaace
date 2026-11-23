extends Control

# ---------------------------------------------------------------------------
# SPAAAAAAAAAACE — Gamepad + Mouse Main Menu Flow
# Title ("PRESS START") -> Mode Select (Time Trial) -> Track Select (5 Presets
# + 6th Random Sector w/ Live Preview & Re-roll) -> Weight Class Select ->
# Tech Tier Select (with Shared Session Best Times) -> Launch Race!
# ---------------------------------------------------------------------------

enum Screen {
	TITLE,
	MODE,
	TRACK,
	WEIGHT,
	TIER,
}

var _current_screen: Screen = Screen.TITLE
var _preview_cache: Dictionary = {} # "<type>_<seed>" -> preview dict
var _preview_track: Node = null
var _pulse_time: float = 0.0

# Screen containers
var _title_box: Control = null
var _press_start_label: Label = null
var _mode_box: Control = null
var _track_box: Control = null
var _weight_box: Control = null
var _tier_box: Control = null
var _footer_label: Label = null

# Mode buttons
var _btn_time_trial: Button = null
var _btn_telemetry_toggle: Button = null
var _btn_quit: Button = null

# Track screen widgets
var _track_buttons: Array[Button] = []
var _track_preview: Control = null
var _track_name_label: Label = null
var _track_meta_label: Label = null
var _track_blurb_label: Label = null
var _btn_reroll: Button = null
var _focused_track_idx: int = 0

# Weight class widgets
var _weight_buttons: Array[Button] = []
var _weight_title_label: Label = null
var _weight_stats_label: Label = null
var _weight_blurb_label: Label = null
var _focused_weight_idx: int = 0

# Tech tier widgets
var _tier_buttons: Array[Button] = []
var _tier_header_label: Label = null
var _tier_record_label: Label = null
var _tier_stats_label: Label = null
var _tier_blurb_label: Label = null
var _focused_tier_num: int = 1


func _ready() -> void:
	get_tree().paused = false
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# Lightweight hidden Track helper strictly for fast pure-geometry minimap previews
	var track_script := load("res://track.gd") as Script
	_preview_track = StaticBody2D.new()
	_preview_track.name = "PreviewTrackHelper"
	_preview_track.visible = false
	_preview_track.set_script(track_script)

	_build_ui()

	_focused_track_idx = GameState.selected_track_index
	_focused_weight_idx = GameState.selected_weight_class
	_focused_tier_num = GameState.selected_tech_tier

	if GameState.skip_title_screen:
		_show_screen(Screen.MODE)
	else:
		_show_screen(Screen.TITLE)


func _exit_tree() -> void:
	if _preview_track != null and is_instance_valid(_preview_track):
		_preview_track.free()
		_preview_track = null


func _process(delta: float) -> void:
	_pulse_time += delta
	if _current_screen == Screen.TITLE and _press_start_label != null:
		var alpha := 0.55 + 0.45 * sin(_pulse_time * 4.0)
		_press_start_label.modulate = Color(1.0, 1.0, 1.0, alpha)


func _unhandled_input(event: InputEvent) -> void:
	if _current_screen == Screen.TITLE:
		if (
			(InputMap.has_action("pause") and event.is_action_pressed("pause"))
			or event.is_action_pressed("ui_accept")
			or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT)
		):
			GameState.skip_title_screen = true
			_show_screen(Screen.MODE)
			get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_cancel"):
		_go_back()
		get_viewport().set_input_as_handled()
		return

	if _current_screen == Screen.TRACK and _focused_track_idx == GameState.RANDOM_TRACK_INDEX:
		if InputMap.has_action("ui_reroll") and event.is_action_pressed("ui_reroll"):
			_on_reroll_pressed()
			get_viewport().set_input_as_handled()


func _go_back() -> void:
	match _current_screen:
		Screen.MODE:
			GameState.skip_title_screen = false
			_show_screen(Screen.TITLE)
		Screen.TRACK:
			_show_screen(Screen.MODE)
		Screen.WEIGHT:
			_show_screen(Screen.TRACK)
		Screen.TIER:
			_show_screen(Screen.WEIGHT)


func _show_screen(screen: Screen) -> void:
	_current_screen = screen
	_title_box.visible = (screen == Screen.TITLE)
	_mode_box.visible = (screen == Screen.MODE)
	_track_box.visible = (screen == Screen.TRACK)
	_weight_box.visible = (screen == Screen.WEIGHT)
	_tier_box.visible = (screen == Screen.TIER)

	match screen:
		Screen.TITLE:
			_footer_label.text = "START / A / CLICK: Begin"
		Screen.MODE:
			_footer_label.text = "D-Pad / Stick: Navigate   |   A: Select   |   B: Back"
			_refresh_telemetry_button()
			_btn_time_trial.grab_focus()
		Screen.TRACK:
			_footer_label.text = "D-Pad / Stick: Select Track   |   A: Confirm   |   X / R: Re-roll Random   |   B: Back"
			_refresh_track_preview(_focused_track_idx)
			var idx := clampi(_focused_track_idx, 0, _track_buttons.size() - 1)
			_track_buttons[idx].grab_focus()
		Screen.WEIGHT:
			_footer_label.text = "D-Pad / Stick: Choose Weight Class   |   A: Confirm   |   B: Back"
			_refresh_weight_details(_focused_weight_idx)
			var idx := clampi(_focused_weight_idx, 0, _weight_buttons.size() - 1)
			_weight_buttons[idx].grab_focus()
		Screen.TIER:
			_footer_label.text = "D-Pad / Stick: Choose Tech Tier   |   A: Launch Time Trial   |   B: Back"
			_refresh_tier_details(_focused_tier_num)
			var idx := clampi(_focused_tier_num - 1, 0, _tier_buttons.size() - 1)
			_tier_buttons[idx].grab_focus()


func _refresh_track_preview(track_idx: int) -> void:
	_focused_track_idx = clampi(track_idx, 0, GameState.get_track_option_count() - 1)
	var info: Dictionary = GameState.get_track_info(_focused_track_idx)
	var t_type: int = int(info["track_type"])
	var seed_val: int = int(info["seed"])
	var is_random: bool = bool(info.get("is_random", false))

	_track_name_label.text = str(info["name"])
	_track_blurb_label.text = str(info["blurb"])
	_btn_reroll.visible = is_random

	var cache_key := "%d_%d" % [t_type, seed_val]
	var geom: Dictionary
	if _preview_cache.has(cache_key):
		geom = _preview_cache[cache_key]
	else:
		geom = _preview_track.build_preview_geometry(seed_val, t_type)
		_preview_cache[cache_key] = geom

	var outer_pts: PackedVector2Array = geom.get("outer", PackedVector2Array())
	var inner_pts: PackedVector2Array = geom.get("inner", PackedVector2Array())
	var start_pt: Vector2 = geom.get("start", Vector2.ZERO)
	var length_km: float = float(geom.get("length_px", 0.0)) / (16.0 * 1000.0)
	var turn_deg: float = float(geom.get("total_turn_deg", 0.0))
	var type_label: String = _preview_track.get_track_type_label(t_type)

	_track_meta_label.text = "%s   |   Seed #%d   |   %.2f km   |   %.0f° Total Turn" % [
		type_label, seed_val, length_km, turn_deg
	]
	if _track_preview != null and _track_preview.has_method("set_preview_geometry"):
		_track_preview.set_preview_geometry(outer_pts, inner_pts, start_pt)


func _refresh_telemetry_button() -> void:
	if _btn_telemetry_toggle != null:
		_btn_telemetry_toggle.text = "Show Telemetry: %s" % ("ON" if GameState.show_telemetry else "OFF")


func _on_reroll_pressed() -> void:
	GameState.reroll_random_track()
	_refresh_track_preview(GameState.RANDOM_TRACK_INDEX)


func _on_track_selected(track_idx: int) -> void:
	GameState.selected_track_index = clampi(track_idx, 0, GameState.get_track_option_count() - 1)
	_focused_track_idx = GameState.selected_track_index
	_show_screen(Screen.WEIGHT)


func _refresh_weight_details(weight_idx: int) -> void:
	_focused_weight_idx = clampi(weight_idx, 0, 2)
	var stats: Dictionary = GameState.compute_ship_stats(_focused_weight_idx, GameState.selected_tech_tier)
	_weight_title_label.text = GameState.SIZE_DISPLAY_NAMES[_focused_weight_idx]
	_weight_blurb_label.text = GameState.SIZE_BLURBS[_focused_weight_idx]

	if not stats.is_empty():
		var t_lbl := GameState.selected_tech_tier
		_weight_stats_label.text = (
			"Preview Specs (at Tier %d):\n"
			+ "Wet / Dry Mass:   %.0f kg / %.0f kg\n"
			+ "Fuel Tank:   %.0f kg  (%.1f s full burn)\n"
			+ "Max Acceleration:   %.2f G → %.2f G\n"
			+ "Rotational Turn Rate:   %.1f rad/s²\n"
			+ "Peak Radiative Cooling:   %.1f kW"
		) % [
			t_lbl,
			stats["wet_mass"], stats["dry_mass"],
			stats["fuel_cap"], stats["burn_time_s"],
			stats["accel_wet_g"], stats["accel_dry_g"],
			stats["turn_wet_rad_s2"],
			stats["max_cool_kw"],
		]


func _on_weight_selected(weight_idx: int) -> void:
	GameState.selected_weight_class = clampi(weight_idx, 0, 2)
	_focused_weight_idx = GameState.selected_weight_class
	_show_screen(Screen.TIER)


func _refresh_tier_details(tier_num: int) -> void:
	_focused_tier_num = clampi(tier_num, 1, 4)
	var track_info: Dictionary = GameState.get_active_track_info()
	var weight_name := GameState.SIZE_DISPLAY_NAMES[GameState.selected_weight_class]
	var stats: Dictionary = GameState.compute_ship_stats(GameState.selected_weight_class, _focused_tier_num)

	_tier_header_label.text = "%s   •   %s   •   %s" % [
		str(track_info["name"]),
		weight_name,
		GameState.TIER_NAMES[_focused_tier_num - 1],
	]
	_tier_blurb_label.text = GameState.TIER_BLURBS[_focused_tier_num - 1]

	# Shared Best Time across ALL weight classes for (Selected Track, Focused Tech Tier)
	var best: Dictionary = GameState.get_best_time(GameState.selected_track_index, _focused_tier_num)
	if not best.is_empty():
		_tier_record_label.text = "SESSION BEST (TIER %d):  %s   —   %s" % [
			_focused_tier_num,
			GameState.format_time(float(best["time"])),
			str(best["ship_class"]),
		]
		_tier_record_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.68, 1.0))
	else:
		_tier_record_label.text = "SESSION BEST (TIER %d):  --:--.--  (No Record Yet)" % _focused_tier_num
		_tier_record_label.add_theme_color_override("font_color", Color(0.70, 0.85, 0.96, 0.88))

	if not stats.is_empty():
		_tier_stats_label.text = (
			"Hull: %s\n"
			+ "Engine: %s (%.0f s Isp)\n"
			+ "RCS: %s\n"
			+ "Mass (Wet / Dry): %.0f / %.0f kg   |   Fuel: %.0f kg\n"
			+ "Max Thrust: %.2f kN   |   Accel: %.2f → %.2f G\n"
			+ "Turn Authority: %.1f rad/s²   |   Burn Time: %.1f s\n"
			+ "Thermal: %.0f kW Overburn  /  %.1f kW Peak Rad"
		) % [
			stats["hull_name"],
			stats["engine_name"], stats["isp"],
			stats["rcs_name"],
			stats["wet_mass"], stats["dry_mass"], stats["fuel_cap"],
			stats["max_thrust_kn"], stats["accel_wet_g"], stats["accel_dry_g"],
			stats["turn_wet_rad_s2"], stats["burn_time_s"],
			stats["overburn_heat_kw"], stats["max_cool_kw"],
		]


func _on_tier_selected(tier_num: int) -> void:
	GameState.selected_tech_tier = clampi(tier_num, 1, 4)
	GameState.launched_from_menu = true
	GameState.skip_title_screen = true
	get_tree().change_scene_to_file("res://level.tscn")


# ---------------------------------------------------------------------------
# UI Construction (Clean Space-League Theme matching in-game HUD)
# ---------------------------------------------------------------------------
func _make_panel_style(border_col: Color = Color(0.25, 0.75, 1.0, 0.45)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.10, 0.84)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = border_col
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_right = 8
	sb.corner_radius_bottom_left = 8
	sb.content_margin_left = 24.0
	sb.content_margin_top = 20.0
	sb.content_margin_right = 24.0
	sb.content_margin_bottom = 20.0
	return sb


func _make_menu_button(text: String, min_size: Vector2 = Vector2(280.0, 48.0)) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = min_size
	btn.add_theme_font_size_override("font_size", 20)
	return btn


func _build_ui() -> void:
	# Background Milky Way + subtle dark scrim so menu text pops crisply
	var bg := TextureRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.texture = load("res://resources/milky_way/milky-way-3.jpg") as Texture2D
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.modulate = Color(0.55, 0.62, 0.75, 1.0)
	add_child(bg)

	var scrim := ColorRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.color = Color(0.02, 0.04, 0.08, 0.45)
	add_child(scrim)

	# --- 1. TITLE SCREEN ---
	_title_box = VBoxContainer.new()
	_title_box.set_anchors_preset(Control.PRESET_CENTER)
	_title_box.offset_left = -420.0
	_title_box.offset_right = 420.0
	_title_box.offset_top = -140.0
	_title_box.offset_bottom = 140.0
	_title_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_title_box.add_theme_constant_override("separation", 24)
	add_child(_title_box)

	var title_lbl := Label.new()
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_size_override("font_size", 78)
	title_lbl.add_theme_color_override("font_color", Color(0.86, 0.96, 1.0, 1.0))
	title_lbl.add_theme_color_override("font_outline_color", Color(0.05, 0.35, 0.70, 0.9))
	title_lbl.add_theme_constant_override("outline_size", 8)
	title_lbl.text = "SPAAAAAAAAAACE"
	_title_box.add_child(title_lbl)

	var sub_lbl := Label.new()
	sub_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_lbl.add_theme_font_size_override("font_size", 22)
	sub_lbl.add_theme_color_override("font_color", Color(0.58, 0.85, 1.0, 0.92))
	sub_lbl.text = "Zero-G Newtonian Orbital Racing"
	_title_box.add_child(sub_lbl)

	_press_start_label = Label.new()
	_press_start_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_press_start_label.add_theme_font_size_override("font_size", 30)
	_press_start_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.72, 1.0))
	_press_start_label.text = "PRESS START"
	_title_box.add_child(_press_start_label)

	# --- 2. MODE SELECT ---
	_mode_box = PanelContainer.new()
	_mode_box.set_anchors_preset(Control.PRESET_CENTER)
	_mode_box.offset_left = -240.0
	_mode_box.offset_right = 240.0
	_mode_box.offset_top = -185.0
	_mode_box.offset_bottom = 185.0
	_mode_box.add_theme_stylebox_override("panel", _make_panel_style())
	add_child(_mode_box)

	var mode_v := VBoxContainer.new()
	mode_v.alignment = BoxContainer.ALIGNMENT_CENTER
	mode_v.add_theme_constant_override("separation", 16)
	_mode_box.add_child(mode_v)

	var mode_title := Label.new()
	mode_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mode_title.add_theme_font_size_override("font_size", 32)
	mode_title.add_theme_color_override("font_color", Color(0.86, 0.96, 1.0, 1.0))
	mode_title.text = "SELECT MODE"
	mode_v.add_child(mode_title)

	_btn_time_trial = _make_menu_button("Time Trial (1-Lap Sprint)", Vector2(340.0, 56.0))
	_btn_time_trial.pressed.connect(func() -> void: _show_screen(Screen.TRACK))
	mode_v.add_child(_btn_time_trial)

	_btn_telemetry_toggle = _make_menu_button("Show Telemetry: OFF", Vector2(340.0, 48.0))
	_btn_telemetry_toggle.pressed.connect(func() -> void:
		GameState.toggle_telemetry()
		_refresh_telemetry_button()
	)
	mode_v.add_child(_btn_telemetry_toggle)

	_btn_quit = _make_menu_button("Quit", Vector2(340.0, 48.0))
	_btn_quit.pressed.connect(func() -> void: get_tree().quit())
	mode_v.add_child(_btn_quit)

	# --- 3. TRACK SELECT (5 Curated Presets + 6th Random Sector w/ Preview & Re-roll) ---
	_track_box = PanelContainer.new()
	_track_box.set_anchors_preset(Control.PRESET_CENTER)
	_track_box.offset_left = -520.0
	_track_box.offset_right = 520.0
	_track_box.offset_top = -290.0
	_track_box.offset_bottom = 290.0
	_track_box.add_theme_stylebox_override("panel", _make_panel_style())
	add_child(_track_box)

	var track_outer := VBoxContainer.new()
	track_outer.add_theme_constant_override("separation", 16)
	_track_box.add_child(track_outer)

	var track_hdr := Label.new()
	track_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	track_hdr.add_theme_font_size_override("font_size", 30)
	track_hdr.text = "SELECT TRACK"
	track_outer.add_child(track_hdr)

	var track_cols := HBoxContainer.new()
	track_cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	track_cols.add_theme_constant_override("separation", 24)
	track_outer.add_child(track_cols)

	var track_list := VBoxContainer.new()
	track_list.custom_minimum_size = Vector2(330.0, 0.0)
	track_list.add_theme_constant_override("separation", 10)
	track_cols.add_child(track_list)

	_track_buttons.clear()
	for i in range(GameState.get_track_option_count()):
		var info := GameState.get_track_info(i)
		var btn_label := "%d. %s" % [i + 1, str(info["name"])]
		var btn := _make_menu_button(btn_label, Vector2(320.0, 52.0))
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.focus_entered.connect(_refresh_track_preview.bind(i))
		btn.mouse_entered.connect(_refresh_track_preview.bind(i))
		btn.pressed.connect(_on_track_selected.bind(i))
		track_list.add_child(btn)
		_track_buttons.append(btn)

	var track_right := VBoxContainer.new()
	track_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	track_right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	track_right.add_theme_constant_override("separation", 10)
	track_cols.add_child(track_right)

	_track_name_label = Label.new()
	_track_name_label.add_theme_font_size_override("font_size", 26)
	_track_name_label.add_theme_color_override("font_color", Color(0.85, 0.96, 1.0, 1.0))
	track_right.add_child(_track_name_label)

	_track_meta_label = Label.new()
	_track_meta_label.add_theme_font_size_override("font_size", 15)
	_track_meta_label.add_theme_color_override("font_color", Color(0.50, 0.85, 1.0, 0.95))
	track_right.add_child(_track_meta_label)

	var preview_script := load("res://track_preview.gd") as Script
	_track_preview = Control.new()
	_track_preview.name = "TrackPreview"
	_track_preview.set_script(preview_script)
	_track_preview.custom_minimum_size = Vector2(400.0, 290.0)
	_track_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_track_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	track_right.add_child(_track_preview)

	_track_blurb_label = Label.new()
	_track_blurb_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_track_blurb_label.add_theme_font_size_override("font_size", 15)
	_track_blurb_label.add_theme_color_override("font_color", Color(0.80, 0.90, 0.98, 0.92))
	track_right.add_child(_track_blurb_label)

	_btn_reroll = _make_menu_button("Re-roll Random Track  [X / R]", Vector2(280.0, 42.0))
	_btn_reroll.pressed.connect(_on_reroll_pressed)
	_btn_reroll.visible = false
	track_right.add_child(_btn_reroll)

	# --- 4. WEIGHT CLASS SELECT ---
	_weight_box = PanelContainer.new()
	_weight_box.set_anchors_preset(Control.PRESET_CENTER)
	_weight_box.offset_left = -460.0
	_weight_box.offset_right = 460.0
	_weight_box.offset_top = -230.0
	_weight_box.offset_bottom = 230.0
	_weight_box.add_theme_stylebox_override("panel", _make_panel_style())
	add_child(_weight_box)

	var w_outer := VBoxContainer.new()
	w_outer.add_theme_constant_override("separation", 18)
	_weight_box.add_child(w_outer)

	var w_hdr := Label.new()
	w_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	w_hdr.add_theme_font_size_override("font_size", 30)
	w_hdr.text = "SELECT WEIGHT CLASS"
	w_outer.add_child(w_hdr)

	var w_cols := HBoxContainer.new()
	w_cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	w_cols.add_theme_constant_override("separation", 26)
	w_outer.add_child(w_cols)

	var w_list := VBoxContainer.new()
	w_list.custom_minimum_size = Vector2(300.0, 0.0)
	w_list.alignment = BoxContainer.ALIGNMENT_CENTER
	w_list.add_theme_constant_override("separation", 14)
	w_cols.add_child(w_list)

	_weight_buttons.clear()
	for i in range(3):
		var btn := _make_menu_button(GameState.SIZE_DISPLAY_NAMES[i], Vector2(290.0, 62.0))
		btn.focus_entered.connect(_refresh_weight_details.bind(i))
		btn.mouse_entered.connect(_refresh_weight_details.bind(i))
		btn.pressed.connect(_on_weight_selected.bind(i))
		w_list.add_child(btn)
		_weight_buttons.append(btn)

	var w_right := VBoxContainer.new()
	w_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	w_right.alignment = BoxContainer.ALIGNMENT_CENTER
	w_right.add_theme_constant_override("separation", 14)
	w_cols.add_child(w_right)

	_weight_title_label = Label.new()
	_weight_title_label.add_theme_font_size_override("font_size", 26)
	_weight_title_label.add_theme_color_override("font_color", Color(0.85, 0.96, 1.0, 1.0))
	w_right.add_child(_weight_title_label)

	_weight_blurb_label = Label.new()
	_weight_blurb_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_weight_blurb_label.add_theme_font_size_override("font_size", 16)
	_weight_blurb_label.add_theme_color_override("font_color", Color(0.75, 0.90, 1.0, 0.95))
	w_right.add_child(_weight_blurb_label)

	_weight_stats_label = Label.new()
	_weight_stats_label.add_theme_font_size_override("font_size", 17)
	_weight_stats_label.add_theme_color_override("font_color", Color(0.92, 0.97, 1.0, 1.0))
	w_right.add_child(_weight_stats_label)

	# --- 5. TECH TIER SELECT (Shows Shared Session Best Time per Track + Tier) ---
	_tier_box = PanelContainer.new()
	_tier_box.set_anchors_preset(Control.PRESET_CENTER)
	_tier_box.offset_left = -520.0
	_tier_box.offset_right = 520.0
	_tier_box.offset_top = -270.0
	_tier_box.offset_bottom = 270.0
	_tier_box.add_theme_stylebox_override("panel", _make_panel_style())
	add_child(_tier_box)

	var t_outer := VBoxContainer.new()
	t_outer.add_theme_constant_override("separation", 16)
	_tier_box.add_child(t_outer)

	var t_hdr := Label.new()
	t_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t_hdr.add_theme_font_size_override("font_size", 30)
	t_hdr.text = "SELECT TECH TIER"
	t_outer.add_child(t_hdr)

	_tier_header_label = Label.new()
	_tier_header_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tier_header_label.add_theme_font_size_override("font_size", 16)
	_tier_header_label.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0, 0.95))
	t_outer.add_child(_tier_header_label)

	var t_cols := HBoxContainer.new()
	t_cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	t_cols.add_theme_constant_override("separation", 26)
	t_outer.add_child(t_cols)

	var t_list := VBoxContainer.new()
	t_list.custom_minimum_size = Vector2(310.0, 0.0)
	t_list.alignment = BoxContainer.ALIGNMENT_CENTER
	t_list.add_theme_constant_override("separation", 12)
	t_cols.add_child(t_list)

	_tier_buttons.clear()
	for t_idx in range(4):
		var tier_num := t_idx + 1
		var btn := _make_menu_button(GameState.TIER_NAMES[t_idx], Vector2(300.0, 58.0))
		btn.focus_entered.connect(_refresh_tier_details.bind(tier_num))
		btn.mouse_entered.connect(_refresh_tier_details.bind(tier_num))
		btn.pressed.connect(_on_tier_selected.bind(tier_num))
		t_list.add_child(btn)
		_tier_buttons.append(btn)

	var t_right := VBoxContainer.new()
	t_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t_right.alignment = BoxContainer.ALIGNMENT_CENTER
	t_right.add_theme_constant_override("separation", 14)
	t_cols.add_child(t_right)

	_tier_record_label = Label.new()
	_tier_record_label.add_theme_font_size_override("font_size", 22)
	t_right.add_child(_tier_record_label)

	_tier_blurb_label = Label.new()
	_tier_blurb_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tier_blurb_label.add_theme_font_size_override("font_size", 16)
	_tier_blurb_label.add_theme_color_override("font_color", Color(0.75, 0.90, 1.0, 0.95))
	t_right.add_child(_tier_blurb_label)

	_tier_stats_label = Label.new()
	_tier_stats_label.add_theme_font_size_override("font_size", 16)
	_tier_stats_label.add_theme_color_override("font_color", Color(0.92, 0.97, 1.0, 1.0))
	t_right.add_child(_tier_stats_label)

	# Bottom Footer Hint Bar
	_footer_label = Label.new()
	_footer_label.anchor_left = 0.0
	_footer_label.anchor_right = 1.0
	_footer_label.anchor_top = 1.0
	_footer_label.anchor_bottom = 1.0
	_footer_label.offset_top = -46.0
	_footer_label.offset_bottom = -14.0
	_footer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_footer_label.add_theme_font_size_override("font_size", 16)
	_footer_label.add_theme_color_override("font_color", Color(0.70, 0.86, 1.0, 0.85))
	add_child(_footer_label)
