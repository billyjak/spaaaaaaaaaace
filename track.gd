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
@export var sample_spacing: float = 65.0
## Smoothing passes for the gentle-arc camera guide rail (auto-scaled with sample_spacing).
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

	return {
		"points": control_pts,
		"handle_ratio": handle_ratio,
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
