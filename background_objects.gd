extends Node2D

# ---------------------------------------------------------------------------
# True-Perspective Continuous-Depth Space Background (Sprites X2 Only)
# Every object sits at a real 3D distance Z behind the ship plane (Z = 1.0):
#   - Parallax scroll speed:  depth = 1.0 / Z
#   - Perspective scale:      scale = base_scale * size_mult * (1.0 / Z)
#
# Distance Z is weighted toward far space (like a widening 3D camera frustum)
# and extends out to Z = 110 so asteroids shrink smoothly all the way down to
# ~2-3 px specks before vanishing into the static Milky Way starfield (no hard
# 200m depth cliff). Sparse colossal deep-space anchors (gigantic dwarf-asteroids
# and megastations at Z = 35..95) ground the scene with unmistakable scale.
#
# All sprites stay at or below native resolution (never blurry-upscaled).
# ---------------------------------------------------------------------------

const STATION_TEXTURES: PackedStringArray = [
	"res://resources/kenney_space-shooter-extension/PNG/Sprites X2/CompleteStations/spaceStation_017.png",
	"res://resources/kenney_space-shooter-extension/PNG/Sprites X2/CompleteStations/spaceStation_018.png",
	"res://resources/kenney_space-shooter-extension/PNG/Sprites X2/CompleteStations/spaceStation_019.png",
	"res://resources/kenney_space-shooter-extension/PNG/Sprites X2/CompleteStations/spaceStation_020.png",
	"res://resources/kenney_space-shooter-extension/PNG/Sprites X2/CompleteStations/spaceStation_024.png",
	"res://resources/kenney_space-shooter-extension/PNG/Sprites X2/CompleteStations/spaceStation_025.png",
	"res://resources/kenney_space-shooter-extension/PNG/Sprites X2/CompleteStations/spaceStation_026.png",
]

const COLOSSAL_STATION_TEXTURES: PackedStringArray = [
	"res://resources/kenney_space-shooter-extension/PNG/Sprites X2/CompleteStations/spaceStation_017.png",
	"res://resources/kenney_space-shooter-extension/PNG/Sprites X2/CompleteStations/spaceStation_026.png",
]

const COLOSSAL_METEOR_TEXTURES: PackedStringArray = [
	"res://resources/SpaceShipsPack-AntuZ/Extras/meteor-01-xl.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/meteor-02-xl.png",
]

const METEOR_TEXTURES: PackedStringArray = [
	"res://resources/SpaceShipsPack-AntuZ/Extras/meteor-01-s.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/meteor-02-s.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/meteor-01-m.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/meteor-02-m.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/meteor-01-l.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/meteor-02-l.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/meteor-01-xl.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/meteor-02-xl.png",
]

const DUST_TEXTURES: PackedStringArray = [
	"res://resources/SpaceShipsPack-AntuZ/Extras/space-dust-01.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/space-dust-01s.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/space-dust-02.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/space-dust-02s.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/space-dust-03.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/space-dust-03s.png",
	"res://resources/SpaceShipsPack-AntuZ/Extras/space-dust-04.png",
]

@export_group("Generation & Counts")
## 0 = fresh random background every launch; non-zero = deterministic layout.
@export var random_seed: int = 0
## Seamless toroidal wrap box around the camera (large enough to hide wrapping even when zoomed out).
@export var field_size: Vector2 = Vector2(5200.0, 3800.0)
## Number of asteroids across the full 3D frustum (Z = 2.2..110; mostly mid/far, sparse up close).
@export_range(0, 500) var meteor_count: int = 240
## Number of Kenney high-res space stations across the 3D frustum.
@export_range(0, 100) var station_count: int = 26
## Number of translucent space dust clouds.
@export_range(0, 100) var dust_count: int = 24
## Sparse colossal deep-space landmarks (gigantic xl asteroids & 017/026 megastations at Z = 35..95).
@export_range(0, 20) var colossal_anchor_count: int = 8
## Probability that a colossal anchor is an AntuZ xl asteroid instead of a 017/026 megastation.
@export_range(0.0, 1.0, 0.05) var anchor_asteroid_chance: float = 0.72
## Scale range for colossal AntuZ xl asteroids (~52px native -> ~180-320px world width).
@export var colossal_asteroid_scale_range: Vector2 = Vector2(3.5, 6.0)

@export_group("3D Distance Ranges Z (1.0 = Ship Plane, Larger = Farther)")
## Distance Z range for meteors (2.2 -> depth 0.45 close; 110.0 -> depth 0.009 tiny 2-3px specks).
@export var meteor_z_range: Vector2 = Vector2(2.2, 110.0)
## Distance Z range for space stations (3.0 -> depth 0.33 close; 60.0 -> depth 0.017 distant).
@export var station_z_range: Vector2 = Vector2(3.0, 60.0)
## Distance Z range for space dust clouds.
@export var dust_z_range: Vector2 = Vector2(2.5, 40.0)
## Distance Z range for colossal deep-space anchors (very slow parallax, huge apparent scale).
@export var anchor_z_range: Vector2 = Vector2(35.0, 95.0)
## Logarithmic depth bias (< 1.0 puts slightly more rocks in deeper octaves; 1.0 = equal rocks per distance doubling).
@export_range(0.5, 1.5, 0.05) var frustum_far_bias: float = 0.85

@export_group("Perspective Scales & Sharpness Cap")
## Perspective scale multiplier at Z = 1.0 for AntuZ meteors (scale = base * size_mult / Z).
@export var meteor_base_scale: float = 1.8
## Hard upper scale cap on AntuZ meteors (~54px max native) so close rocks stay crisp and never blur.
@export var max_meteor_scale: float = 1.05
## Perspective scale multiplier at Z = 1.0 for X2 space stations (scale = base / Z).
@export var station_base_scale: float = 1.55
## Hard upper scale cap on X2 station sprites so nothing ever stretches past crisp native resolution.
@export var max_station_scale: float = 0.72

@export_group("Meteor Size (Bell Curve) & Spin Physics")
## Minimum physical size multiplier for rare tiny pebbles.
@export var meteor_min_size_mult: float = 0.5
## Maximum physical size multiplier for rare behemoth asteroids.
@export var meteor_max_size_mult: float = 5.0
## Center (mean) of the Gaussian bell curve where the majority of asteroids fall.
@export var meteor_size_mean: float = 2.75
## Standard deviation of the bell curve (~68% within mean +/- 1*stddev; ~2.3% at each tail).
@export_range(0.1, 2.0, 0.05) var meteor_size_stddev: float = 0.75
## Maximum safe spin rate (rad/s) for a 1.0x reference rock; scales down as 1 / size_mult^exponent.
@export var max_spin_at_1x_rad_s: float = 1.1
## Exponent controlling how sharply spin drops with rock size (1.0 = tensile 1/R limit, 0.5 = rubble-pile).
@export_range(0.5, 1.5, 0.05) var spin_size_exponent: float = 1.0
## Minimum fraction of a rock's safe spin limit.
@export_range(0.0, 1.0, 0.05) var min_spin_fraction: float = 0.2

var _rng := RandomNumberGenerator.new()
var _station_res: Array[Texture2D] = []
var _colossal_station_res: Array[Texture2D] = []
var _colossal_meteor_res: Array[Texture2D] = []
var _meteor_res: Array[Texture2D] = []
var _dust_res: Array[Texture2D] = []

# Each entry: { "node": Sprite2D, "anchor": Vector2, "depth": float, "z_dist": float, "angular_vel": float }
var _bg_objects: Array[Dictionary] = []


func _ready() -> void:
	_load_textures()
	regenerate()


func _load_texture_safe(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	var abs_path := ProjectSettings.globalize_path(path)
	var img := Image.load_from_file(abs_path)
	if img != null and not img.is_empty():
		return ImageTexture.create_from_image(img)
	return null


func _load_textures() -> void:
	_station_res.clear()
	for path in STATION_TEXTURES:
		var tex := _load_texture_safe(path)
		if tex != null:
			_station_res.append(tex)

	_colossal_station_res.clear()
	for path in COLOSSAL_STATION_TEXTURES:
		var tex := _load_texture_safe(path)
		if tex != null:
			_colossal_station_res.append(tex)

	_colossal_meteor_res.clear()
	for path in COLOSSAL_METEOR_TEXTURES:
		var tex := _load_texture_safe(path)
		if tex != null:
			_colossal_meteor_res.append(tex)

	_meteor_res.clear()
	for path in METEOR_TEXTURES:
		var tex := _load_texture_safe(path)
		if tex != null:
			_meteor_res.append(tex)

	_dust_res.clear()
	for path in DUST_TEXTURES:
		var tex := _load_texture_safe(path)
		if tex != null:
			_dust_res.append(tex)


# Logarithmic depth sampling across [min_z, max_z]: ensures every doubling of distance
# (2->4->8->16->32->64->110) is continuously populated with zero gaps or abrupt cliffs.
func _sample_frustum_z(min_z: float, max_z: float) -> float:
	var lo := maxf(minf(min_z, max_z), 1.0)
	var hi := maxf(maxf(min_z, max_z), lo)
	var u := pow(_rng.randf(), frustum_far_bias)
	return lo * pow(hi / lo, u)


func regenerate() -> void:
	for child in get_children():
		child.queue_free()
	_bg_objects.clear()

	if random_seed == 0:
		_rng.randomize()
	else:
		_rng.seed = random_seed

	# 1. Colossal Deep-Space Anchors (AntuZ xl giant asteroids + 017/026 X2 megastations)
	# Asteroids are more common than stations (anchor_asteroid_chance = 0.72).
	if colossal_anchor_count > 0 and (not _colossal_meteor_res.is_empty() or not _colossal_station_res.is_empty()):
		var placed_anchors: Array[Vector2] = []
		var min_anchor_sep := minf(field_size.x, field_size.y) * 0.28
		for _i in colossal_anchor_count:
			var z_dist := _rng.randf_range(anchor_z_range.x, anchor_z_range.y)
			var depth := 1.0 / maxf(z_dist, 1.0)
			var anchor := _pick_spaced_position(field_size, placed_anchors, min_anchor_sep)
			placed_anchors.append(anchor)

			var is_asteroid := _colossal_station_res.is_empty() or (
				not _colossal_meteor_res.is_empty() and _rng.randf() < anchor_asteroid_chance
			)
			var tex: Texture2D = (
				_colossal_meteor_res[_rng.randi_range(0, _colossal_meteor_res.size() - 1)]
				if is_asteroid
				else _colossal_station_res[_rng.randi_range(0, _colossal_station_res.size() - 1)]
			)

			var sprite := Sprite2D.new()
			sprite.texture = tex
			sprite.rotation = _rng.randf_range(0.0, TAU)
			var s := (
				_rng.randf_range(colossal_asteroid_scale_range.x, colossal_asteroid_scale_range.y)
				if is_asteroid
				else minf(_rng.randf_range(0.48, 0.72), max_station_scale)
			)
			sprite.scale = Vector2(s, s)
			# Subtle deeper-space shading so foreground ship/asteroids read clearly over the mega-anchor
			var shade := _rng.randf_range(0.68, 0.84)
			sprite.modulate = Color(shade * 0.94, shade * 0.97, shade, 1.0)
			sprite.z_index = -1000 + int(round(depth * 900.0)) - 10
			add_child(sprite)

			var spin_dir := 1.0 if _rng.randf() >= 0.5 else -1.0
			var angular_vel := (
				spin_dir * _rng.randf_range(0.004, 0.015)
				if is_asteroid
				else spin_dir * _rng.randf_range(0.0, 0.004)
			)

			_bg_objects.append({
				"node": sprite,
				"anchor": anchor,
				"depth": depth,
				"z_dist": z_dist,
				"base_scale": s,
				"is_anchor": true,
				"is_anchor_asteroid": is_asteroid,
				"angular_vel": angular_vel,
			})

	# 2. Space Dust Clouds
	if dust_count > 0 and not _dust_res.is_empty():
		for _i in dust_count:
			var z_dist := _sample_frustum_z(dust_z_range.x, dust_z_range.y)
			var depth := 1.0 / maxf(z_dist, 1.0)
			var z_t := clampf((z_dist - dust_z_range.x) / maxf(dust_z_range.y - dust_z_range.x, 0.001), 0.0, 1.0)

			var sprite := Sprite2D.new()
			sprite.texture = _dust_res[_rng.randi_range(0, _dust_res.size() - 1)]
			sprite.rotation = _rng.randf_range(0.0, TAU)
			var s := lerpf(1.1, 3.0, z_t) * _rng.randf_range(0.75, 1.3)
			sprite.scale = Vector2(s, s)
			var alpha := lerpf(0.12, 0.26, z_t) * _rng.randf_range(0.75, 1.2)
			sprite.modulate = Color(0.9, 0.92, 1.0, alpha)
			sprite.z_index = -1000 + int(round(depth * 900.0)) - 5
			add_child(sprite)

			var anchor := Vector2(_rng.randf_range(0.0, field_size.x), _rng.randf_range(0.0, field_size.y))
			_bg_objects.append({
				"node": sprite,
				"anchor": anchor,
				"depth": depth,
				"z_dist": z_dist,
				"base_scale": s,
				"angular_vel": 0.0,
			})

	# 3. Kenney High-Res Complete Stations (true 3D frustum Z & 1/Z perspective scaling)
	if station_count > 0 and not _station_res.is_empty():
		var placed_stations: Array[Vector2] = []
		var min_station_sep := minf(field_size.x, field_size.y) * 0.12
		for _i in station_count:
			var z_dist := _sample_frustum_z(station_z_range.x, station_z_range.y)
			var depth := 1.0 / maxf(z_dist, 1.0)
			var anchor := _pick_spaced_position(field_size, placed_stations, min_station_sep)
			placed_stations.append(anchor)

			var sprite := Sprite2D.new()
			sprite.texture = _station_res[_rng.randi_range(0, _station_res.size() - 1)]
			sprite.rotation = _rng.randf_range(0.0, TAU)
			var s := minf(station_base_scale * depth * _rng.randf_range(0.85, 1.15), max_station_scale)
			sprite.scale = Vector2(s, s)
			var shade := _rng.randf_range(0.86, 1.0)
			sprite.modulate = Color(shade * 0.96, shade * 0.98, shade, 1.0)
			sprite.z_index = -1000 + int(round(depth * 900.0))
			add_child(sprite)

			_bg_objects.append({
				"node": sprite,
				"anchor": anchor,
				"depth": depth,
				"z_dist": z_dist,
				"base_scale": s,
				"angular_vel": 0.0,
			})

	# 4. AntuZ Meteors (meteor-01/02-s/m/l/xl.png):
	#    Roll physical size on symmetric Gaussian bell curve
	# -> Match AntuZ s/m/l/xl sprite resolution to size tier
	# -> Compute safe structural spin limit from physical size (larger -> slower)
	# -> Roll logarithmic 3D distance Z (2.2..110) and cap scale <= max_meteor_scale so rocks stay crisp
	if meteor_count > 0 and not _meteor_res.is_empty():
		for _i in meteor_count:
			# Step 1: Roll physical size multiplier on a symmetric bell curve
			var size_mult := clampf(
				_rng.randfn(meteor_size_mean, meteor_size_stddev),
				meteor_min_size_mult,
				meteor_max_size_mult
			)

			var tex := _pick_meteor_texture_for_size(size_mult)

			# Step 2: Structural spin barrier from true physical size (larger rock -> slower max spin)
			var max_safe_omega := max_spin_at_1x_rad_s / pow(maxf(size_mult, 0.2), spin_size_exponent)
			var spin_dir := 1.0 if _rng.randf() >= 0.5 else -1.0
			var angular_vel := spin_dir * max_safe_omega * _rng.randf_range(min_spin_fraction, 1.0)

			# Step 3: Roll logarithmic 3D distance Z
			var effective_min_z := maxf(meteor_z_range.x, 1.4 + maxf(size_mult - 2.0, 0.0) * 0.65)
			var z_dist := _sample_frustum_z(effective_min_z, meteor_z_range.y)
			var depth := 1.0 / maxf(z_dist, 1.0)

			var sprite := Sprite2D.new()
			sprite.texture = tex
			sprite.rotation = _rng.randf_range(0.0, TAU)
			# True 1/Z perspective scaling, capped <= max_meteor_scale so AntuZ sprites stay sharp
			var s := minf(meteor_base_scale * size_mult * depth, max_meteor_scale)
			sprite.scale = Vector2(s, s)
			var shade := _rng.randf_range(0.80, 1.0)
			sprite.modulate = Color(shade, shade, shade, 1.0)
			sprite.z_index = -1000 + int(round(depth * 900.0))
			add_child(sprite)

			var anchor := Vector2(_rng.randf_range(0.0, field_size.x), _rng.randf_range(0.0, field_size.y))
			_bg_objects.append({
				"node": sprite,
				"anchor": anchor,
				"depth": depth,
				"z_dist": z_dist,
				"base_scale": s,
				"size_mult": size_mult,
				"angular_vel": angular_vel,
			})

	_update_positions(0.0)


# METEOR_TEXTURES is ordered [s, s, m, m, l, l, xl, xl].
# Match sprite size class to rolled physical size so behemoths use xl and pebbles use s.
func _pick_meteor_texture_for_size(size_mult: float) -> Texture2D:
	if _meteor_res.size() < 8:
		return _meteor_res[_rng.randi_range(0, _meteor_res.size() - 1)]
	if size_mult >= 4.0:
		return _meteor_res[_rng.randi_range(6, 7)] # xl
	if size_mult >= 3.2:
		return _meteor_res[_rng.randi_range(4, 7)] # l / xl
	if size_mult >= 2.0:
		return _meteor_res[_rng.randi_range(2, 5)] # m / l
	if size_mult >= 1.25:
		return _meteor_res[_rng.randi_range(0, 3)] # s / m
	return _meteor_res[_rng.randi_range(0, 1)] # s


func _pick_spaced_position(bounds: Vector2, existing: Array[Vector2], min_dist: float) -> Vector2:
	var best_pos := Vector2(_rng.randf_range(0.0, bounds.x), _rng.randf_range(0.0, bounds.y))
	var best_min_d := -1.0
	for _attempt in range(16):
		var candidate := Vector2(_rng.randf_range(0.0, bounds.x), _rng.randf_range(0.0, bounds.y))
		var nearest := INF
		for other in existing:
			var dx := absf(candidate.x - other.x)
			dx = minf(dx, bounds.x - dx)
			var dy := absf(candidate.y - other.y)
			dy = minf(dy, bounds.y - dy)
			nearest = minf(nearest, sqrt(dx * dx + dy * dy))
		if nearest >= min_dist:
			return candidate
		if nearest > best_min_d:
			best_min_d = nearest
			best_pos = candidate
	return best_pos


func _process(delta: float) -> void:
	_update_positions(delta)


func _update_positions(delta: float) -> void:
	var cam := get_viewport().get_camera_2d() if get_viewport() != null else null
	var cam_pos := cam.get_screen_center_position() if cam != null else Vector2.ZERO
	var cam_zoom := maxf(cam.zoom.x, 0.05) if cam != null else 1.0
	var half_w := field_size.x * 0.5
	var half_h := field_size.y * 0.5

	for entry in _bg_objects:
		var sprite: Sprite2D = entry["node"]
		var anchor: Vector2 = entry["anchor"]
		var depth: float = entry["depth"]
		var z_dist: float = entry["z_dist"]
		var base_scale: float = entry["base_scale"]

		# True 3D camera altitude projection (Z_cam = 1 / cam_zoom above the ship plane Z = 0):
		# Cancels Godot's 2D lens magnification so zooming behaves like physically moving the
		# camera closer/farther — near rocks scale and separate naturally, while distant stations
		# and colossal anchors stay solid and steady against the stars.
		var altitude_comp := z_dist / (1.0 + cam_zoom * maxf(z_dist - 1.0, 0.0))

		var rel_x := fposmod(anchor.x - cam_pos.x * depth + half_w, field_size.x) - half_w
		var rel_y := fposmod(anchor.y - cam_pos.y * depth + half_h, field_size.y) - half_h
		sprite.global_position = cam_pos + Vector2(rel_x, rel_y) * altitude_comp

		var s := base_scale * altitude_comp
		sprite.scale = Vector2(s, s)

		var ang_vel: float = entry["angular_vel"]
		if ang_vel != 0.0 and delta > 0.0:
			sprite.rotation += ang_vel * delta
