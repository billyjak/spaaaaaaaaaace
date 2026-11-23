extends Control

@export var padding_px: float = 14.0
@export var wall_color: Color = Color(0.88, 0.94, 1.0, 0.9)
@export var wall_width: float = 1.6
@export var start_line_color: Color = Color(0.35, 1.0, 0.55, 0.95)
@export var ship_color: Color = Color(1.0, 0.32, 0.32, 1.0)
@export var ship_marker_size: float = 7.5
@export var show_flip_burn_projection: bool = false
@export var flip_drift_color: Color = Color(1.0, 0.68, 0.2, 0.85)
@export var burn_line_color: Color = Color(0.28, 0.88, 1.0, 0.85)
@export var stop_marker_color: Color = Color(1.0, 0.85, 0.25, 0.95)

var _ship: Node2D = null
var _track: Node2D = null

var _world_center: Vector2 = Vector2.ZERO
var _scale_factor: float = 1.0
var _outer_map_pts: PackedVector2Array = PackedVector2Array()
var _inner_map_pts: PackedVector2Array = PackedVector2Array()
var _has_track: bool = false


func _ready() -> void:
	# Node hierarchy: Level -> PlayerShip -> TelemetryLayer -> MinimapPanel -> Minimap
	var root_level := get_tree().current_scene
	if root_level != null:
		_ship = root_level.get_node_or_null("PlayerShip") as Node2D
		_track = root_level.get_node_or_null("Track") as Node2D

	# Fallback traversal if instanced inside a test harness without current_scene
	if _ship == null or _track == null:
		var n: Node = self
		while n != null:
			if n.name == "Level":
				_ship = n.get_node_or_null("PlayerShip") as Node2D
				_track = n.get_node_or_null("Track") as Node2D
				break
			n = n.get_parent()

	if _track != null and _track.has_signal("track_generated"):
		_track.track_generated.connect(_on_track_generated)

	resized.connect(_rebuild_map_cache)
	call_deferred("_rebuild_map_cache")


func _on_track_generated(_seed_val: int, _spawn_pos: Vector2, _spawn_rot: float) -> void:
	_rebuild_map_cache()


func _process(_delta: float) -> void:
	if _has_track:
		queue_redraw()


func world_to_minimap(world_pos: Vector2) -> Vector2:
	return (world_pos - _world_center) * _scale_factor + size * 0.5


func _rebuild_map_cache() -> void:
	_outer_map_pts = PackedVector2Array()
	_inner_map_pts = PackedVector2Array()
	_has_track = false

	if _track == null or not ("outer_points" in _track) or not ("inner_points" in _track):
		queue_redraw()
		return

	var outer_local: PackedVector2Array = _track.outer_points
	var inner_local: PackedVector2Array = _track.inner_points
	if outer_local.size() < 3 or inner_local.size() < 3:
		queue_redraw()
		return

	var min_pt := Vector2(INF, INF)
	var max_pt := Vector2(-INF, -INF)

	var outer_world := PackedVector2Array()
	for pt in outer_local:
		var wp := _track.to_global(pt)
		outer_world.append(wp)
		min_pt.x = minf(min_pt.x, wp.x)
		min_pt.y = minf(min_pt.y, wp.y)
		max_pt.x = maxf(max_pt.x, wp.x)
		max_pt.y = maxf(max_pt.y, wp.y)

	var inner_world := PackedVector2Array()
	for pt in inner_local:
		var wp := _track.to_global(pt)
		inner_world.append(wp)
		min_pt.x = minf(min_pt.x, wp.x)
		min_pt.y = minf(min_pt.y, wp.y)
		max_pt.x = maxf(max_pt.x, wp.x)
		max_pt.y = maxf(max_pt.y, wp.y)

	var span := max_pt - min_pt
	var avail := size - Vector2(padding_px * 2.0, padding_px * 2.0)
	if span.x <= 0.001 or span.y <= 0.001 or avail.x <= 1.0 or avail.y <= 1.0:
		queue_redraw()
		return

	_world_center = (min_pt + max_pt) * 0.5
	_scale_factor = minf(avail.x / span.x, avail.y / span.y)

	for wp in outer_world:
		_outer_map_pts.append(world_to_minimap(wp))
	_outer_map_pts.append(_outer_map_pts[0]) # Close loop

	for wp in inner_world:
		_inner_map_pts.append(world_to_minimap(wp))
	_inner_map_pts.append(_inner_map_pts[0]) # Close loop

	_has_track = true
	queue_redraw()


func _draw() -> void:
	if not _has_track:
		return

	# Track outer and inner white borders
	draw_polyline(_outer_map_pts, wall_color, wall_width, true)
	draw_polyline(_inner_map_pts, wall_color, wall_width, true)

	# Start/Spawn line tick across point 0
	if _outer_map_pts.size() > 0 and _inner_map_pts.size() > 0:
		draw_line(_outer_map_pts[0], _inner_map_pts[0], start_line_color, 2.5, true)

	# Live Newtonian flip-and-burn stopping projection (drawn beneath ship chevron)
	if show_flip_burn_projection and _ship != null and _ship.has_method("get_flip_and_burn_projection"):
		var proj: Dictionary = _ship.get_flip_and_burn_projection()
		if proj.get("valid", false):
			var ship_map := world_to_minimap(_ship.global_position)
			var flip_map := world_to_minimap(proj["flip_end_world"])
			var stop_map := world_to_minimap(proj["stop_world"])
			var bounds := Rect2(Vector2(2.0, 2.0), size - Vector2(4.0, 4.0))

			# Segment 1: drift while rotating to retrograde (amber)
			var flip_clamped := _clamp_segment_end(ship_map, flip_map, bounds)
			if ship_map.distance_to(flip_clamped) > 1.0:
				draw_line(ship_map, flip_clamped, flip_drift_color, 1.8, true)

			# Segment 2: main-engine retro-burn braking distance (cyan)
			if bounds.has_point(flip_map):
				var stop_clamped := _clamp_segment_end(flip_map, stop_map, bounds)
				if flip_map.distance_to(stop_clamped) > 1.0:
					draw_line(flip_map, stop_clamped, burn_line_color, 1.8, true)

				# Stopping-point ring marker (or edge tick if beyond minimap bounds)
				if bounds.has_point(stop_map):
					draw_arc(stop_map, 4.0, 0.0, TAU, 16, stop_marker_color, 1.5, true)
					draw_circle(stop_map, 1.5, stop_marker_color)
				else:
					draw_circle(stop_clamped, 3.0, flip_drift_color)
			else:
				draw_circle(flip_clamped, 3.0, flip_drift_color)

	# Directional ship marker (chevron pointing along ship nose Vector2.UP rotated by ship.global_rotation)
	if _ship != null:
		var ship_pos := world_to_minimap(_ship.global_position)
		var rot := _ship.global_rotation
		var s := ship_marker_size
		var nose := ship_pos + Vector2(0.0, -s).rotated(rot)
		var port_wing := ship_pos + Vector2(-s * 0.65, s * 0.7).rotated(rot)
		var tail_notch := ship_pos + Vector2(0.0, s * 0.25).rotated(rot)
		var stbd_wing := ship_pos + Vector2(s * 0.65, s * 0.7).rotated(rot)
		draw_colored_polygon(PackedVector2Array([nose, stbd_wing, tail_notch, port_wing]), ship_color)


# Clips a ray from `start` toward `end` cleanly onto `bounds` so extreme speeds never draw outside the minimap.
func _clamp_segment_end(start: Vector2, end: Vector2, bounds: Rect2) -> Vector2:
	if bounds.has_point(end):
		return end
	var dir := end - start
	var t_max := 1.0
	if absf(dir.x) > 0.0001:
		var tx1 := (bounds.position.x - start.x) / dir.x
		var tx2 := (bounds.end.x - start.x) / dir.x
		var tx := maxf(tx1, tx2)
		if tx >= 0.0:
			t_max = minf(t_max, tx)
	if absf(dir.y) > 0.0001:
		var ty1 := (bounds.position.y - start.y) / dir.y
		var ty2 := (bounds.end.y - start.y) / dir.y
		var ty := maxf(ty1, ty2)
		if ty >= 0.0:
			t_max = minf(t_max, ty)
	return start + dir * clampf(t_max, 0.0, 1.0)
