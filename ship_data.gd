class_name ShipData
extends Resource

## Display name shown in the Telemetry HUD and future Ship Select menu.
@export var ship_name: String = "Unnamed Ship"
## Hull visual + collider scene (must contain ShipSprite, ExhaustSprite, HullCollision, and 6 RCS nozzles).
@export var hull_scene: PackedScene

@export_group("Ship Parts (Mass in kg)")
@export var thruster_mass: float = 35.0
@export var fuel_mass: float = 200.0
@export var ship_part_3_mass: float = 120.0
@export var ship_part_4_mass: float = 45.0
@export var ship_part_5_mass: float = 0.0

@export_group("Inertia & RCS")
@export var inertia_radius_m: float = 1.5
@export var rcs_torque: float = 45000.0
@export var rcs_linear_force: float = 6000.0
