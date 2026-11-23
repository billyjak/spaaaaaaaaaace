extends Control

# ---------------------------------------------------------------------------
# 1-Lap Time-Trial Race Manager & HUD
# Manages:
#   - Ordered checkpoint progression (CP 1..N -> Finish Gate)
#   - Trials-style starts: 3-2-1-GO! on initial track launch, snappy 1s
#     READY-GO! on restart (`restart` hotkey / Select button or Finish UI)
#   - Top-center live Race Timer & Checkpoint readout + split flash
#   - Session-only in-memory best times keyed by (seed, track_type, tech_tier)
#     shared across ship weight classes (recording winning class)
#   - Gamepad-navigable Finish Overlay (Restart / Main Menu)
# ---------------------------------------------------------------------------

enum RaceState {
	COUNTDOWN_INITIAL,
	COUNTDOWN_RESTART,
	RACING,
	FINISHED,
}

@export var initial_countdown_seconds: float = 3.0
@export var restart_countdown_seconds: float = 1.0
@export var go_banner_duration: float = 0.65

var state: RaceState = RaceState.COUNTDOWN_INITIAL
var race_time: float = 0.0
var countdown_remaining: float = 3.0
var next_gate_index: int = 0
var total_checkpoints: int = 10

# In-memory session best times (zero disk writes):
# Key: "%d_%d_T%d" % [track_type, seed, tech_tier] -> { "time": float, "ship_class": String }
var session_best_times: Dictionary = {}

var _ship: RigidBody2D = null
var _track: Node = null
var _go_banner_timer: float = 0.0
var _split_flash_timer: float = 0.0
var _last_finish_is_best: bool = false

# UI Nodes (built programmatically inside this full-rect Control so scene stays lightweight)
var _timer_panel: PanelContainer = null
var _timer_label: Label = null
var _status_label: Label = null
var _split_label: Label = null
var _countdown_label: Label = null
var _finish_panel: PanelContainer = null
var _finish_title_label: Label = null
var _finish_time_label: Label = null
var _finish_details_label: Label = null
var _finish_note_label: Label = null
var _btn_restart: Button = null
var _btn_main_menu: Button = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	_bind_scene_nodes()
	# Defer initial race start one frame so Track._ready() has generated checkpoints first
	call_deferred("_start_initial_race")


func _bind_scene_nodes() -> void:
	var cur: Node = get_parent()
	while cur != null:
		if cur is RigidBody2D and cur.has_method("place_at_spawn"):
			_ship = cur as RigidBody2D
			break
		cur = cur.get_parent()

	if _ship != null and _ship.get_parent() != null:
		_track = _ship.get_parent().get_node_or_null("Track")

	if _track != null:
		if _track.has_signal("track_generated") and not _track.track_generated.is_connected(_on_track_generated):
			_track.track_generated.connect(_on_track_generated)
		if _track.has_signal("checkpoint_crossed") and not _track.checkpoint_crossed.is_connected(_on_checkpoint_crossed):
			_track.checkpoint_crossed.connect(_on_checkpoint_crossed)


func _start_initial_race() -> void:
	if _ship == null or _track == null:
		_bind_scene_nodes()
	begin_race(false)


func _on_track_generated(_seed_value: int, _spawn_pos: Vector2, _spawn_rot: float) -> void:
	begin_race(false)


func begin_race(is_restart: bool) -> void:
	if _track != null and "checkpoint_count" in _track:
		total_checkpoints = maxi(int(_track.checkpoint_count), 1)

	next_gate_index = 0
	race_time = 0.0
	_go_banner_timer = 0.0
	_split_flash_timer = 0.0
	_last_finish_is_best = false

	if _track != null and _track.has_method("set_active_checkpoint"):
		_track.set_active_checkpoint(0)

	if _ship != null and _track != null:
		_ship.place_at_spawn(_track.get_spawn_position(), _track.get_spawn_rotation(), true)
		_ship.controls_locked = true
		_ship.hold_at_start = true

	if is_restart:
		state = RaceState.COUNTDOWN_RESTART
		countdown_remaining = maxf(restart_countdown_seconds, 0.2)
	else:
		state = RaceState.COUNTDOWN_INITIAL
		countdown_remaining = maxf(initial_countdown_seconds, 0.5)

	if _finish_panel != null:
		_finish_panel.visible = false
	if _finish_note_label != null:
		_finish_note_label.text = ""
	if _split_label != null:
		_split_label.text = ""
	_update_hud()


func _process(delta: float) -> void:
	if _ship == null or _track == null:
		_bind_scene_nodes()

	# Quick restart hotkey (`restart` -> Controller Select / Back / Minus, button 4)
	if InputMap.has_action("restart") and Input.is_action_just_pressed("restart"):
		begin_race(true)
		return

	if _go_banner_timer > 0.0:
		_go_banner_timer = maxf(_go_banner_timer - delta, 0.0)
	if _split_flash_timer > 0.0:
		_split_flash_timer = maxf(_split_flash_timer - delta, 0.0)
		if _split_flash_timer <= 0.0 and _split_label != null:
			_split_label.text = ""

	match state:
		RaceState.COUNTDOWN_INITIAL, RaceState.COUNTDOWN_RESTART:
			countdown_remaining -= delta
			if countdown_remaining <= 0.0:
				countdown_remaining = 0.0
				state = RaceState.RACING
				_go_banner_timer = go_banner_duration
				if _ship != null:
					_ship.controls_locked = false
					_ship.hold_at_start = false

		RaceState.RACING:
			race_time += delta

		RaceState.FINISHED:
			pass

	_update_hud()


func _on_checkpoint_crossed(gate_index: int) -> void:
	if state != RaceState.RACING:
		return
	if gate_index != next_gate_index:
		return

	if gate_index < total_checkpoints:
		next_gate_index += 1
		if _track != null and _track.has_method("set_active_checkpoint"):
			_track.set_active_checkpoint(next_gate_index)
		if _split_label != null:
			if next_gate_index == total_checkpoints:
				_split_label.text = "ALL CHECKPOINTS CLEARED — HEAD FOR FINISH! (%s)" % format_time(race_time)
				_split_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.68, 1.0))
			else:
				_split_label.text = "CP %d / %d   %s" % [next_gate_index, total_checkpoints, format_time(race_time)]
				_split_label.add_theme_color_override("font_color", Color(0.55, 0.95, 1.0, 0.95))
		_split_flash_timer = 1.6
	else:
		# Crossed Finish Gate after clearing all ordered checkpoints
		_complete_race()


func _complete_race() -> void:
	state = RaceState.FINISHED
	if _ship != null:
		_ship.controls_locked = true
		_ship.hold_at_start = false
	if _track != null and _track.has_method("set_active_checkpoint"):
		_track.set_active_checkpoint(total_checkpoints + 1)

	var key := _current_record_key()
	var ship_class := _get_ship_weight_class_label()
	var prev_record: Dictionary = session_best_times.get(key, {})
	var prev_time: float = float(prev_record.get("time", INF))
	var delta_str := ""

	if race_time < prev_time:
		_last_finish_is_best = true
		if prev_time < INF:
			delta_str = " (-%s)" % format_time(prev_time - race_time)
		session_best_times[key] = {
			"time": race_time,
			"ship_class": ship_class,
		}
	else:
		_last_finish_is_best = false
		delta_str = " (+%s)" % format_time(race_time - prev_time)

	_show_finish_overlay(delta_str)


func _show_finish_overlay(delta_str: String) -> void:
	if _finish_panel == null:
		return
	var best_rec: Dictionary = session_best_times.get(_current_record_key(), {})
	var best_t: float = float(best_rec.get("time", race_time))
	var best_cls: String = str(best_rec.get("ship_class", _get_ship_weight_class_label()))

	if _last_finish_is_best:
		_finish_title_label.text = "FINISH — NEW SESSION BEST!"
		_finish_title_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.65, 1.0))
	else:
		_finish_title_label.text = "FINISH!"
		_finish_title_label.add_theme_color_override("font_color", Color(0.85, 0.96, 1.0, 1.0))

	_finish_time_label.text = "%s%s" % [format_time(race_time), delta_str]
	var track_label: String = _track.get_track_type_label() if (_track != null and _track.has_method("get_track_type_label")) else "Track"
	var seed_val: int = int(_track.active_seed) if (_track != null and "active_seed" in _track) else 0
	var tier_num: int = _get_ship_tier()
	_finish_details_label.text = (
		"%s  #%d\n"
		+ "Ship: %s (Tier %d)\n"
		+ "Session Best (Tier %d): %s (%s)"
	) % [track_label, seed_val, _get_ship_weight_class_label(), tier_num, tier_num, format_time(best_t), best_cls]

	_finish_note_label.text = ""
	_finish_panel.visible = true
	if _btn_restart != null:
		_btn_restart.grab_focus()


func _on_restart_pressed() -> void:
	begin_race(true)


func _on_main_menu_pressed() -> void:
	if ResourceLoader.exists("res://main_menu.tscn"):
		get_tree().change_scene_to_file("res://main_menu.tscn")
	elif _finish_note_label != null:
		_finish_note_label.text = "Main Menu will be wired in Step 2!"


func _current_record_key() -> String:
	var t_type: int = int(_track.active_track_type) if (_track != null and "active_track_type" in _track) else 1
	var seed_val: int = int(_track.active_seed) if (_track != null and "active_seed" in _track) else 0
	var tier := _get_ship_tier()
	return "%d_%d_T%d" % [t_type, seed_val, tier]


func _get_ship_tier() -> int:
	if _ship != null and "installed_thruster" in _ship and _ship.installed_thruster != null:
		return clampi(int(_ship.installed_thruster.tech_tier), 1, 4)
	return 1


func _get_ship_weight_class_label() -> String:
	if _ship != null and "installed_hull" in _ship and _ship.installed_hull != null:
		match int(_ship.installed_hull.size_class):
			0:
				return "Small (Dart)"
			1:
				return "Medium (Vector)"
			2:
				return "Large (Titan)"
	return "Custom"


func _update_hud() -> void:
	if _timer_label != null:
		_timer_label.text = format_time(race_time)

	if _status_label != null:
		var cp_text := (
			"FINISH ARMED"
			if next_gate_index >= total_checkpoints
			else "CP %d / %d" % [next_gate_index, total_checkpoints]
		)
		var best_rec: Dictionary = session_best_times.get(_current_record_key(), {})
		var best_text := (
			"BEST: %s (%s)" % [format_time(float(best_rec["time"])), str(best_rec["ship_class"])]
			if not best_rec.is_empty()
			else "BEST: --:--.--"
		)
		_status_label.text = "%s   |   %s" % [cp_text, best_text]

	if _countdown_label != null:
		if state == RaceState.COUNTDOWN_INITIAL:
			var digit := maxi(int(ceil(countdown_remaining)), 1)
			_countdown_label.visible = true
			_countdown_label.text = str(digit)
			_countdown_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.25, 1.0))
		elif state == RaceState.COUNTDOWN_RESTART:
			_countdown_label.visible = true
			_countdown_label.text = "READY"
			_countdown_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.25, 1.0))
		elif _go_banner_timer > 0.0:
			var alpha := clampf(_go_banner_timer / maxf(go_banner_duration, 0.01), 0.0, 1.0)
			_countdown_label.visible = true
			_countdown_label.text = "GO!"
			_countdown_label.add_theme_color_override("font_color", Color(0.32, 1.0, 0.65, alpha))
		else:
			_countdown_label.visible = false


static func format_time(seconds: float) -> String:
	var clamped := maxf(seconds, 0.0)
	var mins := int(floor(clamped / 60.0))
	var secs := int(floor(fmod(clamped, 60.0)))
	var hundredths := int(floor(fmod(clamped * 100.0, 100.0)))
	return "%02d:%02d.%02d" % [mins, secs, hundredths]


func _make_panel_style(border_col: Color = Color(0.25, 0.75, 1.0, 0.45)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.10, 0.78)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = border_col
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_right = 6
	sb.corner_radius_bottom_left = 6
	sb.content_margin_left = 16.0
	sb.content_margin_top = 10.0
	sb.content_margin_right = 16.0
	sb.content_margin_bottom = 10.0
	return sb


func _build_ui() -> void:
	# 1. Top-Center Race Timer & Checkpoint Panel
	_timer_panel = PanelContainer.new()
	_timer_panel.name = "RaceTimerPanel"
	_timer_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer_panel.anchor_left = 0.5
	_timer_panel.anchor_right = 0.5
	_timer_panel.anchor_top = 0.0
	_timer_panel.anchor_bottom = 0.0
	_timer_panel.offset_left = -180.0
	_timer_panel.offset_right = 180.0
	_timer_panel.offset_top = 20.0
	_timer_panel.offset_bottom = 92.0
	_timer_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_timer_panel.add_theme_stylebox_override("panel", _make_panel_style())
	add_child(_timer_panel)

	var timer_vbox := VBoxContainer.new()
	timer_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	timer_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer_panel.add_child(timer_vbox)

	_timer_label = Label.new()
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer_label.add_theme_font_size_override("font_size", 32)
	_timer_label.add_theme_color_override("font_color", Color(0.92, 0.98, 1.0, 1.0))
	_timer_label.text = "00:00.00"
	timer_vbox.add_child(_timer_label)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", Color(0.62, 0.86, 1.0, 0.92))
	_status_label.text = "CP 0 / 10   |   BEST: --:--.--"
	timer_vbox.add_child(_status_label)

	# 2. Split Flash Label right under the timer panel
	_split_label = Label.new()
	_split_label.name = "SplitFlashLabel"
	_split_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_split_label.anchor_left = 0.5
	_split_label.anchor_right = 0.5
	_split_label.anchor_top = 0.0
	_split_label.anchor_bottom = 0.0
	_split_label.offset_left = -260.0
	_split_label.offset_right = 260.0
	_split_label.offset_top = 104.0
	_split_label.offset_bottom = 134.0
	_split_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_split_label.add_theme_font_size_override("font_size", 18)
	_split_label.text = ""
	add_child(_split_label)

	# 3. Center Countdown Banner ("3", "2", "1", "READY", "GO!")
	_countdown_label = Label.new()
	_countdown_label.name = "CountdownLabel"
	_countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_countdown_label.anchor_left = 0.5
	_countdown_label.anchor_right = 0.5
	_countdown_label.anchor_top = 0.36
	_countdown_label.anchor_bottom = 0.36
	_countdown_label.offset_left = -220.0
	_countdown_label.offset_right = 220.0
	_countdown_label.offset_top = -50.0
	_countdown_label.offset_bottom = 50.0
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_countdown_label.add_theme_font_size_override("font_size", 76)
	_countdown_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_countdown_label.add_theme_constant_override("outline_size", 8)
	_countdown_label.visible = false
	add_child(_countdown_label)

	# 4. Centered Race Finish Overlay (Gamepad + Mouse navigable)
	_finish_panel = PanelContainer.new()
	_finish_panel.name = "FinishPanel"
	_finish_panel.anchor_left = 0.5
	_finish_panel.anchor_right = 0.5
	_finish_panel.anchor_top = 0.5
	_finish_panel.anchor_bottom = 0.5
	_finish_panel.offset_left = -240.0
	_finish_panel.offset_right = 240.0
	_finish_panel.offset_top = -145.0
	_finish_panel.offset_bottom = 145.0
	_finish_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_finish_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_finish_panel.add_theme_stylebox_override("panel", _make_panel_style(Color(0.32, 1.0, 0.72, 0.75)))
	_finish_panel.visible = false
	add_child(_finish_panel)

	var fin_vbox := VBoxContainer.new()
	fin_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	fin_vbox.add_theme_constant_override("separation", 12)
	_finish_panel.add_child(fin_vbox)

	_finish_title_label = Label.new()
	_finish_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_finish_title_label.add_theme_font_size_override("font_size", 26)
	_finish_title_label.text = "FINISH!"
	fin_vbox.add_child(_finish_title_label)

	_finish_time_label = Label.new()
	_finish_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_finish_time_label.add_theme_font_size_override("font_size", 42)
	_finish_time_label.add_theme_color_override("font_color", Color(0.95, 0.99, 1.0, 1.0))
	_finish_time_label.text = "00:00.00"
	fin_vbox.add_child(_finish_time_label)

	_finish_details_label = Label.new()
	_finish_details_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_finish_details_label.add_theme_font_size_override("font_size", 16)
	_finish_details_label.add_theme_color_override("font_color", Color(0.76, 0.90, 1.0, 0.95))
	fin_vbox.add_child(_finish_details_label)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	fin_vbox.add_child(btn_row)

	_btn_restart = Button.new()
	_btn_restart.text = "Restart"
	_btn_restart.custom_minimum_size = Vector2(150.0, 42.0)
	_btn_restart.pressed.connect(_on_restart_pressed)
	btn_row.add_child(_btn_restart)

	_btn_main_menu = Button.new()
	_btn_main_menu.text = "Main Menu"
	_btn_main_menu.custom_minimum_size = Vector2(150.0, 42.0)
	_btn_main_menu.pressed.connect(_on_main_menu_pressed)
	btn_row.add_child(_btn_main_menu)

	_finish_note_label = Label.new()
	_finish_note_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_finish_note_label.add_theme_font_size_override("font_size", 13)
	_finish_note_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.35, 0.9))
	_finish_note_label.text = ""
	fin_vbox.add_child(_finish_note_label)
