extends RigidBody2D

signal module_detached(module_name: String, impact_g: float)
signal ship_wrecked(reason: String, impact_g: float)

# Standard Earth gravity (m/s^2), used to convert Specific Impulse (I_sp in seconds)
# into effective exhaust velocity: v_e = I_sp * STANDARD_GRAVITY (m/s).
const STANDARD_GRAVITY := 9.80665

# Safety floors so Godot's RigidBody2D physics never divides by zero if every
# part mass or radius is manually set to 0 in the Inspector.
const MIN_TOTAL_MASS := 0.01
const MIN_INERTIA := 0.01
const ShipModuleScript = preload("res://ship_module.gd")

# ---------------------------------------------------------------------------
# Ship Loadout Presets (Small / Medium / Large)
# Each ShipData .tres is a collection of ShipPart pointers (hull, thruster,
# rcs, aux_parts). Swapping ships installs that loadout's parts onto the ship.
# ---------------------------------------------------------------------------
@export_group("Ship Presets")
@export var ship_small: ShipData = preload("res://ship_small.tres")
@export var ship_medium: ShipData = preload("res://ship_medium.tres")
@export var ship_large: ShipData = preload("res://ship_large.tres")
@export_enum("Small", "Medium", "Large") var starting_ship: int = 0
## Starting tech tier (1-4) for Hull, Engine, and RCS on launch.
@export_range(1, 4) var starting_tier: int = 1
## Optional hull scene override (e.g. ship_attempt.tscn) for testing modular blueprints
## while keeping the selected ship class and tech tier stats.
@export var test_hull_scene_override: PackedScene = null

# ---------------------------------------------------------------------------
# Installed Parts (Drag-and-drop .tres parts from res://parts/ to test!)
# If left empty before Play, _ready() equips `starting_ship`.
# If you assign custom parts in the Inspector (or swap them live in Remote
# Inspector), PlayerShip immediately recomputes mass, inertia, thrust, and I_sp.
# ---------------------------------------------------------------------------
@export_group("Installed Parts")
@export var installed_hull: HullPart
@export var installed_thruster: ThrusterPart
@export var installed_rcs: RCSPart
@export var installed_aux_parts: Array[ShipPart] = []
## Shared propellant currently in the tank (kg), initialized from installed_hull.fuel_capacity_kg.
@export var fuel_mass: float = 250.0

# ---------------------------------------------------------------------------
# Global Physics Baselines (SI Units)
# Every ThrusterPart and RCSPart scales off these square-cube (L^2 / L^3)
# reference baselines multiplied by each part's own tech_thrust_multiplier:
#   F_main   = reference_thrust_newtons * (thruster.mass_kg / reference_thruster_mass)^(2/3) * tech_mult
#   F_nozzle = reference_rcs_nozzle_thrust_n * (rcs.mass_kg / reference_rcs_mass)^(2/3) * tech_mult
#   tau_rcs  = 2 * F_nozzle * hull.rcs_lever_arm_m
#   F_lin    = 2 * F_nozzle
# ---------------------------------------------------------------------------
@export_group("Global Propulsion Baselines (SI)")
## Baseline NASA-era main engine mass (kg) corresponding to reference_thrust_newtons.
@export var reference_thruster_mass: float = 35.0
## Baseline NASA-era main thrust (N) at reference_thruster_mass (9 kN -> ~2.0-4.6 G on Medium).
@export var reference_thrust_newtons: float = 9000.0
## Square-cube scaling exponent for main engines (2/3 -> L^2 nozzle area / L^3 engine mass).
@export var thrust_mass_exponent: float = 2.0 / 3.0
## Baseline 6-nozzle RCS system mass (kg) corresponding to reference_rcs_nozzle_thrust_n.
@export var reference_rcs_mass: float = 20.0
## Baseline thrust per individual RCS nozzle (N) at reference_rcs_mass (300 N real-world hydrazine jets).
@export var reference_rcs_nozzle_thrust_n: float = 300.0
## Square-cube scaling exponent for RCS nozzles (2/3 -> L^2 area / L^3 volume).
@export var rcs_mass_exponent: float = 2.0 / 3.0
## World scale connecting SI meters to Godot 2D pixels (16 px/m -> 39 px Medium ship = ~2.4 m drone).
@export var pixels_per_meter: float = 16.0

# ---------------------------------------------------------------------------
# Flight Computer & RCS Valve Timing
# ---------------------------------------------------------------------------
@export_group("Flight Computer & RCS Visuals")
## Safety margin multiplier on angular stopping distance when stick-aiming.
@export var brake_multiplier: float = 1.5
## Angular deadband (radians) around stick-aim target (~0.025 rad = ~1.4 deg) to prevent
## microscopic analog stick jitter from constantly firing RCS and wasting propellant.
@export var aim_deadband_rad: float = 0.025
## Minimum time (s) an RCS nozzle stays ON once fired (Space Shuttle PRCS min pulse = 0.08 s).
@export var rcs_min_on_time: float = 0.08
## Minimum cooldown (s) after shutting OFF before an RCS nozzle can fire again (~6 Hz max cycle).
@export var rcs_min_off_time: float = 0.08
## Fraction of derived RCS torque required to trigger a visual puff (filters stick micro-jitter).
@export var rcs_visual_torque_threshold: float = 0.05

# ---------------------------------------------------------------------------
# Overburn & Stefan-Boltzmann Thermal Physics
# ---------------------------------------------------------------------------
@export_group("Overburn & Thermal Physics")
## Cold equilibrium hull temperature (K) at 0% heat (300 K = ~27 C).
@export var ambient_temp_k: float = 300.0
## Thermal safety redline temperature (K) at 100% heat (650 K = ~377 C).
@export var redline_temp_k: float = 650.0
## Heat fraction below which the thermal safety interlock re-enables Overburn after hitting 100%.
@export_range(0.1, 0.9, 0.05) var overheat_recovery_fraction: float = 0.25
## Enable developer mid-flight D-pad ship/part cycling and fuel refill hotkey.
@export var dev_hotkeys_enabled: bool = false

# ---------------------------------------------------------------------------
# Structural Integrity & Impact Physics
# ---------------------------------------------------------------------------
@export_group("Structural Integrity & Impact Physics")
## Enable real impact G-load calculation and modular part shear/detachment.
@export var destruction_enabled: bool = true
## Fixed structural crush pulse duration (s) converting delta-v into framerate-independent G-load.
@export var impact_pulse_duration_s: float = 0.05
## Baseline Tier 1 whole-ship shock G-limit before Transmitter loses signal.
@export var transmitter_shock_g_limit: float = 60.0
## Metallic restitution (bounciness) used for exact rigid-body rebound of sheared parts.
@export_range(0.0, 0.9, 0.05) var debris_restitution: float = 0.35
## Tangential Coulomb friction coefficient used for wall-scrape spin of sheared parts.
@export_range(0.0, 1.5, 0.05) var debris_friction: float = 0.45

var rotational_stabilize := true
var controls_locked: bool = false
var hold_at_start: bool = false
var is_wrecked: bool = false
var current_heat_kj: float = 0.0
var heat_capacity_kj: float = 100.0
var overburn_locked_out: bool = false
var is_overburning: bool = false
var _current_heating_kw: float = 0.0
var _current_cooling_kw: float = 0.0
var _current_max_cooling_kw: float = 18.0

const SIZE_KEYS: PackedStringArray = ["small", "medium", "large"]
const HULL_TIER_SLUGS: PackedStringArray = ["steel", "titanium", "carbon", "exotic"]
const ENGINE_TIER_SLUGS: PackedStringArray = ["chemical", "ntr", "fusion", "exotic"]
const RCS_TIER_SLUGS: PackedStringArray = ["hydrazine", "resistojet", "plasma", "exotic"]

var _active_ship_name: String = "Custom"
var _active_size_index: int = 0
var _hull_tier: int = 1
var _engine_tier: int = 1
var _rcs_tier: int = 1
var _loaded_hull_scene: PackedScene = null
var _initial_fuel_mass: float = 0.0
var _dry_mass: float = 0.0
var _inertia_si: float = 1.0
var _current_max_thrust_n: float = 0.0
var _current_applied_thrust_n: float = 0.0
var _current_fuel_burn_rate: float = 0.0
var _current_rcs_burn_rate: float = 0.0
var _current_rcs_nozzle_thrust_n: float = 0.0
var _current_rcs_torque: float = 0.0
var _max_rcs_cw_torque: float = 0.0
var _max_rcs_ccw_torque: float = 0.0
var _current_rcs_linear_force: float = 0.0
var _size_warnings: PackedStringArray = PackedStringArray()

var _active_hull_node: Node2D = null
var _active_collisions: Array[Node2D] = []
var _part_collider_map: Dictionary = {}
var _exhaust_sprite: Sprite2D = null
var _exhaust_base_scale: Vector2 = Vector2.ONE

# Per-part geometry properties cached from modular hull Shape polygons. Each entry:
#   "node": Node2D, "name": String, "role": int (ShipModule.ModuleRole),
#   "hull_mass_weight": float, "area_m2": float, "centroid_m": Vector2,
#   "i_cm_per_kg": float (moment of inertia per kg about part's own centroid)
var _modular_parts: Array[Dictionary] = []
var _aux_mount_positions_m: Array[Vector2] = []
var _center_of_mass_m: Vector2 = Vector2.ZERO
var _initial_total_hull_weight: float = 0.0
var _initial_rcs_nozzle_count: int = 0
var _has_main_engine: bool = true
var _hull_damaged: bool = false
var _last_impact_g: float = 0.0

# Impact tracking & detached zero-G debris management
var _prev_linear_velocity: Vector2 = Vector2.ZERO
var _prev_angular_velocity: float = 0.0
var _has_prev_velocity: bool = false
var _ccd_hold_frames: int = 0
var _pending_detach_ids: Dictionary = {}
var _spawned_debris: Array[RigidBody2D] = []
var _debris_exception_timers: Array[Dictionary] = []

# Discovered RCS nozzles in ship-local space. Each entry stores:
#   "node": Node2D, "name": String, "pos_px": Vector2, "pos_m": Vector2,
#   "thrust_dir_local": Vector2, "unit_torque_per_n": float,
#   "is_rotational": bool, "valve_on": bool, "valve_timer": float
var _rcs_nozzles: Array[Dictionary] = []

@onready var _telemetry_panel: Control = get_node_or_null("TelemetryLayer/TelemetryPanel")
@onready var _telemetry_label: Label = get_node_or_null("TelemetryLayer/TelemetryPanel/TelemetryLabel")
@onready var _track: Node = get_parent().get_node_or_null("Track") if get_parent() != null else null


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 8
	var gs := get_node_or_null("/root/GameState")
	if _telemetry_panel != null:
		_telemetry_panel.visible = bool(gs.show_telemetry) if gs != null else false
	if gs != null and gs.has_signal("telemetry_visibility_changed"):
		if not gs.telemetry_visibility_changed.is_connected(_on_telemetry_visibility_changed):
			gs.telemetry_visibility_changed.connect(_on_telemetry_visibility_changed)

	if gs != null and bool(gs.launched_from_menu):
		_active_size_index = clampi(int(gs.selected_weight_class), 0, 2)
		var init_tier := clampi(int(gs.selected_tech_tier), 1, 4)
		_hull_tier = init_tier
		_engine_tier = init_tier
		_rcs_tier = init_tier
		equip_size_and_tiers(_active_size_index, _hull_tier, _engine_tier, _rcs_tier)
		return

	_active_size_index = clampi(starting_ship, 0, 2)
	var init_tier := clampi(starting_tier, 1, 4)
	_hull_tier = init_tier
	_engine_tier = init_tier
	_rcs_tier = init_tier

	# If custom parts were already dragged onto PlayerShip in the Inspector, keep them;
	# otherwise load the selected starting ship size and tech tier.
	if installed_hull != null:
		_active_ship_name = "Custom (%s)" % installed_hull.part_name
		_sync_indices_from_installed_parts()
		_initial_fuel_mass = maxf(installed_hull.fuel_capacity_kg, 0.0)
		fuel_mass = _initial_fuel_mass
		_rebuild_hull_visuals()
		_refresh_all_stats()
	else:
		equip_size_and_tiers(_active_size_index, _hull_tier, _engine_tier, _rcs_tier)


func _on_telemetry_visibility_changed(is_visible: bool) -> void:
	if _telemetry_panel != null:
		_telemetry_panel.visible = is_visible


func _sync_indices_from_installed_parts() -> void:
	if installed_hull != null:
		_hull_tier = clampi(installed_hull.tech_tier, 1, 4)
		match installed_hull.size_class:
			ShipPart.SizeClass.SMALL:
				_active_size_index = 0
			ShipPart.SizeClass.MEDIUM:
				_active_size_index = 1
			ShipPart.SizeClass.LARGE:
				_active_size_index = 2
	if installed_thruster != null:
		_engine_tier = clampi(installed_thruster.tech_tier, 1, 4)
	if installed_rcs != null:
		_rcs_tier = clampi(installed_rcs.tech_tier, 1, 4)


func _load_hull_part(size_index: int, tier: int) -> HullPart:
	var s_key := SIZE_KEYS[clampi(size_index, 0, 2)]
	var t := clampi(tier, 1, 4)
	var path := "res://parts/hulls/%s/tier_%d/hull_%s_t%d_%s.tres" % [s_key, t, s_key, t, HULL_TIER_SLUGS[t - 1]]
	return load(path) as HullPart


func _load_thruster_part(size_index: int, tier: int) -> ThrusterPart:
	var s_key := SIZE_KEYS[clampi(size_index, 0, 2)]
	var t := clampi(tier, 1, 4)
	var path := "res://parts/thrusters/%s/tier_%d/thruster_%s_t%d_%s.tres" % [s_key, t, s_key, t, ENGINE_TIER_SLUGS[t - 1]]
	return load(path) as ThrusterPart


func _load_rcs_part(size_index: int, tier: int) -> RCSPart:
	var s_key := SIZE_KEYS[clampi(size_index, 0, 2)]
	var t := clampi(tier, 1, 4)
	var path := "res://parts/rcs/%s/tier_%d/rcs_%s_t%d_%s.tres" % [s_key, t, s_key, t, RCS_TIER_SLUGS[t - 1]]
	return load(path) as RCSPart


func equip_ship(data: ShipData) -> void:
	if data == null:
		return

	_active_ship_name = data.ship_name
	installed_hull = data.hull
	installed_thruster = data.thruster
	installed_rcs = data.rcs
	installed_aux_parts = data.aux_parts.duplicate()
	_sync_indices_from_installed_parts()

	_initial_fuel_mass = maxf(installed_hull.fuel_capacity_kg, 0.0) if installed_hull != null else 0.0
	fuel_mass = _initial_fuel_mass

	_rebuild_hull_visuals()
	_refresh_all_stats()


func equip_size_and_tier(size_index: int, tier: int) -> void:
	var t := clampi(tier, 1, 4)
	equip_size_and_tiers(size_index, t, t, t)


func equip_size_and_tiers(size_index: int, hull_tier: int, engine_tier: int, rcs_tier: int) -> void:
	_active_size_index = clampi(size_index, 0, 2)
	_hull_tier = clampi(hull_tier, 1, 4)
	_engine_tier = clampi(engine_tier, 1, 4)
	_rcs_tier = clampi(rcs_tier, 1, 4)

	var base_preset: ShipData = ship_small
	match _active_size_index:
		0:
			base_preset = ship_small
		1:
			base_preset = ship_medium
		2:
			base_preset = ship_large

	var hull_res := _load_hull_part(_active_size_index, _hull_tier)
	var eng_res := _load_thruster_part(_active_size_index, _engine_tier)
	var rcs_res := _load_rcs_part(_active_size_index, _rcs_tier)

	_active_ship_name = base_preset.ship_name if base_preset != null else SIZE_KEYS[_active_size_index].capitalize()
	installed_hull = hull_res if hull_res != null else (base_preset.hull if base_preset != null else null)
	installed_thruster = eng_res if eng_res != null else (base_preset.thruster if base_preset != null else null)
	installed_rcs = rcs_res if rcs_res != null else (base_preset.rcs if base_preset != null else null)
	installed_aux_parts = base_preset.aux_parts.duplicate() if base_preset != null else []

	_initial_fuel_mass = maxf(installed_hull.fuel_capacity_kg, 0.0) if installed_hull != null else 0.0
	fuel_mass = _initial_fuel_mass

	_rebuild_hull_visuals()
	_refresh_all_stats()


func cycle_ship_size() -> void:
	var next_size := (_active_size_index + 1) % 3
	equip_size_and_tiers(next_size, _hull_tier, _engine_tier, _rcs_tier)


func cycle_hull_tier() -> void:
	_hull_tier = (_hull_tier % 4) + 1
	var next_hull := _load_hull_part(_active_size_index, _hull_tier)
	if next_hull != null:
		install_hull(next_hull, false)


func cycle_engine_tier() -> void:
	_engine_tier = (_engine_tier % 4) + 1
	var next_eng := _load_thruster_part(_active_size_index, _engine_tier)
	if next_eng != null:
		install_thruster(next_eng)


func cycle_rcs_tier() -> void:
	_rcs_tier = (_rcs_tier % 4) + 1
	var next_rcs := _load_rcs_part(_active_size_index, _rcs_tier)
	if next_rcs != null:
		install_rcs(next_rcs)


func install_hull(part: HullPart, refill_fuel: bool = true) -> void:
	installed_hull = part
	if installed_hull != null:
		_initial_fuel_mass = maxf(installed_hull.fuel_capacity_kg, 0.0)
		if refill_fuel:
			fuel_mass = _initial_fuel_mass
		else:
			fuel_mass = minf(fuel_mass, _initial_fuel_mass)
	_rebuild_hull_visuals()
	_refresh_all_stats()


func install_thruster(part: ThrusterPart) -> void:
	installed_thruster = part
	_refresh_all_stats()


func install_rcs(part: RCSPart) -> void:
	installed_rcs = part
	_refresh_all_stats()


func get_flip_and_burn_projection() -> Dictionary:
	var speed_px := linear_velocity.length()
	if speed_px < 10.0 or mass <= 0.0:
		return {"valid": false}

	var vel_dir := linear_velocity / speed_px
	var retro_rot := (-vel_dir).angle() + PI * 0.5
	var turn_angle := absf(wrapf(retro_rot - global_rotation, -PI, PI))

	# Time to finish turning from current heading to retrograde using live RCS & inertia
	var t_flip := 0.0
	if turn_angle > aim_deadband_rad and _current_rcs_torque > 0.0 and _inertia_si > 0.0 and fuel_mass > 0.0:
		var alpha := _current_rcs_torque / _inertia_si
		var alpha_brake := alpha / maxf(brake_multiplier, 1.0)
		t_flip = sqrt(2.0 * turn_angle * (1.0 / alpha + 1.0 / alpha_brake))

	var flip_drift_px := speed_px * t_flip

	# Main engine retro-burn stopping distance using live wet mass & thrust
	var max_accel_px := (_current_max_thrust_n / mass) * pixels_per_meter
	var can_burn := fuel_mass > 0.0 and max_accel_px > 0.001
	var burn_dist_px := (speed_px * speed_px) / (2.0 * max_accel_px) if can_burn else 0.0

	var flip_end_world := global_position + vel_dir * flip_drift_px
	var stop_world := global_position + vel_dir * (flip_drift_px + burn_dist_px)

	return {
		"valid": can_burn,
		"vel_dir": vel_dir,
		"flip_drift_px": flip_drift_px,
		"burn_dist_px": burn_dist_px,
		"total_stop_px": flip_drift_px + burn_dist_px,
		"t_flip": t_flip,
		"flip_end_world": flip_end_world,
		"stop_world": stop_world,
	}


func place_at_spawn(world_pos: Vector2, world_rot: float, refill_fuel: bool = true) -> void:
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0
	global_position = world_pos
	global_rotation = world_rot
	# Keep PhysicsServer2D in sync immediately so teleporting a RigidBody2D leaves no residual momentum
	PhysicsServer2D.body_set_state(
		get_rid(),
		PhysicsServer2D.BODY_STATE_TRANSFORM,
		Transform2D(world_rot, world_pos)
	)
	PhysicsServer2D.body_set_state(get_rid(), PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, Vector2.ZERO)
	PhysicsServer2D.body_set_state(get_rid(), PhysicsServer2D.BODY_STATE_ANGULAR_VELOCITY, 0.0)
	if refill_fuel:
		clear_debris()
		is_wrecked = false
		_last_impact_g = 0.0
		_has_prev_velocity = false
		_ccd_hold_frames = 0
		_prev_linear_velocity = Vector2.ZERO
		_prev_angular_velocity = 0.0
		_pending_detach_ids.clear()
		fuel_mass = _initial_fuel_mass
		current_heat_kj = 0.0
		overburn_locked_out = false
		is_overburning = false
		if _hull_damaged:
			_rebuild_hull_visuals()
			_refresh_all_stats()
		else:
			_recalculate_mass_and_inertia()
	var cam := get_node_or_null("Camera2D")
	if cam != null and cam.has_method("reset_snap"):
		cam.reset_snap()
	_update_telemetry()


func get_heat_fraction() -> float:
	if heat_capacity_kj <= 0.001:
		return 0.0
	return clampf(current_heat_kj / heat_capacity_kj, 0.0, 1.0)


func get_hull_temp_k() -> float:
	return lerpf(ambient_temp_k, redline_temp_k, get_heat_fraction())


func _compute_radiative_cooling_kw(heat_frac: float) -> float:
	var h := clampf(heat_frac, 0.0, 1.0)
	var t_amb := maxf(ambient_temp_k, 1.0)
	var t_max := maxf(redline_temp_k, t_amb + 1.0)
	var t_cur := lerpf(t_amb, t_max, h)
	var t_amb4 := pow(t_amb, 4.0)
	var t_max4 := pow(t_max, 4.0)
	var rad_factor := clampf((pow(t_cur, 4.0) - t_amb4) / maxf(t_max4 - t_amb4, 1.0), 0.0, 1.0)
	return _current_max_cooling_kw * rad_factor


func _get_desired_hull_scene() -> PackedScene:
	if test_hull_scene_override != null:
		return test_hull_scene_override
	return installed_hull.hull_scene if installed_hull != null else null


func _get_transform_relative_to_ship(node: Node2D) -> Transform2D:
	var xform := Transform2D.IDENTITY
	var cur: Node = node
	while cur != null and cur != self:
		if cur is Node2D:
			xform = (cur as Node2D).transform * xform
		cur = cur.get_parent()
	return xform


func _find_first_node_by_name(root: Node, target_name: String) -> Node:
	if root == null:
		return null
	for child in root.get_children():
		if child.name == target_name:
			return child
		var found := _find_first_node_by_name(child, target_name)
		if found != null:
			return found
	return null


func _collect_rcs_nozzles(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		if child is Node2D and child.get_node_or_null("Plume") != null:
			var nozzle_node := child as Node2D
			var xform := _get_transform_relative_to_ship(nozzle_node)
			var pos_px := xform.origin
			var pos_m := pos_px / maxf(pixels_per_meter, 0.001)
			# Exhaust plume shoots along local -Y (Vector2.UP), so Newton's 3rd law
			# thrust acts along local +Y (Vector2.DOWN).
			var thrust_dir_local := xform.basis_xform(Vector2.DOWN).normalized()
			var unit_torque_per_n := pos_m.cross(thrust_dir_local)
			var lever_len := pos_m.length()
			var tangentiality := (absf(unit_torque_per_n) / lever_len) if lever_len > 0.001 else 0.0
			var is_rotational := absf(unit_torque_per_n) > 0.01 and tangentiality >= 0.5
			nozzle_node.visible = false
			_rcs_nozzles.append({
				"node": nozzle_node,
				"name": String(nozzle_node.name),
				"pos_px": pos_px,
				"pos_m": pos_m,
				"thrust_dir_local": thrust_dir_local,
				"unit_torque_per_n": unit_torque_per_n,
				"is_rotational": is_rotational,
				"valve_on": false,
				"valve_timer": 0.0,
			})
		else:
			_collect_rcs_nozzles(child)


func _compute_polygon_mass_properties(poly_px: PackedVector2Array) -> Dictionary:
	var n := poly_px.size()
	if n < 3:
		return {"area_m2": 0.0, "centroid_m": Vector2.ZERO, "i_cm_per_kg": 0.0}

	var inv_ppm := 1.0 / maxf(pixels_per_meter, 0.001)
	var twice_area := 0.0
	var centroid_acc := Vector2.ZERO
	var j_origin_acc := 0.0

	for i in n:
		var a := poly_px[i] * inv_ppm
		var b := poly_px[(i + 1) % n] * inv_ppm
		var cross := a.cross(b)
		twice_area += cross
		centroid_acc += (a + b) * cross
		j_origin_acc += cross * (a.dot(a) + a.dot(b) + b.dot(b))

	var signed_area := 0.5 * twice_area
	if absf(signed_area) < 1e-8:
		var avg := Vector2.ZERO
		for pt in poly_px:
			avg += pt * inv_ppm
		return {"area_m2": 0.0, "centroid_m": avg / float(n), "i_cm_per_kg": 0.0}

	var centroid_m := centroid_acc / (6.0 * signed_area)
	var j_origin := j_origin_acc / 12.0
	# Parallel Axis Theorem back to the polygon's own centroid: I_cm / m = J_origin / A - |C|^2
	var i_cm_per_kg := maxf((j_origin / signed_area) - centroid_m.length_squared(), 0.0)
	return {
		"area_m2": absf(signed_area),
		"centroid_m": centroid_m,
		"i_cm_per_kg": i_cm_per_kg,
	}


func _infer_module_role(part_node: Node2D) -> int:
	if part_node is ShipModuleScript:
		return int(part_node.role)
	var lower := String(part_node.name).to_lower()
	if lower.contains("fuel") or lower.contains("tank"):
		return ShipModuleScript.ModuleRole.FUEL_TANK
	if lower.contains("engine") or lower.contains("thruster"):
		return ShipModuleScript.ModuleRole.MAIN_ENGINE
	if lower.contains("transmitter") or lower.contains("receiver") or lower.contains("avionics"):
		return ShipModuleScript.ModuleRole.TRANSMITTER
	return ShipModuleScript.ModuleRole.STRUCTURE


func clear_debris() -> void:
	for entry in _debris_exception_timers:
		var body: RigidBody2D = entry["body"]
		if is_instance_valid(body):
			remove_collision_exception_with(body)
	_debris_exception_timers.clear()

	for debris in _spawned_debris:
		if is_instance_valid(debris):
			debris.queue_free()
	_spawned_debris.clear()


func _get_hull_tier_strength_multiplier() -> float:
	var tier := clampi(installed_hull.tech_tier if installed_hull != null else _hull_tier, 1, 4)
	match tier:
		1:
			return 1.0
		2:
			return 1.25
		3:
			return 1.50
		4:
			return 1.80
	return 1.0


func _rebuild_hull_visuals() -> void:
	clear_debris()
	_pending_detach_ids.clear()
	_hull_damaged = false
	_has_main_engine = true
	_initial_total_hull_weight = 0.0
	_initial_rcs_nozzle_count = 0

	# Immediately detach and free previous hull and reparented/generated collision shapes
	for col in _active_collisions:
		if is_instance_valid(col):
			if col.get_parent() == self:
				remove_child(col)
			col.queue_free()
	_active_collisions.clear()
	_part_collider_map.clear()
	_modular_parts.clear()
	_aux_mount_positions_m.clear()
	_center_of_mass_m = Vector2.ZERO

	if _active_hull_node != null:
		remove_child(_active_hull_node)
		_active_hull_node.queue_free()
		_active_hull_node = null

	_loaded_hull_scene = _get_desired_hull_scene()
	_exhaust_sprite = null
	_exhaust_base_scale = Vector2.ONE
	_rcs_nozzles.clear()

	if _loaded_hull_scene != null:
		_active_hull_node = _loaded_hull_scene.instantiate() as Node2D
		add_child(_active_hull_node)

		# 1) Legacy single-collider hulls: reparent HullCollision (or any direct Collision* child)
		var legacy_cols: Array[Node2D] = []
		var hull_col: Node2D = _active_hull_node.get_node_or_null("HullCollision") as Node2D
		if hull_col != null:
			legacy_cols.append(hull_col)
		else:
			for child in _active_hull_node.get_children():
				if child is CollisionShape2D or child is CollisionPolygon2D:
					legacy_cols.append(child as Node2D)

		if not legacy_cols.is_empty():
			for col in legacy_cols:
				var col_transform := _get_transform_relative_to_ship(col)
				col.get_parent().remove_child(col)
				col.owner = null
				add_child(col)
				col.transform = col_transform
				_active_collisions.append(col)
		else:
			# 2) Modular blueprints: auto-generate one CollisionPolygon2D per part's Shape Polygon2D
			# and cache each part's centroid, area, and self-inertia for exact CoM & Moment of Inertia.
			var inv_ppm := 1.0 / maxf(pixels_per_meter, 0.001)
			for child in _active_hull_node.get_children():
				if child is Marker2D and String(child.name).to_lower().begins_with("auxmount"):
					var mx := _get_transform_relative_to_ship(child as Node2D)
					_aux_mount_positions_m.append(mx.origin * inv_ppm)
					continue
				if not (child is Node2D):
					continue
				var part_node := child as Node2D
				var shape_poly := part_node.get_node_or_null("Shape") as Polygon2D
				if shape_poly == null or shape_poly.polygon.size() < 3:
					continue
				var xform := _get_transform_relative_to_ship(shape_poly)
				var transformed_pts := PackedVector2Array()
				transformed_pts.resize(shape_poly.polygon.size())
				for idx in shape_poly.polygon.size():
					transformed_pts[idx] = xform * shape_poly.polygon[idx]
				var col_poly := CollisionPolygon2D.new()
				col_poly.name = "%sCollision" % part_node.name
				col_poly.polygon = transformed_pts
				add_child(col_poly)
				_active_collisions.append(col_poly)
				_part_collider_map[col_poly] = part_node

				var props := _compute_polygon_mass_properties(transformed_pts)
				var role := _infer_module_role(part_node)
				var weight: float
				var shear_limit := 11.0
				var axial_mult := 2.2
				if part_node is ShipModuleScript:
					weight = maxf(float(part_node.hull_mass_weight), 0.0)
					shear_limit = maxf(float(part_node.shear_g_limit), 1.0)
					axial_mult = maxf(float(part_node.axial_strength_multiplier), 1.0)
				else:
					weight = 0.0 if role == ShipModuleScript.ModuleRole.MAIN_ENGINE else maxf(float(props["area_m2"]), 0.001)
					if role == ShipModuleScript.ModuleRole.FUEL_TANK:
						shear_limit = 32.0
						axial_mult = 1.0
					elif role == ShipModuleScript.ModuleRole.TRANSMITTER:
						shear_limit = 22.0
						axial_mult = 1.5
					elif role == ShipModuleScript.ModuleRole.MAIN_ENGINE:
						shear_limit = 17.0
						axial_mult = 1.8

				var part_xform := _get_transform_relative_to_ship(part_node)
				var axis_local := part_xform.basis_xform(Vector2.UP).normalized()

				_modular_parts.append({
					"node": part_node,
					"collider": col_poly,
					"name": String(part_node.name),
					"role": role,
					"hull_mass_weight": weight,
					"shear_g_limit": shear_limit,
					"axial_strength_multiplier": axial_mult,
					"axis_local": axis_local,
					"area_m2": float(props["area_m2"]),
					"centroid_m": props["centroid_m"] as Vector2,
					"i_cm_per_kg": float(props["i_cm_per_kg"]),
				})
				_initial_total_hull_weight += weight

		# Find ExhaustSprite anywhere inside the hull (supports both hull root and MainEngine/ExhaustSprite)
		_exhaust_sprite = _find_first_node_by_name(_active_hull_node, "ExhaustSprite") as Sprite2D
		if _exhaust_sprite != null:
			_exhaust_base_scale = _exhaust_sprite.scale

		# Discover every mounted RCS nozzle recursively (any Node2D with a Plume child)
		_collect_rcs_nozzles(_active_hull_node)
		_initial_rcs_nozzle_count = _rcs_nozzles.size()

	_update_exhaust_visual(0.0)
	var empty_throttles := PackedFloat32Array()
	empty_throttles.resize(_rcs_nozzles.size())
	_update_rcs_visuals(empty_throttles, 0.0)


func _refresh_all_stats() -> void:
	_validate_installed_part_sizes()
	_recalculate_mass_and_inertia()
	_recalculate_propulsion()
	_current_applied_thrust_n = 0.0
	_current_fuel_burn_rate = 0.0
	_current_rcs_burn_rate = 0.0
	_update_telemetry()


func _validate_installed_part_sizes() -> void:
	_size_warnings.clear()
	if installed_hull == null:
		return
	var hull_size := installed_hull.size_class
	var hull_label := ShipPart.size_class_name(hull_size)

	if installed_thruster != null and not installed_thruster.fits_hull_size(hull_size):
		_size_warnings.append(
			"Engine %s (%s) > %s hull"
			% [installed_thruster.part_name, ShipPart.size_class_name(installed_thruster.size_class), hull_label]
		)
	if installed_rcs != null and not installed_rcs.fits_hull_size(hull_size):
		_size_warnings.append(
			"RCS %s (%s) > %s hull"
			% [installed_rcs.part_name, ShipPart.size_class_name(installed_rcs.size_class), hull_label]
		)
	for aux in installed_aux_parts:
		if aux != null and not aux.fits_hull_size(hull_size):
			_size_warnings.append(
				"Aux %s (%s) > %s hull"
				% [aux.part_name, ShipPart.size_class_name(aux.size_class), hull_label]
			)

	for warning in _size_warnings:
		push_warning("SPAAAAAAAAAACE part size mismatch: %s" % warning)


func _get_inertia_radius_m() -> float:
	return maxf(installed_hull.inertia_radius_m, 0.01) if installed_hull != null else 1.5


func _get_rcs_lever_arm_m() -> float:
	return maxf(installed_hull.rcs_lever_arm_m, 0.0) if installed_hull != null else 1.8


# Returns every installed part's mass and radial distance from the center of mass.
# Currently all parts share the hull's inertia_radius_m, making it easy to swap in
# per-part positions or pixel-based CoM calculations later.
func _get_ship_parts() -> Array[Dictionary]:
	var r := _get_inertia_radius_m()
	var parts: Array[Dictionary] = []

	if installed_hull != null:
		parts.append({"name": "hull", "mass": maxf(installed_hull.mass_kg, 0.0), "radius_m": r})
	if installed_thruster != null:
		parts.append({"name": "thruster", "mass": maxf(installed_thruster.mass_kg, 0.0), "radius_m": r})
	if installed_rcs != null:
		parts.append({"name": "rcs", "mass": maxf(installed_rcs.mass_kg, 0.0), "radius_m": r})
	for i in installed_aux_parts.size():
		var aux := installed_aux_parts[i]
		if aux != null:
			parts.append({"name": "aux_%d" % i, "mass": maxf(aux.mass_kg, 0.0), "radius_m": r})

	parts.append({"name": "fuel", "mass": maxf(fuel_mass, 0.0), "radius_m": r})
	return parts


func _recalculate_mass_and_inertia() -> void:
	# Modular hull path: real per-part Center of Mass + Parallel Axis Theorem Moment of Inertia
	if not _modular_parts.is_empty():
		var mass_elements: Array[Dictionary] = []
		var hull_mass_kg := maxf(installed_hull.mass_kg, 0.0) if installed_hull != null else 0.0
		var thruster_mass_kg := maxf(installed_thruster.mass_kg, 0.0) if installed_thruster != null else 0.0
		var rcs_mass_kg := maxf(installed_rcs.mass_kg, 0.0) if installed_rcs != null else 0.0
		var cur_fuel_kg := maxf(fuel_mass, 0.0)

		var total_hull_weight := _initial_total_hull_weight
		var fuel_tank_count := 0
		var main_engine_count := 0
		for part in _modular_parts:
			var role: int = part["role"]
			if role == ShipModuleScript.ModuleRole.FUEL_TANK:
				fuel_tank_count += 1
			elif role == ShipModuleScript.ModuleRole.MAIN_ENGINE:
				main_engine_count += 1
		if total_hull_weight <= 0.0:
			for part in _modular_parts:
				total_hull_weight += float(part["hull_mass_weight"])

		# Distribute hull dry mass by explicit per-part weights (preserving original denominator
		# so detaching a part genuinely removes its mass from the ship!), thruster mass onto
		# MainEngine(s), and live fuel_mass onto FuelTank(s).
		var dry := 0.0
		for part in _modular_parts:
			var role: int = part["role"]
			var centroid_m: Vector2 = part["centroid_m"]
			var i_cm_per_kg: float = part["i_cm_per_kg"]
			var part_dry_kg := 0.0

			if total_hull_weight > 0.0:
				part_dry_kg += hull_mass_kg * (float(part["hull_mass_weight"]) / total_hull_weight)
			if role == ShipModuleScript.ModuleRole.MAIN_ENGINE and main_engine_count > 0 and _has_main_engine:
				part_dry_kg += thruster_mass_kg / float(main_engine_count)

			if part_dry_kg > 0.0:
				dry += part_dry_kg
				mass_elements.append({
					"mass": part_dry_kg,
					"pos_m": centroid_m,
					"i_cm_per_kg": i_cm_per_kg,
				})

			if role == ShipModuleScript.ModuleRole.FUEL_TANK and fuel_tank_count > 0 and cur_fuel_kg > 0.0:
				mass_elements.append({
					"mass": cur_fuel_kg / float(fuel_tank_count),
					"pos_m": centroid_m,
					"i_cm_per_kg": i_cm_per_kg,
				})

		# Fallbacks only on intact custom blueprints that omitted FuelTank or MainEngine roles
		if main_engine_count == 0 and _has_main_engine and not _hull_damaged and thruster_mass_kg > 0.0:
			dry += thruster_mass_kg
			mass_elements.append({"mass": thruster_mass_kg, "pos_m": Vector2.ZERO, "i_cm_per_kg": 0.0})
		if fuel_tank_count == 0 and not _hull_damaged and cur_fuel_kg > 0.0:
			mass_elements.append({"mass": cur_fuel_kg, "pos_m": Vector2.ZERO, "i_cm_per_kg": 0.0})

		# Distribute RCS system mass across surviving RCS nozzles (preserving per-nozzle mass)
		if rcs_mass_kg > 0.0:
			if not _rcs_nozzles.is_empty():
				var denom := float(maxi(_initial_rcs_nozzle_count, _rcs_nozzles.size()))
				var per_nozzle_kg := rcs_mass_kg / denom
				dry += per_nozzle_kg * float(_rcs_nozzles.size())
				for noz in _rcs_nozzles:
					mass_elements.append({
						"mass": per_nozzle_kg,
						"pos_m": noz["pos_m"] as Vector2,
						"i_cm_per_kg": 0.0,
					})
			elif not _hull_damaged:
				dry += rcs_mass_kg
				mass_elements.append({"mass": rcs_mass_kg, "pos_m": Vector2.ZERO, "i_cm_per_kg": 0.0})

		# Distribute each installed aux part symmetrically across AuxMount* markers
		# (e.g., paired port/starboard mounts) so symmetric gear stays balanced in CoM
		# while still adding its real radial inertia at the mount distance.
		for aux in installed_aux_parts:
			if aux == null:
				continue
			var aux_kg := maxf(aux.mass_kg, 0.0)
			if aux_kg <= 0.0:
				continue
			dry += aux_kg
			if not _aux_mount_positions_m.is_empty():
				var per_mount_kg := aux_kg / float(_aux_mount_positions_m.size())
				for mount_pos_m in _aux_mount_positions_m:
					mass_elements.append({"mass": per_mount_kg, "pos_m": mount_pos_m, "i_cm_per_kg": 0.0})
			else:
				mass_elements.append({"mass": aux_kg, "pos_m": Vector2.ZERO, "i_cm_per_kg": 0.0})

		# 1) Total mass and exact Center of Mass
		var total_mass := 0.0
		var com_weighted := Vector2.ZERO
		for el in mass_elements:
			var m: float = el["mass"]
			total_mass += m
			com_weighted += (el["pos_m"] as Vector2) * m

		_center_of_mass_m = (com_weighted / total_mass) if total_mass > MIN_TOTAL_MASS else Vector2.ZERO
		center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_CUSTOM
		center_of_mass = _center_of_mass_m * pixels_per_meter

		# 2) Exact Moment of Inertia via Parallel Axis Theorem: I = sum(m_i * (i_cm_i + |p_i - CoM|^2))
		var total_inertia := 0.0
		for el in mass_elements:
			var m: float = el["mass"]
			var d_sq: float = ((el["pos_m"] as Vector2) - _center_of_mass_m).length_squared()
			total_inertia += m * (float(el["i_cm_per_kg"]) + d_sq)

		_dry_mass = dry
		mass = maxf(total_mass, MIN_TOTAL_MASS)
		_inertia_si = maxf(total_inertia, MIN_INERTIA)
		# Godot 2D RigidBody2D operates in pixels (kg*px^2), so scale SI inertia by ppm^2
		# so wall/ship collision spin matches real-world rotational inertia!
		var ppm_sq := maxf(pixels_per_meter, 0.001) * maxf(pixels_per_meter, 0.001)
		inertia = _inertia_si * ppm_sq
		return

	# Legacy single-collider hull path: uniform-radius inertia approximation around origin
	_center_of_mass_m = Vector2.ZERO
	center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_AUTO
	var parts := _get_ship_parts()
	var total_mass := 0.0
	var total_inertia := 0.0
	var dry := 0.0

	for part in parts:
		var part_mass: float = part["mass"]
		var part_radius: float = part["radius_m"]
		total_mass += part_mass
		total_inertia += part_mass * part_radius * part_radius
		if part["name"] != "fuel":
			dry += part_mass

	_dry_mass = dry
	mass = maxf(total_mass, MIN_TOTAL_MASS)
	_inertia_si = maxf(total_inertia, MIN_INERTIA)
	var ppm_sq := maxf(pixels_per_meter, 0.001) * maxf(pixels_per_meter, 0.001)
	inertia = _inertia_si * ppm_sq


func _recalculate_propulsion() -> void:
	if installed_thruster != null and _has_main_engine:
		_current_max_thrust_n = installed_thruster.get_max_thrust_newtons(
			reference_thruster_mass, reference_thrust_newtons, thrust_mass_exponent
		)
	else:
		_current_max_thrust_n = 0.0

	if installed_rcs != null:
		_current_rcs_nozzle_thrust_n = installed_rcs.get_nozzle_thrust_newtons(
			reference_rcs_mass, reference_rcs_nozzle_thrust_n, rcs_mass_exponent
		)
	else:
		_current_rcs_nozzle_thrust_n = 0.0

	# Derive real RCS rotational & linear authority directly from every discovered nozzle
	# relative to the ship's live Center of Mass (_center_of_mass_m).
	# Falls back to symmetric 2-nozzle hull estimates only if a hull has no mounted nozzles.
	if not _rcs_nozzles.is_empty():
		var cw_tau := 0.0
		var ccw_tau := 0.0
		var max_axis_linear := 0.0
		for nozzle in _rcs_nozzles:
			var r_m: Vector2 = (nozzle["pos_m"] as Vector2) - _center_of_mass_m
			var thrust_dir_local: Vector2 = nozzle["thrust_dir_local"]
			var unit_tau := r_m.cross(thrust_dir_local)
			var lever_len := r_m.length()
			var tangentiality := (absf(unit_tau) / lever_len) if lever_len > 0.001 else 0.0
			var is_rot := absf(unit_tau) > 0.01 and tangentiality >= 0.5
			nozzle["unit_torque_per_n"] = unit_tau
			nozzle["is_rotational"] = is_rot

			if is_rot:
				if unit_tau > 0.0:
					cw_tau += unit_tau * _current_rcs_nozzle_thrust_n
				elif unit_tau < 0.0:
					ccw_tau += (-unit_tau) * _current_rcs_nozzle_thrust_n

		# Sample cardinal axes to estimate linear RCS authority for HUD / braking availability
		for dir in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
			var axis_n := 0.0
			for nozzle in _rcs_nozzles:
				var d: float = (nozzle["thrust_dir_local"] as Vector2).dot(dir)
				if d > 0.1:
					axis_n += d * _current_rcs_nozzle_thrust_n
			max_axis_linear = maxf(max_axis_linear, axis_n)

		_max_rcs_cw_torque = cw_tau
		_max_rcs_ccw_torque = ccw_tau
		_current_rcs_torque = maxf(cw_tau, ccw_tau)
		_current_rcs_linear_force = max_axis_linear
	else:
		if _hull_damaged:
			_max_rcs_cw_torque = 0.0
			_max_rcs_ccw_torque = 0.0
			_current_rcs_torque = 0.0
			_current_rcs_linear_force = 0.0
		else:
			var lever_arm := _get_rcs_lever_arm_m()
			_max_rcs_cw_torque = 2.0 * _current_rcs_nozzle_thrust_n * lever_arm
			_max_rcs_ccw_torque = _max_rcs_cw_torque
			_current_rcs_torque = _max_rcs_cw_torque
			_current_rcs_linear_force = 2.0 * _current_rcs_nozzle_thrust_n

	if installed_hull != null:
		heat_capacity_kj = maxf(installed_hull.heat_capacity_kj, 1.0)
		_current_max_cooling_kw = maxf(installed_hull.max_radiative_cooling_kw, 0.0)
	else:
		heat_capacity_kj = 100.0
		_current_max_cooling_kw = 18.0
	current_heat_kj = clampf(current_heat_kj, 0.0, heat_capacity_kj)


func _find_modular_part_entry(part_node: Node2D) -> Dictionary:
	for entry in _modular_parts:
		if entry["node"] == part_node:
			return entry
	return {}


func _compute_module_mass_and_inertia(part_entry: Dictionary) -> Dictionary:
	var part_node: Node2D = part_entry["node"]
	var role: int = part_entry["role"]
	var hull_mass_kg := maxf(installed_hull.mass_kg, 0.0) if installed_hull != null else 0.0
	var thruster_mass_kg := maxf(installed_thruster.mass_kg, 0.0) if installed_thruster != null else 0.0
	var rcs_mass_kg := maxf(installed_rcs.mass_kg, 0.0) if installed_rcs != null else 0.0

	var base_kg := 0.0
	if _initial_total_hull_weight > 0.0:
		base_kg += hull_mass_kg * (float(part_entry["hull_mass_weight"]) / _initial_total_hull_weight)
	if role == ShipModuleScript.ModuleRole.MAIN_ENGINE and _has_main_engine:
		base_kg += thruster_mass_kg
	if role == ShipModuleScript.ModuleRole.FUEL_TANK:
		base_kg += maxf(fuel_mass, 0.0)

	var centroid_m: Vector2 = part_entry["centroid_m"]
	var i_cm_per_kg: float = part_entry["i_cm_per_kg"]
	var total_kg := base_kg
	var com_weighted := centroid_m * base_kg

	# Include any RCS nozzles mounted on this module (e.g. RcsCW + RcsCCW on a truss)
	var child_nozzles: Array[Dictionary] = []
	var per_nozzle_kg := (rcs_mass_kg / float(_initial_rcs_nozzle_count)) if _initial_rcs_nozzle_count > 0 else 0.0
	if per_nozzle_kg > 0.0:
		for noz in _rcs_nozzles:
			var noz_node: Node2D = noz["node"]
			if is_instance_valid(noz_node) and part_node.is_ancestor_of(noz_node):
				child_nozzles.append(noz)
				total_kg += per_nozzle_kg
				com_weighted += (noz["pos_m"] as Vector2) * per_nozzle_kg

	total_kg = maxf(total_kg, 0.5)
	var module_com_m := (com_weighted / total_kg) if base_kg > 0.0 or not child_nozzles.is_empty() else centroid_m

	# Parallel Axis Theorem around the module's combined center of mass
	var total_i := base_kg * (i_cm_per_kg + (centroid_m - module_com_m).length_squared())
	for noz in child_nozzles:
		total_i += per_nozzle_kg * ((noz["pos_m"] as Vector2) - module_com_m).length_squared()

	return {
		"mass": total_kg,
		"inertia": maxf(total_i, 0.02),
		"com_ship_m": module_com_m,
	}


func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if hold_at_start:
		_prev_linear_velocity = Vector2.ZERO
		_prev_angular_velocity = 0.0
		_has_prev_velocity = true
		return

	if not _has_prev_velocity:
		_prev_linear_velocity = state.linear_velocity
		_prev_angular_velocity = state.angular_velocity
		_has_prev_velocity = true
		return

	var contact_count := state.get_contact_count()
	if contact_count > 0 and destruction_enabled and not is_wrecked and not _modular_parts.is_empty():
		var ppm := maxf(pixels_per_meter, 0.001)
		var pulse_s := maxf(impact_pulse_duration_s, 0.005)
		var tier_mult := _get_hull_tier_strength_multiplier()
		var ship_xform: Transform2D = state.transform
		var ship_com_world: Vector2 = ship_xform * center_of_mass

		# Aggregate strongest contact per hit modular part
		var part_hits: Dictionary = {}
		var fuel_tank_contacted := false

		for i in contact_count:
			var local_shape_idx := state.get_contact_local_shape(i)
			var owner_id := shape_find_owner(local_shape_idx)
			var col_node := shape_owner_get_owner(owner_id) as Node2D
			var part_node: Node2D = _part_collider_map.get(col_node, null)
			if part_node == null or not is_instance_valid(part_node):
				continue

			var part_id := part_node.get_instance_id()
			if _pending_detach_ids.has(part_id):
				continue

			var contact_world: Vector2 = state.get_contact_collider_position(i)
			var push_normal: Vector2 = state.get_contact_local_normal(i).normalized()
			if push_normal.length_squared() < 0.01:
				continue

			var r_ship_px := contact_world - ship_com_world
			var v_self_contact := _prev_linear_velocity + Vector2(
				-_prev_angular_velocity * r_ship_px.y,
				_prev_angular_velocity * r_ship_px.x
			)
			var v_other_contact: Vector2 = state.get_contact_collider_velocity_at_position(i)
			var v_rel_px := v_self_contact - v_other_contact
			var v_close_m_s := maxf(-v_rel_px.dot(push_normal), 0.0) / ppm

			# Reduced-mass factor: walls=1.0, tiny debris=~0.04, heavier ships=m_other/(m_self+m_other)
			var mass_factor := 1.0
			var other_obj := state.get_contact_collider_object(i)
			if other_obj is RigidBody2D:
				var m_other := maxf((other_obj as RigidBody2D).mass, 0.01)
				mass_factor = m_other / (mass + m_other)

			var eff_dv_m_s := v_close_m_s * mass_factor
			var local_g := (eff_dv_m_s / pulse_s) / STANDARD_GRAVITY
			_last_impact_g = maxf(_last_impact_g, local_g)

			var entry := _find_modular_part_entry(part_node)
			if entry.is_empty():
				continue
			if int(entry["role"]) == ShipModuleScript.ModuleRole.FUEL_TANK:
				fuel_tank_contacted = true

			if not part_hits.has(part_id) or local_g > float(part_hits[part_id]["impact_g"]):
				part_hits[part_id] = {
					"entry": entry,
					"impact_g": local_g,
					"contact_world": contact_world,
					"push_normal": push_normal,
					"v_other_contact": v_other_contact,
				}

		var sheared_outer := false
		var strongest_shear_frac := 1.0
		var fatal_reason := ""
		var fatal_g := 0.0

		for part_id in part_hits.keys():
			var hit: Dictionary = part_hits[part_id]
			var entry: Dictionary = hit["entry"]
			var impact_g: float = hit["impact_g"]
			var push_normal: Vector2 = hit["push_normal"]
			# Directional structural strength: axial compression (straight down the beam into
			# the hub) is stronger than 90-deg perpendicular shear/bending at the tip.
			var axis_world := ship_xform.basis_xform(entry["axis_local"] as Vector2).normalized()
			var axial := clampf(absf(push_normal.dot(axis_world)), 0.0, 1.0)
			var axial_mult := maxf(float(entry.get("axial_strength_multiplier", 1.0)), 1.0)
			var limit_g := float(entry["shear_g_limit"]) * tier_mult * lerpf(1.0, axial_mult, axial * axial)
			if impact_g <= limit_g:
				continue

			var part_node: Node2D = entry["node"]
			var role: int = entry["role"]
			var props := _compute_module_mass_and_inertia(entry)
			var m_part: float = props["mass"]
			var i_part: float = props["inertia"]
			var part_com_world: Vector2 = ship_xform * ((props["com_ship_m"] as Vector2) * ppm)

			# Exact 2D rigid-body post-impact velocity & spin of the detached part (zero randomness!)
			var r_part_ship_px := part_com_world - ship_com_world
			var v_part_pre := _prev_linear_velocity + Vector2(
				-_prev_angular_velocity * r_part_ship_px.y,
				_prev_angular_velocity * r_part_ship_px.x
			)
			var contact_world: Vector2 = hit["contact_world"]
			var v_other_contact: Vector2 = hit["v_other_contact"]
			var r_tip_m := (contact_world - part_com_world) / ppm
			var v_tip_rel_m := (v_part_pre - v_other_contact) / ppm + Vector2(
				-_prev_angular_velocity * r_tip_m.y,
				_prev_angular_velocity * r_tip_m.x
			)

			var v_n := v_tip_rel_m.dot(push_normal)
			var r_cross_n := r_tip_m.cross(push_normal)
			var denom_n := (1.0 / m_part) + (r_cross_n * r_cross_n) / maxf(i_part, 0.001)
			var j_n := -(1.0 + debris_restitution) * minf(v_n, 0.0) / denom_n

			var tangent := Vector2(-push_normal.y, push_normal.x)
			var v_t := v_tip_rel_m.dot(tangent)
			var r_cross_t := r_tip_m.cross(tangent)
			var denom_t := (1.0 / m_part) + (r_cross_t * r_cross_t) / maxf(i_part, 0.001)
			var j_t := clampf(-v_t / denom_t, -debris_friction * j_n, debris_friction * j_n)

			var j_si := push_normal * j_n + tangent * j_t
			var v_debris_px := v_part_pre + (j_si / m_part) * ppm
			var w_debris := _prev_angular_velocity + r_tip_m.cross(j_si) / maxf(i_part, 0.001)

			_pending_detach_ids[part_id] = true
			call_deferred("_execute_detach_module", {
				"part_node": part_node,
				"impact_g": impact_g,
				"mass": m_part,
				"inertia": i_part,
				"com_ship_m": props["com_ship_m"],
				"v_debris_px": v_debris_px,
				"w_debris": w_debris,
				"push_normal": push_normal,
				"emit_signal": true,
			})

			if role == ShipModuleScript.ModuleRole.FUEL_TANK:
				fatal_reason = "HULL RUPTURE"
				fatal_g = maxf(fatal_g, impact_g)
			elif role == ShipModuleScript.ModuleRole.TRANSMITTER:
				if fatal_reason.is_empty():
					fatal_reason = "SIGNAL LOST"
				fatal_g = maxf(fatal_g, impact_g)
			else:
				sheared_outer = true
				strongest_shear_frac = minf(strongest_shear_frac, clampf(limit_g / maxf(impact_g, 0.001), 0.2, 0.85))

		# Glancing shear-through: if only outer appendages sheared off (not the core tank),
		# cap the remaining ship's velocity change to the weld's shear yield fraction.
		if sheared_outer and not fuel_tank_contacted and fatal_reason.is_empty():
			state.linear_velocity = _prev_linear_velocity.lerp(state.linear_velocity, strongest_shear_frac)
			state.angular_velocity = lerpf(_prev_angular_velocity, state.angular_velocity, strongest_shear_frac)

		# Whole-ship transmitted shock check on Transmitter (even if outer parts took the contact)
		var body_dv_m_s := (state.linear_velocity - _prev_linear_velocity).length() / ppm
		var whole_ship_g := (body_dv_m_s / pulse_s) / STANDARD_GRAVITY
		_last_impact_g = maxf(_last_impact_g, whole_ship_g)
		if fatal_reason.is_empty() and whole_ship_g > transmitter_shock_g_limit * tier_mult:
			fatal_reason = "SIGNAL LOST"
			fatal_g = whole_ship_g

		if not fatal_reason.is_empty():
			is_wrecked = true
			controls_locked = true
			call_deferred("_execute_fatal_wreck", fatal_reason, fatal_g, state.linear_velocity, state.angular_velocity)

		_ccd_hold_frames = 0
		_prev_linear_velocity = state.linear_velocity
		_prev_angular_velocity = state.angular_velocity
	else:
		# Godot's CCD_MODE_CAST_RAY often pre-brakes linear_velocity 1 frame BEFORE
		# reporting polygon contacts (contact_count == 0). If speed drops sharply without
		# thruster explanation, preserve the true pre-CCD velocity for up to 2 ticks so
		# the immediately following contact frame measures the real impact speed.
		var max_expected_dv_px := (
			((_current_applied_thrust_n + _current_rcs_linear_force) / maxf(mass, MIN_TOTAL_MASS))
			* maxf(pixels_per_meter, 0.001)
			* maxf(state.step, 0.001)
		) + 24.0
		var dv_px := (state.linear_velocity - _prev_linear_velocity).length()
		var slowed_down := state.linear_velocity.length_squared() < _prev_linear_velocity.length_squared()
		if _ccd_hold_frames == 0 and slowed_down and dv_px > max_expected_dv_px:
			_ccd_hold_frames = 2
		elif _ccd_hold_frames > 0:
			_ccd_hold_frames -= 1
			if _ccd_hold_frames == 0:
				_prev_linear_velocity = state.linear_velocity
				_prev_angular_velocity = state.angular_velocity
		else:
			_prev_linear_velocity = state.linear_velocity
			_prev_angular_velocity = state.angular_velocity


func _hide_visual_effects_recursive(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		if child.name == "ExhaustSprite" and child is CanvasItem:
			(child as CanvasItem).visible = false
		elif child is Node2D and child.get_node_or_null("Plume") != null:
			(child as Node2D).visible = false
		else:
			_hide_visual_effects_recursive(child)


func _execute_detach_module(info: Dictionary) -> void:
	var part_node: Node2D = info["part_node"]
	if not is_instance_valid(part_node) or _active_hull_node == null:
		return
	if not _active_hull_node.is_ancestor_of(part_node):
		return

	var entry := _find_modular_part_entry(part_node)
	if entry.is_empty():
		return

	_hull_damaged = true
	var role: int = entry["role"]
	var mod_name: String = entry["name"]
	var ppm := maxf(pixels_per_meter, 0.001)

	# 1) Remove old collider from PlayerShip
	var col_poly: Node2D = entry["collider"]
	if is_instance_valid(col_poly):
		_part_collider_map.erase(col_poly)
		_active_collisions.erase(col_poly)
		if col_poly.get_parent() == self:
			remove_child(col_poly)
		col_poly.queue_free()

	# 2) Remove any RCS nozzles mounted on this module
	for i in range(_rcs_nozzles.size() - 1, -1, -1):
		var noz_node: Node2D = _rcs_nozzles[i]["node"]
		if not is_instance_valid(noz_node) or part_node.is_ancestor_of(noz_node):
			_rcs_nozzles.remove_at(i)

	# 3) If MainEngine detached, shut off main thruster and exhaust reference
	if role == ShipModuleScript.ModuleRole.MAIN_ENGINE:
		_has_main_engine = false
		if _exhaust_sprite != null and (not is_instance_valid(_exhaust_sprite) or part_node.is_ancestor_of(_exhaust_sprite)):
			_exhaust_sprite = null

	_modular_parts.erase(entry)

	# 4) Spawn zero-G RigidBody2D debris with exact world transform, mass, inertia, and velocity
	var part_world_xform := part_node.global_transform
	var shape_poly := part_node.get_node_or_null("Shape") as Polygon2D
	var push_normal: Vector2 = info["push_normal"]

	var debris := RigidBody2D.new()
	debris.name = "%sDebris" % mod_name
	debris.gravity_scale = 0.0
	debris.linear_damp = 0.0
	debris.angular_damp = 0.0
	debris.continuous_cd = RigidBody2D.CCD_MODE_CAST_RAY
	debris.mass = maxf(float(info["mass"]), 0.5)
	debris.inertia = maxf(float(info["inertia"]), 0.02) * ppm * ppm

	# Compute CoM in the debris body's local coordinates (matching part_node's local frame)
	var com_ship_px := (info["com_ship_m"] as Vector2) * ppm
	var part_rel_ship := _get_transform_relative_to_ship(part_node)
	var com_local_px := part_rel_ship.affine_inverse() * com_ship_px
	debris.center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_CUSTOM
	debris.center_of_mass = com_local_px

	debris.global_position = part_world_xform.origin + push_normal * 1.5
	debris.global_rotation = part_world_xform.get_rotation()
	debris.linear_velocity = info["v_debris_px"]
	debris.angular_velocity = float(info["w_debris"])

	# Reparent visual module onto the debris body and shut off plumes/exhaust
	part_node.get_parent().remove_child(part_node)
	part_node.owner = null
	part_node.transform = Transform2D.IDENTITY
	_hide_visual_effects_recursive(part_node)
	debris.add_child(part_node)

	if shape_poly != null and shape_poly.polygon.size() >= 3:
		var debris_col := CollisionPolygon2D.new()
		var pts := PackedVector2Array()
		pts.resize(shape_poly.polygon.size())
		var s_xform := shape_poly.transform
		for idx in shape_poly.polygon.size():
			pts[idx] = s_xform * shape_poly.polygon[idx]
		debris_col.polygon = pts
		debris.add_child(debris_col)

	var parent_node := get_parent()
	if parent_node != null:
		parent_node.add_child(debris)
		_spawned_debris.append(debris)
		add_collision_exception_with(debris)
		_debris_exception_timers.append({"body": debris, "time": 0.15})
	else:
		debris.queue_free()

	# 5) Recompute live mass, CoM, inertia, and remaining thruster/RCS authority
	_recalculate_mass_and_inertia()
	_recalculate_propulsion()
	if bool(info.get("emit_signal", true)):
		module_detached.emit(mod_name, float(info["impact_g"]))


func _execute_fatal_wreck(reason: String, impact_g: float, ship_vel_px: Vector2, ship_ang_vel: float) -> void:
	_update_exhaust_visual(0.0, false)
	var empty_throttles := PackedFloat32Array()
	empty_throttles.resize(_rcs_nozzles.size())
	_update_rcs_visuals(empty_throttles, 0.0)

	# On core Hull Rupture, scatter every remaining attached module along its true rigid-body tangent
	if reason == "HULL RUPTURE":
		var ppm := maxf(pixels_per_meter, 0.001)
		var ship_com_world := global_transform * center_of_mass
		var remaining := _modular_parts.duplicate()
		for entry in remaining:
			var part_node: Node2D = entry["node"]
			if not is_instance_valid(part_node):
				continue
			var props := _compute_module_mass_and_inertia(entry)
			var part_com_world := global_transform * ((props["com_ship_m"] as Vector2) * ppm)
			var r_px := part_com_world - ship_com_world
			var v_part := ship_vel_px + Vector2(-ship_ang_vel * r_px.y, ship_ang_vel * r_px.x)
			var out_dir := r_px.normalized() if r_px.length_squared() > 0.1 else Vector2.ZERO
			_execute_detach_module({
				"part_node": part_node,
				"impact_g": impact_g,
				"mass": props["mass"],
				"inertia": props["inertia"],
				"com_ship_m": props["com_ship_m"],
				"v_debris_px": v_part + out_dir * (3.0 * ppm),
				"w_debris": ship_ang_vel,
				"push_normal": out_dir,
				"emit_signal": false,
			})

	ship_wrecked.emit(reason, impact_g)


func _physics_process(delta: float) -> void:
	# Expire temporary spawn collision exceptions on detached debris so wreckage becomes solid
	for i in range(_debris_exception_timers.size() - 1, -1, -1):
		var item: Dictionary = _debris_exception_timers[i]
		var t: float = float(item["time"]) - delta
		var body: RigidBody2D = item["body"]
		if t <= 0.0 or not is_instance_valid(body):
			if is_instance_valid(body):
				remove_collision_exception_with(body)
			_debris_exception_timers.remove_at(i)
		else:
			item["time"] = t
	if dev_hotkeys_enabled:
		if InputMap.has_action("cycle_ship_size") and Input.is_action_just_pressed("cycle_ship_size"):
			cycle_ship_size()
		if InputMap.has_action("cycle_hull") and Input.is_action_just_pressed("cycle_hull"):
			cycle_hull_tier()
		if InputMap.has_action("cycle_engine") and Input.is_action_just_pressed("cycle_engine"):
			cycle_engine_tier()
		if InputMap.has_action("cycle_rcs") and Input.is_action_just_pressed("cycle_rcs"):
			cycle_rcs_tier()

		if InputMap.has_action("swap_ship_small") and Input.is_action_just_pressed("swap_ship_small"):
			equip_size_and_tiers(0, _hull_tier, _engine_tier, _rcs_tier)
		elif InputMap.has_action("swap_ship_medium") and Input.is_action_just_pressed("swap_ship_medium"):
			equip_size_and_tiers(1, _hull_tier, _engine_tier, _rcs_tier)
		elif InputMap.has_action("swap_ship_large") and Input.is_action_just_pressed("swap_ship_large"):
			equip_size_and_tiers(2, _hull_tier, _engine_tier, _rcs_tier)

		if InputMap.has_action("reset_fuel") and Input.is_action_just_pressed("reset_fuel"):
			fuel_mass = _initial_fuel_mass
			current_heat_kj = 0.0
			overburn_locked_out = false
			is_overburning = false

	if Input.is_action_just_pressed("toggle_rotational_stabilization"):
		rotational_stabilize = not rotational_stabilize

	# Support live drag-and-drop HullPart or override scene replacement in Remote Inspector
	var desired_scene: PackedScene = _get_desired_hull_scene()
	if desired_scene != _loaded_hull_scene:
		_rebuild_hull_visuals()

	_recalculate_mass_and_inertia()
	_recalculate_propulsion()

	var main_throttle := 0.0
	var overburn_active := false
	var desired_rcs_torque := 0.0
	var desired_rcs_linear_n := 0.0
	var desired_rcs_linear_dir_world := Vector2.ZERO

	if hold_at_start:
		linear_velocity = Vector2.ZERO
		angular_velocity = 0.0

	if not controls_locked:
		# Player boost (main thruster)
		var trigger := Input.get_action_strength("boost")
		if trigger > 0.05:
			main_throttle = maxf(main_throttle, trigger)

		# Dedicated Overburn bind: fires full throttle at 200% thrust / 400% fuel burn
		# while allowed by the thermal safety interlock.
		var overburn_pressed := (
			(InputMap.has_action("overburn") and Input.is_action_pressed("overburn"))
			or (InputMap.has_action(" overburn") and Input.is_action_pressed(" overburn"))
		)
		if overburn_pressed and not overburn_locked_out and fuel_mass > 0.0 and _current_max_thrust_n > 0.0:
			overburn_active = true
			main_throttle = 1.0

		# Stick aim (draws from shared fuel_mass)
		var stick := Vector2(
			Input.get_axis("look_left", "look_right"),
			Input.get_axis("look_up", "look_down")
		)
		var aiming: bool = stick.length() > 0.2

		if aiming:
			if fuel_mass > 0.0 and _current_rcs_torque > 0.0:
				var target_rot: float = stick.angle() + PI * 0.5
				var error: float = wrapf(target_rot - rotation, -PI, PI)
				var abs_error: float = abs(error)
				var abs_vel: float = abs(angular_velocity)

				# Inside angular deadband — stop residual spin without chasing stick micro-jitter
				if abs_error < aim_deadband_rad:
					if abs_vel < 0.08:
						angular_velocity = 0.0
					elif _inertia_si > 0.0 and delta > 0.0:
						var stop_torque: float = -angular_velocity * _inertia_si / delta
						desired_rcs_torque = clampf(stop_torque, -_current_rcs_torque, _current_rcs_torque)
				elif _inertia_si > 0.0 and delta > 0.0:
					# Time-optimal phase-plane speed profile with PWM fractional final-tick pulse
					# so RCS never overshoots past the target into a 2-frame limit cycle.
					var alpha: float = _current_rcs_torque / _inertia_si
					var alpha_brake: float = alpha / maxf(brake_multiplier, 1.0)
					var desired_speed: float = minf(sqrt(2.0 * alpha_brake * abs_error), abs_error / delta)
					var desired_vel: float = signf(error) * desired_speed
					var required_torque: float = (desired_vel - angular_velocity) * _inertia_si / delta
					desired_rcs_torque = clampf(required_torque, -_current_rcs_torque, _current_rcs_torque)

		# Rotational stabilize only when not aiming (draws from shared fuel_mass)
		elif rotational_stabilize:
			if fuel_mass > 0.0 and _current_rcs_torque > 0.0:
				if abs(angular_velocity) > 0.001 and delta > 0.0:
					# Fire full RCS torque when spinning fast, or a PWM fractional pulse on the
					# final tick to land directly on 0.0 rad/s without overshooting.
					var stop_torque: float = -angular_velocity * _inertia_si / delta
					desired_rcs_torque = clampf(stop_torque, -_current_rcs_torque, _current_rcs_torque)
				else:
					angular_velocity = 0.0

		# Momentum stabilize (uses main engine when nose is aligned opposite velocity;
		# otherwise falls back to symmetric linear RCS — both draw from shared fuel_mass)
		if Input.is_action_pressed("stabilize_momentum"):
			var speed: float = linear_velocity.length()
			if speed > 0.5 and delta > 0.0 and fuel_mass > 0.0:
				var vel_dir: Vector2 = linear_velocity.normalized()
				var forward: Vector2 = Vector2.UP.rotated(rotation)
				var alignment: float = forward.dot(-vel_dir)
				if alignment > 0.1 and _current_max_thrust_n > 0.0:
					main_throttle = maxf(main_throttle, clampf(alignment, 0.0, 1.0))
				elif _current_rcs_linear_force > 0.0:
					var speed_m_s: float = speed / maxf(pixels_per_meter, 0.001)
					var force_to_stop_n: float = speed_m_s * mass / delta
					desired_rcs_linear_n = force_to_stop_n
					if desired_rcs_linear_n > 0.0:
						desired_rcs_linear_dir_world = -vel_dir
			elif fuel_mass > 0.0:
				linear_velocity = Vector2.ZERO

	# Allocate per-nozzle RCS throttles (works for any N-nozzle geometry: 8-nozzle X-frame,
	# 6-nozzle legacy hulls, double-truss, or asymmetric damaged craft).
	var desired_rcs_linear_dir_local := (
		desired_rcs_linear_dir_world.rotated(-rotation).normalized()
		if desired_rcs_linear_dir_world.length_squared() > 0.0
		else Vector2.ZERO
	)
	var rcs_throttles := _allocate_rcs_nozzles(
		desired_rcs_torque, desired_rcs_linear_n, desired_rcs_linear_dir_local
	)

	# Compute combined propellant draw from shared fuel_mass for both main engine & RCS
	_current_applied_thrust_n = 0.0
	_current_fuel_burn_rate = 0.0
	_current_rcs_burn_rate = 0.0
	var active_throttle := 0.0
	var applied_rcs_throttles := PackedFloat32Array()
	applied_rcs_throttles.resize(_rcs_nozzles.size())

	var clamped_throttle := clampf(main_throttle, 0.0, 1.0)
	var ob_thrust_mult := (
		installed_thruster.overburn_thrust_multiplier
		if (overburn_active and installed_thruster != null)
		else (2.0 if overburn_active else 1.0)
	)
	var ob_fuel_mult := (
		installed_thruster.overburn_fuel_multiplier
		if (overburn_active and installed_thruster != null)
		else (4.0 if overburn_active else 1.0)
	)

	var base_main_thrust_n := (_current_max_thrust_n * clamped_throttle) if (clamped_throttle > 0.0 and _current_max_thrust_n > 0.0) else 0.0
	var desired_main_thrust_n := base_main_thrust_n * ob_thrust_mult

	var total_desired_rcs_thrust_n := 0.0
	if not _rcs_nozzles.is_empty():
		for t in rcs_throttles:
			total_desired_rcs_thrust_n += t * _current_rcs_nozzle_thrust_n
	else:
		var lever_arm := _get_rcs_lever_arm_m()
		var rotational_rcs_thrust_n := (absf(desired_rcs_torque) / lever_arm) if lever_arm > 0.0 else 0.0
		total_desired_rcs_thrust_n = rotational_rcs_thrust_n + minf(desired_rcs_linear_n, _current_rcs_linear_force)

	var main_isp := installed_thruster.specific_impulse if installed_thruster != null else 310.0
	var rcs_isp := installed_rcs.specific_impulse if installed_rcs != null else 260.0
	var main_exhaust_v := maxf(main_isp * STANDARD_GRAVITY, 0.01)
	var rcs_exhaust_v := maxf(rcs_isp * STANDARD_GRAVITY, 0.01)

	var desired_main_burn_rate := (base_main_thrust_n / main_exhaust_v) * ob_fuel_mult
	var desired_rcs_burn_rate := total_desired_rcs_thrust_n / rcs_exhaust_v
	var total_fuel_needed := (desired_main_burn_rate + desired_rcs_burn_rate) * delta

	var overburn_burn_fraction := 0.0
	if total_fuel_needed > 0.0 and fuel_mass > 0.0 and delta > 0.0:
		var burn_fraction := 1.0
		if total_fuel_needed > fuel_mass:
			burn_fraction = fuel_mass / total_fuel_needed
			fuel_mass = 0.0
		else:
			fuel_mass -= total_fuel_needed

		if desired_rcs_burn_rate > 0.0:
			_current_rcs_burn_rate = desired_rcs_burn_rate * burn_fraction
			if not _rcs_nozzles.is_empty():
				# Sum exact SI force (N) and SI torque (N*m) across every firing nozzle so
				# Godot's pixel-scaled apply_central_force never creates a 256x torque error.
				var total_rcs_force_local_n := Vector2.ZERO
				var total_rcs_torque_nm := 0.0
				for i in _rcs_nozzles.size():
					var t: float = rcs_throttles[i] * burn_fraction
					applied_rcs_throttles[i] = t
					if t <= 0.0:
						continue
					var nozzle: Dictionary = _rcs_nozzles[i]
					var f_n: float = _current_rcs_nozzle_thrust_n * t
					total_rcs_force_local_n += (nozzle["thrust_dir_local"] as Vector2) * f_n
					total_rcs_torque_nm += float(nozzle["unit_torque_per_n"]) * f_n

				var ppm_sq := pixels_per_meter * pixels_per_meter
				if total_rcs_force_local_n.length_squared() > 0.0:
					apply_central_force(total_rcs_force_local_n.rotated(rotation) * pixels_per_meter)
				if absf(total_rcs_torque_nm) > 0.0:
					apply_torque(total_rcs_torque_nm * ppm_sq)
			else:
				var ppm_sq := pixels_per_meter * pixels_per_meter
				if absf(desired_rcs_torque) > 0.0:
					apply_torque(desired_rcs_torque * burn_fraction * ppm_sq)
				if desired_rcs_linear_n > 0.0:
					var lin_n := minf(desired_rcs_linear_n, _current_rcs_linear_force) * burn_fraction
					apply_central_force(desired_rcs_linear_dir_world * lin_n * pixels_per_meter)

		if desired_main_burn_rate > 0.0:
			_current_applied_thrust_n = desired_main_thrust_n * burn_fraction
			_current_fuel_burn_rate = desired_main_burn_rate * burn_fraction
			active_throttle = clamped_throttle * burn_fraction
			if overburn_active:
				overburn_burn_fraction = burn_fraction
			var forward := Vector2.UP.rotated(rotation)
			apply_central_force(forward * _current_applied_thrust_n * pixels_per_meter)

		# Immediately reflect burned fuel in mass & inertia for this frame's telemetry
		_recalculate_mass_and_inertia()

	# Continuous Stefan-Boltzmann radiative cooling + Overburn heat input
	is_overburning = overburn_active and overburn_burn_fraction > 0.01
	var engine_ob_heat_kw := installed_thruster.overburn_heat_kw if installed_thruster != null else 44.0
	_current_heating_kw = engine_ob_heat_kw * overburn_burn_fraction if is_overburning else 0.0
	_current_cooling_kw = _compute_radiative_cooling_kw(get_heat_fraction())
	current_heat_kj = clampf(current_heat_kj + (_current_heating_kw - _current_cooling_kw) * delta, 0.0, heat_capacity_kj)

	# In-universe thermal safety interlock: cuts off Overburn at 100% until cooled below recovery threshold
	if current_heat_kj >= heat_capacity_kj - 0.001:
		overburn_locked_out = true
	elif overburn_locked_out and get_heat_fraction() <= overheat_recovery_fraction:
		overburn_locked_out = false

	_update_exhaust_visual(active_throttle, is_overburning)
	_update_rcs_visuals(applied_rcs_throttles, delta)
	_update_telemetry()


func _allocate_rcs_nozzles(
	desired_torque_nm: float, desired_linear_n: float, linear_dir_local: Vector2
) -> PackedFloat32Array:
	var count := _rcs_nozzles.size()
	var throttles := PackedFloat32Array()
	throttles.resize(count)
	if count == 0 or _current_rcs_nozzle_thrust_n <= 0.0:
		return throttles

	# 1) Rotational allocation (pure CW or CCW spin across tangential nozzles)
	if desired_torque_nm > 0.0 and _max_rcs_cw_torque > 0.0:
		var rot_frac := clampf(desired_torque_nm / _max_rcs_cw_torque, 0.0, 1.0)
		for i in count:
			var nozzle: Dictionary = _rcs_nozzles[i]
			if nozzle["is_rotational"] and float(nozzle["unit_torque_per_n"]) > 0.0:
				throttles[i] = rot_frac
	elif desired_torque_nm < 0.0 and _max_rcs_ccw_torque > 0.0:
		var rot_frac := clampf(-desired_torque_nm / _max_rcs_ccw_torque, 0.0, 1.0)
		for i in count:
			var nozzle: Dictionary = _rcs_nozzles[i]
			if nozzle["is_rotational"] and float(nozzle["unit_torque_per_n"]) < 0.0:
				throttles[i] = rot_frac

	# 2) Torque-balanced linear allocation across all 360 deg directions
	if desired_linear_n > 0.0 and linear_dir_local.length_squared() > 0.0001:
		var weights := PackedFloat32Array()
		weights.resize(count)
		var tau_pos := 0.0
		var tau_neg := 0.0

		for i in count:
			var nozzle: Dictionary = _rcs_nozzles[i]
			var align: float = (nozzle["thrust_dir_local"] as Vector2).dot(linear_dir_local)
			if align > 0.1:
				weights[i] = align
				var u_tau: float = nozzle["unit_torque_per_n"]
				if u_tau > 0.001:
					tau_pos += align * u_tau
				elif u_tau < -0.001:
					tau_neg += align * (-u_tau)

		# Balance CW vs CCW torque contributions so linear braking induces zero net spin
		if tau_pos > 0.0001 and tau_neg > 0.0001:
			if tau_pos > tau_neg:
				var cw_scale := tau_neg / tau_pos
				for i in count:
					if float(_rcs_nozzles[i]["unit_torque_per_n"]) > 0.001:
						weights[i] *= cw_scale
			elif tau_neg > tau_pos:
				var ccw_scale := tau_pos / tau_neg
				for i in count:
					if float(_rcs_nozzles[i]["unit_torque_per_n"]) < -0.001:
						weights[i] *= ccw_scale
		elif tau_pos > 0.0001 or tau_neg > 0.0001:
			# Only one rotational sign available; keep only zero-torque nozzles if any exist
			for i in count:
				if absf(float(_rcs_nozzles[i]["unit_torque_per_n"])) > 0.001:
					weights[i] = 0.0

		var achieved_n := 0.0
		var max_w := 0.0
		for i in count:
			var w: float = weights[i]
			if w > 0.0:
				var align: float = ( _rcs_nozzles[i]["thrust_dir_local"] as Vector2 ).dot(linear_dir_local)
				achieved_n += w * _current_rcs_nozzle_thrust_n * align
				max_w = maxf(max_w, w)

		if achieved_n > 0.0001 and max_w > 0.0001:
			var lin_scale := minf(desired_linear_n / achieved_n, 1.0 / max_w)
			for i in count:
				if weights[i] > 0.0:
					throttles[i] = clampf(throttles[i] + weights[i] * lin_scale, 0.0, 1.0)

	return throttles


func _update_exhaust_visual(throttle: float, overburning: bool = false) -> void:
	if _exhaust_sprite == null:
		return
	_exhaust_sprite.visible = throttle > 0.01
	if _exhaust_sprite.visible:
		var width_mult := 1.28 if overburning else 1.0
		var len_mult := lerpf(0.35, 1.25, throttle) * (1.55 if overburning else 1.0)
		_exhaust_sprite.scale = Vector2(
			_exhaust_base_scale.x * width_mult,
			_exhaust_base_scale.y * len_mult
		)
		_exhaust_sprite.modulate = Color(1.35, 1.45, 1.65, 1.0) if overburning else Color.WHITE


func _step_rcs_valve(nozzle: Dictionary, desired_on: bool, delta: float) -> bool:
	var is_on: bool = nozzle["valve_on"]
	var timer: float = maxf(float(nozzle["valve_timer"]) - delta, 0.0)

	if is_on:
		# Stay open for at least rcs_min_on_time, and remain open continuously while commanded.
		if not desired_on and timer <= 0.0:
			is_on = false
			timer = maxf(rcs_min_off_time, 0.0)
	else:
		# Wait for rcs_min_off_time cooldown before allowing the valve to crack open again.
		if desired_on and timer <= 0.0:
			is_on = true
			timer = maxf(rcs_min_on_time, 0.0)

	nozzle["valve_on"] = is_on
	nozzle["valve_timer"] = timer
	return is_on


# RCS thrusters are strictly boolean (on/off, never scaled) with minimum valve
# pulse & cooldown durations so they never strobe at the 60 Hz physics tick rate.
func _update_rcs_visuals(applied_throttles: PackedFloat32Array, delta: float) -> void:
	var threshold := maxf(rcs_visual_torque_threshold, 0.0)
	for i in _rcs_nozzles.size():
		var nozzle: Dictionary = _rcs_nozzles[i]
		var nozzle_node: Node2D = nozzle["node"]
		var desired_on := i < applied_throttles.size() and applied_throttles[i] > threshold
		var is_on := _step_rcs_valve(nozzle, desired_on, delta)
		if is_instance_valid(nozzle_node):
			nozzle_node.visible = is_on


func _update_telemetry() -> void:
	if _telemetry_label == null:
		return

	var fuel_pct := (fuel_mass / _initial_fuel_mass * 100.0) if _initial_fuel_mass > 0.0 else 0.0
	var max_accel_m_s2 := _current_max_thrust_n / mass
	var max_accel_g := max_accel_m_s2 / STANDARD_GRAVITY
	var max_turn_accel := _current_rcs_torque / _inertia_si if _inertia_si > 0.0 else 0.0
	var active_accel_m_s2 := _current_applied_thrust_n / mass
	var active_accel_g := active_accel_m_s2 / STANDARD_GRAVITY
	var speed_m_s := linear_velocity.length() / maxf(pixels_per_meter, 0.001)

	var hull_label := (
		"[T%d] %s" % [installed_hull.tech_tier, installed_hull.part_name]
		if installed_hull != null
		else "None"
	)
	var eng_label := (
		"[T%d] %s (%.0fs)" % [installed_thruster.tech_tier, installed_thruster.part_name, installed_thruster.specific_impulse]
		if installed_thruster != null
		else "None"
	)
	var rcs_label := (
		"[T%d] %s (%.0fs)" % [installed_rcs.tech_tier, installed_rcs.part_name, installed_rcs.specific_impulse]
		if installed_rcs != null
		else "None"
	)
	var warning_line := ""
	if not _size_warnings.is_empty():
		warning_line = "\n[!] SIZE MISMATCH: %s" % ", ".join(_size_warnings)

	var track_line := ""
	if _track != null and "active_seed" in _track:
		var status: String = _track.save_status_text if "save_status_text" in _track else ""
		var suffix := (" %s" % status) if not status.is_empty() else ""
		var type_str: String = _track.get_track_type_label() if _track.has_method("get_track_type_label") else ""
		var type_prefix := ("[%s] " % type_str) if not type_str.is_empty() else ""
		track_line = "\nTRACK: %s#%d%s" % [type_prefix, int(_track.active_seed), suffix]

	var heat_pct := get_heat_fraction() * 100.0
	var hull_temp_k := get_hull_temp_k()
	var heat_tag := ""
	if overburn_locked_out:
		heat_tag = " [OVERHEAT LOCKOUT]"
	elif is_overburning:
		heat_tag = " [OVERBURN]"

	_telemetry_label.text = (
		"SHIP: %s\n"
		+ "HULL: %s\n"
		+ "ENG: %s | RCS: %s\n"
		+ "FUEL: %.1f / %.1f kg (%.0f%%)\n"
		+ "HEAT: %.0f%% (%.0f K) | RAD: %.1f/%.0f kW%s\n"
		+ "MASS: %.1f kg (Dry: %.1f kg)\n"
		+ "INERTIA: %.1f kg·m² | TURN: %.1f rad/s²\n"
		+ "RCS (%d noz): %.2f kN/noz | %.2f kN·m\n"
		+ "MAX THRUST: %.2f kN (%.2f G max)\n"
		+ "BURN: %.2f main / %.2f rcs kg/s | ACCEL: %.2f G\n"
		+ "SPEED: %.1f m/s%s%s"
	) % [
		_active_ship_name,
		hull_label,
		eng_label,
		rcs_label,
		fuel_mass,
		_initial_fuel_mass,
		fuel_pct,
		heat_pct,
		hull_temp_k,
		_current_cooling_kw,
		_current_max_cooling_kw,
		heat_tag,
		mass,
		_dry_mass,
		_inertia_si,
		max_turn_accel,
		_rcs_nozzles.size(),
		_current_rcs_nozzle_thrust_n / 1000.0,
		_current_rcs_torque / 1000.0,
		_current_max_thrust_n / 1000.0,
		max_accel_g,
		_current_fuel_burn_rate,
		_current_rcs_burn_rate,
		active_accel_g,
		speed_m_s,
		track_line,
		warning_line,
	]
