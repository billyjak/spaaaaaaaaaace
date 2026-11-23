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
## Total thermal energy capacity (kJ) before reaching thermal safety redline (100% heat).
@export var heat_capacity_kj: float = 100.0
## Peak passive radiative cooling power (kW) at redline temperature via Stefan-Boltzmann T^4 law.
@export var max_radiative_cooling_kw: float = 18.0
