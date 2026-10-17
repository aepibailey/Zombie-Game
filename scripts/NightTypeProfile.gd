extends Resource
class_name NightTypeProfile
## Data-driven night type: how one night's shape departs from the escalation
## curve. Modeled on ZombieType — a new night type is a .tres file, not a code
## change. See docs/RUN_STRUCTURE.md "Escalation, night types and Day".
##
## Every field OVERRIDES an existing tunable or multiplies an existing
## result; none of them needs a system of its own. All defaults are "no
## change", so Normal is simply this resource with nothing set.
##
## Which night gets which profile is GameManager's schedule
## (get_night_profile); how each field is applied lives in the apply_*
## helpers below, so the rule is written once and the spawner, the scoring
## site and the table tests all use the same one.

# --- Identity --------------------------------------------------------------
@export var id: String = "normal"
## Shown on the HUD at night start and written to the run log.
@export var display_name: String = "Normal"

# --- Overrides ---------------------------------------------------------------
## Multiplies the night's base pool BEFORE carryover is added.
@export var pool_mult: float = 1.0
## Multiplies each variant's HP AFTER the escalation curve.
@export var hp_mult: float = 1.0
## Replaces the night's leaper share when >= 0. -1 = use the curve.
@export var leaper_share_override: float = -1.0
## Added to the computed max alive, before the ceiling.
@export var max_alive_bonus: int = 0
## Replaces the computed max alive when >= 0. -1 = use the curve.
@export var max_alive_override: int = -1
## Spawn arc around one random bearing chosen per night. 360 = the full ring.
@export var spawn_arc_deg: float = 360.0
## Multiplies Night kill awards. Day kills by placed defenses always use 1.0.
@export var points_mult: float = 1.0

# --- Application -------------------------------------------------------------
## round(base x pool_mult). Carryover is added by the caller, after.
func apply_pool(base_pool: int) -> int:
	return roundi(float(base_pool) * pool_mult)

## round(curve HP x hp_mult).
func apply_hp(curve_hp: int) -> int:
	return roundi(float(curve_hp) * hp_mult)

func apply_leaper_share(curve_share: float) -> float:
	return leaper_share_override if leaper_share_override >= 0.0 else curve_share

## Points for one Night kill.
func apply_points(points: int) -> int:
	return roundi(float(points) * points_mult)

func has_spawn_arc() -> bool:
	return spawn_arc_deg < 360.0
