class_name HullPart
extends ShipPart

## Visual + HullCollision scene for this hull.
@export var hull_scene: PackedScene
## Maximum shared propellant tank capacity in kilograms.
@export var fuel_capacity_kg: float = 250.0
## Uniform radius of gyration (m) used for rotational inertia I = sum(m * r^2).
@export var inertia_radius_m: float = 1.5
## Equidistant lever arm (m) from center of mass to symmetric RCS nozzles.
@export var rcs_lever_arm_m: float = 1.8
