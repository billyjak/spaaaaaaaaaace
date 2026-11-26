extends StaticBody2D

signal track_generated(seed_value: int, spawn_pos: Vector2, spawn_rot: float)
signal checkpoint_crossed(gate_index: int)

enum TrackType {
	TYPE_1 = 1, ## Speedway: wide sweeping curves and long arcs
	TYPE_2 = 2, ## Circuit: balanced mix of long straights into hard hairpins
	TYPE_3 = 3, ## Technical: frequent sharp hairpins and chained tight turns
	TYPE_4 = 4, ## Switchback: relentless deep hairpins and back-to-back tight bends
	DYNAMIC = 5, ## Dynamic Mixed: random-length sectors with varying continuous curviness (0..1)
}

const TRACK_TYPE_COUNT: int = 4

@export_group("Track Seed, Type & Saving")
## 0 = generate a fresh random track every launch; non-zero = deterministically replay that exact seed.
@export var track_seed: int = 0
## Track archetype controlling turn density and hairpin intensity (Type 1 = swoopy -> Type 4 = switchback).
@export var track_type: TrackType = TrackType.TYPE_1
## JSON file where favorite track seeds are saved when pressing `save_track`.
@export var saved_tracks_path: String = "user://saved_tracks.json"
## Enable developer track-swapping & saving hotkeys (`N`, `J`, `S`) during flight.
@export var dev_hotkeys_enabled: bool = false

@export_group("Track Geometry (Medium Circuit Defaults)")
## Number of radial control points around the loop (fewer = sweeping speedway, more = twisty technical).
@export_range(6, 24) var control_point_count: int = 12
## Average distance from track center to centerline (px). 4,000 px ~ 250 m radius (~1.6 km lap at 16 px/m).
@export var base_radius: float = 4000.0
## Maximum inward/outward radial push as a fraction of base_radius.
@export_range(0.05, 0.55, 0.01) var radial_variation: float = 0.35
## Slight angular jitter per control point (fraction of angular step) for organic corner spacing.
@export_range(0.0, 0.35, 0.01) var angular_jitter: float = 0.18
## Total track width between inner and outer white lines (px).
@export var track_width: float = 480.0
## Approximate spacing between sampled vertices along the smooth spline (px).
@export var sample_spacing: float = 65.0
## Smoothing passes for the gentle-arc camera guide rail (auto-scaled with sample_spacing).
@export_range(0, 120) var camera_rail_smoothing_passes: int = 55

@export_group("Walls & Collision")
## Toggle solid physics barriers (true = solid walls, false = visual lines only).
@export var solid_walls: bool = true
## Physics collision thickness along each wall segment (px).
@export var wall_thickness: float = 20.0
## Core energy rail stroke thickness (px).
@export var wall_line_width: float = 3.6
## Number of ordered intermediate checkpoints evenly spaced around the lap (plus Start/Finish gate).
@export_range(4, 24) var checkpoint_count: int = 10
## Trigger thickness (px) along the track direction for checkpoint Area2D gates (prevents high-speed tunneling).
@export var checkpoint_trigger_depth: float = 110.0

@export_group("Orbital Holo-Corridor Visuals")
## Translucent electric-blue surface color along the track edges at the midpoint peak (Peak Blue = Flip & Burn!).
@export var surface_edge_color: Color = Color(0.06, 0.58, 1.0, 0.36)
## Mid-band translucent blue color (stays calm translucent blue across the track interior).
@export var surface_mid_color: Color = Color(0.04, 0.36, 0.78, 0.14)
## Ultra-sheer blue center tint so the Milky Way and 3D background shine cleanly through.
@export var surface_center_color: Color = Color(0.02, 0.22, 0.52, 0.06)
## Soft, desaturated amber edge color for slow turns (calm and balanced against the blue rail).
@export var hairpin_warn_edge_color: Color = Color(0.86, 0.54, 0.26, 0.34)
## Bend radius (px) below which a turn is marked as a full 100% Amber slow corner.
@export var corner_warn_radius_px: float = 950.0
## Reference acceleration (px/s^2) used to find the flip-and-burn midpoint peak (~3.0 G).
@export var pacing_ref_accel_px: float = 480.0
## Spacing between centerline holographic forward chevrons (px).
@export var chevron_spacing_px: float = 300.0
## Spacing between physical projector buoys along both walls (px).
@export var buoy_spacing_px: float = 340.0

# Public read-only track geometry for future visuals, checkpoints, minimaps, and AI
var active_seed: int = 0
var active_track_type: TrackType = TrackType.TYPE_1
var centerline_points: PackedVector2Array = PackedVector2Array()
var camera_rail_points: PackedVector2Array = PackedVector2Array()
var outer_points: PackedVector2Array = PackedVector2Array()
var inner_points: PackedVector2Array = PackedVector2Array()
var pacing_brake: PackedFloat32Array = PackedFloat32Array()
var pacing_outer_amber: PackedFloat32Array = PackedFloat32Array()
var pacing_inner_amber: PackedFloat32Array = PackedFloat32Array()
var track_length_px: float = 0.0
var total_track_turn_rad: float = 0.0
var _centerline_cum_dist: PackedFloat32Array = PackedFloat32Array()
var _centerline_cum_turn: PackedFloat32Array = PackedFloat32Array()

var save_status_text: String = ""
var _save_status_timer: float = 0.0

var _rng := RandomNumberGenerator.new()
var _generated_colliders: Array[CollisionShape2D] = []
var _checkpoint_areas: Array[Area2D] = []
var checkpoint_gates: Array[Dictionary] = []

@onready var _outer_line: Line2D = $OuterWallVisual
@onready var _inner_line: Line2D = $InnerWallVisual

var _surface_mesh: MeshInstance2D = null
var _outer_bloom: Line2D = null
var _outer_glow: Line2D = null
var _inner_bloom: Line2D = null
var _inner_glow: Line2D = null
var _holo_overlay: Node2D = null


func _ready() -> void:
	visible = true
	if _outer_line:
		_outer_line.visible = true
	if _inner_line:
		_inner_line.visible = true

	_ensure_holo_visual_nodes()
	var gs := get_node_or_null("/root/GameState")
	if gs != null and bool(gs.launched_from_menu):
		var info: Dictionary = gs.get_active_track_info()
		active_track_type = int(info["track_type"]) as TrackType
		track_type = active_track_type
		generate_track(int(info["seed"]), active_track_type)
	else:
		active_track_type = track_type
		generate_track(track_seed, active_track_type)


func _process(delta: float) -> void:
	if _save_status_timer > 0.0:
		_save_status_timer = maxf(_save_status_timer - delta, 0.0)
		if _save_status_timer <= 0.0:
			save_status_text = ""

	if dev_hotkeys_enabled:
		if InputMap.has_action("new_track") and Input.is_action_just_pressed("new_track"):
			cycle_track_type()
		if InputMap.has_action("new_dynamic_track") and Input.is_action_just_pressed("new_dynamic_track"):
			generate_track(0, TrackType.DYNAMIC)
		if InputMap.has_action("save_track") and Input.is_action_just_pressed("save_track"):
			save_current_track()


## Pure-geometry generator for Main Menu minimap previews (no colliders, visuals, or ship placement).
func build_preview_geometry(seed_override: int, type_override: int) -> Dictionary:
	var t_type: TrackType = clampi(type_override, TrackType.TYPE_1, TrackType.DYNAMIC) as TrackType
	var use_seed := seed_override if seed_override != 0 else 1000001
	var built := false
	for attempt in range(28):
		_rng.seed = use_seed + int(t_type) * 104729 + attempt * 7919
		if _try_build_geometry(t_type):
			built = true
			break
	if not built:
		_build_fallback_geometry()
	_rebuild_centerline_arc_table()
	# Compute total turning angle without running camera rail Laplacian smoothing
	var turn_sum := 0.0
	var n := centerline_points.size()
	if n >= 3:
		for i in n:
			var d0 := (centerline_points[i] - centerline_points[(i - 1 + n) % n]).normalized()
			var d1 := (centerline_points[(i + 1) % n] - centerline_points[i]).normalized()
			turn_sum += absf(d0.angle_to(d1))
	return {
		"outer": outer_points.duplicate(),
		"inner": inner_points.duplicate(),
		"start": centerline_points[0] if n > 0 else Vector2.ZERO,
		"length_px": track_length_px,
		"total_turn_deg": rad_to_deg(turn_sum),
	}


func get_track_type_label(t_type: int = -1) -> String:
	var resolved := int(active_track_type) if t_type < 0 else t_type
	match resolved:
		TrackType.TYPE_1:
			return "Type 1 - Speedway"
		TrackType.TYPE_2:
			return "Type 2 - Circuit"
		TrackType.TYPE_3:
			return "Type 3 - Technical"
		TrackType.TYPE_4:
			return "Type 4 - Switchback"
		TrackType.DYNAMIC:
			return "Dynamic - Mixed"
		_:
			return "Type %d" % resolved


func cycle_track_type() -> void:
	var cur := int(active_track_type)
	var next_int := 1 if (cur < 1 or cur >= TRACK_TYPE_COUNT) else (cur + 1)
	active_track_type = next_int as TrackType
	track_type = active_track_type
	generate_track(0, active_track_type)


func generate_track(seed_override: int = 0, type_override: int = 0) -> void:
	if type_override >= TrackType.TYPE_1 and type_override <= TrackType.DYNAMIC:
		active_track_type = type_override as TrackType
		track_type = active_track_type

	if seed_override != 0:
		active_seed = seed_override
	else:
		# Pick a clean, human-readable positive 7-digit seed for easy note-taking/sharing
		var seed_picker := RandomNumberGenerator.new()
		seed_picker.randomize()
		active_seed = seed_picker.randi_range(1000000, 9999999)

	save_status_text = ""
	_save_status_timer = 0.0

	# Attempt generation deterministically from (active_seed, active_track_type); if an extreme
	# hairpin geometry self-intersects after smoothing, deterministically step the attempt counter.
	var built := false
	for attempt in range(28):
		_rng.seed = active_seed + int(active_track_type) * 104729 + attempt * 7919
		if _try_build_geometry(active_track_type):
			built = true
			break

	if not built:
		# Guaranteed fallback: clean gentle oval derived from active_seed
		_build_fallback_geometry()

	_rebuild_centerline_arc_table()
	_rebuild_camera_guides()
	_rebuild_checkpoints()
	_apply_visuals()
	_rebuild_collisions()

	var spawn_pos := get_spawn_position()
	var spawn_rot := get_spawn_rotation()
	_place_player_at_spawn(spawn_pos, spawn_rot)
	track_generated.emit(active_seed, spawn_pos, spawn_rot)


func _rebuild_centerline_arc_table() -> void:
	_centerline_cum_dist = PackedFloat32Array()
	var n := centerline_points.size()
	if n < 2:
		return
	var acc := 0.0
	_centerline_cum_dist.append(0.0)
	for i in n:
		acc += centerline_points[i].distance_to(centerline_points[(i + 1) % n])
		_centerline_cum_dist.append(acc)
	track_length_px = acc


## Precomputes:
## 1) `_centerline_cum_turn`: continuous cumulative absolute turning (radians) along the true course,
##    enabling smooth O(log N) sightline / corner-anchor queries with zero vertex-crossing jumps.
## 2) `camera_rail_points`: a heavily smoothed, gentle-arc approximation of the track loop that the
##    camera follows to avoid uncomfortable swishing through tight hairpins and S-bends.
func _rebuild_camera_guides() -> void:
	_centerline_cum_turn = PackedFloat32Array()
	camera_rail_points = PackedVector2Array()
	total_track_turn_rad = 0.0

	var n := centerline_points.size()
	if n < 3:
		camera_rail_points = centerline_points.duplicate()
		return

	# 1. Per-segment unit directions and per-vertex absolute exterior turning angles
	var seg_dirs: Array[Vector2] = []
	seg_dirs.resize(n)
	for i in n:
		var v := centerline_points[(i + 1) % n] - centerline_points[i]
		seg_dirs[i] = v.normalized() if v.length_squared() > 1e-6 else Vector2.RIGHT

	var vertex_turns: PackedFloat32Array = PackedFloat32Array()
	vertex_turns.resize(n)
	for i in n:
		var prev_dir: Vector2 = seg_dirs[(i - 1 + n) % n]
		var next_dir: Vector2 = seg_dirs[i]
		vertex_turns[i] = absf(prev_dir.angle_to(next_dir))

	# Distribute vertex turning symmetrically onto adjacent segments for C1-continuous arc lookup
	var turn_acc := 0.0
	_centerline_cum_turn.append(0.0)
	for i in n:
		var seg_turn := 0.5 * (vertex_turns[i] + vertex_turns[(i + 1) % n])
		turn_acc += seg_turn
		_centerline_cum_turn.append(turn_acc)
	total_track_turn_rad = turn_acc

	# 2. Build gentle-arc camera guide rail via circular Laplacian smoothing
	#    Scale passes relative to sample_spacing so the physical smoothing radius stays consistent.
	var rail: Array[Vector2] = []
	rail.resize(n)
	for i in n:
		rail[i] = centerline_points[i]

	var spacing_scale := pow(120.0 / maxf(sample_spacing, 30.0), 1.6)
	var passes := clampi(int(round(float(maxi(camera_rail_smoothing_passes, 0)) * spacing_scale)), 0, 240)
	for _pass in range(passes):
		var next_rail: Array[Vector2] = []
		next_rail.resize(n)
		for i in n:
			var prev_pt := rail[(i - 1 + n) % n]
			var curr_pt := rail[i]
			var next_pt := rail[(i + 1) % n]
			next_rail[i] = curr_pt.lerp((prev_pt + next_pt) * 0.5, 0.5)
		rail = next_rail

	camera_rail_points = PackedVector2Array(rail)


func _project_world_to_arc(world_pos: Vector2) -> float:
	var n := centerline_points.size()
	if n < 2 or track_length_px <= 0.001 or _centerline_cum_dist.size() != n + 1:
		return 0.0

	var local_pos := to_local(world_pos)
	var best_dist_sq := INF
	var best_arc := 0.0

	for i in n:
		var a := centerline_points[i]
		var b := centerline_points[(i + 1) % n]
		var closest := Geometry2D.get_closest_point_to_segment(local_pos, a, b)
		var d_sq := local_pos.distance_squared_to(closest)
		if d_sq < best_dist_sq:
			best_dist_sq = d_sq
			best_arc = _centerline_cum_dist[i] + a.distance_to(closest)

	return best_arc


## Projects `world_pos` onto the closed track centerline, advances `lookahead_px` forward
## along the course (wrapping cleanly around Start/Finish), and returns that world-space point.
func get_course_lookahead_world(world_pos: Vector2, lookahead_px: float) -> Vector2:
	var n := centerline_points.size()
	if n < 2 or track_length_px <= 0.001 or _centerline_cum_dist.size() != n + 1:
		return world_pos

	var best_arc := _project_world_to_arc(world_pos)
	var target_arc := fposmod(best_arc + lookahead_px, track_length_px)
	return to_global(_sample_loop_at_arc(centerline_points, target_arc))


## Walks forward along the true track centerline from `world_pos` until cumulative absolute
## turning reaches `turn_threshold_rad` (or `max_sightline_px`), returning:
## - `anchor_world`: exact upcoming corner/straight-end point on the true centerline
## - `rail_anchor_world`: corresponding gentle-arc point on `camera_rail_points`
## - `sightline_dist_px`: forward arc distance from ship to anchor
## - `ship_arc`: projected arc position along the loop
func get_course_sightline(world_pos: Vector2, turn_threshold_rad: float, max_sightline_px: float) -> Dictionary:
	var n := centerline_points.size()
	if n < 3 or track_length_px <= 0.001 or _centerline_cum_dist.size() != n + 1 or _centerline_cum_turn.size() != n + 1:
		return {
			"anchor_world": world_pos,
			"rail_anchor_world": world_pos,
			"sightline_dist_px": 0.0,
			"ship_arc": 0.0,
		}

	var ship_arc := _project_world_to_arc(world_pos)
	var max_dist := minf(maxf(max_sightline_px, 0.0), track_length_px * 0.45)
	var sightline_dist := max_dist

	if total_track_turn_rad > 0.001 and turn_threshold_rad > 0.0 and turn_threshold_rad < total_track_turn_rad:
		var start_turn := _sample_cum_turn_at_arc(ship_arc)
		var target_turn := start_turn + turn_threshold_rad
		if target_turn <= total_track_turn_rad:
			var raw_anchor_arc := _find_arc_for_cum_turn(target_turn)
			sightline_dist = raw_anchor_arc - ship_arc
		else:
			var wrapped_turn := target_turn - total_track_turn_rad
			var wrapped_arc := _find_arc_for_cum_turn(wrapped_turn)
			sightline_dist = (track_length_px - ship_arc) + wrapped_arc

	sightline_dist = clampf(sightline_dist, 0.0, max_dist)
	var anchor_arc := fposmod(ship_arc + sightline_dist, track_length_px)

	var anchor_local := _sample_loop_at_arc(centerline_points, anchor_arc)
	var rail_source := camera_rail_points if camera_rail_points.size() == n else centerline_points
	var rail_anchor_local := _sample_loop_at_arc(rail_source, anchor_arc)

	return {
		"anchor_world": to_global(anchor_local),
		"rail_anchor_world": to_global(rail_anchor_local),
		"sightline_dist_px": sightline_dist,
		"ship_arc": ship_arc,
	}


func _sample_loop_at_arc(loop_pts: PackedVector2Array, arc_dist: float) -> Vector2:
	var n := loop_pts.size()
	if n == 0:
		return Vector2.ZERO
	if n == 1:
		return loop_pts[0]

	var d := fposmod(arc_dist, track_length_px)
	# Binary search cumulative arc table for O(log N) exact interpolation
	var lo := 0
	var hi := n - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if _centerline_cum_dist[mid] <= d:
			lo = mid
		else:
			hi = mid - 1

	var seg_start := _centerline_cum_dist[lo]
	var seg_end := _centerline_cum_dist[lo + 1]
	var seg_len := maxf(seg_end - seg_start, 0.0001)
	var t := clampf((d - seg_start) / seg_len, 0.0, 1.0)
	return loop_pts[lo].lerp(loop_pts[(lo + 1) % n], t)


func _sample_cum_turn_at_arc(arc_dist: float) -> float:
	var n := centerline_points.size()
	var d := fposmod(arc_dist, track_length_px)
	var lo := 0
	var hi := n - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if _centerline_cum_dist[mid] <= d:
			lo = mid
		else:
			hi = mid - 1

	var seg_start := _centerline_cum_dist[lo]
	var seg_end := _centerline_cum_dist[lo + 1]
	var seg_len := maxf(seg_end - seg_start, 0.0001)
	var t := clampf((d - seg_start) / seg_len, 0.0, 1.0)
	return lerpf(_centerline_cum_turn[lo], _centerline_cum_turn[lo + 1], t)


func _find_arc_for_cum_turn(target_turn: float) -> float:
	var n := centerline_points.size()
	if target_turn <= 0.0:
		return 0.0
	if target_turn >= total_track_turn_rad:
		return track_length_px

	var lo := 0
	var hi := n - 1
	while lo < hi:
		var mid := (lo + hi) >> 1
		if _centerline_cum_turn[mid + 1] >= target_turn:
			hi = mid
		else:
			lo = mid + 1

	var turn_start := _centerline_cum_turn[lo]
	var turn_end := _centerline_cum_turn[lo + 1]
	var turn_span := turn_end - turn_start
	var frac := clampf((target_turn - turn_start) / turn_span, 0.0, 1.0) if turn_span > 1e-6 else 0.0
	return lerpf(_centerline_cum_dist[lo], _centerline_cum_dist[lo + 1], frac)


func get_spawn_position() -> Vector2:
	if centerline_points.is_empty():
		return global_position
	return to_global(centerline_points[0])


func get_spawn_rotation() -> float:
	if centerline_points.size() < 2:
		return 0.0
	var tangent := (centerline_points[1] - centerline_points[0]).normalized()
	# PlayerShip's nose points along local Vector2.UP (-Y), so add PI/2 to standard angle()
	return tangent.angle() + PI * 0.5


func save_current_track() -> bool:
	var records: Array = []

	if FileAccess.file_exists(saved_tracks_path):
		var read_file := FileAccess.open(saved_tracks_path, FileAccess.READ)
		if read_file != null:
			var parsed: Variant = JSON.parse_string(read_file.get_as_text())
			if parsed is Array:
				records = parsed

	for existing in records:
		if existing is Dictionary and int(existing.get("seed", 0)) == active_seed and int(existing.get("track_type", TrackType.TYPE_1)) == int(active_track_type):
			save_status_text = "[ALREADY SAVED]"
			_save_status_timer = 3.0
			print("Track %s #%d is already saved in %s" % [get_track_type_label(), active_seed, ProjectSettings.globalize_path(saved_tracks_path)])
			return true

	var entry := {
		"seed": active_seed,
		"track_type": int(active_track_type),
		"track_type_name": get_track_type_label(),
		"control_point_count": control_point_count,
		"base_radius": base_radius,
		"radial_variation": radial_variation,
		"angular_jitter": angular_jitter,
		"track_width": track_width,
		"length_px": snappedf(track_length_px, 1.0),
		"total_turn_deg": snappedf(rad_to_deg(total_track_turn_rad), 1.0),
		"saved_at": Time.get_datetime_string_from_system(),
	}
	records.append(entry)

	var write_file := FileAccess.open(saved_tracks_path, FileAccess.WRITE)
	if write_file == null:
		save_status_text = "[SAVE FAILED]"
		_save_status_timer = 3.0
		push_warning("Could not write saved tracks file at %s" % saved_tracks_path)
		return false

	write_file.store_string(JSON.stringify(records, "\t") + "\n")
	write_file.close()

	save_status_text = "[SAVED!]"
	_save_status_timer = 3.0
	print("Saved track %s #%d -> %s" % [get_track_type_label(), active_seed, ProjectSettings.globalize_path(saved_tracks_path)])
	return true


func _build_control_points_for_type(t_type: TrackType) -> Dictionary:
	var control_pts: Array[Vector2] = []
	var handle_ratio := 0.30

	match t_type:
		TrackType.TYPE_1:
			# Type 1 - Speedway: elongated asymmetric hull + 2-3 gentle sweeping edge pushes
			var aspect := _rng.randf_range(1.28, 1.75)
			var w := base_radius * 2.35 * sqrt(aspect)
			var h := base_radius * 2.35 / sqrt(aspect)
			var hull := _build_convex_hull_base(w, h, 18, 1500.0)
			control_pts = _carve_track_edges(hull, 0, 1, 2, 1300.0)
			control_pts = _relax_control_points(control_pts, 1350.0, 8)
			handle_ratio = 0.33

		TrackType.TYPE_2:
			# Type 2 - Circuit: real GP layout — 1-2 intact long straights, 2 sharp hairpin pockets, 1-2 S-chicanes
			var aspect := _rng.randf_range(1.30, 1.85)
			var w := base_radius * 2.65 * sqrt(aspect)
			var h := base_radius * 2.65 / sqrt(aspect)
			var hull := _build_convex_hull_base(w, h, 20, 1600.0)
			control_pts = _carve_track_edges(hull, 2, 2, 1, 1200.0, true)
			control_pts = _relax_control_points(control_pts, 1180.0, 10)
			handle_ratio = 0.27

		TrackType.TYPE_3:
			# Type 3 - Technical: multiple 3-turn Esses/chicanes + sharp hairpins, minimal straights
			var aspect := _rng.randf_range(1.25, 1.80)
			var w := base_radius * 3.05 * sqrt(aspect)
			var h := base_radius * 3.05 / sqrt(aspect)
			var hull := _build_convex_hull_base(w, h, 22, 1600.0)
			control_pts = _carve_track_edges(hull, 3, 3, 1, 1300.0, false, 3, 0.95)
			control_pts = _relax_control_points(control_pts, 1140.0, 14)
			handle_ratio = 0.24

		TrackType.TYPE_4:
			# Type 4 - Switchback: asymmetric hull with relentless hairpins & chained Esses on every side
			var aspect := _rng.randf_range(1.25, 1.85)
			var w := base_radius * 3.55 * sqrt(aspect)
			var h := base_radius * 3.55 / sqrt(aspect)
			var hull := _build_convex_hull_base(w, h, 26, 1750.0)
			control_pts = _carve_track_edges(hull, 5, 5, 2, 1450.0, false, 4, 0.96)
			control_pts = _relax_control_points(control_pts, 1200.0, 16)
			handle_ratio = 0.24

		TrackType.DYNAMIC:
			# Dynamic Mixed: walk the silhouette in random-length chunks, rolling a fresh
			# continuous curviness number (0.0 = dead straight -> 1.0 = tight hairpins/switchbacks)
			# for every sector, including per-vertex spline handle tension.
			return _build_dynamic_sector_points()

	return {
		"points": control_pts,
		"handle_ratio": handle_ratio,
		"handle_ratios": PackedFloat32Array(),
	}


func _build_dynamic_sector_points() -> Dictionary:
	var scale_mult := _rng.randf_range(2.95, 3.50)
	var aspect := _rng.randf_range(1.25, 1.85)
	var w := base_radius * scale_mult * sqrt(aspect)
	var h := base_radius * scale_mult / sqrt(aspect)
	var hull := _build_convex_hull_base(w, h, 24, 1550.0)

	# Subdivide only truly massive hull edges so every span stays wide enough for crisp hairpins
	var base_loop: Array[Vector2] = []
	var hn := hull.size()
	for i in hn:
		var a := hull[i]
		var b := hull[(i + 1) % hn]
		base_loop.append(a)
		if a.distance_to(b) > 5600.0:
			base_loop.append(a.lerp(b, _rng.randf_range(0.42, 0.58)))

	var m := base_loop.size()
	var signed_area := _compute_signed_area(base_loop)
	var inward_sign := -1.0 if signed_area >= 0.0 else 1.0

	# Assign random-length chunks (1..3 spans each) with a continuous curviness value c in [0..1].
	# Re-roll once if too close to the previous chunk so adjacent sectors create crisp pacing contrast.
	var span_curviness: PackedFloat32Array = PackedFloat32Array()
	span_curviness.resize(m)
	var cursor := 0
	var prev_c := -1.0
	while cursor < m:
		var chunk_len := _rng.randi_range(1, 3)
		var c := _rng.randf()
		if prev_c >= 0.0 and absf(c - prev_c) < 0.28:
			c = _rng.randf()
		# Gently stretch toward extremes so dead-straights and intense hairpins both show up clearly
		c = clampf((c - 0.5) * 1.18 + 0.5, 0.0, 1.0)
		prev_c = c
		for k in range(chunk_len):
			if cursor >= m:
				break
			span_curviness[cursor] = c
			cursor += 1

	var out_pts: Array[Vector2] = []
	var out_ratios := PackedFloat32Array()

	for i in m:
		var a := base_loop[i]
		var b := base_loop[(i + 1) % m]
		var c := span_curviness[i]
		# Local spline handle tension interpolates smoothly from flowing (0.34) to tight hairpin (0.22)
		var local_ratio := lerpf(0.34, 0.22, c)

		out_pts.append(a)
		out_ratios.append(local_ratio)

		var seg := b - a
		var seg_len := seg.length()
		if seg_len < 1250.0:
			continue
		var dir := seg / seg_len
		var inward_n := Vector2(dir.y, -dir.x) * inward_sign

		if c < 0.22:
			# Straightaway sector (0.00..0.22): keep edge clean & fast with optional tiny kink
			if c > 0.14 and seg_len > 2800.0:
				var kink_depth := seg_len * lerpf(0.03, 0.08, (c - 0.14) / 0.08)
				var side := 1.0 if _rng.randf() >= 0.5 else -1.0
				out_pts.append(a.lerp(b, _rng.randf_range(0.40, 0.60)) + inward_n * (kink_depth * side))
				out_ratios.append(local_ratio)

		elif c < 0.48:
			# Flowing sweeper sector (0.22..0.48): smooth single arc push
			var t := (c - 0.22) / 0.26
			var side := 1.0 if _rng.randf() < 0.65 else -1.0
			var max_safe := minf(seg_len * 0.36, 2100.0)
			var depth := clampf(seg_len * lerpf(0.14, 0.30, t), minf(480.0, max_safe), max_safe)
			out_pts.append(a.lerp(b, _rng.randf_range(0.36, 0.64)) + inward_n * (depth * side))
			out_ratios.append(local_ratio)

		elif c < 0.74:
			# Medium chicane / S-bend sector (0.48..0.74)
			var t := (c - 0.48) / 0.26
			var side := 1.0 if _rng.randf() >= 0.5 else -1.0
			if _rng.randf() < 0.35 and seg_len >= 2300.0:
				# Medium hairpin pocket (requires wide span so shoulders never pinch)
				var max_safe := minf(seg_len * 0.42, 2300.0)
				var depth := clampf(seg_len * lerpf(0.28, 0.38, t), minf(800.0, max_safe), max_safe)
				var t_apex := _rng.randf_range(0.42, 0.58)
				out_pts.append(a.lerp(b, t_apex - 0.22) + inward_n * (depth * 0.08 * -side))
				out_ratios.append(local_ratio)
				out_pts.append(a.lerp(b, t_apex) + inward_n * (depth * side))
				out_ratios.append(local_ratio)
				out_pts.append(a.lerp(b, t_apex + 0.22) + inward_n * (depth * 0.08 * -side))
				out_ratios.append(local_ratio)
			elif seg_len >= 2100.0:
				# 2-to-3 turn S-chicane
				var max_turns := clampi(int(floor(seg_len / 1200.0)), 2, 3)
				var turns := mini(2 if t < 0.55 else 3, max_turns)
				var max_safe_amp := minf(seg_len * 0.26, 1750.0)
				var amp := clampf(seg_len * lerpf(0.16, 0.24, t), minf(620.0, max_safe_amp), max_safe_amp)
				for k in range(turns):
					var frac := float(k + 1) / float(turns + 1)
					var local_amp := amp * _rng.randf_range(0.85, 1.15)
					out_pts.append(a.lerp(b, clampf(frac + _rng.randf_range(-0.025, 0.025), 0.16, 0.84)) + inward_n * (local_amp * side))
					out_ratios.append(local_ratio)
					side = -side
			else:
				# Short-span sharp corner kick
				var depth := seg_len * lerpf(0.24, 0.34, t)
				out_pts.append(a.lerp(b, _rng.randf_range(0.40, 0.60)) + inward_n * (depth * side))
				out_ratios.append(local_ratio)

		else:
			# High-curviness hairpin / switchback cluster (0.74..1.00)
			var t := (c - 0.74) / 0.26
			var side := 1.0 if _rng.randf() < 0.68 else -1.0
			if seg_len >= 2400.0 and _rng.randf() < 0.50:
				# Deep sharp hairpin pocket
				var max_safe := minf(seg_len * 0.46, 2500.0)
				var depth := clampf(seg_len * lerpf(0.35, 0.45, t), minf(900.0, max_safe), max_safe)
				var shoulder := depth * _rng.randf_range(0.04, 0.12) * -side
				var t_apex := _rng.randf_range(0.44, 0.56)
				out_pts.append(a.lerp(b, t_apex - 0.23) + inward_n * shoulder)
				out_ratios.append(local_ratio)
				out_pts.append(a.lerp(b, t_apex) + inward_n * (depth * side))
				out_ratios.append(local_ratio)
				out_pts.append(a.lerp(b, t_apex + 0.23) + inward_n * shoulder)
				out_ratios.append(local_ratio)
			elif seg_len >= 2100.0:
				# Tight 2-to-4 turn switchback Esses
				var max_turns := clampi(int(floor(seg_len / 1200.0)), 2, 4)
				var desired_turns := 3 if t < 0.5 else 4
				var turns := mini(desired_turns, max_turns)
				var max_safe_amp := minf(seg_len * 0.28, 1800.0)
				var amp := clampf(seg_len * lerpf(0.21, 0.27, t), minf(680.0, max_safe_amp), max_safe_amp)
				for k in range(turns):
					var frac := float(k + 1) / float(turns + 1)
					var local_amp := amp * _rng.randf_range(0.88, 1.12)
					out_pts.append(a.lerp(b, clampf(frac + _rng.randf_range(-0.02, 0.02), 0.16, 0.84)) + inward_n * (local_amp * side))
					out_ratios.append(local_ratio)
					side = -side
			else:
				# Compact hairpin apex on shorter span
				var depth := seg_len * lerpf(0.32, 0.42, t)
				out_pts.append(a.lerp(b, _rng.randf_range(0.42, 0.58)) + inward_n * (depth * side))
				out_ratios.append(local_ratio)

	out_pts = _relax_control_points(out_pts, 1220.0, 16)
	return {
		"points": out_pts,
		"handle_ratio": 0.27,
		"handle_ratios": out_ratios,
	}


func _build_convex_hull_base(width_px: float, height_px: float, scatter_count: int, min_edge_px: float) -> Array[Vector2]:
	var rot := _rng.randf_range(0.0, TAU)
	var cos_r := cos(rot)
	var sin_r := sin(rot)
	var raw := PackedVector2Array()

	for _i in range(scatter_count):
		# Uniform scatter inside an ellipse so hull corners are varied and organic
		var theta := _rng.randf_range(0.0, TAU)
		var rad := sqrt(_rng.randf_range(0.15, 1.0))
		var lx := cos(theta) * rad * width_px * 0.5
		var ly := sin(theta) * rad * height_px * 0.5
		raw.append(Vector2(lx * cos_r - ly * sin_r, lx * sin_r + ly * cos_r))

	var hull_packed := Geometry2D.convex_hull(raw)
	var pts: Array[Vector2] = []
	for p in hull_packed:
		pts.append(p)
	if pts.size() > 1 and pts[0].is_equal_approx(pts[pts.size() - 1]):
		pts.pop_back()

	# Merge overly short hull edges so the silhouette starts bold and clean
	var merged := true
	while merged and pts.size() > 5:
		merged = false
		for i in pts.size():
			var next_i := (i + 1) % pts.size()
			if pts[i].distance_to(pts[next_i]) < min_edge_px:
				pts[i] = (pts[i] + pts[next_i]) * 0.5
				pts.remove_at(next_i)
				merged = true
				break

	# Re-center around origin
	if not pts.is_empty():
		var centroid := Vector2.ZERO
		for p in pts:
			centroid += p
		centroid /= float(pts.size())
		for i in pts.size():
			pts[i] -= centroid

	return pts


## Carves race-track features perpendicular to existing edges of `poly`:
## - `hairpin_count`: deep U/V hairpin pockets carved perpendicular to long edges
## - `esses_count`: alternating left-right S-bend / Esses complexes along edges
## - `sweeper_count`: gentle single-midpoint corner bends
## - `keep_longest_straight`: preserves the single longest edge intact as a fast straightaway
func _carve_track_edges(
	poly: Array[Vector2],
	hairpin_count: int,
	esses_count: int,
	sweeper_count: int,
	min_carve_len: float,
	keep_longest_straight: bool = false,
	esses_turns: int = 2,
	depth_scale: float = 1.0
) -> Array[Vector2]:
	var n := poly.size()
	if n < 3:
		return poly

	var signed_area := _compute_signed_area(poly)
	# Consistent inward normal for each edge (a -> b)
	var inward_sign := -1.0 if signed_area >= 0.0 else 1.0

	# Rank edges by length (longest first)
	var edge_indices: Array[int] = []
	var edge_lengths: Array[float] = []
	edge_lengths.resize(n)
	for i in n:
		edge_indices.append(i)
		edge_lengths[i] = poly[i].distance_to(poly[(i + 1) % n])

	edge_indices.sort_custom(func(a: int, b: int) -> bool: return edge_lengths[a] > edge_lengths[b])

	# Assign feature roles per edge: 0 = intact straight, 1 = hairpin pocket, 2 = esses/chicane, 3 = sweeper
	var edge_roles: Array[int] = []
	edge_roles.resize(n)
	edge_roles.fill(0)

	var cursor := 0
	if keep_longest_straight and edge_indices.size() > 3:
		# Reserve the single longest edge as an unmistakable flip-and-burn straightaway
		cursor = 1

	var rem_hairpins := hairpin_count
	var rem_esses := esses_count
	var rem_sweepers := sweeper_count

	# Shuffle candidate order slightly among qualifying long edges for organic variety
	var candidates: Array[int] = []
	for k in range(cursor, edge_indices.size()):
		var ei := edge_indices[k]
		if edge_lengths[ei] >= min_carve_len:
			candidates.append(ei)

	# Assign hairpins & esses to the longest qualifying edges first, then sweepers
	for ei in candidates:
		if rem_hairpins > 0 and rem_esses > 0:
			if _rng.randf() < 0.5:
				edge_roles[ei] = 1
				rem_hairpins -= 1
			else:
				edge_roles[ei] = 2
				rem_esses -= 1
		elif rem_hairpins > 0:
			edge_roles[ei] = 1
			rem_hairpins -= 1
		elif rem_esses > 0:
			edge_roles[ei] = 2
			rem_esses -= 1
		elif rem_sweepers > 0:
			edge_roles[ei] = 3
			rem_sweepers -= 1

	var out: Array[Vector2] = []
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		out.append(a)

		var role := edge_roles[i]
		if role == 0:
			continue

		var seg := b - a
		var seg_len := seg.length()
		if seg_len < min_carve_len:
			continue
		var dir := seg / seg_len
		var inward_n := Vector2(dir.y, -dir.x) * inward_sign

		if role == 1:
			# Hairpin Pocket: entry shoulder -> deep perpendicular apex -> exit shoulder
			# Bias inward (70%) so pockets carve cleanly into the circuit silhouette
			var side := 1.0 if _rng.randf() < 0.70 else -1.0
			var max_safe_depth := minf(seg_len * 0.48, 2600.0)
			var depth := clampf(seg_len * _rng.randf_range(0.34, 0.46) * depth_scale, minf(850.0, max_safe_depth), max_safe_depth)
			var shoulder := depth * _rng.randf_range(0.04, 0.14) * -side
			var t_apex := _rng.randf_range(0.44, 0.56)
			out.append(a.lerp(b, t_apex - 0.22) + inward_n * shoulder)
			out.append(a.lerp(b, t_apex) + inward_n * (depth * side))
			out.append(a.lerp(b, t_apex + 0.22) + inward_n * shoulder)

		elif role == 2:
			# S-Bend / Esses Complex: alternating perpendicular bends flowing along the edge
			var max_turns := clampi(int(floor(seg_len / 1200.0)), 2, 4)
			var turns := mini(esses_turns, max_turns)
			var side := 1.0 if _rng.randf() >= 0.5 else -1.0
			var max_safe_amp := minf(seg_len * 0.30, 1850.0)
			var amp := clampf(seg_len * _rng.randf_range(0.18, 0.27) * depth_scale, minf(680.0, max_safe_amp), max_safe_amp)
			for k in range(turns):
				var frac := float(k + 1) / float(turns + 1)
				var jitter_t := _rng.randf_range(-0.025, 0.025)
				var local_amp := amp * _rng.randf_range(0.85, 1.15)
				out.append(a.lerp(b, clampf(frac + jitter_t, 0.14, 0.86)) + inward_n * (local_amp * side))
				side = -side

		elif role == 3:
			# Gentle Sweeper: single perpendicular push
			var side := 1.0 if _rng.randf() < 0.65 else -1.0
			var max_safe_depth := minf(seg_len * 0.38, 2200.0)
			var depth := clampf(seg_len * _rng.randf_range(0.16, 0.28) * depth_scale, minf(500.0, max_safe_depth), max_safe_depth)
			var t_mid := _rng.randf_range(0.38, 0.62)
			out.append(a.lerp(b, t_mid) + inward_n * (depth * side))

	return out


func _relax_control_points(pts: Array[Vector2], min_dist: float, passes: int) -> Array[Vector2]:
	var n := pts.size()
	if n < 4:
		return pts
	var work := pts.duplicate()
	var min_seg_dist := min_dist * 0.88

	for _pass in range(passes):
		# 1. Pairwise vertex separation
		for i in n:
			for j in range(i + 1, n):
				var delta: Vector2 = work[j] - work[i]
				var d := delta.length()
				if d < min_dist and d > 0.001:
					var push := (delta / d) * ((min_dist - d) * 0.35)
					work[i] -= push
					work[j] += push

		# 2. Non-adjacent vertex-to-segment clearance (prevents opposite walls pinching)
		for i in n:
			var p: Vector2 = work[i]
			for j in n:
				var j_next := (j + 1) % n
				if i == j or i == j_next:
					continue
				var a: Vector2 = work[j]
				var b: Vector2 = work[j_next]
				var closest := Geometry2D.get_closest_point_to_segment(p, a, b)
				var diff := p - closest
				var d := diff.length()
				if d < min_seg_dist and d > 0.001:
					var push := (diff / d) * ((min_seg_dist - d) * 0.40)
					work[i] += push
					work[j] -= push * 0.25
					work[j_next] -= push * 0.25

	return work


func _try_build_geometry(t_type: TrackType = TrackType.TYPE_1) -> bool:
	# 1. Place control pegs according to active track archetype
	var built_ctrl := _build_control_points_for_type(t_type)
	var control_pts: Array[Vector2] = built_ctrl["points"]
	var handle_ratio: float = built_ctrl["handle_ratio"]
	var handle_ratios: PackedFloat32Array = built_ctrl.get("handle_ratios", PackedFloat32Array())
	var use_per_pt_ratio := handle_ratios.size() == control_pts.size()
	var n := control_pts.size()
	if n < 5:
		return false

	# 2. Build closed Catmull-Rom spline via Curve2D with distance-clamped handles
	#    (prevents Bezier overshoot loops on asymmetric straight-into-hairpin transitions)
	var curve := Curve2D.new()
	for i in n:
		var prev_pt := control_pts[(i - 1 + n) % n]
		var curr_pt := control_pts[i]
		var next_pt := control_pts[(i + 1) % n]
		var chord := next_pt - prev_pt
		var dir := chord.normalized() if chord.length_squared() > 1e-6 else Vector2.RIGHT
		var r_i := handle_ratios[i] if use_per_pt_ratio else handle_ratio
		var in_len := curr_pt.distance_to(prev_pt) * r_i
		var out_len := curr_pt.distance_to(next_pt) * r_i
		curve.add_point(curr_pt, -dir * in_len, dir * out_len)
	# Close loop by repeating point 0 with matching clamped handles
	var first_chord := control_pts[1] - control_pts[n - 1]
	var first_dir := first_chord.normalized() if first_chord.length_squared() > 1e-6 else Vector2.RIGHT
	var r_0 := handle_ratios[0] if use_per_pt_ratio else handle_ratio
	var first_in := control_pts[0].distance_to(control_pts[n - 1]) * r_0
	var first_out := control_pts[0].distance_to(control_pts[1]) * r_0
	curve.add_point(control_pts[0], -first_dir * first_in, first_dir * first_out)

	var raw_len := curve.get_baked_length()
	if raw_len < track_width * 4.0:
		return false

	# 3. Sample evenly along arc length
	var sample_count := maxi(int(round(raw_len / maxf(sample_spacing, 30.0))), 48)
	var sampled: Array[Vector2] = []
	for i in sample_count:
		var dist := (float(i) / float(sample_count)) * raw_len
		sampled.append(curve.sample_baked(dist))

	# 4. Anti-pinch curvature smoothing pass: ensure minimum bend radius > track_width * 0.80
	#    Scale pass budget with sample_spacing so tight hairpins smooth cleanly at finer resolution.
	var min_bend_radius := track_width * 0.80
	var smooth_passes := clampi(int(round(32.0 * pow(120.0 / maxf(sample_spacing, 30.0), 1.5))), 32, 110)
	for _pass in range(smooth_passes):
		var any_tight := false
		var next_sampled := sampled.duplicate()
		for i in sample_count:
			var prev_i := (i - 1 + sample_count) % sample_count
			var next_i := (i + 1) % sample_count
			var a := sampled[prev_i]
			var b := sampled[i]
			var c := sampled[next_i]
			var bend_r := _estimate_bend_radius(a, b, c)
			if bend_r < min_bend_radius:
				any_tight = true
				next_sampled[i] = b.lerp((a + c) * 0.5, 0.38)
		sampled = next_sampled
		if not any_tight:
			break

	# 5. Compute outer & inner wall offset loops
	var signed_area := _compute_signed_area(sampled)
	# Ensure consistent outward normal regardless of loop winding
	var normal_sign := 1.0 if signed_area >= 0.0 else -1.0
	var half_w := track_width * 0.5

	var center := PackedVector2Array()
	var outer := PackedVector2Array()
	var inner := PackedVector2Array()
	var length_acc := 0.0

	for i in sample_count:
		var prev_pt := sampled[(i - 1 + sample_count) % sample_count]
		var curr_pt := sampled[i]
		var next_pt := sampled[(i + 1) % sample_count]
		length_acc += curr_pt.distance_to(next_pt)

		var tangent := (next_pt - prev_pt).normalized()
		var outward := Vector2(tangent.y, -tangent.x) * normal_sign

		center.append(curr_pt)
		outer.append(curr_pt + outward * half_w)
		inner.append(curr_pt - outward * half_w)

	# 6. Verify neither wall self-intersects and walls never cross each other
	if _loop_self_intersects(outer) or _loop_self_intersects(inner) or _loops_intersect(outer, inner):
		return false

	centerline_points = center
	outer_points = outer
	inner_points = inner
	track_length_px = length_acc
	return true


func _build_fallback_geometry() -> void:
	var sample_count := 96
	var half_w := track_width * 0.5
	var center := PackedVector2Array()
	var outer := PackedVector2Array()
	var inner := PackedVector2Array()
	var length_acc := 0.0

	for i in sample_count:
		var theta := (float(i) / float(sample_count)) * TAU
		var pt := Vector2(cos(theta) * base_radius, sin(theta) * base_radius * 0.78)
		center.append(pt)

	for i in sample_count:
		var prev_pt := center[(i - 1 + sample_count) % sample_count]
		var curr_pt := center[i]
		var next_pt := center[(i + 1) % sample_count]
		length_acc += curr_pt.distance_to(next_pt)
		var tangent := (next_pt - prev_pt).normalized()
		var outward := Vector2(tangent.y, -tangent.x)
		outer.append(curr_pt + outward * half_w)
		inner.append(curr_pt - outward * half_w)

	centerline_points = center
	outer_points = outer
	inner_points = inner
	track_length_px = length_acc


func _estimate_bend_radius(a: Vector2, b: Vector2, c: Vector2) -> float:
	var ab := b - a
	var bc := c - b
	var ac := c - a
	var area2 := absf(ab.cross(ac))
	if area2 < 0.001:
		return INF
	# Circumradius R = (|ab| * |bc| * |ac|) / (2 * |ab x ac|)
	return (ab.length() * bc.length() * ac.length()) / (2.0 * area2)


func _compute_signed_area(pts: Array[Vector2]) -> float:
	var area := 0.0
	var count := pts.size()
	for i in count:
		var a := pts[i]
		var b := pts[(i + 1) % count]
		area += a.x * b.y - b.x * a.y
	return area * 0.5


func _build_segment_grid(pts: PackedVector2Array, cell_size: float) -> Dictionary:
	var grid: Dictionary = {}
	var n := pts.size()
	var inv := 1.0 / maxf(cell_size, 1.0)
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var min_cx := int(floor(minf(a.x, b.x) * inv))
		var max_cx := int(floor(maxf(a.x, b.x) * inv))
		var min_cy := int(floor(minf(a.y, b.y) * inv))
		var max_cy := int(floor(maxf(a.y, b.y) * inv))
		for cx in range(min_cx, max_cx + 1):
			for cy in range(min_cy, max_cy + 1):
				var key := Vector2i(cx, cy)
				if not grid.has(key):
					grid[key] = PackedInt32Array([i])
				else:
					var bucket: PackedInt32Array = grid[key]
					bucket.append(i)
					grid[key] = bucket
	return grid


func _loop_self_intersects(pts: PackedVector2Array) -> bool:
	var n := pts.size()
	if n < 4:
		return false
	var grid := _build_segment_grid(pts, 480.0)
	for bucket: PackedInt32Array in grid.values():
		var m := bucket.size()
		if m < 2:
			continue
		for bi in m:
			var i := bucket[bi]
			var a1 := pts[i]
			var a2 := pts[(i + 1) % n]
			var a_min_x := minf(a1.x, a2.x)
			var a_max_x := maxf(a1.x, a2.x)
			var a_min_y := minf(a1.y, a2.y)
			var a_max_y := maxf(a1.y, a2.y)
			for bj in range(bi + 1, m):
				var j := bucket[bj]
				var diff := absi(i - j)
				if diff <= 1 or diff == n - 1:
					continue
				var b1 := pts[j]
				var b2 := pts[(j + 1) % n]
				if maxf(b1.x, b2.x) < a_min_x or minf(b1.x, b2.x) > a_max_x:
					continue
				if maxf(b1.y, b2.y) < a_min_y or minf(b1.y, b2.y) > a_max_y:
					continue
				if Geometry2D.segment_intersects_segment(a1, a2, b1, b2) != null:
					return true
	return false


func _loops_intersect(loop_a: PackedVector2Array, loop_b: PackedVector2Array) -> bool:
	var na := loop_a.size()
	var nb := loop_b.size()
	if na < 2 or nb < 2:
		return false
	var cell_size := 480.0
	var inv := 1.0 / cell_size
	var grid_b := _build_segment_grid(loop_b, cell_size)
	for i in na:
		var a1 := loop_a[i]
		var a2 := loop_a[(i + 1) % na]
		var a_min_x := minf(a1.x, a2.x)
		var a_max_x := maxf(a1.x, a2.x)
		var a_min_y := minf(a1.y, a2.y)
		var a_max_y := maxf(a1.y, a2.y)
		var min_cx := int(floor(a_min_x * inv))
		var max_cx := int(floor(a_max_x * inv))
		var min_cy := int(floor(a_min_y * inv))
		var max_cy := int(floor(a_max_y * inv))
		for cx in range(min_cx, max_cx + 1):
			for cy in range(min_cy, max_cy + 1):
				var key := Vector2i(cx, cy)
				if not grid_b.has(key):
					continue
				var bucket: PackedInt32Array = grid_b[key]
				for j in bucket:
					var b1 := loop_b[j]
					var b2 := loop_b[(j + 1) % nb]
					if maxf(b1.x, b2.x) < a_min_x or minf(b1.x, b2.x) > a_max_x:
						continue
					if maxf(b1.y, b2.y) < a_min_y or minf(b1.y, b2.y) > a_max_y:
						continue
					if Geometry2D.segment_intersects_segment(a1, a2, b1, b2) != null:
						return true
	return false


func _ensure_holo_visual_nodes() -> void:
	if _surface_mesh == null:
		_surface_mesh = MeshInstance2D.new()
		_surface_mesh.name = "HoloSurfaceMesh"
		_surface_mesh.z_index = -20
		add_child(_surface_mesh)

	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD

	if _outer_bloom == null:
		_outer_bloom = _make_glow_line("OuterWallBloom", -15, add_mat)
	if _inner_bloom == null:
		_inner_bloom = _make_glow_line("InnerWallBloom", -15, add_mat)
	if _outer_glow == null:
		_outer_glow = _make_glow_line("OuterWallGlow", -12, add_mat)
	if _inner_glow == null:
		_inner_glow = _make_glow_line("InnerWallGlow", -12, add_mat)

	if _holo_overlay == null:
		var overlay_script := load("res://track_holo_overlay.gd") as Script
		_holo_overlay = Node2D.new()
		_holo_overlay.name = "HoloDetailOverlay"
		_holo_overlay.z_index = -7
		if overlay_script != null:
			_holo_overlay.set_script(overlay_script)
		add_child(_holo_overlay)


func _make_glow_line(node_name: String, z_idx: int, mat: Material) -> Line2D:
	var ln := Line2D.new()
	ln.name = node_name
	ln.closed = true
	ln.joint_mode = Line2D.LINE_JOINT_ROUND
	ln.antialiased = true
	ln.z_index = z_idx
	ln.material = mat
	add_child(ln)
	return ln


func _smoothstep_range(edge0: float, edge1: float, x: float) -> float:
	if absf(edge1 - edge0) < 1e-6:
		return 1.0 if x >= edge1 else 0.0
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


# Smooth continuous Blue (0.0) <-> Soft Amber (1.0) spectrum.
# Moves quickly past the perceptual blue dead-zone right off the midpoint (u=0.0->0.16),
# then progresses evenly through pale sky-blue -> warm sand -> light amber -> soft amber,
# preserving smooth brightness and alpha across bloom, glow, core rail, and surface edges.
func _eval_pacing_color(blue_col: Color, amber_col: Color, amber_t: float) -> Color:
	var u := clampf(amber_t, 0.0, 1.0)
	if u <= 0.0001:
		return blue_col
	if u >= 0.9999:
		return amber_col

	var target_v := lerpf(blue_col.v, amber_col.v, u)
	var target_a := lerpf(blue_col.a, amber_col.a, u)

	var c1 := Color(0.50, 0.82, 0.96, target_a)
	var c2 := Color(0.86, 0.80, 0.66, target_a)
	var c3 := Color(0.90, 0.68, 0.44, target_a)

	var out_col: Color
	if u < 0.16:
		var k := u / 0.16
		var c1_scaled := Color(c1.r, c1.g, c1.b, target_a)
		c1_scaled.v = lerpf(blue_col.v, amber_col.v, 0.16)
		out_col = blue_col.lerp(c1_scaled, k)
	elif u < 0.45:
		var k := (u - 0.16) / 0.29
		var a_col := c1
		a_col.v = lerpf(blue_col.v, amber_col.v, 0.16)
		var b_col := c2
		b_col.v = lerpf(blue_col.v, amber_col.v, 0.45)
		out_col = a_col.lerp(b_col, k)
	elif u < 0.75:
		var k := (u - 0.45) / 0.30
		var a_col := c2
		a_col.v = lerpf(blue_col.v, amber_col.v, 0.45)
		var b_col := c3
		b_col.v = lerpf(blue_col.v, amber_col.v, 0.75)
		out_col = a_col.lerp(b_col, k)
	else:
		var k := (u - 0.75) / 0.25
		var a_col := c3
		a_col.v = lerpf(blue_col.v, amber_col.v, 0.75)
		out_col = a_col.lerp(amber_col, k)

	out_col.v = target_v
	out_col.a = target_a
	return out_col


# Statically bakes the 2-color Blue <-> Orange pacing gradient around the closed loop:
#   - 1.0 (Full Orange): Inside slow turns where the ship must be moving slowly.
#   - 1.0 -> 0.0 fade:   Coming out of a turn, orange fades smoothly toward blue,
#                        reaching 0.0 (Peak Blue) ONLY at the exact flip-and-burn midpoint
#                        where the forward acceleration pass meets the backward braking pass.
#   - 0.0 -> 1.0 fade:   Past the midpoint, blue fades smoothly back into full Orange
#                        entering the next turn.
# Short straights flash quickly Orange -> Peak Blue -> Orange; long straights fade
# gradually so the player reads straight length and flip timing right off the track.
func _compute_pacing_zones() -> void:
	var n := centerline_points.size()
	pacing_brake = PackedFloat32Array()
	pacing_outer_amber = PackedFloat32Array()
	pacing_inner_amber = PackedFloat32Array()
	if n < 3:
		return

	pacing_brake.resize(n)
	pacing_outer_amber.resize(n)
	pacing_inner_amber.resize(n)

	# 1. Smoothed local curvature kappa = 1 / R and signed inside-wall direction along the loop
	var kappa := PackedFloat32Array()
	var signed_inside := PackedFloat32Array() # > 0 => outer_points is the inside apex; < 0 => inner_points is inside
	kappa.resize(n)
	signed_inside.resize(n)
	for i in n:
		var prev_pt := centerline_points[(i - 1 + n) % n]
		var curr_pt := centerline_points[i]
		var next_pt := centerline_points[(i + 1) % n]
		var r := _estimate_bend_radius(prev_pt, curr_pt, next_pt)
		kappa[i] = 1.0 / maxf(r, 80.0)
		var d_in := (curr_pt - prev_pt).normalized()
		var d_out := (next_pt - curr_pt).normalized()
		var turn_inward := d_out - d_in
		var to_outer := (outer_points[i] - curr_pt).normalized()
		signed_inside[i] = to_outer.dot(turn_inward)

	for _pass in range(4):
		var next_k := PackedFloat32Array()
		var next_s := PackedFloat32Array()
		next_k.resize(n)
		next_s.resize(n)
		for i in n:
			var pi := (i - 1 + n) % n
			var ni := (i + 1) % n
			next_k[i] = kappa[pi] * 0.25 + kappa[i] * 0.5 + kappa[ni] * 0.25
			next_s[i] = signed_inside[pi] * 0.25 + signed_inside[i] * 0.5 + signed_inside[ni] * 0.25
		kappa = next_k
		signed_inside = next_s

	# 2. Forward acceleration pass & backward braking pass -> exact v_opt speed profile
	var a_accel := maxf(pacing_ref_accel_px, 100.0)
	var a_lat := a_accel * 0.72
	# 0.80 * a_accel places the flip-and-burn peak right around ~45% down a straight
	var a_brake := a_accel * 0.80
	var v_cap := 2400.0

	var v_corner := PackedFloat32Array()
	v_corner.resize(n)
	var min_radius := INF
	for i in n:
		var r_s := 1.0 / maxf(kappa[i], 1e-6)
		min_radius = minf(min_radius, r_s)
		v_corner[i] = minf(sqrt(a_lat * r_s), v_cap)

	var seg_len := PackedFloat32Array()
	seg_len.resize(n)
	for i in n:
		seg_len[i] = centerline_points[i].distance_to(centerline_points[(i + 1) % n])

	var v_accel := v_corner.duplicate()
	for step in range(n * 2):
		var i := step % n
		var ni := (i + 1) % n
		var v_next := sqrt(v_accel[i] * v_accel[i] + 2.0 * a_accel * seg_len[i])
		if v_next < v_accel[ni]:
			v_accel[ni] = v_next

	var v_brake := v_corner.duplicate()
	for step in range(n * 2):
		var ni := (n * 2 - 1 - step) % n
		var i := (ni - 1 + n) % n
		var v_prev := sqrt(v_brake[ni] * v_brake[ni] + 2.0 * a_brake * seg_len[i])
		if v_prev < v_brake[i]:
			v_brake[i] = v_prev

	var v_opt := PackedFloat32Array()
	v_opt.resize(n)
	for i in n:
		v_opt[i] = minf(v_accel[i], v_brake[i])

	# 3. Identify slow turn zones (full Orange) around the closed loop.
	# If a Speedway has no tight corners below corner_warn_radius_px, adapt threshold
	# gently to its tightest bends so even Speedways show clean corner-to-midpoint pacing.
	var turn_r := maxf(corner_warn_radius_px, track_width * 1.4)
	var is_turn := PackedByteArray()
	is_turn.resize(n)
	var turn_count := 0
	for i in n:
		var r_s := 1.0 / maxf(kappa[i], 1e-6)
		if r_s < turn_r:
			is_turn[i] = 1
			turn_count += 1
		else:
			is_turn[i] = 0

	var turn_orange_level := 1.0
	if turn_count == 0:
		var adaptive_r := clampf(min_radius * 1.35, turn_r, 1850.0)
		turn_orange_level = clampf(_smoothstep_range(2100.0, 950.0, min_radius), 0.55, 1.0)
		for i in n:
			var r_s := 1.0 / maxf(kappa[i], 1e-6)
			if r_s < adaptive_r:
				is_turn[i] = 1
				turn_count += 1

	# Edge case: completely circular / all-turn loop -> map directly from global v_opt range
	if turn_count == 0 or turn_count == n:
		var v_lo := INF
		var v_hi := 0.0
		for i in n:
			v_lo = minf(v_lo, v_opt[i])
			v_hi = maxf(v_hi, v_opt[i])
		var v_span := maxf(v_hi - v_lo, 1.0)
		for i in n:
			var lv := clampf(1.0 - (v_opt[i] - v_lo) / v_span, 0.0, 1.0) * turn_orange_level
			pacing_brake[i] = lv
			if signed_inside[i] >= 0.0:
				pacing_outer_amber[i] = lv
				pacing_inner_amber[i] = 0.0
			else:
				pacing_outer_amber[i] = 0.0
				pacing_inner_amber[i] = lv
		return

	# 4. Merge tiny gaps (< 180 px) between adjacent turns (e.g. tight S-bends) so they stay Orange
	var first_turn := -1
	for i in n:
		if is_turn[i] == 1:
			first_turn = i
			break

	var cur_idx := first_turn
	var visited := 0
	while visited < n:
		if is_turn[cur_idx] == 1:
			cur_idx = (cur_idx + 1) % n
			visited += 1
			continue
		var gap_start := cur_idx
		var gap_dist := 0.0
		var gap_len := 0
		while visited < n and is_turn[cur_idx] == 0:
			gap_dist += seg_len[cur_idx]
			cur_idx = (cur_idx + 1) % n
			gap_len += 1
			visited += 1
		if gap_dist < 180.0:
			for k in gap_len:
				is_turn[(gap_start + k) % n] = 1

	# 5. Fill directional inside-edge amber arrays:
	#   - Inside slow turns: ONLY the inside edge (apex side) is 100% Amber; outside stays Blue.
	#   - First half of straight (Turn A exit -> Midpoint Peak): Turn A's inside edge fades Amber -> Blue.
	#   - At Midpoint Peak: BOTH edges hit 100% Pure Blue (flip-and-burn cue).
	#   - Second half of straight (Midpoint Peak -> Turn B entry): Turn B's inside edge fades Blue -> Amber,
	#     telegraphing both braking timing AND upcoming turn direction (Left vs Right)!
	for i in n:
		if is_turn[i] == 1:
			pacing_brake[i] = turn_orange_level
			if signed_inside[i] >= 0.0:
				pacing_outer_amber[i] = turn_orange_level
				pacing_inner_amber[i] = 0.0
			else:
				pacing_outer_amber[i] = 0.0
				pacing_inner_amber[i] = turn_orange_level
		else:
			pacing_brake[i] = 0.0
			pacing_outer_amber[i] = 0.0
			pacing_inner_amber[i] = 0.0

	first_turn = -1
	for i in n:
		if is_turn[i] == 1:
			first_turn = i
			break
	if first_turn == -1:
		return

	cur_idx = first_turn
	visited = 0
	while visited < n:
		if is_turn[cur_idx] == 1:
			cur_idx = (cur_idx + 1) % n
			visited += 1
			continue

		# Collect contiguous non-turn span (straight / connecting section between two turns)
		var span_indices: PackedInt32Array = PackedInt32Array()
		var span_cum_d: PackedFloat32Array = PackedFloat32Array()
		var d_acc := 0.0
		while visited < n and is_turn[cur_idx] == 0:
			span_indices.append(cur_idx)
			span_cum_d.append(d_acc)
			d_acc += seg_len[cur_idx]
			cur_idx = (cur_idx + 1) % n
			visited += 1

		var m := span_indices.size()
		if m == 0:
			continue

		# Determine exit turn's inside wall (Turn A) and upcoming turn's inside wall (Turn B)
		var exit_dir_sum := 0.0
		for step_back in range(1, 5):
			var ti := (span_indices[0] - step_back + n) % n
			if is_turn[ti] == 1 or step_back == 1:
				exit_dir_sum += signed_inside[ti]
		var exit_is_outer := exit_dir_sum >= 0.0

		var entry_dir_sum := 0.0
		for step_fwd in range(1, 5):
			var ti := (span_indices[m - 1] + step_fwd) % n
			if is_turn[ti] == 1 or step_fwd == 1:
				entry_dir_sum += signed_inside[ti]
		var entry_is_outer := entry_dir_sum >= 0.0

		# Find exact physics flip-and-burn midpoint peak (max v_opt inside this span)
		var peak_k := 0
		var peak_v := -1.0
		for k in m:
			var v_here := v_opt[span_indices[k]]
			if v_here > peak_v:
				peak_v = v_here
				peak_k = k

		if m >= 3:
			peak_k = clampi(peak_k, 1, m - 2)

		var lead_seg := seg_len[(span_indices[0] - 1 + n) % n]
		var d_peak := lead_seg + span_cum_d[peak_k]
		var d_exit := maxf(d_peak, 1.0)
		var d_total := maxf(lead_seg + d_acc, 1.0)
		var d_rem := maxf(d_total - d_peak, 1.0)

		for k in m:
			var vi := span_indices[k]
			var d_from_turn := lead_seg + span_cum_d[k]
			if k <= peak_k:
				# First half: Turn A's inside edge fades Amber (1.0) -> Pure Blue (0.0) at midpoint
				var u := clampf(d_from_turn / d_exit, 0.0, 1.0)
				var lv := (1.0 - u) * turn_orange_level
				pacing_brake[vi] = lv
				if exit_is_outer:
					pacing_outer_amber[vi] = lv
					pacing_inner_amber[vi] = 0.0
				else:
					pacing_outer_amber[vi] = 0.0
					pacing_inner_amber[vi] = lv
			else:
				# Second half: Turn B's inside edge fades Pure Blue (0.0) -> Amber (1.0) into Turn B
				var u := clampf((d_from_turn - d_peak) / d_rem, 0.0, 1.0)
				var lv := u * turn_orange_level
				pacing_brake[vi] = lv
				if entry_is_outer:
					pacing_outer_amber[vi] = lv
					pacing_inner_amber[vi] = 0.0
				else:
					pacing_outer_amber[vi] = 0.0
					pacing_inner_amber[vi] = lv

	# 6. Light 1-pass smoothing per edge so boundaries and S-bend side-swaps flow seamlessly
	var sm_b := PackedFloat32Array()
	var sm_o := PackedFloat32Array()
	var sm_i := PackedFloat32Array()
	sm_b.resize(n)
	sm_o.resize(n)
	sm_i.resize(n)
	for i in n:
		var pi := (i - 1 + n) % n
		var ni := (i + 1) % n
		sm_b[i] = pacing_brake[pi] * 0.2 + pacing_brake[i] * 0.6 + pacing_brake[ni] * 0.2
		sm_o[i] = pacing_outer_amber[pi] * 0.2 + pacing_outer_amber[i] * 0.6 + pacing_outer_amber[ni] * 0.2
		sm_i[i] = pacing_inner_amber[pi] * 0.2 + pacing_inner_amber[i] * 0.6 + pacing_inner_amber[ni] * 0.2
	pacing_brake = sm_b
	pacing_outer_amber = sm_o
	pacing_inner_amber = sm_i


func _build_wall_gradient(
	wall_pts: PackedVector2Array,
	wall_amber: PackedFloat32Array,
	accel_col: Color,
	brake_col: Color,
	warn_vals: PackedFloat32Array,
	warn_boost_col: Color
) -> Gradient:
	var n := wall_pts.size()
	if n < 3 or wall_amber.size() != n:
		return null

	var cum := PackedFloat32Array()
	cum.resize(n + 1)
	cum[0] = 0.0
	for i in n:
		cum[i + 1] = cum[i] + wall_pts[i].distance_to(wall_pts[(i + 1) % n])
	var total_len := maxf(cum[n], 1.0)

	var stop_count := mini(n, 160)
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	offsets.resize(stop_count + 1)
	colors.resize(stop_count + 1)

	var v_idx := 0
	for s in range(stop_count):
		var frac := float(s) / float(stop_count)
		var target_d := frac * total_len
		while v_idx + 1 < n and cum[v_idx + 1] < target_d:
			v_idx += 1
		var ni := (v_idx + 1) % n
		var seg_d := maxf(cum[v_idx + 1] - cum[v_idx], 0.0001)
		var t := clampf((target_d - cum[v_idx]) / seg_d, 0.0, 1.0)
		var bw := lerpf(wall_amber[v_idx], wall_amber[ni], t)
		var col := _eval_pacing_color(accel_col, brake_col, bw)
		if warn_vals.size() == n:
			var ww := lerpf(warn_vals[v_idx], warn_vals[ni], t)
			col = col.lerp(warn_boost_col, ww * 0.5)
		offsets[s] = frac
		colors[s] = col

	offsets[stop_count] = 1.0
	colors[stop_count] = colors[0]

	var grad := Gradient.new()
	grad.offsets = offsets
	grad.colors = colors
	return grad


func _apply_visuals() -> void:
	_ensure_holo_visual_nodes()

	var n := centerline_points.size()
	if n < 3 or outer_points.size() != n or inner_points.size() != n:
		return

	# 0. Compute 2-pass static Newtonian pacing ribbon (Cyan-Blue <-> Amber)
	_compute_pacing_zones()

	# 1. Compute per-vertex INSIDE-corner apex kerb intensities (0..1) for sharp hairpins
	#    (outside wall stays crisp Blue; inside apex glows bright Light Amber!)
	var outer_warn := PackedFloat32Array()
	var inner_warn := PackedFloat32Array()
	outer_warn.resize(n)
	inner_warn.resize(n)
	var tight_r := track_width * 0.85
	var warn_r := maxf(corner_warn_radius_px, tight_r + 50.0)

	for i in n:
		var prev_pt := centerline_points[(i - 1 + n) % n]
		var curr_pt := centerline_points[i]
		var next_pt := centerline_points[(i + 1) % n]
		var r := _estimate_bend_radius(prev_pt, curr_pt, next_pt)
		if r < warn_r:
			var intensity := clampf((warn_r - r) / (warn_r - tight_r), 0.0, 1.0)
			# Smoothstep for soft organic kerb fade-in/out
			intensity = intensity * intensity * (3.0 - 2.0 * intensity)
			var d_in := (curr_pt - prev_pt).normalized()
			var d_out := (next_pt - curr_pt).normalized()
			var turn_inward := d_out - d_in
			var to_outer := outer_points[i] - curr_pt
			if to_outer.dot(turn_inward) >= 0.0:
				outer_warn[i] = intensity
				inner_warn[i] = 0.0
			else:
				outer_warn[i] = 0.0
				inner_warn[i] = intensity
		else:
			outer_warn[i] = 0.0
			inner_warn[i] = 0.0

	# Smooth warning intensities slightly along adjacent vertices so kerbs flow seamlessly
	for _pass in range(2):
		var next_ow := outer_warn.duplicate()
		var next_iw := inner_warn.duplicate()
		for i in n:
			var pi := (i - 1 + n) % n
			var ni := (i + 1) % n
			next_ow[i] = outer_warn[pi] * 0.25 + outer_warn[i] * 0.5 + outer_warn[ni] * 0.25
			next_iw[i] = inner_warn[pi] * 0.25 + inner_warn[i] * 0.5 + inner_warn[ni] * 0.25
		outer_warn = next_ow
		inner_warn = next_iw

	# 2. Build 2-color edge-faded translucent pacing ArrayMesh
	_rebuild_surface_mesh(outer_warn, inner_warn)

	# 3. Layered glowing energy barrier walls tinted along the smooth Blue <-> Soft Amber spectrum
	var bloom_accel := Color(0.06, 0.45, 0.98, 0.22)
	var bloom_brake := Color(0.86, 0.52, 0.24, 0.18)

	var glow_accel := Color(0.18, 0.78, 1.0, 0.52)
	var glow_brake := Color(0.88, 0.56, 0.28, 0.44)

	var core_accel := Color(0.56, 0.88, 1.0, 0.96)
	var core_brake := Color(0.96, 0.76, 0.54, 0.94)

	var warn_bloom := Color(0.86, 0.52, 0.24, 0.22)
	var warn_glow := Color(0.90, 0.58, 0.30, 0.48)
	var warn_core := Color(0.96, 0.78, 0.56, 0.94)

	var outer_bloom_grad := _build_wall_gradient(outer_points, pacing_outer_amber, bloom_accel, bloom_brake, outer_warn, warn_bloom)
	var inner_bloom_grad := _build_wall_gradient(inner_points, pacing_inner_amber, bloom_accel, bloom_brake, inner_warn, warn_bloom)
	var outer_glow_grad := _build_wall_gradient(outer_points, pacing_outer_amber, glow_accel, glow_brake, outer_warn, warn_glow)
	var inner_glow_grad := _build_wall_gradient(inner_points, pacing_inner_amber, glow_accel, glow_brake, inner_warn, warn_glow)
	var outer_core_grad := _build_wall_gradient(outer_points, pacing_outer_amber, core_accel, core_brake, outer_warn, warn_core)
	var inner_core_grad := _build_wall_gradient(inner_points, pacing_inner_amber, core_accel, core_brake, inner_warn, warn_core)

	for spec in [
		[_outer_bloom, outer_points, 28.0, outer_bloom_grad, bloom_accel],
		[_inner_bloom, inner_points, 28.0, inner_bloom_grad, bloom_accel],
		[_outer_glow, outer_points, 11.0, outer_glow_grad, glow_accel],
		[_inner_glow, inner_points, 11.0, inner_glow_grad, glow_accel],
	]:
		var ln: Line2D = spec[0]
		if ln != null:
			ln.closed = true
			ln.width = float(spec[2])
			ln.gradient = spec[3]
			ln.default_color = Color.WHITE if spec[3] != null else spec[4]
			ln.points = spec[1]

	if _outer_line != null:
		_outer_line.closed = true
		_outer_line.joint_mode = Line2D.LINE_JOINT_ROUND
		_outer_line.antialiased = true
		_outer_line.z_index = -9
		_outer_line.width = wall_line_width
		_outer_line.gradient = outer_core_grad
		_outer_line.default_color = Color.WHITE if outer_core_grad != null else core_accel
		_outer_line.points = outer_points
	if _inner_line != null:
		_inner_line.closed = true
		_inner_line.joint_mode = Line2D.LINE_JOINT_ROUND
		_inner_line.antialiased = true
		_inner_line.z_index = -9
		_inner_line.width = wall_line_width
		_inner_line.gradient = inner_core_grad
		_inner_line.default_color = Color.WHITE if inner_core_grad != null else core_accel
		_inner_line.points = inner_points

	# 4. Populate forward chevrons, hairpin warning kerbs, projector buoys, and Start/Finish gate
	if _holo_overlay != null and _holo_overlay.has_method("set_holo_data"):
		var chevrons := _build_holo_chevrons()
		var buoys := _build_projector_buoys(outer_warn, inner_warn)
		_holo_overlay.set_holo_data(
			centerline_points,
			outer_points,
			inner_points,
			outer_warn,
			inner_warn,
			chevrons,
			buoys,
			checkpoint_gates
		)


func set_active_checkpoint(idx: int) -> void:
	if _holo_overlay != null and _holo_overlay.has_method("set_active_checkpoint"):
		_holo_overlay.set_active_checkpoint(idx)


func _rebuild_checkpoints() -> void:
	for area in _checkpoint_areas:
		if is_instance_valid(area):
			remove_child(area)
			area.queue_free()
	_checkpoint_areas.clear()
	checkpoint_gates.clear()

	var n := centerline_points.size()
	if n < 3 or track_length_px <= 1.0:
		return

	var count := maxi(checkpoint_count, 4)
	# Intermediate checkpoints 0 .. count-1 evenly spaced along the loop
	for k in range(count):
		var arc := (float(k + 1) / float(count + 1)) * track_length_px
		_add_checkpoint_gate(k, arc, false)

	# Finish gate at index `count` (right across Start/Finish at arc = 0.0)
	_add_checkpoint_gate(count, 0.0, true)


func _add_checkpoint_gate(gate_idx: int, arc_dist: float, is_finish: bool) -> void:
	var n := centerline_points.size()
	var seg_info := _locate_arc_segment(arc_dist)
	var lo: int = seg_info["lo"]
	var hi: int = (lo + 1) % n
	var t: float = seg_info["t"]

	var p_out := outer_points[lo].lerp(outer_points[hi], t)
	var p_in := inner_points[lo].lerp(inner_points[hi], t)
	var center := (p_in + p_out) * 0.5
	var across := p_out - p_in
	var gate_width := across.length()
	var tangent := (centerline_points[hi] - centerline_points[lo]).normalized()
	if tangent.length_squared() < 0.5:
		tangent = Vector2.RIGHT

	checkpoint_gates.append({
		"index": gate_idx,
		"inner": p_in,
		"outer": p_out,
		"center": center,
		"tangent": tangent,
		"is_finish": is_finish,
	})

	var area := Area2D.new()
	area.name = "FinishGate" if is_finish else "Checkpoint_%d" % gate_idx
	area.monitoring = true
	area.monitorable = false
	area.collision_layer = 0
	area.collision_mask = 0xFFFFFFFF
	area.position = center
	area.rotation = across.angle()

	var col := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(gate_width + 60.0, maxf(checkpoint_trigger_depth, 40.0))
	col.shape = rect
	area.add_child(col)

	area.body_entered.connect(_on_checkpoint_body_entered.bind(gate_idx))
	add_child(area)
	_checkpoint_areas.append(area)


func _on_checkpoint_body_entered(body: Node2D, gate_idx: int) -> void:
	if body != null and body.name == "PlayerShip":
		checkpoint_crossed.emit(gate_idx)


func _rebuild_surface_mesh(outer_warn: PackedFloat32Array, inner_warn: PackedFloat32Array) -> void:
	if _surface_mesh == null:
		return
	var n := centerline_points.size()
	if n < 3:
		_surface_mesh.mesh = null
		return

	# 5 cross-section bands: outer edge (0.0) -> mid-outer (0.22) -> center (0.50) -> mid-inner (0.78) -> inner edge (1.0)
	const BANDS: PackedFloat32Array = [0.0, 0.22, 0.50, 0.78, 1.0]
	var strip_count := BANDS.size() - 1
	var verts := PackedVector2Array()
	var colors := PackedColorArray()
	verts.resize(n * strip_count * 6)
	colors.resize(n * strip_count * 6)

	var has_pacing := pacing_outer_amber.size() == n and pacing_inner_amber.size() == n
	var idx := 0
	for i in n:
		var ni := (i + 1) % n
		var o0 := outer_points[i]
		var i0 := inner_points[i]
		var o1 := outer_points[ni]
		var i1 := inner_points[ni]

		var bo0 := clampf(pacing_outer_amber[i], 0.0, 1.0) if has_pacing else 0.0
		var bi0 := clampf(pacing_inner_amber[i], 0.0, 1.0) if has_pacing else 0.0
		var bo1 := clampf(pacing_outer_amber[ni], 0.0, 1.0) if has_pacing else 0.0
		var bi1 := clampf(pacing_inner_amber[ni], 0.0, 1.0) if has_pacing else 0.0

		# Keep the track center calm translucent blue; ONLY the inside edge of each turn
		# transitions Blue <-> Light Amber while the outside edge stays pure crisp Blue!
		var edge0_o := _eval_pacing_color(surface_edge_color, hairpin_warn_edge_color, bo0)
		var edge0_i := _eval_pacing_color(surface_edge_color, hairpin_warn_edge_color, bi0)
		var edge1_o := _eval_pacing_color(surface_edge_color, hairpin_warn_edge_color, bo1)
		var edge1_i := _eval_pacing_color(surface_edge_color, hairpin_warn_edge_color, bi1)

		var col0_o := edge0_o.lerp(hairpin_warn_edge_color, outer_warn[i] * 0.55)
		var col0_i := edge0_i.lerp(hairpin_warn_edge_color, inner_warn[i] * 0.55)
		var col1_o := edge1_o.lerp(hairpin_warn_edge_color, outer_warn[ni] * 0.55)
		var col1_i := edge1_i.lerp(hairpin_warn_edge_color, inner_warn[ni] * 0.55)

		var row0_c: Array[Color] = [col0_o, surface_mid_color, surface_center_color, surface_mid_color, col0_i]
		var row1_c: Array[Color] = [col1_o, surface_mid_color, surface_center_color, surface_mid_color, col1_i]

		for b in strip_count:
			var t_a := BANDS[b]
			var t_b := BANDS[b + 1]
			var p00 := o0.lerp(i0, t_a)
			var p01 := o0.lerp(i0, t_b)
			var p10 := o1.lerp(i1, t_a)
			var p11 := o1.lerp(i1, t_b)

			var c00 := row0_c[b]
			var c01 := row0_c[b + 1]
			var c10 := row1_c[b]
			var c11 := row1_c[b + 1]

			# Triangle 1
			verts[idx] = p00; colors[idx] = c00; idx += 1
			verts[idx] = p10; colors[idx] = c10; idx += 1
			verts[idx] = p11; colors[idx] = c11; idx += 1
			# Triangle 2
			verts[idx] = p00; colors[idx] = c00; idx += 1
			verts[idx] = p11; colors[idx] = c11; idx += 1
			verts[idx] = p01; colors[idx] = c01; idx += 1

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_surface_mesh.mesh = mesh


func _build_holo_chevrons() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var n := centerline_points.size()
	if n < 3 or track_length_px <= 1.0 or chevron_spacing_px <= 10.0:
		return result
	var has_pacing := pacing_brake.size() == n
	var count := maxi(int(floor(track_length_px / chevron_spacing_px)), 4)
	var step := track_length_px / float(count)
	for k in range(count):
		var arc := float(k) * step
		# Leave clean space right over the Start/Finish gate
		if arc < 110.0 or arc > track_length_px - 110.0:
			continue
		var p0 := _sample_loop_at_arc(centerline_points, arc)
		var p1 := _sample_loop_at_arc(centerline_points, arc + 12.0)
		var dir := (p1 - p0).normalized()
		if dir.length_squared() > 0.5:
			var bw := 0.0
			if has_pacing:
				var seg := _locate_arc_segment(arc)
				var lo: int = seg["lo"]
				var hi: int = (lo + 1) % n
				var t: float = seg["t"]
				bw = lerpf(pacing_brake[lo], pacing_brake[hi], t)
			result.append({"pos": p0, "dir": dir, "brake": bw})
	return result


func _build_projector_buoys(outer_warn: PackedFloat32Array, inner_warn: PackedFloat32Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var n := centerline_points.size()
	if n < 3 or track_length_px <= 1.0 or buoy_spacing_px <= 20.0:
		return result
	var has_pacing := pacing_outer_amber.size() == n and pacing_inner_amber.size() == n
	var count := maxi(int(floor(track_length_px / buoy_spacing_px)), 6)
	var step := track_length_px / float(count)
	var perch_offset := 15.0

	for k in range(count):
		var arc := float(k) * step
		# Skip right on top of Start/Finish gate pylons
		if arc < 80.0 or arc > track_length_px - 80.0:
			continue
		var seg_info := _locate_arc_segment(arc)
		var lo: int = seg_info["lo"]
		var hi: int = (lo + 1) % n
		var t: float = seg_info["t"]

		var o_pos := outer_points[lo].lerp(outer_points[hi], t)
		var i_pos := inner_points[lo].lerp(inner_points[hi], t)
		var o_tan := (outer_points[hi] - outer_points[lo]).normalized()
		var i_tan := (inner_points[hi] - inner_points[lo]).normalized()
		var to_center_from_outer := (i_pos - o_pos).normalized()
		var bo := lerpf(pacing_outer_amber[lo], pacing_outer_amber[hi], t) if has_pacing else 0.0
		var bi := lerpf(pacing_inner_amber[lo], pacing_inner_amber[hi], t) if has_pacing else 0.0
		var o_w := maxf(lerpf(outer_warn[lo], outer_warn[hi], t), bo)
		var i_w := maxf(lerpf(inner_warn[lo], inner_warn[hi], t), bi)

		result.append({
			"pos": o_pos - to_center_from_outer * perch_offset,
			"tangent": o_tan,
			"inward": to_center_from_outer,
			"warn": o_w,
		})
		result.append({
			"pos": i_pos + to_center_from_outer * perch_offset,
			"tangent": i_tan,
			"inward": -to_center_from_outer,
			"warn": i_w,
		})

	return result


func _locate_arc_segment(arc_dist: float) -> Dictionary:
	var n := centerline_points.size()
	var d := fposmod(arc_dist, track_length_px)
	var lo := 0
	var hi := n - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if _centerline_cum_dist[mid] <= d:
			lo = mid
		else:
			hi = mid - 1
	var seg_start := _centerline_cum_dist[lo]
	var seg_end := _centerline_cum_dist[lo + 1]
	var seg_len := maxf(seg_end - seg_start, 0.0001)
	return {"lo": lo, "t": clampf((d - seg_start) / seg_len, 0.0, 1.0)}


func _rebuild_collisions() -> void:
	for col in _generated_colliders:
		if is_instance_valid(col):
			remove_child(col)
			col.queue_free()
	_generated_colliders.clear()

	if not solid_walls:
		return

	_build_wall_colliders(outer_points)
	_build_wall_colliders(inner_points)


func _build_wall_colliders(pts: PackedVector2Array) -> void:
	var count := pts.size()
	if count < 2:
		return
	for i in count:
		var a := pts[i]
		var b := pts[(i + 1) % count]
		var seg_len := a.distance_to(b)
		if seg_len < 1.0:
			continue

		var col := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(seg_len + wall_thickness, wall_thickness)
		col.shape = rect
		col.position = (a + b) * 0.5
		col.rotation = (b - a).angle()
		add_child(col)
		_generated_colliders.append(col)


func _place_player_at_spawn(spawn_pos: Vector2, spawn_rot: float) -> void:
	var ship := get_parent().get_node_or_null("PlayerShip") if get_parent() != null else null
	if ship != null and ship.has_method("place_at_spawn"):
		ship.place_at_spawn(spawn_pos, spawn_rot, true)
