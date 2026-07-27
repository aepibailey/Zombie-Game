extends Resource
class_name WeaponData
## Data-driven weapon definition. Everything the player controller needs to fire
## a given gun lives here, so adding a weapon is data, not code. Definitions are
## built in the Arsenal autoload. See PROJECT_SPEC.md "Weapons".

enum FireMode { SEMI, AUTO, BOTH }   # BOTH = selectable (HK416)

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

@export var hip_spread_radius: float = 80.0   # screen-px scatter when not ADS
@export var recoil_per_shot: float = 0.03
@export var max_range: float = 150.0

@export var noise_unsuppressed: float = 40.0
@export var noise_suppressed: float = 8.0

@export var cost: int = 0                 # points to buy at the crate (0 = starter)
## Optional purchase prerequisite: an item id the player must already own.
## Unused by weapons today; the crate's purchase flow honours it so future
## enablers (UAV/Apache/supply drop requiring the Radio) need no new plumbing.
@export var requires: String = ""
