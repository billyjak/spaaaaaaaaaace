class_name ShipPart
extends Resource

enum SizeClass {
	SMALL,
	MEDIUM,
	LARGE,
	UNIVERSAL,
}

## Display name for telemetry, inspector, and future shop/garage UI.
@export var part_name: String = "Unnamed Part"
## Tech tier (1 = NASA-era starter, 2 = Mid-early, 3 = Mid-late, 4 = Exotic).
@export_range(1, 4) var tech_tier: int = 1
## Which hull size class this part is built for (UNIVERSAL fits any hull).
@export var size_class: SizeClass = SizeClass.MEDIUM
## Physical dry mass of this component in kilograms (contributes to ship mass & inertia).
@export var mass_kg: float = 0.0
@export_multiline var description: String = ""


func fits_hull_size(hull_size: SizeClass) -> bool:
	return size_class == SizeClass.UNIVERSAL or size_class == hull_size


static func size_class_name(size: SizeClass) -> String:
	match size:
		SizeClass.SMALL:
			return "Small"
		SizeClass.MEDIUM:
			return "Medium"
		SizeClass.LARGE:
			return "Large"
		SizeClass.UNIVERSAL:
			return "Universal"
	return "Unknown"
