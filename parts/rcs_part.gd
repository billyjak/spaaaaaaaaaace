class_name RCSPart
extends ShipPart

## Specific impulse I_sp (seconds) for RCS nozzles.
## Benchmarks: ~70 s cold gas, ~260 s hypergolic/green monopropellant, ~1,200 s plasma/arcjet.
@export var specific_impulse: float = 260.0
## Tech-tier thrust density multiplier applied on top of the square-cube mass^(2/3) scaling law.
## 1.0 = baseline starter RCS (1.5 kN/nozzle @ 20 kg), >1.0 = higher-tech maneuvering jets.
@export var tech_thrust_multiplier: float = 1.0


func get_nozzle_thrust_newtons(ref_mass: float, ref_nozzle_thrust_n: float, exponent: float) -> float:
	if mass_kg <= 0.0 or ref_mass <= 0.0 or ref_nozzle_thrust_n <= 0.0 or tech_thrust_multiplier <= 0.0:
		return 0.0
	var mass_ratio := mass_kg / ref_mass
	return ref_nozzle_thrust_n * pow(mass_ratio, exponent) * tech_thrust_multiplier
