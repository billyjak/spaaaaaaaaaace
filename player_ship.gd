extends RigidBody2D

# Standard Earth gravity (m/s^2), used to convert Specific Impulse (I_sp in seconds)
# into effective exhaust velocity: v_e = I_sp * STANDARD_GRAVITY (m/s).
const STANDARD_GRAVITY := 9.80665

# Safety floors so Godot's RigidBody2D physics never divides by zero if every
# part mass or radius is manually set to 0 in the Inspector.
const MIN_TOTAL_MASS := 0.01
const MIN_INERTIA := 0.01

# ---------------------------------------------------------------------------
# Ship Presets (Small / Medium / Large)
# Each ShipData .tres defines its hull scene (sprite, exhaust, 6 RCS nozzles,
# and HullCollision) alongside its SI part masses, inertia radius, and RCS.
# ---------------------------------------------------------------------------
@export_group("Ship Presets")
@export var ship_small: ShipData = preload("res://ship_small.tres")
@export var ship_medium: ShipData = preload("res://ship_medium.tres")
@export var ship_large: ShipData = preload("res://ship_large.tres")
@export_enum("Small", "Medium", "Large") var starting_ship: int = 1

# ---------------------------------------------------------------------------
# Ship Part Masses (kg)
# Modeled after a ~4m unmanned bipropellant racing drone (D-10.png at 0.35x
# scale is ~39 px long -> 3.9 m at 10 px/m).
# Dry mass = 200 kg, Fuel = 200 kg -> 50% propellant fraction (400 kg wet),
# which is realistic for high-delta-v small orbital spacecraft and makes the
# ship noticeably twice as quick to accelerate and turn as the tank empties.
# ---------------------------------------------------------------------------
@export_group("Ship Parts (Mass in kg)")
## Main rocket engine mass (kg). ~35 kg is comparable to a Rocket Lab Rutherford engine.
@export var thruster_mass: float = 35.0
## Propellant mass (kg). Consumed while the main thruster fires; drops to 0.0 when empty.
@export var fuel_mass: float = 200.0
## Placeholder part 3 (kg) - e.g., hull / airframe / propellant tank structure.
@export var ship_part_3_mass: float = 120.0
## Placeholder part 4 (kg) - e.g., avionics, battery/power, and RCS hardware.
@export var ship_part_4_mass: float = 45.0
## Placeholder part 5 (kg) - free slot for future modules (weapons, shields, cargo).
@export var ship_part_5_mass: float = 0.0

# ---------------------------------------------------------------------------
# Thruster & Fuel Consumption Physics (SI Units)
# Square-cube scaling: engine mass scales with volume (L^3), while nozzle
# throat cross-sectional area & thrust scale with area (L^2), giving:
#   max_thrust = reference_thrust * (thruster_mass / reference_thruster_mass)^(2/3)
#
# Fuel flow rate is linear with applied thrust:
#   mass_flow_rate (kg/s) = applied_thrust (N) / (specific_impulse * g0)
# Because mass drops in real time as fuel burns, the exponential Tsiolkovsky
# rocket equation emerges naturally from the physics engine.
# ---------------------------------------------------------------------------
@export_group("Thruster & Fuel Physics (SI)")
## Baseline engine mass (kg) corresponding to reference_thrust_newtons.
@export var reference_thruster_mass: float = 35.0
## Baseline thrust (N) at reference_thruster_mass. 25,000 N (25 kN) matches a
## Rutherford-class engine: ~6.4 G (62.5 m/s^2) wet -> ~12.7 G (125 m/s^2) dry.
@export var reference_thrust_newtons: float = 25000.0
## Square-cube scaling exponent (2/3 = 0.6667 -> L^2 area / L^3 volume).
@export var thrust_mass_exponent: float = 2.0 / 3.0
## Specific impulse I_sp (seconds). Real methalox / hypergolic vacuum engines
## achieve ~280-330 s (310 s -> v_e = 3,040 m/s, burning ~8.2 kg/s at 25 kN,
## ~24.3 s of continuous full burn or ~1 min of typical racing).
@export var specific_impulse: float = 310.0

# ---------------------------------------------------------------------------
# Inertia & World Scale
# ---------------------------------------------------------------------------
@export_group("Inertia & World Scale")
## Uniform radius of gyration (m) applied to all parts for now (I = sum(m * r^2)).
## On a ~3.9 m craft, 1.5 m yields 900 kg*m^2 wet -> 450 kg*m^2 dry.
@export var inertia_radius_m: float = 1.5
## World scale connecting SI meters to Godot 2D pixels.
## At 10 px/m: 39 px ship = 3.9 m, ~370 px track = 37 m, 62.5 m/s^2 = 625 px/s^2.
@export var pixels_per_meter: float = 10.0

# ---------------------------------------------------------------------------
# RCS Controls (Infinite Propellant for Now)
# Note: Real orbital satellites turn slowly with ~10-100 N*m; an unmanned
# high-G racing drone uses large bipropellant RCS quads (~45,000 N*m) to flip
# 180 degrees in ~0.6 s wet (~0.4 s dry).
# ---------------------------------------------------------------------------
@export_group("RCS (Infinite for Now)")
## Rotational RCS torque (N*m). Radians are dimensionless, so no px/m conversion needed.
@export var rcs_torque: float = 45000.0
## Omnidirectional linear RCS braking force (N). 6,000 N = 15 m/s^2 wet -> 30 m/s^2 dry.
@export var rcs_linear_force: float = 6000.0
## Safety margin multiplier on angular stopping distance when stick-aiming.
@export var brake_multiplier: float = 3.0
## Minimum time (s) an RCS nozzle stays ON once fired (Space Shuttle PRCS min pulse = 0.08 s).
@export var rcs_min_on_time: float = 0.08
## Minimum cooldown (s) after shutting OFF before an RCS nozzle can fire again (~6 Hz max cycle).
@export var rcs_min_off_time: float = 0.08
## Fraction of rcs_torque required to trigger a visual puff (filters analog stick micro-jitter).
@export var rcs_visual_torque_threshold: float = 0.05

var rotational_stabilize := true

var _active_ship_name: String = "Custom"
var _initial_fuel_mass: float = 0.0
var _dry_mass: float = 0.0
var _current_max_thrust_n: float = 0.0
var _current_applied_thrust_n: float = 0.0
var _current_fuel_burn_rate: float = 0.0

var _active_hull: Node2D = null
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


func _ready() -> void:
	match starting_ship:
		0:
			equip_ship(ship_small)
		1:
			equip_ship(ship_medium)
		2:
			equip_ship(ship_large)
		_:
			equip_ship(ship_medium)


func equip_ship(data: ShipData) -> void:
	if data == null:
		return

	# Immediately detach and free previous hull and reparented collision shape
	if _active_collision != null:
		remove_child(_active_collision)
		_active_collision.queue_free()
		_active_collision = null

	if _active_hull != null:
		remove_child(_active_hull)
		_active_hull.queue_free()
		_active_hull = null

	_exhaust_sprite = null
	_exhaust_base_scale = Vector2.ONE
	_rcs_bow_port = null
	_rcs_bow_starboard = null
	_rcs_stern_port = null
	_rcs_stern_starboard = null
	_rcs_retro_port = null
	_rcs_retro_starboard = null

	# Apply ship preset stats onto instance variables (still editable in Remote Inspector)
	_active_ship_name = data.ship_name
	thruster_mass = data.thruster_mass
	fuel_mass = data.fuel_mass
	ship_part_3_mass = data.ship_part_3_mass
	ship_part_4_mass = data.ship_part_4_mass
	ship_part_5_mass = data.ship_part_5_mass
	inertia_radius_m = data.inertia_radius_m
	rcs_torque = data.rcs_torque
	rcs_linear_force = data.rcs_linear_force
	_initial_fuel_mass = maxf(fuel_mass, 0.0)

	# Instantiate new hull scene and wire up visuals + collider
	if data.hull_scene != null:
		_active_hull = data.hull_scene.instantiate() as Node2D
		add_child(_active_hull)

		# Reparent HullCollision directly under RigidBody2D so Godot physics uses it
		var hull_col: Node2D = _active_hull.get_node_or_null("HullCollision") as Node2D
		if hull_col == null:
			for child in _active_hull.get_children():
				if child is CollisionShape2D or child is CollisionPolygon2D:
					hull_col = child
					break
		if hull_col != null:
			var col_transform := hull_col.transform
			_active_hull.remove_child(hull_col)
			hull_col.owner = null
			add_child(hull_col)
			hull_col.transform = col_transform
			_active_collision = hull_col

		_exhaust_sprite = _active_hull.get_node_or_null("ExhaustSprite") as Sprite2D
		if _exhaust_sprite != null:
			_exhaust_base_scale = _exhaust_sprite.scale

		_rcs_bow_port = _active_hull.get_node_or_null("BowPort") as Node2D
		_rcs_bow_starboard = _active_hull.get_node_or_null("BowStarboard") as Node2D
		_rcs_stern_port = _active_hull.get_node_or_null("SternPort") as Node2D
		_rcs_stern_starboard = _active_hull.get_node_or_null("SternStarboard") as Node2D
		_rcs_retro_port = _active_hull.get_node_or_null("RetroPort") as Node2D
		_rcs_retro_starboard = _active_hull.get_node_or_null("RetroStarboard") as Node2D

	for key in _rcs_valve_state.keys():
		_rcs_valve_state[key]["on"] = false
		_rcs_valve_state[key]["timer"] = 0.0

	_recalculate_mass_and_inertia()
	_current_max_thrust_n = _calculate_max_thrust_newtons()
	_current_applied_thrust_n = 0.0
	_current_fuel_burn_rate = 0.0
	_update_exhaust_visual(0.0)
	_update_rcs_visuals(0.0, Vector2.ZERO, 0.0)
	_update_telemetry()


# Returns every part's mass and radial distance from the center of mass.
# Currently all parts share `inertia_radius_m`, making it easy to swap in
# per-part positions or pixel-based CoM calculations later.
func _get_ship_parts() -> Array[Dictionary]:
	return [
		{"name": "thruster", "mass": maxf(thruster_mass, 0.0), "radius_m": inertia_radius_m},
		{"name": "fuel", "mass": maxf(fuel_mass, 0.0), "radius_m": inertia_radius_m},
		{"name": "ship_part_3", "mass": maxf(ship_part_3_mass, 0.0), "radius_m": inertia_radius_m},
		{"name": "ship_part_4", "mass": maxf(ship_part_4_mass, 0.0), "radius_m": inertia_radius_m},
		{"name": "ship_part_5", "mass": maxf(ship_part_5_mass, 0.0), "radius_m": inertia_radius_m},
	]


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


func _calculate_max_thrust_newtons() -> float:
	if thruster_mass <= 0.0 or reference_thruster_mass <= 0.0 or reference_thrust_newtons <= 0.0:
		return 0.0
	var mass_ratio := thruster_mass / reference_thruster_mass
	return reference_thrust_newtons * pow(mass_ratio, thrust_mass_exponent)


func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("swap_ship_small"):
		equip_ship(ship_small)
	elif Input.is_action_just_pressed("swap_ship_medium"):
		equip_ship(ship_medium)
	elif Input.is_action_just_pressed("swap_ship_large"):
		equip_ship(ship_large)

	if Input.is_action_just_pressed("reset_fuel"):
		fuel_mass = _initial_fuel_mass

	if Input.is_action_just_pressed("toggle_rotational_stabilization"):
		rotational_stabilize = not rotational_stabilize

	_recalculate_mass_and_inertia()
	_current_max_thrust_n = _calculate_max_thrust_newtons()

	var main_throttle := 0.0
	var applied_rcs_torque := 0.0
	var applied_rcs_linear_dir_world := Vector2.ZERO

	# Player boost (main thruster)
	var trigger := Input.get_action_strength("boost")
	if trigger > 0.05:
		main_throttle = maxf(main_throttle, trigger)

	# Stick aim (infinite RCS for now)
	var stick := Vector2(
		Input.get_axis("look_left", "look_right"),
		Input.get_axis("look_up", "look_down")
	)
	var aiming: bool = stick.length() > 0.2

	if aiming:
		var target_rot: float = stick.angle() + PI * 0.5
		var error: float = wrapf(target_rot - rotation, -PI, PI)
		var abs_error: float = abs(error)
		var abs_vel: float = abs(angular_velocity)

		# Close enough — kill spin and stop cleanly
		if abs_error < 0.005 and abs_vel < 0.05:
			angular_velocity = 0.0
		elif inertia > 0.0 and delta > 0.0:
			# Time-optimal phase-plane speed profile with fractional final-tick pulse
			# so RCS never overshoots past the target into a 2-frame limit cycle.
			var alpha: float = rcs_torque / inertia
			var alpha_brake: float = alpha / maxf(brake_multiplier, 1.0)
			var desired_speed: float = minf(sqrt(2.0 * alpha_brake * abs_error), abs_error / delta)
			var desired_vel: float = signf(error) * desired_speed
			var required_torque: float = (desired_vel - angular_velocity) * inertia / delta
			applied_rcs_torque = clampf(required_torque, -rcs_torque, rcs_torque)
			apply_torque(applied_rcs_torque)

	# Rotational stabilize only when not aiming (infinite RCS for now)
	elif rotational_stabilize:
		if abs(angular_velocity) > 0.001 and delta > 0.0:
			# Fire full RCS torque when spinning fast, or a fractional pulse on the
			# final tick to land directly on 0.0 rad/s without overshooting.
			var stop_torque: float = -angular_velocity * inertia / delta
			applied_rcs_torque = clampf(stop_torque, -rcs_torque, rcs_torque)
			apply_torque(applied_rcs_torque)
		else:
			angular_velocity = 0.0

	# Momentum stabilize (uses main engine when nose is aligned opposite velocity
	# and fuel remains; otherwise falls back to infinite omnidirectional RCS)
	if Input.is_action_pressed("stabilize_momentum"):
		var speed: float = linear_velocity.length()
		if speed > 0.5 and delta > 0.0:
			var vel_dir: Vector2 = linear_velocity.normalized()
			var forward: Vector2 = Vector2.UP.rotated(rotation)
			var alignment: float = forward.dot(-vel_dir)
			if alignment > 0.1 and fuel_mass > 0.0 and _current_max_thrust_n > 0.0:
				main_throttle = maxf(main_throttle, clampf(alignment, 0.0, 1.0))
			else:
				var speed_m_s: float = speed / maxf(pixels_per_meter, 0.001)
				var force_to_stop_n: float = speed_m_s * mass / delta
				var applied_rcs_n: float = minf(rcs_linear_force, force_to_stop_n)
				if applied_rcs_n > 0.0:
					applied_rcs_linear_dir_world = -vel_dir
					apply_central_force(applied_rcs_linear_dir_world * applied_rcs_n * pixels_per_meter)
		else:
			linear_velocity = Vector2.ZERO

	# Apply main thruster force and consume fuel linearly with applied thrust
	_current_applied_thrust_n = 0.0
	_current_fuel_burn_rate = 0.0
	var active_throttle := 0.0

	if main_throttle > 0.0 and fuel_mass > 0.0 and _current_max_thrust_n > 0.0:
		var clamped_throttle := clampf(main_throttle, 0.0, 1.0)
		var desired_thrust_n := _current_max_thrust_n * clamped_throttle
		var exhaust_velocity := maxf(specific_impulse * STANDARD_GRAVITY, 0.01)
		var burn_rate := desired_thrust_n / exhaust_velocity # kg/s
		var fuel_needed := burn_rate * delta

		var burn_fraction := 1.0
		if fuel_needed > fuel_mass:
			burn_fraction = fuel_mass / fuel_needed
			fuel_mass = 0.0
		else:
			fuel_mass -= fuel_needed

		_current_applied_thrust_n = desired_thrust_n * burn_fraction
		_current_fuel_burn_rate = burn_rate * burn_fraction
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
	var torque_threshold := rcs_torque * maxf(rcs_visual_torque_threshold, 0.0)
	var spin_cw := torque_applied > torque_threshold
	var spin_ccw := torque_applied < -torque_threshold

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
	var max_turn_accel := rcs_torque / inertia if inertia > 0.0 else 0.0
	var active_accel_m_s2 := _current_applied_thrust_n / mass
	var active_accel_g := active_accel_m_s2 / STANDARD_GRAVITY
	var speed_m_s := linear_velocity.length() / maxf(pixels_per_meter, 0.001)

	_telemetry_label.text = (
		"SHIP: %s\n"
		+ "FUEL: %.1f / %.1f kg (%.0f%%)\n"
		+ "MASS: %.1f kg (Dry: %.1f kg)\n"
		+ "INERTIA: %.1f kg·m² | TURN: %.1f rad/s²\n"
		+ "MAX THRUST: %.2f kN (%.2f G max)\n"
		+ "BURN: %.2f kg/s | ACCEL: %.2f G (%.1f m/s²)\n"
		+ "SPEED: %.1f m/s"
	) % [
		_active_ship_name,
		fuel_mass,
		_initial_fuel_mass,
		fuel_pct,
		mass,
		_dry_mass,
		inertia,
		max_turn_accel,
		_current_max_thrust_n / 1000.0,
		max_accel_g,
		_current_fuel_burn_rate,
		active_accel_g,
		active_accel_m_s2,
		speed_m_s,
	]
