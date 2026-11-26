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
## Baseline Tier 1 structural impact limit (in G at a 50 ms crush pulse) before this
## module shears off or ruptures. Higher hull tech tiers automatically scale this upward.
@export_range(1.0, 500.0, 1.0) var shear_g_limit: float = 11.0
## Multiplier applied to shear_g_limit when impact force pushes straight along the
## module's axial centerline into the hub (compression) vs perpendicular (90 deg shear).
@export_range(1.0, 5.0, 0.1) var axial_strength_multiplier: float = 2.2
