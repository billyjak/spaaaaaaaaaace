extends Camera2D

# ---------------------------------------------------------------------------
# Course-Geometry Sightline & Gentle-Arc Camera
# Purely driven by upcoming track geometry (zero ship-velocity dependency):
# - Walks forward along the true track centerline until cumulative turning hits
#   `turn_threshold_deg`, pinning a "Corner Anchor" at the end of the current
#   straight or bend.
# - Frames both ship and anchor: zooms out on long straights to reveal the
#   upcoming braking/turn point, and automatically tightens & zooms in as you
#   close on a hairpin or thread technical bends.
# - Follows a heavily smoothed gentle-arc camera guide rail with a critically
#   damped spring so S-bends and tight corners never swish or whip the view.
# ---------------------------------------------------------------------------

@export_group("Sightline & Corner Anchor")
## Enable/disable course-geometry camera framing.
@export var enable_course_framing: bool = true
## Cumulative track turning angle (degrees) ahead of the ship where the sightline anchors.
## Lower = anchors closer to corner entry; higher = looks deeper into gentle curves.
@export_range(15.0, 120.0, 1.0) var turn_threshold_deg: float = 35.0
## Hard cap on how far ahead along the track the sightline can reach (px).
@export var max_sightline_px: float = 4200.0
## Weighting of camera center between ship (0.0) and upcoming corner anchor (1.0).
@export_range(0.0, 0.5, 0.01) var anchor_lead_weight: float = 0.42
## Blend toward the smoothed gentle-arc camera rail (1.0 = pure gentle rail, 0.0 = raw centerline).
@export_range(0.0, 1.0, 0.05) var rail_arc_blend: float = 1.0
## Maximum offset as a fraction of viewport width/height so the ship always stays comfortably on-screen.
@export_range(0.0, 0.42, 0.01) var max_lead_screen_fraction: float = 0.30
## Critically damped spring settle time (seconds) for camera offset; higher = gentler, rounder arcs.
@export_range(0.08, 2.0, 0.02) var offset_smooth_time: float = 0.55

@export_group("Course-Driven Zoom (3-Zone Honest Curve)")
## Enable/disable automatic zoom based on upcoming track openness.
@export var enable_course_zoom: bool = true
## Close-up zoom when approaching and navigating tight turns/hairpins.
@export var close_zoom: float = 1.5
## Default cruising zoom for normal course sections and gentle sweeping curves.
@export var default_zoom: float = 1.15
## Widest zoom-out reserved strictly for major straightaways (lower to see even further down straights).
@export var wide_zoom: float = 0.85
## Sightline distance (px) at or below which camera reaches full `close_zoom` (tight turns).
@export var turn_sightline_px: float = 550.0
## Sightline distance (px) corresponding to `default_zoom` (median/normal track openness).
@export var medium_sightline_px: float = 1700.0
## Sightline distance (px) at or above which camera reaches full `wide_zoom` (big straights).
@export var straight_sightline_px: float = 3100.0
## Smoothing speed when zooming IN toward a turn / braking zone.
@export var zoom_in_smoothing: float = 3.2
## Smoothing speed when zooming OUT as a straightaway opens up (gentler prevents corner-exit pop).
@export var zoom_out_smoothing: float = 1.8

var _ship: RigidBody2D = null
var _track: Node = null
var _offset_velocity: Vector2 = Vector2.ZERO
var _needs_snap: bool = true


func _ready() -> void:
	ignore_rotation = true
	_ship = get_parent() as RigidBody2D
	_bind_track()
	zoom = Vector2(default_zoom, default_zoom)
	offset = Vector2.ZERO
	_offset_velocity = Vector2.ZERO
	_needs_snap = true


func _bind_track() -> void:
	if _track != null or _ship == null or _ship.get_parent() == null:
		return
	_track = _ship.get_parent().get_node_or_null("Track")
	if _track != null and _track.has_signal("track_generated"):
		if not _track.track_generated.is_connected(_on_track_generated):
			_track.track_generated.connect(_on_track_generated)


func _on_track_generated(_seed_value: int, _spawn_pos: Vector2, _spawn_rot: float) -> void:
	_offset_velocity = Vector2.ZERO
	_needs_snap = true


func _compute_course_zoom(sightline_dist_px: float) -> float:
	var d_turn := minf(turn_sightline_px, medium_sightline_px - 1.0)
	var d_med := medium_sightline_px
	var d_str := maxf(straight_sightline_px, medium_sightline_px + 1.0)

	if sightline_dist_px <= d_med:
		var t := clampf((sightline_dist_px - d_turn) / maxf(d_med - d_turn, 1.0), 0.0, 1.0)
		var eased := t * t * (3.0 - 2.0 * t)
		return lerpf(close_zoom, default_zoom, eased)
	else:
		var t := clampf((sightline_dist_px - d_med) / maxf(d_str - d_med, 1.0), 0.0, 1.0)
		var eased := t * t * (3.0 - 2.0 * t)
		return lerpf(default_zoom, wide_zoom, eased)


func _process(delta: float) -> void:
	if _ship == null:
		return

	if _track == null:
		_bind_track()

	var target_zoom_scalar := default_zoom
	var target_offset := Vector2.ZERO
	var vp_size := get_viewport_rect().size

	if enable_course_framing and _track != null and _track.has_method("get_course_sightline"):
		var sightline: Dictionary = _track.get_course_sightline(
			_ship.global_position,
			deg_to_rad(turn_threshold_deg),
			max_sightline_px
		)
		var true_anchor_world: Vector2 = sightline.get("anchor_world", _ship.global_position)
		var rail_anchor_world: Vector2 = sightline.get("rail_anchor_world", true_anchor_world)
		var sightline_dist_px: float = float(sightline.get("sightline_dist_px", medium_sightline_px))

		# 1. Honest orientation-independent zoom curve:
		#    tight turn -> close_zoom | normal track -> default_zoom | big straight -> wide_zoom
		if enable_course_zoom:
			target_zoom_scalar = _compute_course_zoom(sightline_dist_px)

		# 2. Gentle-arc offset target: aim toward the smoothed camera rail at the corner anchor
		var blended_anchor := true_anchor_world.lerp(rail_anchor_world, rail_arc_blend)
		var raw_lead := (blended_anchor - _ship.global_position) * anchor_lead_weight

		# Clamp inside an elliptical viewport margin using the active zoom so the ship never leaves view
		var ref_zoom := maxf(zoom.x if not _needs_snap else target_zoom_scalar, 0.05)
		var max_x := (vp_size.x / ref_zoom) * max_lead_screen_fraction
		var max_y := (vp_size.y / ref_zoom) * max_lead_screen_fraction
		var norm_x := raw_lead.x / maxf(max_x, 1.0)
		var norm_y := raw_lead.y / maxf(max_y, 1.0)
		var ellip_len := sqrt(norm_x * norm_x + norm_y * norm_y)
		if ellip_len > 1.0:
			target_offset = raw_lead / ellip_len
		else:
			target_offset = raw_lead

	# Snap cleanly on initial frame or fresh track generation (no dragging across the map)
	if _needs_snap:
		zoom = Vector2(target_zoom_scalar, target_zoom_scalar)
		offset = target_offset
		_offset_velocity = Vector2.ZERO
		_needs_snap = false
		return

	# Asymmetric zoom damping: snappier tightening into hairpins, calm unfurling onto straights
	var zoom_rate := zoom_in_smoothing if target_zoom_scalar > zoom.x else zoom_out_smoothing
	var zoom_alpha := 1.0 - exp(-maxf(zoom_rate, 0.01) * delta)
	var next_zoom := lerpf(zoom.x, target_zoom_scalar, zoom_alpha)
	zoom = Vector2(next_zoom, next_zoom)

	# Critically damped spring for camera offset: continuous velocity -> smooth, rounded arcs with zero whip
	var omega := 2.0 / maxf(offset_smooth_time, 0.01)
	var x := omega * delta
	var exp_factor := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change := offset - target_offset
	var temp := (_offset_velocity + omega * change) * delta
	_offset_velocity = (_offset_velocity - omega * temp) * exp_factor
	offset = target_offset + (change + temp) * exp_factor
