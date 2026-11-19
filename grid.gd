extends Node2D

@export var grid_size: float = 100.0
@export var grid_color: Color = Color(0.6, 0.6, 0.6, 1.0)
@export var line_width: float = 2.0
@export var extent: float = 40000.0

func _ready() -> void:
	queue_redraw()

func _draw() -> void:
	var x := -extent
	while x <= extent:
		draw_line(Vector2(x, -extent), Vector2(x, extent), grid_color, line_width)
		x += grid_size
	
	var y := -extent
	while y <= extent:
		draw_line(Vector2(-extent, y), Vector2(extent, y), grid_color, line_width)
		y += grid_size

func _process(_delta: float) -> void:
	queue_redraw()
