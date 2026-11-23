extends RigidBody2D

# Standard Earth gravity (m/s^2), used to convert Specific Impulse (I_sp in seconds)
# into effective exhaust velocity: v_e = I_sp * STANDARD_GRAVITY (m/s).
const STANDARD_GRAVITY := 9.80665

# Safety floors so Godot's RigidBody2D physics never divides by zero if every
# part mass or radius is manually set to 0 in the Inspector.
const MIN_TOTAL_MASS := 0.01
const MIN_INERTIA := 0.01

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
## Baseline thrust per individual RCS nozzle (N) at reference_rcs_mass (1.5 kN starter jets).
@export var reference_rcs_nozzle_thrust_n: float = 1500.0
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

var rotational_stabilize := true

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
var _current_max_thrust_n: float = 0.0
var _current_applied_thrust_n: float = 0.0
var _current_fuel_burn_rate: float = 0.0
var _current_rcs_burn_rate: float = 0.0
var _current_rcs_nozzle_thrust_n: float = 0.0
var _current_rcs_torque: float = 0.0
var _current_rcs_linear_force: float = 0.0
var _size_warnings: PackedStringArray = PackedStringArray()

var _active_hull_node: Node2D = null
var _active_collision: Node2D = null
var _exhaust_sprite: Sprite2D = null
var _exhaust_base_scale: Vector2 = Vector2.ONE

var _rcs_bow_port: Node2D = null
var _rcs_bow_starboard: Node2D = null
var _rcs_stern_port: Node2D = null
var _rcs_stern_starboard: Node2D = null
var _rcs_retro_port: Node2D = null
var _rcs_retro_starboard: Node2D = null

# Per-nozzle valve state: { "on": bool, "timer": float }
var _rcs_valve_state: Dictionary = {
	"bow_port": {"on": false, "timer": 0.0},
	"bow_starboard": {"on": false, "timer": 0.0},
	"stern_port": {"on": false, "timer": 0.0},
	"stern_starboard": {"on": false, "timer": 0.0},
	"retro_port": {"on": false, "timer": 0.0},
	"retro_starboard": {"on": false, "timer": 0.0},
}

@onready var _telemetry_label: Label = get_node_or_null("TelemetryLayer/TelemetryPanel/TelemetryLabel")
@onready var _track: Node = get_parent().get_node_or_null("Track") if get_parent() != null else null


func _ready() -> void:
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
	if turn_angle > aim_deadband_rad and _current_rcs_torque > 0.0 and inertia > 0.0 and fuel_mass > 0.0:
		var alpha := _current_rcs_torque / inertia
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
		fuel_mass = _initial_fuel_mass
		_recalculate_mass_and_inertia()
	_update_telemetry()


func _rebuild_hull_visuals() -> void:
	# Immediately detach and free previous hull and reparented collision shape
	if _active_collision != null:
		remove_child(_active_collision)
		_active_collision.queue_free()
		_active_collision = null

	if _active_hull_node != null:
		remove_child(_active_hull_node)
		_active_hull_node.queue_free()
		_active_hull_node = null

	_loaded_hull_scene = installed_hull.hull_scene if installed_hull != null else null
	_exhaust_sprite = null
	_exhaust_base_scale = Vector2.ONE
	_rcs_bow_port = null
	_rcs_bow_starboard = null
	_rcs_stern_port = null
	_rcs_stern_starboard = null
	_rcs_retro_port = null
	_rcs_retro_starboard = null

	if _loaded_hull_scene != null:
		_active_hull_node = _loaded_hull_scene.instantiate() as Node2D
		add_child(_active_hull_node)

		# Reparent HullCollision directly under RigidBody2D so Godot physics uses it
		var hull_col: Node2D = _active_hull_node.get_node_or_null("HullCollision") as Node2D
		if hull_col == null:
			for child in _active_hull_node.get_children():
				if child is CollisionShape2D or child is CollisionPolygon2D:
					hull_col = child
					break
		if hull_col != null:
			var col_transform := hull_col.transform
			_active_hull_node.remove_child(hull_col)
			hull_col.owner = null
			add_child(hull_col)
			hull_col.transform = col_transform
			_active_collision = hull_col

		_exhaust_sprite = _active_hull_node.get_node_or_null("ExhaustSprite") as Sprite2D
		if _exhaust_sprite != null:
			_exhaust_base_scale = _exhaust_sprite.scale

		_rcs_bow_port = _active_hull_node.get_node_or_null("BowPort") as Node2D
		_rcs_bow_starboard = _active_hull_node.get_node_or_null("BowStarboard") as Node2D
		_rcs_stern_port = _active_hull_node.get_node_or_null("SternPort") as Node2D
		_rcs_stern_starboard = _active_hull_node.get_node_or_null("SternStarboard") as Node2D
		_rcs_retro_port = _active_hull_node.get_node_or_null("RetroPort") as Node2D
		_rcs_retro_starboard = _active_hull_node.get_node_or_null("RetroStarboard") as Node2D

	for key in _rcs_valve_state.keys():
		_rcs_valve_state[key]["on"] = false
		_rcs_valve_state[key]["timer"] = 0.0

	_update_exhaust_visual(0.0)
	_update_rcs_visuals(0.0, Vector2.ZERO, 0.0)


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
	inertia = maxf(total_inertia, MIN_INERTIA)


func _recalculate_propulsion() -> void:
	if installed_thruster != null:
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

	# Symmetric RCS pairs equidistant (hull.rcs_lever_arm_m) from center of mass:
	# - Rotation uses 2 opposing nozzles -> tau = 2 * F_nozzle * L
	# - Linear braking uses 2 aligned nozzles -> F_linear = 2 * F_nozzle
	var lever_arm := _get_rcs_lever_arm_m()
	_current_rcs_torque = 2.0 * _current_rcs_nozzle_thrust_n * lever_arm
	_current_rcs_linear_force = 2.0 * _current_rcs_nozzle_thrust_n


func _physics_process(delta: float) -> void:
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

	if Input.is_action_just_pressed("reset_fuel"):
		fuel_mass = _initial_fuel_mass

	if Input.is_action_just_pressed("toggle_rotational_stabilization"):
		rotational_stabilize = not rotational_stabilize

	# Support live drag-and-drop HullPart replacement in Remote Inspector
	var desired_scene: PackedScene = installed_hull.hull_scene if installed_hull != null else null
	if desired_scene != _loaded_hull_scene:
		_rebuild_hull_visuals()

	_recalculate_mass_and_inertia()
	_recalculate_propulsion()

	var main_throttle := 0.0
	var desired_rcs_torque := 0.0
	var desired_rcs_linear_n := 0.0
	var desired_rcs_linear_dir_world := Vector2.ZERO

	# Player boost (main thruster)
	var trigger := Input.get_action_strength("boost")
	if trigger > 0.05:
		main_throttle = maxf(main_throttle, trigger)

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
				elif inertia > 0.0 and delta > 0.0:
					var stop_torque: float = -angular_velocity * inertia / delta
					desired_rcs_torque = clampf(stop_torque, -_current_rcs_torque, _current_rcs_torque)
			elif inertia > 0.0 and delta > 0.0:
				# Time-optimal phase-plane speed profile with PWM fractional final-tick pulse
				# so RCS never overshoots past the target into a 2-frame limit cycle.
				var alpha: float = _current_rcs_torque / inertia
				var alpha_brake: float = alpha / maxf(brake_multiplier, 1.0)
				var desired_speed: float = minf(sqrt(2.0 * alpha_brake * abs_error), abs_error / delta)
				var desired_vel: float = signf(error) * desired_speed
				var required_torque: float = (desired_vel - angular_velocity) * inertia / delta
				desired_rcs_torque = clampf(required_torque, -_current_rcs_torque, _current_rcs_torque)

	# Rotational stabilize only when not aiming (draws from shared fuel_mass)
	elif rotational_stabilize:
		if fuel_mass > 0.0 and _current_rcs_torque > 0.0:
			if abs(angular_velocity) > 0.001 and delta > 0.0:
				# Fire full RCS torque when spinning fast, or a PWM fractional pulse on the
				# final tick to land directly on 0.0 rad/s without overshooting.
				var stop_torque: float = -angular_velocity * inertia / delta
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
				desired_rcs_linear_n = minf(_current_rcs_linear_force, force_to_stop_n)
				if desired_rcs_linear_n > 0.0:
					desired_rcs_linear_dir_world = -vel_dir
		elif fuel_mass > 0.0:
			linear_velocity = Vector2.ZERO

	# Compute combined propellant draw from shared fuel_mass for both main engine & RCS
	var applied_rcs_torque := 0.0
	var applied_rcs_linear_dir_world := Vector2.ZERO
	_current_applied_thrust_n = 0.0
	_current_fuel_burn_rate = 0.0
	_current_rcs_burn_rate = 0.0
	var active_throttle := 0.0

	var clamped_throttle := clampf(main_throttle, 0.0, 1.0)
	var desired_main_thrust_n := (_current_max_thrust_n * clamped_throttle) if (clamped_throttle > 0.0 and _current_max_thrust_n > 0.0) else 0.0
	var lever_arm := _get_rcs_lever_arm_m()
	var rotational_rcs_thrust_n := (absf(desired_rcs_torque) / lever_arm) if lever_arm > 0.0 else 0.0
	var total_desired_rcs_thrust_n := rotational_rcs_thrust_n + desired_rcs_linear_n

	var main_isp := installed_thruster.specific_impulse if installed_thruster != null else 310.0
	var rcs_isp := installed_rcs.specific_impulse if installed_rcs != null else 260.0
	var main_exhaust_v := maxf(main_isp * STANDARD_GRAVITY, 0.01)
	var rcs_exhaust_v := maxf(rcs_isp * STANDARD_GRAVITY, 0.01)

	var desired_main_burn_rate := desired_main_thrust_n / main_exhaust_v
	var desired_rcs_burn_rate := total_desired_rcs_thrust_n / rcs_exhaust_v
	var total_fuel_needed := (desired_main_burn_rate + desired_rcs_burn_rate) * delta

	if total_fuel_needed > 0.0 and fuel_mass > 0.0 and delta > 0.0:
		var burn_fraction := 1.0
		if total_fuel_needed > fuel_mass:
			burn_fraction = fuel_mass / total_fuel_needed
			fuel_mass = 0.0
		else:
			fuel_mass -= total_fuel_needed

		if desired_rcs_burn_rate > 0.0:
			_current_rcs_burn_rate = desired_rcs_burn_rate * burn_fraction
			if absf(desired_rcs_torque) > 0.0:
				applied_rcs_torque = desired_rcs_torque * burn_fraction
				apply_torque(applied_rcs_torque)
			if desired_rcs_linear_n > 0.0:
				applied_rcs_linear_dir_world = desired_rcs_linear_dir_world
				apply_central_force(applied_rcs_linear_dir_world * (desired_rcs_linear_n * burn_fraction) * pixels_per_meter)

		if desired_main_burn_rate > 0.0:
			_current_applied_thrust_n = desired_main_thrust_n * burn_fraction
			_current_fuel_burn_rate = desired_main_burn_rate * burn_fraction
			active_throttle = clamped_throttle * burn_fraction
			var forward := Vector2.UP.rotated(rotation)
			apply_central_force(forward * _current_applied_thrust_n * pixels_per_meter)

		# Immediately reflect burned fuel in mass & inertia for this frame's telemetry
		_recalculate_mass_and_inertia()

	_update_exhaust_visual(active_throttle)
	_update_rcs_visuals(applied_rcs_torque, applied_rcs_linear_dir_world, delta)
	_update_telemetry()


func _update_exhaust_visual(throttle: float) -> void:
	if _exhaust_sprite == null:
		return
	_exhaust_sprite.visible = throttle > 0.01
	if _exhaust_sprite.visible:
		_exhaust_sprite.scale = Vector2(
			_exhaust_base_scale.x,
			_exhaust_base_scale.y * lerpf(0.35, 1.25, throttle)
		)


func _step_rcs_valve(nozzle_key: String, desired_on: bool, delta: float) -> bool:
	var state: Dictionary = _rcs_valve_state[nozzle_key]
	var is_on: bool = state["on"]
	var timer: float = maxf(state["timer"] - delta, 0.0)

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

	state["on"] = is_on
	state["timer"] = timer
	return is_on


# RCS thrusters are strictly boolean (on/off, never scaled) with minimum valve
# pulse & cooldown durations so they never strobe at the 60 Hz physics tick rate.
func _update_rcs_visuals(torque_applied: float, linear_dir_world: Vector2, delta: float) -> void:
	var torque_threshold := _current_rcs_torque * maxf(rcs_visual_torque_threshold, 0.0)
	var spin_cw := _current_rcs_torque > 0.0 and torque_applied > torque_threshold
	var spin_ccw := _current_rcs_torque > 0.0 and torque_applied < -torque_threshold

	var push_starboard := false
	var push_port := false
	var push_retro := false

	if linear_dir_world != Vector2.ZERO:
		# Convert desired push direction into ship-local space:
		# +X = Starboard (right), -X = Port (left), +Y = Aft (retrograde brake)
		var local_push := linear_dir_world.rotated(-rotation)
		push_starboard = local_push.x > 0.25
		push_port = local_push.x < -0.25
		push_retro = local_push.y > 0.25

	var bow_port_on := _step_rcs_valve("bow_port", spin_cw or push_starboard, delta)
	var bow_starboard_on := _step_rcs_valve("bow_starboard", spin_ccw or push_port, delta)
	var stern_port_on := _step_rcs_valve("stern_port", spin_ccw or push_starboard, delta)
	var stern_starboard_on := _step_rcs_valve("stern_starboard", spin_cw or push_port, delta)
	var retro_port_on := _step_rcs_valve("retro_port", push_retro, delta)
	var retro_starboard_on := _step_rcs_valve("retro_starboard", push_retro, delta)

	if _rcs_bow_port:
		_rcs_bow_port.visible = bow_port_on
	if _rcs_bow_starboard:
		_rcs_bow_starboard.visible = bow_starboard_on
	if _rcs_stern_port:
		_rcs_stern_port.visible = stern_port_on
	if _rcs_stern_starboard:
		_rcs_stern_starboard.visible = stern_starboard_on
	if _rcs_retro_port:
		_rcs_retro_port.visible = retro_port_on
	if _rcs_retro_starboard:
		_rcs_retro_starboard.visible = retro_starboard_on


func _update_telemetry() -> void:
	if _telemetry_label == null:
		return

	var fuel_pct := (fuel_mass / _initial_fuel_mass * 100.0) if _initial_fuel_mass > 0.0 else 0.0
	var max_accel_m_s2 := _current_max_thrust_n / mass
	var max_accel_g := max_accel_m_s2 / STANDARD_GRAVITY
	var max_turn_accel := _current_rcs_torque / inertia if inertia > 0.0 else 0.0
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

	_telemetry_label.text = (
		"SHIP: %s\n"
		+ "HULL: %s\n"
		+ "ENG: %s | RCS: %s\n"
		+ "FUEL: %.1f / %.1f kg (%.0f%%)\n"
		+ "MASS: %.1f kg (Dry: %.1f kg)\n"
		+ "INERTIA: %.1f kg·m² | TURN: %.1f rad/s²\n"
		+ "RCS: %.2f kN/noz × %.1fm = %.1f kN·m\n"
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
		mass,
		_dry_mass,
		inertia,
		max_turn_accel,
		_current_rcs_nozzle_thrust_n / 1000.0,
		_get_rcs_lever_arm_m(),
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
