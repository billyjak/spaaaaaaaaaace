extends Control

# ---------------------------------------------------------------------------
# Live Orbital Track Preview Widget (for Main Menu Track Select)
# Renders an aspect-preserving glowing cyan-blue silhouette of any preset or
# freshly re-rolled random track, complete with Start/Finish beacon.
# ---------------------------------------------------------------------------

var outer_points: PackedVector2Array = PackedVector2Array()
var inner_points: PackedVector2Array = PackedVector2Array()
var start_point: Vector2 = Vector2.ZERO
var _bounds_min: Vector2 = Vector2.ZERO
var _bounds_max: Vector2 = Vector2.ONE


func set_preview_geometry(p_outer: PackedVector2Array, p_inner: PackedVector2Array, p_start: Vector2) -> void:
	outer_points = p_outer
	inner_points = p_inner
	start_point = p_start

	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for p in outer_points:
		min_p.x = minf(min_p.x, p.x)
		min_p.y = minf(min_p.y, p.y)
		max_p.x = maxf(max_p.x, p.x)
		max_p.y = maxf(max_p.y, p.y)
	for p in inner_points:
		min_p.x = minf(min_p.x, p.x)
		min_p.y = minf(min_p.y, p.y)
		max_p.x = maxf(max_p.x, p.x)
		max_p.y = maxf(max_p.y, p.y)

	if min_p.x < INF:
		_bounds_min = min_p
		_bounds_max = max_p
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.03, 0.05, 0.09, 0.90), true)

	if outer_points.size() < 3 or inner_points.size() < 3:
		return

	var span := _bounds_max - _bounds_min
	var pad := 22.0
	var avail_w := maxf(size.x - pad * 2.0, 10.0)
	var avail_h := maxf(size.y - pad * 2.0, 10.0)
	var scale_f := minf(avail_w / maxf(span.x, 1.0), avail_h / maxf(span.y, 1.0))
	var world_center := (_bounds_min + _bounds_max) * 0.5
	var view_center := size * 0.5

	var outer_ui := _map_loop(outer_points, world_center, scale_f, view_center)
	var inner_ui := _map_loop(inner_points, world_center, scale_f, view_center)

	# Soft glowing halo + crisp ice-blue rails
	draw_polyline(outer_ui, Color(0.08, 0.55, 1.0, 0.28), 6.0, true)
	draw_polyline(inner_ui, Color(0.08, 0.55, 1.0, 0.28), 6.0, true)
	draw_polyline(outer_ui, Color(0.75, 0.95, 1.0, 0.95), 2.0, true)
	draw_polyline(inner_ui, Color(0.48, 0.84, 1.0, 0.90), 2.0, true)

	# Emerald Start/Finish beacon
	var st_ui := (start_point - world_center) * scale_f + view_center
	draw_circle(st_ui, 7.5, Color(0.20, 1.0, 0.65, 0.30))
	draw_circle(st_ui, 3.8, Color(0.45, 1.0, 0.78, 1.0))


func _map_loop(pts: PackedVector2Array, world_center: Vector2, scale_f: float, view_center: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := pts.size()
	out.resize(n + 1)
	for i in n:
		out[i] = (pts[i] - world_center) * scale_f + view_center
	out[n] = out[0]
	return out
