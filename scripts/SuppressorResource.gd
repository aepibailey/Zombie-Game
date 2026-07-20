extends Resource
class_name SuppressorResource
## A weapon attachment bought at the supply crate. Attaching it to the M17 swaps the
## gunshot noise radius from 40m to 8m (PROJECT_SPEC.md "Attachments"). This is
## the proof-of-concept for the whole attachment pipeline — foregrip / IR laser
## follow the identical pattern.

@export var display_name: String = "Suppressor"
@export var shot_noise_radius: float = 8.0
