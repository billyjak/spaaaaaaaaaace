extends Node2D

# ---------------------------------------------------------------------------
# Orbital Holo-Corridor Detail Overlay
# Renders all crisp procedural markings on top of the translucent blue track
# surface and energy rails:
#   - Subtle forward-pointing holographic flow chevrons along the centerline
#   - Glowing amber outer-wall warning kerbs on sharp hairpins
#   - Physical projector buoys / emitter nodes anchored along both walls
#   - Illuminated checkered Start/Finish holographic gate
# ---------------------------------------------------------------------------

var outer_points: PackedVector2Array = PackedVector2Array()
var inner_points: PackedVector2Array = PackedVector2Array()
var centerline_points: PackedVector2Array = PackedVector2Array()
var outer_warn: PackedFloat32Array = PackedFloat32Array()
var inner_warn: PackedFloat32Array = PackedFloat32Array()
var chevrons: Array[Dictionary] = [] # { "pos": Vector2, "dir": Vector2 }
var buoys: Array[Dictionary] = []    # { "pos": Vector2, "tangent": Vector2, "inward": Vector2, "warn": float }
var checkpoints: Array[Dictionary] = [] # { "index": int, "inner": Vector2, "outer": Vector2, "tangent": Vector2, "is_finish": bool }
var active_checkpoint_index: int = 0

var chevron_color: Color = Color(0.38, 0.88, 1.0, 0.22)
var cyan_emitter_color: Color = Color(0.32, 0.90, 1.0, 0.95)
var amber_emitter_color: Color = Color(0.90, 0.64, 0.38, 0.92)
var buoy_body_color: Color = Color(0.11, 0.15, 0.22, 0.95)
var buoy_trim_color: Color = Color(0.45, 0.62, 0.78, 0.85)


func set_holo_data(
	p_center: PackedVector2Array,
	p_outer: PackedVector2Array,
	p_inner: PackedVector2Array,
	p_outer_warn: PackedFloat32Array,
	p_inner_warn: PackedFloat32Array,
	p_chevrons: Array[Dictionary],
	p_buoys: Array[Dictionary],
	p_checkpoints: Array[Dictionary] = []
) -> void:
	centerline_points = p_center
	outer_points = p_outer
	inner_points = p_inner
	outer_warn = p_outer_warn
	inner_warn = p_inner_warn
	chevrons = p_chevrons
	buoys = p_buoys
	checkpoints = p_checkpoints
	active_checkpoint_index = 0
	queue_redraw()


func set_active_checkpoint(idx: int) -> void:
	active_checkpoint_index = idx
	queue_redraw()


func _draw() -> void:
	var n := centerline_points.size()
	if n < 3 or outer_points.size() != n or inner_points.size() != n:
		return

	# 1. Subtle holographic forward-flow chevrons along the calm blue centerline
	for ch in chevrons:
		var pos: Vector2 = ch["pos"]
		var fwd: Vector2 = ch["dir"]
		var side := Vector2(-fwd.y, fwd.x)
		var tip := pos + fwd * 18.0
		var wing_l := pos - fwd * 12.0 - side * 34.0
		var wing_r := pos - fwd * 12.0 + side * 34.0
		draw_polyline(PackedVector2Array([wing_l, tip, wing_r]), chevron_color, 2.5, true)
		# Secondary trailing echo chevron for clean forward-motion read
		var back_off := -fwd * 14.0
		var echo_col := Color(chevron_color.r, chevron_color.g, chevron_color.b, chevron_color.a * 0.48)
		draw_polyline(
			PackedVector2Array([wing_l + back_off, tip + back_off, wing_r + back_off]),
			echo_col,
			1.8,
			true
		)

	# 2. Glowing amber outer-wall warning kerbs on sharp hairpins
	_draw_warning_kerbs(outer_points, outer_warn)
	_draw_warning_kerbs(inner_points, inner_warn)

	# 3. Ordered checkpoint gates (subtle future gates, glowing next active gate)
	_draw_checkpoints()

	# 4. Start / Finish holographic checkered gate at index 0
	_draw_start_finish_gate()

	# 5. Physical projector buoys / emitter nodes along both walls
	for b in buoys:
		_draw_projector_buoy(b["pos"], b["tangent"], b["inward"], float(b["warn"]))


func _draw_checkpoints() -> void:
	if checkpoints.is_empty():
		return
	for cp in checkpoints:
		if bool(cp.get("is_finish", false)):
			continue
		var idx: int = int(cp["index"])
		# Already cleared checkpoints disappear cleanly
		if idx < active_checkpoint_index:
			continue
		var p_in: Vector2 = cp["inner"]
		var p_out: Vector2 = cp["outer"]
		var is_next := (idx == active_checkpoint_index)
		if is_next:
			# Bright glowing cyan-mint active checkpoint beam + edge beacons
			draw_line(p_in, p_out, Color(0.18, 0.98, 0.85, 0.24), 18.0, true)
			draw_line(p_in, p_out, Color(0.55, 1.0, 0.94, 0.85), 3.2, true)
			draw_circle(p_in, 10.0, Color(0.25, 1.0, 0.88, 0.35))
			draw_circle(p_in, 4.5, Color(0.75, 1.0, 0.96, 1.0))
			draw_circle(p_out, 10.0, Color(0.25, 1.0, 0.88, 0.35))
			draw_circle(p_out, 4.5, Color(0.75, 1.0, 0.96, 1.0))
		else:
			# Subtle upcoming checkpoint gate line
			draw_line(p_in, p_out, Color(0.25, 0.80, 1.0, 0.14), 2.0, true)


func _draw_warning_kerbs(wall_pts: PackedVector2Array, warn_vals: PackedFloat32Array) -> void:
	var n := wall_pts.size()
	if warn_vals.size() != n:
		return
	for i in n:
		var next_i := (i + 1) % n
		var w := maxf(warn_vals[i], warn_vals[next_i])
		if w <= 0.05:
			continue
		var a := wall_pts[i]
		var b := wall_pts[next_i]
		# Subtle desaturated-amber apex highlight (no over-saturation)
		draw_line(a, b, Color(0.88, 0.58, 0.32, 0.16 * w), 11.0, true)
		draw_line(a, b, Color(0.96, 0.78, 0.56, 0.48 * w), 3.4, true)


func _draw_start_finish_gate() -> void:
	var p_in := inner_points[0]
	var p_out := outer_points[0]
	var across := p_out - p_in
	var width_px := across.length()
	if width_px < 10.0:
		return
	var across_dir := across / width_px
	var fwd := (centerline_points[1] - centerline_points[0]).normalized()

	# Subtle glowing gate energy wash
	var gate_half_depth := 18.0
	var gate_poly := PackedVector2Array([
		p_in - fwd * gate_half_depth,
		p_out - fwd * gate_half_depth,
		p_out + fwd * gate_half_depth,
		p_in + fwd * gate_half_depth,
	])
	draw_colored_polygon(gate_poly, Color(0.18, 0.95, 0.72, 0.14))

	# Two rows of translucent holographic checker squares across the corridor
	var cols := 10
	var rows := 2
	var tile_w := width_px / float(cols)
	var tile_d := (gate_half_depth * 2.0) / float(rows)
	for r in rows:
		var d0 := -gate_half_depth + float(r) * tile_d
		var d1 := d0 + tile_d
		for c in cols:
			if (r + c) % 2 != 0:
				continue
			var x0 := float(c) * tile_w
			var x1 := x0 + tile_w
			var quad := PackedVector2Array([
				p_in + across_dir * x0 + fwd * d0,
				p_in + across_dir * x1 + fwd * d0,
				p_in + across_dir * x1 + fwd * d1,
				p_in + across_dir * x0 + fwd * d1,
			])
			draw_colored_polygon(quad, Color(0.75, 1.0, 0.92, 0.38))

	# Crisp emerald-cyan threshold laser lines at front & back of gate
	# Glows brighter emerald-gold when all checkpoints are cleared and Finish is armed!
	var finish_armed := (not checkpoints.is_empty()) and (active_checkpoint_index >= checkpoints.size() - 1)
	var front_col := Color(0.35, 1.0, 0.65, 1.0) if finish_armed else Color(0.35, 1.0, 0.78, 0.85)
	if finish_armed:
		draw_line(p_in, p_out, Color(0.25, 1.0, 0.60, 0.32), 26.0, true)
	draw_line(p_in + fwd * gate_half_depth, p_out + fwd * gate_half_depth, front_col, 3.6 if finish_armed else 3.0, true)
	draw_line(p_in - fwd * gate_half_depth, p_out - fwd * gate_half_depth, Color(0.25, 0.88, 1.0, 0.50), 2.0, true)

	# Anchor gate pylons just outside both walls
	for end_pt in [p_in - across_dir * 18.0, p_out + across_dir * 18.0]:
		draw_circle(end_pt, 14.0, Color(0.20, 1.0, 0.70, 0.25))
		draw_circle(end_pt, 7.5, buoy_body_color)
		draw_arc(end_pt, 7.5, 0.0, TAU, 16, Color(0.45, 1.0, 0.82, 0.95), 2.0, true)
		draw_circle(end_pt, 3.5, Color(0.70, 1.0, 0.90, 1.0))


func _eval_luminous_ramp(blue_col: Color, amber_col: Color, t_amber: float) -> Color:
	var u := clampf(t_amber, 0.0, 1.0)
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
		out_col = blue_col.lerp(c1, u / 0.16)
	elif u < 0.45:
		out_col = c1.lerp(c2, (u - 0.16) / 0.29)
	elif u < 0.75:
		out_col = c2.lerp(c3, (u - 0.45) / 0.30)
	else:
		out_col = c3.lerp(amber_col, (u - 0.75) / 0.25)
	out_col.v = target_v
	out_col.a = target_a
	return out_col


func _draw_projector_buoy(pos: Vector2, tangent: Vector2, inward: Vector2, warn: float) -> void:
	var emitter_col := _eval_luminous_ramp(cyan_emitter_color, amber_emitter_color, warn)

	# Tiny projector beam glow linking the buoy emitter inward to the energy rail
	var beam_start := pos + inward * 4.0
	var beam_end := pos + inward * 14.0
	draw_line(beam_start, beam_end, Color(emitter_col.r, emitter_col.g, emitter_col.b, 0.42), 5.0, true)

	# Sleek beveled metallic housing oriented along the wall tangent
	var half_l := 9.0
	var half_t := 4.5
	var body := PackedVector2Array([
		pos - tangent * half_l - inward * half_t,
		pos + tangent * half_l - inward * half_t,
		pos + tangent * (half_l * 0.72) + inward * half_t,
		pos - tangent * (half_l * 0.72) + inward * half_t,
	])
	draw_colored_polygon(body, buoy_body_color)
	var outline := PackedVector2Array([body[0], body[1], body[2], body[3], body[0]])
	draw_polyline(outline, buoy_trim_color, 1.4, true)

	# Glowing emitter lens facing inward toward the corridor
	var lens_pos := pos + inward * (half_t * 0.65)
	draw_circle(lens_pos, 6.5, Color(emitter_col.r, emitter_col.g, emitter_col.b, 0.24))
	draw_circle(lens_pos, 2.8, emitter_col)
