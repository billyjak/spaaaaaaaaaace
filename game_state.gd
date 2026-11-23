extends Node

# ---------------------------------------------------------------------------
# Session GameState Autoload (Zero Disk Writes for MVP)
# Holds:
#   - 5 curated deterministic preset tracks + 6th Random Sector slot
#   - Active menu selections (Track, Weight Class, Tech Tier)
#   - In-memory session best times keyed by (Track, Tech Tier), shared across
#     all 3 weight classes (recording both winning time and winning class)
#   - Shared SI ship stat calculation matching PlayerShip physics exactly
# ---------------------------------------------------------------------------

const STANDARD_GRAVITY: float = 9.80665
const REF_THRUSTER_MASS: float = 35.0
const REF_THRUST_N: float = 9000.0
const REF_RCS_MASS: float = 20.0
const REF_RCS_NOZZLE_N: float = 1500.0
const SQUARE_CUBE_EXP: float = 2.0 / 3.0

const SIZE_KEYS: PackedStringArray = ["small", "medium", "large"]
const SIZE_DISPLAY_NAMES: PackedStringArray = ["Small — Dart", "Medium — Vector", "Large — Titan"]
const SIZE_SHORT_NAMES: PackedStringArray = ["Small (Dart)", "Medium (Vector)", "Large (Titan)"]
const SIZE_BLURBS: PackedStringArray = [
	"Ultralight agile drone. Snaps 180° almost instantly and dominates tight hairpins.",
	"Balanced all-rounder. Strong straight-line thrust with forgiving rotational control.",
	"Heavy high-thrust cruiser. Blistering flip-and-burn acceleration on long straights; demands early turn-in.",
]

const HULL_TIER_SLUGS: PackedStringArray = ["steel", "titanium", "carbon", "exotic"]
const ENGINE_TIER_SLUGS: PackedStringArray = ["chemical", "ntr", "fusion", "exotic"]
const RCS_TIER_SLUGS: PackedStringArray = ["hydrazine", "resistojet", "plasma", "exotic"]
const TIER_NAMES: PackedStringArray = [
	"Tier 1 — Chemical",
	"Tier 2 — Nuclear Thermal",
	"Tier 3 — Fusion Torch",
	"Tier 4 — Exotic Drive",
]
const TIER_BLURBS: PackedStringArray = [
	"1960s NASA-era bipropellant hardware (310 s Isp). Modest thrust; tight fuel margin.",
	"Fission thermal propulsion (900 s Isp) & Titanium hull. Major leap in speed and range.",
	"Fusion torch drive (2,400 s Isp) & Carbon frame. High-G burns and fast thermal rejection.",
	"Exotic metamaterial lattice & torch drive (5,500 s Isp). Extreme acceleration and agility.",
]

# 5 curated deterministic preset circuits spanning all archetypes (visually verified clean)
const PRESET_TRACKS: Array[Dictionary] = [
	{
		"id": "preset_helios",
		"name": "Helios Speedway",
		"track_type": 1, # TrackType.TYPE_1 (Speedway)
		"seed": 3100132,
		"blurb": "High-speed orbital speedway with long flowing arcs and massive flip-and-burn straights.",
	},
	{
		"id": "preset_lagrange",
		"name": "Lagrange GP",
		"track_type": 2, # TrackType.TYPE_2 (Circuit)
		"seed": 3151610,
		"blurb": "Classic Grand Prix rhythm: blistering straightaways slamming straight into sharp hairpins.",
	},
	{
		"id": "preset_kepler",
		"name": "Kepler Drift",
		"track_type": 5, # TrackType.DYNAMIC (Mixed Sectors)
		"seed": 7161512,
		"blurb": "Mixed-sector circuit pairing an open power straight with a fierce chained hairpin wing.",
	},
	{
		"id": "preset_kessler",
		"name": "Kessler Slalom",
		"track_type": 3, # TrackType.TYPE_3 (Technical)
		"seed": 3203088,
		"blurb": "Technical orbital slalom packed with sweeping S-bends, chicanes, and tight apexes.",
	},
	{
		"id": "preset_kuiper",
		"name": "Kuiper Switchback",
		"track_type": 4, # TrackType.TYPE_4 (Switchback)
		"seed": 3100525,
		"blurb": "Relentless switchback circuit. Back-to-back hairpins test RCS authority and Overburn saves.",
	},
]

const RANDOM_TRACK_INDEX: int = 5

# Active selections
signal telemetry_visibility_changed(is_visible: bool)

var selected_track_index: int = 0
var random_track_seed: int = 0
var selected_weight_class: int = 0 # 0 = Small, 1 = Medium, 2 = Large
var selected_tech_tier: int = 1    # 1..4
var launched_from_menu: bool = false
var skip_title_screen: bool = false
var show_telemetry: bool = false

# In-memory session best times (zero disk writes):
# Key: "<track_id>_T<tier>" -> { "time": float, "weight_class": int, "ship_class": String }
var session_best_times: Dictionary = {}

var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_ensure_ui_gamepad_binds()
	reroll_random_track()


func _ensure_ui_gamepad_binds() -> void:
	_add_joy_button_if_missing(&"ui_accept", JOY_BUTTON_A)
	_add_joy_button_if_missing(&"ui_cancel", JOY_BUTTON_B)


func _add_joy_button_if_missing(action: StringName, btn_idx: JoyButton) -> void:
	if not InputMap.has_action(action):
		return
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton and ev.button_index == btn_idx:
			return
	var jb := InputEventJoypadButton.new()
	jb.button_index = btn_idx
	InputMap.action_add_event(action, jb)


func reroll_random_track() -> int:
	random_track_seed = _rng.randi_range(1000000, 9999999)
	return random_track_seed


func set_show_telemetry(enabled: bool) -> void:
	show_telemetry = enabled
	telemetry_visibility_changed.emit(show_telemetry)


func toggle_telemetry() -> bool:
	set_show_telemetry(not show_telemetry)
	return show_telemetry


func get_track_option_count() -> int:
	return PRESET_TRACKS.size() + 1


func get_track_info(track_index: int) -> Dictionary:
	if track_index >= 0 and track_index < PRESET_TRACKS.size():
		return PRESET_TRACKS[track_index]
	return {
		"id": "random_%d" % random_track_seed,
		"name": "Random Sector",
		"track_type": 5, # TrackType.DYNAMIC
		"seed": random_track_seed,
		"blurb": "Fresh procedurally carved mixed-sector track (#%d). Re-roll until you like the layout!" % random_track_seed,
		"is_random": true,
	}


func get_active_track_info() -> Dictionary:
	return get_track_info(selected_track_index)


func get_record_key(track_index: int, tech_tier: int) -> String:
	var info := get_track_info(track_index)
	return "%s_T%d" % [str(info["id"]), clampi(tech_tier, 1, 4)]


func get_record_key_for_seed(track_type: int, seed_val: int, tech_tier: int) -> String:
	for i in PRESET_TRACKS.size():
		var p := PRESET_TRACKS[i]
		if int(p["track_type"]) == track_type and int(p["seed"]) == seed_val:
			return "%s_T%d" % [str(p["id"]), clampi(tech_tier, 1, 4)]
	return "random_%d_%d_T%d" % [track_type, seed_val, clampi(tech_tier, 1, 4)]


func get_best_time(track_index: int, tech_tier: int) -> Dictionary:
	var key := get_record_key(track_index, tech_tier)
	return session_best_times.get(key, {})


func record_run_time(track_type: int, seed_val: int, tech_tier: int, weight_class: int, run_time: float) -> Dictionary:
	var key := get_record_key(selected_track_index, tech_tier) if launched_from_menu else get_record_key_for_seed(track_type, seed_val, tech_tier)
	var prev: Dictionary = session_best_times.get(key, {})
	var prev_time: float = float(prev.get("time", INF))
	var cls_name := SIZE_SHORT_NAMES[clampi(weight_class, 0, 2)]
	var is_new_best := run_time < prev_time
	if is_new_best:
		session_best_times[key] = {
			"time": run_time,
			"weight_class": clampi(weight_class, 0, 2),
			"ship_class": cls_name,
		}
	return {
		"is_new_best": is_new_best,
		"prev_time": prev_time,
		"best": session_best_times[key],
	}


func get_best_for_active_run(track_type: int, seed_val: int, tech_tier: int) -> Dictionary:
	var key := get_record_key(selected_track_index, tech_tier) if launched_from_menu else get_record_key_for_seed(track_type, seed_val, tech_tier)
	return session_best_times.get(key, {})


func compute_ship_stats(weight_class: int, tech_tier: int) -> Dictionary:
	var s_idx := clampi(weight_class, 0, 2)
	var t := clampi(tech_tier, 1, 4)
	var s_key := SIZE_KEYS[s_idx]

	var hull := load("res://parts/hulls/%s/tier_%d/hull_%s_t%d_%s.tres" % [s_key, t, s_key, t, HULL_TIER_SLUGS[t - 1]]) as HullPart
	var thruster := load("res://parts/thrusters/%s/tier_%d/thruster_%s_t%d_%s.tres" % [s_key, t, s_key, t, ENGINE_TIER_SLUGS[t - 1]]) as ThrusterPart
	var rcs := load("res://parts/rcs/%s/tier_%d/rcs_%s_t%d_%s.tres" % [s_key, t, s_key, t, RCS_TIER_SLUGS[t - 1]]) as RCSPart
	var aux := load("res://parts/aux/aux_avionics_basic.tres") as ShipPart

	if hull == null or thruster == null or rcs == null:
		return {}

	var aux_mass := aux.mass_kg if aux != null else 0.0
	var dry_mass := hull.mass_kg + thruster.mass_kg + rcs.mass_kg + aux_mass
	var fuel_cap := hull.fuel_capacity_kg
	var wet_mass := dry_mass + fuel_cap
	var r := maxf(hull.inertia_radius_m, 0.01)
	var inertia_wet := wet_mass * r * r

	var max_thrust_n := thruster.get_max_thrust_newtons(REF_THRUSTER_MASS, REF_THRUST_N, SQUARE_CUBE_EXP)
	var rcs_nozzle_n := rcs.get_nozzle_thrust_newtons(REF_RCS_MASS, REF_RCS_NOZZLE_N, SQUARE_CUBE_EXP)
	var rcs_torque := 2.0 * rcs_nozzle_n * hull.rcs_lever_arm_m

	var accel_wet_g := (max_thrust_n / maxf(wet_mass, 0.1)) / STANDARD_GRAVITY
	var accel_dry_g := (max_thrust_n / maxf(dry_mass, 0.1)) / STANDARD_GRAVITY
	var turn_wet := rcs_torque / maxf(inertia_wet, 0.01)
	var full_burn_rate := max_thrust_n / maxf(thruster.specific_impulse * STANDARD_GRAVITY, 0.01)
	var burn_time_s := fuel_cap / maxf(full_burn_rate, 0.001)

	return {
		"hull_name": hull.part_name,
		"engine_name": thruster.part_name,
		"rcs_name": rcs.part_name,
		"dry_mass": dry_mass,
		"wet_mass": wet_mass,
		"fuel_cap": fuel_cap,
		"max_thrust_kn": max_thrust_n / 1000.0,
		"accel_wet_g": accel_wet_g,
		"accel_dry_g": accel_dry_g,
		"turn_wet_rad_s2": turn_wet,
		"isp": thruster.specific_impulse,
		"burn_time_s": burn_time_s,
		"heat_cap_kj": hull.heat_capacity_kj,
		"max_cool_kw": hull.max_radiative_cooling_kw,
		"overburn_heat_kw": thruster.overburn_heat_kw,
	}


static func format_time(seconds: float) -> String:
	var clamped := maxf(seconds, 0.0)
	var mins := int(floor(clamped / 60.0))
	var secs := int(floor(fmod(clamped, 60.0)))
	var hundredths := int(floor(fmod(clamped * 100.0, 100.0)))
	return "%02d:%02d.%02d" % [mins, secs, hundredths]
