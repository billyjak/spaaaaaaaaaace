class_name ShipData
extends Resource

## Display name shown in the Telemetry HUD and future Ship Select menu.
@export var ship_name: String = "Unnamed Ship"

@export_group("Installed Parts")
@export var hull: HullPart
@export var thruster: ThrusterPart
@export var rcs: RCSPart
@export var aux_parts: Array[ShipPart] = []


## Returns human-readable warnings if any installed part doesn't match the hull's size class.
func get_size_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if hull == null:
		return warnings
	var hull_size := hull.size_class
	var hull_size_label := ShipPart.size_class_name(hull_size)

	if thruster != null and not thruster.fits_hull_size(hull_size):
		warnings.append(
			"%s (%s) does not fit %s hull"
			% [thruster.part_name, ShipPart.size_class_name(thruster.size_class), hull_size_label]
		)
	if rcs != null and not rcs.fits_hull_size(hull_size):
		warnings.append(
			"%s (%s) does not fit %s hull"
			% [rcs.part_name, ShipPart.size_class_name(rcs.size_class), hull_size_label]
		)
	for aux in aux_parts:
		if aux != null and not aux.fits_hull_size(hull_size):
			warnings.append(
				"%s (%s) does not fit %s hull"
				% [aux.part_name, ShipPart.size_class_name(aux.size_class), hull_size_label]
			)
	return warnings
