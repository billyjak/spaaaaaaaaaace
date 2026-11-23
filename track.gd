extends StaticBody2D

signal track_generated(seed_value: int, spawn_pos: Vector2, spawn_rot: float)

enum TrackType {
	TYPE_1 = 1, ## Speedway: wide sweeping curves and long arcs
	TYPE_2 = 2, ## Circuit: balanced mix of long straights into hard hairpins
	TYPE_3 = 3, ## Technical: frequent sharp hairpins and chained tight turns
	TYPE_4 = 4, ## Switchback: relentless deep hairpins and back-to-back tight bends
}

const TRACK_TYPE_COUNT: int = 4

@export_group("Track Seed, Type & Saving")
## 0 = generate a fresh random track every launch; non-zero = deterministically replay that exact seed.
@export var track_seed: int = 0
## Track archetype controlling turn density and hairpin intensity (Type 1 = swoopy -> Type 4 = switchback).
@export var track_type: TrackType = TrackType.TYPE_1
## JSON file where favorite track seeds are saved when pressing `save_track`.
@export var saved_tracks_path: String = "user://saved_tracks.json"

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
@export var sample_spacing: float = 120.0
## Smoothing passes for the gentle-arc camera guide rail (higher = gentler arcs through chicanes/hairpins).
@export_range(0, 120) var camera_rail_smoothing_passes: int = 55

@export_group("Walls & Collision")
## Toggle solid physics barriers (true = solid walls, false = visual lines only).
@export var solid_walls: bool = true
## Physics collision thickness along each wall segment (px).
@export var wall_thickness: float = 20.0
## Visual stroke thickness of the two white track lines (px).
@export var wall_line_width: float = 8.0

# Public read-only track geometry for future visuals, checkpoints, minimaps, and AI
var active_seed: int = 0
var active_track_type: TrackType = TrackType.TYPE_1
var centerline_points: PackedVector2Array = PackedVector2Array()
var camera_rail_points: PackedVector2Array = PackedVector2Array()
var outer_points: PackedVector2Array = PackedVector2Array()
var inner_points: PackedVector2Array = PackedVector2Array()
var track_length_px: float = 0.0
var total_track_turn_rad: float = 0.0
var _centerline_cum_dist: PackedFloat32Array = PackedFloat32Array()
var _centerline_cum_turn: PackedFloat32Array = PackedFloat32Array()

var save_status_text: String = ""
var _save_status_timer: float = 0.0

var _rng := RandomNumberGenerator.new()
var _generated_colliders: Array[CollisionShape2D] = []

@onready var _outer_line: Line2D = $OuterWallVisual
@onready var _inner_line: Line2D = $InnerWallVisual


func _ready() -> void:
	visible = true
	if _outer_line:
		_outer_line.visible = true
	if _inner_line:
		_inner_line.visible = true

	active_track_type = track_type
	generate_track(track_seed, active_track_type)


func _process(delta: float) -> void:
	if _save_status_timer > 0.0:
		_save_status_timer = maxf(_save_status_timer - delta, 0.0)
		if _save_status_timer <= 0.0:
			save_status_text = ""

	if InputMap.has_action("new_track") and Input.is_action_just_pressed("new_track"):
		cycle_track_type()
	if InputMap.has_action("save_track") and Input.is_action_just_pressed("save_track"):
		save_current_track()


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
		_:
			return "Type %d" % resolved


func cycle_track_type() -> void:
	var next_int := (int(active_track_type) % TRACK_TYPE_COUNT) + 1
	active_track_type = next_int as TrackType
	track_type = active_track_type
	generate_track(0, active_track_type)


func generate_track(seed_override: int = 0, type_override: int = 0) -> void:
	if type_override >= TrackType.TYPE_1 and type_override <= TrackType.TYPE_4:
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
	var rail: Array[Vector2] = []
	rail.resize(n)
	for i in n:
		rail[i] = centerline_points[i]

	var passes := maxi(camera_rail_smoothing_passes, 0)
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
	var handle_divisor := 6.0

	match t_type:
		TrackType.TYPE_1:
			# Type 1 - Speedway: flowing sweepers and wide arcs
			var n := maxi(control_point_count, 6)
			var angle_step := TAU / float(n)
			var min_r := maxf(base_radius * (1.0 - radial_variation), track_width * 1.6)
			var max_r := maxf(base_radius * (1.0 + radial_variation), min_r + 100.0)
			for i in n:
				var angle := float(i) * angle_step + _rng.randf_range(-angular_jitter, angular_jitter) * angle_step
				var r := _rng.randf_range(min_r, max_r)
				control_pts.append(Vector2(cos(angle), sin(angle)) * r)
			handle_divisor = 6.0

		TrackType.TYPE_2:
			# Type 2 - Circuit: deliberate long straights slamming into sharp hairpins
			var n := 16
			var r_base := base_radius * 1.15
			var phase := _rng.randi_range(0, n - 1)
			var weights: Array[float] = []
			var roles: Array[int] = [] # 0 = normal, 1 = straight, 2 = hairpin
			weights.resize(n)
			roles.resize(n)
			for i in n:
				var slot := (i + phase) % n
				if slot == 0 or slot == 1 or slot == 8 or slot == 9:
					roles[i] = 1
					weights[i] = 1.28
				elif slot == 2 or slot == 3 or slot == 4 or slot == 10 or slot == 11 or slot == 12:
					roles[i] = 2
					weights[i] = 0.84
				else:
					roles[i] = 0
					weights[i] = 0.96

			var angles := _angles_from_weights(weights, 0.10)
			var side := 1.0 if _rng.randf() >= 0.5 else -1.0
			for i in n:
				var r := r_base
				if roles[i] == 1:
					# Straightaway chord: mild radius near base_radius
					r = r_base * _rng.randf_range(0.95, 1.06)
				elif roles[i] == 2:
					# Hairpin cluster: strong alternating inner/outer swings with safe inner clearance
					side = -side
					if side > 0.0:
						r = r_base * _rng.randf_range(1.26, 1.48)
					else:
						r = maxf(r_base * _rng.randf_range(0.56, 0.68), track_width * 2.4)
				else:
					if _rng.randf() < 0.65:
						side = -side
					r = r_base * (_rng.randf_range(1.10, 1.30) if side > 0.0 else _rng.randf_range(0.68, 0.86))
				control_pts.append(Vector2(cos(angles[i]), sin(angles[i])) * r)

			# Flatten the middle pegs of each straightaway onto the chord for a crisp straight
			for start_slot: int in [0, 8]:
				var idx_a: int = (start_slot - phase + n) % n
				var idx_b: int = (idx_a + 1) % n
				var idx_prev: int = (idx_a - 1 + n) % n
				var idx_next: int = (idx_b + 1) % n
				control_pts[idx_a] = control_pts[idx_a].lerp(control_pts[idx_prev].lerp(control_pts[idx_next], 0.35), 0.55)
				control_pts[idx_b] = control_pts[idx_b].lerp(control_pts[idx_prev].lerp(control_pts[idx_next], 0.65), 0.55)
			handle_divisor = 6.8

		TrackType.TYPE_3:
			# Type 3 - Technical: frequent sharp hairpins & chained turn-after-turn sectors
			var n := 18
			var r_base := base_radius * 1.18
			var phase := _rng.randi_range(0, n - 1)
			var weights: Array[float] = []
			var in_cluster: Array[bool] = []
			weights.resize(n)
			in_cluster.resize(n)
			for i in n:
				var slot := (i + phase) % n
				var clustered := (slot >= 1 and slot <= 5) or (slot >= 10 and slot <= 14)
				in_cluster[i] = clustered
				weights[i] = 0.85 if clustered else 1.18

			var angles := _angles_from_weights(weights, 0.10)
			var side := 1.0 if _rng.randf() >= 0.5 else -1.0
			for i in n:
				if in_cluster[i]:
					# Strict alternating tight hairpin chain
					side = -side
					var r := (
						r_base * _rng.randf_range(1.18, 1.40)
						if side > 0.0
						else maxf(r_base * _rng.randf_range(0.56, 0.70), track_width * 2.5)
					)
					control_pts.append(Vector2(cos(angles[i]), sin(angles[i])) * r)
				else:
					if _rng.randf() < 0.78:
						side = -side
					var r := (
						r_base * _rng.randf_range(1.12, 1.34)
						if side > 0.0
						else maxf(r_base * _rng.randf_range(0.62, 0.78), track_width * 2.5)
					)
					control_pts.append(Vector2(cos(angles[i]), sin(angles[i])) * r)
			handle_divisor = 7.4

		TrackType.TYPE_4:
			# Type 4 - Switchback: relentless deep hairpins and back-to-back tight turns
			var n := 22
			var r_base := base_radius * 1.32
			var phase := _rng.randi_range(0, n - 1)
			var weights: Array[float] = []
			weights.resize(n)
			for i in n:
				var slot := (i + phase) % n
				# Compressed switchback chains around the loop
				var tight_chain := (slot % 7) < 5
				weights[i] = 0.88 if tight_chain else 1.22

			var angles := _angles_from_weights(weights, 0.09)
			var side := 1.0 if _rng.randf() >= 0.5 else -1.0
			for i in n:
				side = -side
				var r := (
					r_base * _rng.randf_range(1.20, 1.42)
					if side > 0.0
					else maxf(r_base * _rng.randf_range(0.58, 0.70), track_width * 2.8)
				)
				control_pts.append(Vector2(cos(angles[i]), sin(angles[i])) * r)
			handle_divisor = 8.0

	return {
		"points": control_pts,
		"handle_divisor": handle_divisor,
	}


func _angles_from_weights(weights: Array[float], jitter_frac: float) -> PackedFloat32Array:
	var n := weights.size()
	var total := 0.0
	for w in weights:
		total += maxf(w, 0.1)
	var angles := PackedFloat32Array()
	angles.resize(n)
	var acc := 0.0
	for i in n:
		var step := (maxf(weights[i], 0.1) / maxf(total, 0.001)) * TAU
		var jitter := _rng.randf_range(-jitter_frac, jitter_frac) * step
		angles[i] = acc + jitter
		acc += step
	return angles


func _try_build_geometry(t_type: TrackType = TrackType.TYPE_1) -> bool:
	# 1. Place control pegs according to active track archetype
	var built_ctrl := _build_control_points_for_type(t_type)
	var control_pts: Array[Vector2] = built_ctrl["points"]
	var handle_divisor: float = built_ctrl["handle_divisor"]
	var n := control_pts.size()
	if n < 6:
		return false

	# 2. Build closed Catmull-Rom spline via Curve2D with distance-clamped handles
	#    (prevents Bezier overshoot loops on asymmetric straight-into-hairpin transitions)
	var handle_ratio := 1.0 / maxf(handle_divisor * 0.5, 2.5) # ~0.33 (Type 1) down to ~0.25 (Type 4)
	var curve := Curve2D.new()
	for i in n:
		var prev_pt := control_pts[(i - 1 + n) % n]
		var curr_pt := control_pts[i]
		var next_pt := control_pts[(i + 1) % n]
		var chord := next_pt - prev_pt
		var dir := chord.normalized() if chord.length_squared() > 1e-6 else Vector2.RIGHT
		var in_len := curr_pt.distance_to(prev_pt) * handle_ratio
		var out_len := curr_pt.distance_to(next_pt) * handle_ratio
		curve.add_point(curr_pt, -dir * in_len, dir * out_len)
	# Close loop by repeating point 0 with matching clamped handles
	var first_chord := control_pts[1] - control_pts[n - 1]
	var first_dir := first_chord.normalized() if first_chord.length_squared() > 1e-6 else Vector2.RIGHT
	var first_in := control_pts[0].distance_to(control_pts[n - 1]) * handle_ratio
	var first_out := control_pts[0].distance_to(control_pts[1]) * handle_ratio
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
	#    and gently relax immediate neighbors so segment spacing stays even around tight hairpins.
	var min_bend_radius := track_width * 0.80
	for _pass in range(32):
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


func _loop_self_intersects(pts: PackedVector2Array) -> bool:
	var n := pts.size()
	if n < 4:
		return false
	for i in n:
		var a1 := pts[i]
		var a2 := pts[(i + 1) % n]
		var a_min_x := minf(a1.x, a2.x)
		var a_max_x := maxf(a1.x, a2.x)
		var a_min_y := minf(a1.y, a2.y)
		var a_max_y := maxf(a1.y, a2.y)
		for j in range(i + 2, n):
			# Skip wrap-around adjacent pair (first and last segment share vertex 0)
			if i == 0 and j == n - 1:
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
	for i in na:
		var a1 := loop_a[i]
		var a2 := loop_a[(i + 1) % na]
		var a_min_x := minf(a1.x, a2.x)
		var a_max_x := maxf(a1.x, a2.x)
		var a_min_y := minf(a1.y, a2.y)
		var a_max_y := maxf(a1.y, a2.y)
		for j in nb:
			var b1 := loop_b[j]
			var b2 := loop_b[(j + 1) % nb]
			if maxf(b1.x, b2.x) < a_min_x or minf(b1.x, b2.x) > a_max_x:
				continue
			if maxf(b1.y, b2.y) < a_min_y or minf(b1.y, b2.y) > a_max_y:
				continue
			if Geometry2D.segment_intersects_segment(a1, a2, b1, b2) != null:
				return true
	return false


func _apply_visuals() -> void:
	if _outer_line != null:
		_outer_line.closed = true
		_outer_line.width = wall_line_width
		_outer_line.default_color = Color.WHITE
		_outer_line.points = outer_points
	if _inner_line != null:
		_inner_line.closed = true
		_inner_line.width = wall_line_width
		_inner_line.default_color = Color.WHITE
		_inner_line.points = inner_points


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
