extends Resource
class_name WeaponData
## Data-driven weapon definition. Everything the player controller needs to fire
## a given gun lives here, so adding a weapon is data, not code. Definitions are
## built in the Arsenal autoload. See PROJECT_SPEC.md "Weapons".

enum FireMode { SEMI, AUTO, BOTH }   # BOTH = selectable (HK416)
## How the full-auto penalty multiplier is derived.
##   NONE   — no auto penalty (semi-only weapons)
##   RAMP   — climbs per consecutive shot (HK 416)
##   STANCE — driven by player stance/movement in real time (M249)
enum AutoPenalty { NONE, RAMP, STANCE }

@export var id: String = ""
@export var display_name: String = ""
@export var fire_mode: FireMode = FireMode.SEMI

@export var mag_size: int = 17
## Magazines granted when the weapon is first acquired, INCLUDING the loaded
## one. 2 = one in the gun, one spare (ammo is deliberately scarce).
@export var starting_mags: int = 2
@export var ammo_cost: int = 1            # points per magazine at the crate
@export var fire_interval: float = 0.15   # seconds between shots (rate of fire)
@export var reload_time: float = 1.6

@export var body_damage: int = 34         # per pellet/round
@export var pellets: int = 1              # >1 = shotgun spread
@export var pellet_spread_deg: float = 0.0
## Accuracy cone applied even when aiming down sights. 0 = pinpoint.
@export var ads_cone_deg: float = 0.0

# --- Damage falloff (piecewise linear over distance) ----------------------
# Full damage out to `falloff_near`, then linearly to `falloff_mid_mult` at
# `falloff_mid`, then to `falloff_far_mult` at `falloff_far`, flat beyond.
# Defaults = no falloff at any range.
@export var falloff_near: float = 9999.0
@export var falloff_mid: float = 9999.0
@export var falloff_mid_mult: float = 1.0
@export var falloff_far: float = 9999.0
@export var falloff_far_mult: float = 1.0

## Damage multiplier at a given distance (metres).
func damage_mult_at(distance: float) -> float:
	if distance <= falloff_near:
		return 1.0
	if distance <= falloff_mid:
		var span: float = maxf(0.001, falloff_mid - falloff_near)
		return lerpf(1.0, falloff_mid_mult, (distance - falloff_near) / span)
	if distance <= falloff_far:
		var span2: float = maxf(0.001, falloff_far - falloff_mid)
		return lerpf(falloff_mid_mult, falloff_far_mult, (distance - falloff_mid) / span2)
	return falloff_far_mult

@export var hip_spread_radius: float = 80.0   # screen-px scatter when not ADS
@export var recoil_per_shot: float = 0.03     # vertical, semi-auto baseline
@export var max_range: float = 150.0

# --- Full-auto penalty (see AutoPenalty) ---------------------------------
@export var auto_penalty: AutoPenalty = AutoPenalty.NONE
@export var auto_recoil_start_mult: float = 1.4   # RAMP: first auto shot
@export var auto_recoil_growth: float = 0.12      # RAMP: +12% per consecutive shot
@export var auto_recoil_max_mult: float = 3.5     # RAMP: cap
@export var horizontal_recoil: float = 0.012      # random left/right per shot
@export var bloom_min_deg: float = 0.3            # cone at rest
@export var bloom_max_deg: float = 4.0            # cone at full ramp
@export var bloom_shots_to_max: int = 10
@export var auto_reset_time: float = 0.4          # idle time that clears the ramp

# --- Tube-fed (per-shell) reload -----------------------------------------
## When true the weapon reloads one shell at a time and can be interrupted by
## firing after any completed shell (SPAS-12).
@export var shell_reload: bool = false
@export var shell_time: float = 0.55
@export var reload_start: float = 0.35
@export var reload_end: float = 0.35

@export var noise_unsuppressed: float = 40.0
@export var noise_suppressed: float = 8.0

@export var cost: int = 0                 # points to buy at the crate (0 = starter)
## Optional purchase prerequisite: an item id the player must already own.
## Unused by weapons today; the crate's purchase flow honours it so future
## enablers (UAV/Apache/supply drop requiring the Radio) need no new plumbing.
@export var requires: String = ""
