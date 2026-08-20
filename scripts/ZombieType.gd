extends Resource
class_name ZombieType
## Data-driven zombie variant definition.
##
## Everything that differs between zombie variants lives here, so adding a
## variant is a .tres file rather than a code change — the same pattern
## WeaponData/Arsenal already use for the weapon roster.
##
## What deliberately does NOT live here: anything shared by every variant and
## not expected to differ (line-of-sight ranges, investigate timeout, repath
## cadence, wander radius, the noise-bus wiring). Those stay as constants on
## Zombie.gd. Pulling genuinely-global tuning into a per-variant resource
## would just mean editing N files to change one rule.
##
## See PROJECT_SPEC.md "Zombie AI" and "Zombie variants".

# --- Identity --------------------------------------------------------------
@export var id: String = "walker"
@export var display_name: String = "Walker"

# --- Health & scoring ------------------------------------------------------
## BASE health. The spawner applies the per-night HP scaling on top of this
## (Main._zombie_hp_for_type), so this is night-1 health, not final health.
@export var max_health: int = 100
@export var points_body_kill: int = 1
@export var points_headshot_kill: int = 3

# --- Movement --------------------------------------------------------------
@export var move_speed_wander: float = 1.6
@export var move_speed_chase: float = 3.6
## When > 0, `move_speed_chase` is IGNORED and chase speed is derived at
## runtime as this fraction of the PLAYER'S sprint speed. The leaper is
## specified as "0.85x the player's sprint", which is a relationship, not a
## number — if sprint speed is ever retuned the leaper must follow it
## automatically rather than silently becoming faster or slower than intended.
@export var chase_speed_sprint_fraction: float = 0.0
## Seconds to ramp from wander speed up to chase speed after entering Chase.
## 0.0 = instant (the walker's original behaviour — it had no ramp at all).
@export var acceleration_time: float = 0.0
## Seconds after entering Chase during which the zombie does NOT accelerate —
## it stays at wander speed. The leaper uses this as the player's tell: a
## screech and a lurch before it actually comes for you. 0.0 = no delay.
@export var chase_entry_delay: float = 0.0

# --- Melee -----------------------------------------------------------------
@export var melee_damage: int = 20
@export var melee_cooldown: float = 1.0

# --- Leap (see Zombie.gd State.LEAP) ---------------------------------------
## Master switch. When false every leap code path is skipped outright — a
## walker never evaluates leap conditions at all.
@export var can_leap: bool = false
## Peak height above the launch point. Drives launch velocity via
## v = sqrt(2 * g * apex), read from the project's real gravity setting.
@export var jump_apex_height: float = 5.0
## HARD CAP on horizontal travel. Enforced at launch, not merely aimed for.
@export var max_horizontal_distance: float = 6.0
@export var jump_cooldown: float = 3.0
## Fully immobile after touchdown.
@export var landing_recovery: float = 0.35
## Leap only when the navmesh path is at least this many times longer than
## the straight-line distance to the player (i.e. it's genuinely detouring
## around something). Guards "never leap at an unobstructed player".
@export var leap_path_ratio_threshold: float = 1.6

# --- Appearance (silhouette must be identifiable at NVG range) -------------
@export var body_radius: float = 0.4
@export var body_height: float = 1.56
@export var head_radius: float = 0.12
@export var albedo_active: Color = Color(0.25, 0.6, 0.25)

# --- UAV reveal --------------------------------------------------------------
## Through-wall silhouette color while a UAV is on station (see UAVSystem and
## Zombie._build_uav_silhouette()). This IS the readability payoff of the
## reveal — variants must read apart at a glance, not just by proximity to the
## player. Default is the walker's amber; the leaper overrides to red.
@export var uav_silhouette_color: Color = Color(1.0, 0.75, 0.1)

# --- Audio -----------------------------------------------------------------
## Played once on entering Chase. Deliberately NOT routed through
## NoiseManager — it's a player-facing tell, not a zombie-facing alert, and
## must not pull other zombies in. "" = silent.
@export var sfx_chase_entry: String = ""

# --- Derived ---------------------------------------------------------------
## The chase speed actually used. Reads the player's sprint constant directly
## rather than duplicating the number, so the two can never drift apart.
func resolved_chase_speed() -> float:
	if chase_speed_sprint_fraction > 0.0:
		return float(Player.SPEED[Player.MoveState.SPRINT]) * chase_speed_sprint_fraction
	return move_speed_chase

## Capsule centre height. The head sits directly on top of the capsule so the
## two shapes meet at a single tangent point and never overlap volumetrically
## (see PROJECT_SPEC.md "Zombie geometry & hitboxes").
func body_center_y() -> float:
	return body_height * 0.5

func head_center_y() -> float:
	return body_height + head_radius

func total_height() -> float:
	return body_height + head_radius * 2.0
