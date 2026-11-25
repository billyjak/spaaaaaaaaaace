class_name ShipModule
extends Node2D

## Role determines which installed part / resource mass lives on this module:
## - STRUCTURE / TRANSMITTER: receives a weighted slice of installed_hull.mass_kg
## - FUEL_TANK: receives its weighted slice of installed_hull.mass_kg PLUS live fuel_mass
## - MAIN_ENGINE: carries installed_thruster.mass_kg (hull_mass_weight typically 0)
enum ModuleRole {
	STRUCTURE = 0,
	FUEL_TANK = 1,
	MAIN_ENGINE = 2,
	TRANSMITTER = 3,
}

@export var role: ModuleRole = ModuleRole.STRUCTURE
## Relative weight used to distribute installed_hull.mass_kg across structural modules.
## For example, weights summing to 100 read directly as percentages of hull dry mass.
@export_range(0.0, 100.0, 0.5) var hull_mass_weight: float = 10.0
