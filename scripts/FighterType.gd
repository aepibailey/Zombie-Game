extends Resource
class_name FighterType
## Data-driven allied fighter variant definition.
##
## Everything that differs between fighter variants lives here, so adding a
## variant is a .tres file rather than a code change — the same pattern
## ZombieType and WeaponData/Arsenal already use.
##
## THE BANDS ARE HERE; THE ROLLED VALUES ARE NOT. Hit chance, damage and
## reaction delay are randomized PER FIGHTER at recruitment and never re-roll,
## so this resource carries the min/max each is drawn from and the individual
## Fighter instance carries what it actually got. A variant is therefore a
## different DISTRIBUTION of irregulars, not a different fixed statline.
##
## See PROJECT_SPEC.md "Allied fighters".

# --- Identity --------------------------------------------------------------
@export var id: String = "irregular"
@export var display_name: String = "Irregular"

## Drawn from at recruitment, cosmetic only — names exist so a roster entry
## and a kill notification can be tied to a body in the world. Duplicates are
## possible and harmless; nothing keys off a name.
@export var names: PackedStringArray = PackedStringArray([
	"Reyes", "Ba", "Kovac", "Tran", "Adeyemi", "Marek", "Okonkwo", "Silva",
	"Halim", "Novak", "Diallo", "Petrov", "Amari", "Voss", "Rahim", "Castro",
])

# --- Rolled stat bands (per fighter, permanent) ----------------------------
## Fraction, not percent. The upgrade path in PROJECT_SPEC.md raises a
## fighter's rolled value WITHIN this band — it never lifts the ceiling, which
## is what keeps a fighter's hit chance below 100% at any tier.
@export_range(0.0, 1.0) var hit_chance_min: float = 0.60
@export_range(0.0, 1.0) var hit_chance_max: float = 0.95
@export var damage_min: int = 20
@export var damage_max: int = 35
## Seconds between acquiring a NEW target and the first shot at it. Re-applied
## on every fresh acquisition, not just the first of the night.
@export var reaction_delay_min: float = 0.5
@export var reaction_delay_max: float = 1.5

# --- Fixed stats -----------------------------------------------------------
@export var max_health: int = 100
## Seconds between shots while engaging an acquired target.
@export var fire_interval: float = 1.2
## Total width of the firing sector, centred on the fighter's facing. A
## fighter engages only inside this arc — see Fighter's own note.
@export_range(1.0, 360.0) var sector_arc_degrees: float = 90.0
@export var engagement_range: float = 25.0

# --- Noise -----------------------------------------------------------------
## Emitted through the shared NoiseManager on every shot, exactly like the
## player's gunfire — fighter fire pulls zombies the same way.
@export var noise_radius_unsuppressed: float = 40.0
## After the per-fighter suppressor purchase. Mirrors the M17's suppressed
## radius specifically — see Fighter.suppressed_noise_radius() for why that
## weapon and not the roster average.
@export var noise_radius_suppressed: float = 8.0

# --- Appearance (placeholder capsule — must not read as a zombie) ----------
@export var body_radius: float = 0.36
@export var body_height: float = 1.70
@export var albedo: Color = Color(0.25, 0.45, 0.85)
## Facing wedge marker colour, so a fighter's sector is identifiable on sight.
@export var facing_marker: Color = Color(0.45, 0.7, 1.0)

## Height of this fighter's eye above its own feet, for line of sight.
##
## D4 — ONE FIXED HEIGHT, NO CROUCH. A fighter never ducks, never peeks and
## never adjusts its stance to see over something. A fighter emplaced behind
## full cover genuinely cannot see or shoot over it, and that is a consequence
## the PLAYER is meant to reason about at placement time (which is what the
## sector-of-fire preview exists to show). Do not add a crouched variant of
## this number, and do not make it stance-dependent.
##
## Slightly below body_height: the eye sits in the head, not on the crown.
@export var eye_height: float = 1.58

## How often acquire_target() is re-run for the visibility readout. NOT the
## firing cadence (that is fire_interval, and the engagement loop is a later
## phase) — this only paces how quickly a fighter notices its shot line has
## opened or closed.
@export var acquire_scan_interval: float = 0.25

# --- Derived ---------------------------------------------------------------
## Capsule centre height, matching ZombieType's own convention so world-space
## UI (health bars, markers) can size against either without special-casing.
func body_center_y() -> float:
	return body_height * 0.5

func total_height() -> float:
	return body_height
