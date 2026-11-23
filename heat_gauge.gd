extends Control

# ---------------------------------------------------------------------------
# Thermal Heat Gauge (GUI-Movable & Resizable)
# Draws a clean horizontal heat bar inside its parent PanelContainer, smoothly
# shifting yellow -> orange -> red as heat fills from 0% to 100%, with a 50%
# safety-interlock recovery marker and vivid pulse while locked out.
# ---------------------------------------------------------------------------

@export var bg_color: Color = Color(0.08, 0.10, 0.14, 0.90)
@export var border_color: Color = Color(0.32, 0.45, 0.58, 0.70)
@export var low_heat_color: Color = Color(1.0, 0.88, 0.20, 1.0) # Yellow
@export var mid_heat_color: Color = Color(1.0, 0.50, 0.08, 1.0) # Orange
@export var high_heat_color: Color = Color(1.0, 0.14, 0.12, 1.0) # Red
@export var lockout_flash_color: Color = Color(1.0, 0.08, 0.16, 1.0)
@export var tick_color: Color = Color(0.92, 0.96, 1.0, 0.65)
@export var text_color: Color = Color(0.95, 0.98, 1.0, 0.95)
@export var font_size: int = 14

var _ship: Node = null
var _pulse_time: float = 0.0


func _ready() -> void:
	_find_ship()


func _find_ship() -> void:
	if _ship != null:
		return
	var cur: Node = get_parent()
	while cur != null:
		if cur.has_method("get_heat_fraction"):
			_ship = cur
			return
		cur = cur.get_parent()


func _process(delta: float) -> void:
	if _ship == null:
		_find_ship()
	_pulse_time += delta
	queue_redraw()


func _heat_color(frac: float, locked_out: bool) -> Color:
	var c: Color
	if frac <= 0.5:
		c = low_heat_color.lerp(mid_heat_color, clampf(frac * 2.0, 0.0, 1.0))
	else:
		c = mid_heat_color.lerp(high_heat_color, clampf((frac - 0.5) * 2.0, 0.0, 1.0))
	if locked_out:
		var pulse := 0.5 + 0.5 * sin(_pulse_time * 12.0)
		c = c.lerp(lockout_flash_color, 0.45 + 0.45 * pulse)
	return c


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	if rect.size.x <= 4.0 or rect.size.y <= 4.0:
		return

	var heat_frac := 0.0
	var locked_out := false
	var overburning := false
	var recovery_frac := 0.25
	if _ship != null:
		heat_frac = clampf(float(_ship.get_heat_fraction()), 0.0, 1.0)
		if "overburn_locked_out" in _ship:
			locked_out = bool(_ship.overburn_locked_out)
		if "is_overburning" in _ship:
			overburning = bool(_ship.is_overburning)
		if "overheat_recovery_fraction" in _ship:
			recovery_frac = clampf(float(_ship.overheat_recovery_fraction), 0.0, 1.0)

	# Bar background
	draw_rect(rect, bg_color, true)

	# Filled heat bar
	var pad := 2.0
	var inner_w := maxf(rect.size.x - pad * 2.0, 0.0)
	var inner_h := maxf(rect.size.y - pad * 2.0, 0.0)
	if heat_frac > 0.001 and inner_w > 0.0 and inner_h > 0.0:
		var fill_rect := Rect2(Vector2(pad, pad), Vector2(inner_w * heat_frac, inner_h))
		var bar_col := _heat_color(heat_frac, locked_out)
		draw_rect(fill_rect, bar_col, true)
		# Bright leading edge highlight while actively overburning
		if overburning and fill_rect.size.x > 4.0:
			var edge_rect := Rect2(
				Vector2(fill_rect.position.x + fill_rect.size.x - 4.0, pad),
				Vector2(4.0, inner_h)
			)
			draw_rect(edge_rect, Color(1.0, 1.0, 0.92, 0.85), true)

	# 50% safety-interlock recovery tick line
	var tick_x := pad + inner_w * recovery_frac
	draw_line(
		Vector2(tick_x, pad),
		Vector2(tick_x, rect.size.y - pad),
		tick_color,
		1.5
	)

	# Crisp outline (turns bright red while locked out)
	var frame_col := lockout_flash_color if locked_out else border_color
	draw_rect(rect, frame_col, false, 1.5)

	# Centered status readout
	var font := ThemeDB.fallback_font
	if font != null:
		var pct := int(round(heat_frac * 100.0))
		var label_text := "HEAT %d%%" % pct
		if locked_out:
			label_text = "OVERHEAT LOCKOUT  %d%%" % pct
		elif overburning:
			label_text = "OVERBURN  %d%%" % pct

		var text_size := font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		var text_pos := Vector2(
			(rect.size.x - text_size.x) * 0.5,
			(rect.size.y + text_size.y * 0.65) * 0.5
		)
		# Dark drop shadow for high contrast over bright yellow/orange fill
		draw_string(font, text_pos + Vector2(1.0, 1.0), label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.0, 0.0, 0.0, 0.85))
		draw_string(font, text_pos, label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)
