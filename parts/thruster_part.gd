class_name ThrusterPart
extends ShipPart

## Specific impulse I_sp (seconds). Higher I_sp = higher exhaust velocity = less fuel burned per Newton.
## Benchmarks: ~310 s chemical (NASA-era), ~900 s nuclear thermal, ~2,500+ s fusion torch.
@export var specific_impulse: float = 310.0
## Tech-tier thrust density multiplier applied on top of the square-cube mass^(2/3) scaling law.
## 1.0 = baseline 1960s chemical (9 kN @ 35 kg), >1.0 = higher-tech propulsion.
@export var tech_thrust_multiplier: float = 1.0
## Main thrust multiplier applied while Overburn is active (2.0 = 200% thrust).
@export var overburn_thrust_multiplier: float = 2.0
## Fuel burn multiplier applied while Overburn is active (4.0 = 400% fuel consumption).
@export var overburn_fuel_multiplier: float = 4.0
## Thermal power (kW) dumped into the ship's thermal pool while Overburn is firing.
@export var overburn_heat_kw: float = 44.0


func get_max_thrust_newtons(ref_mass: float, ref_thrust_n: float, exponent: float) -> float:
	if mass_kg <= 0.0 or ref_mass <= 0.0 or ref_thrust_n <= 0.0 or tech_thrust_multiplier <= 0.0:
		return 0.0
	var mass_ratio := mass_kg / ref_mass
	return ref_thrust_n * pow(mass_ratio, exponent) * tech_thrust_multiplier
