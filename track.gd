extends StaticBody2D

@export var wall_thickness: float = 20.0

func _ready() -> void:
	_build_wall($OuterWallVisual)
	_build_wall($InnerWallVisual)

func _build_wall(line: Line2D) -> void:
	var pts := line.points
	for i in pts.size():
		if not line.closed and i == pts.size() - 1:
			break
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		
		var col := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(a.distance_to(b) + wall_thickness, wall_thickness)
		col.shape = rect
		col.position = (a + b) * 0.5
		col.rotation = (b - a).angle()
		add_child(col)



















# extends StaticBody2D
#
#
# # Called when the node enters the scene tree for the first time.
# func _ready() -> void:
# 	$OuterWallCollision.polygon = $OuterWallVisual.points
# 	$InnerWallCollision.polygon = $InnerWallVisual.points
#
# # Called every frame. 'delta' is the elapsed time since the previous frame.
# func _process(delta: float) -> void:
# 	pass
