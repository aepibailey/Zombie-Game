extends Resource
class_name ZombieType
## Data-driven zombie variant definition.
##
## Everything that differs between zombie variants lives here, so adding a
## variant is a .tres file rather than a code change — the same pattern
## WeaponData/Arsenal already use for the weapon roster.
##
## What deliberately does NOT live here: anything shared by every variant and
## not expected to differ (investigate timeout, repath cadence, wander radius,
## the noise-bus wiring, chase-lose and laser ranges). Those stay as constants
## on Zombie.gd. Pulling genuinely-global tuning into a per-variant resource
## would just mean editing N files to change one rule. Passive SIGHT is the
## exception, on purpose: how far a variant sees is part of what makes it that
## variant (the leaper is the alert hunter), so it lives under "Perception".
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

# --- Perception (passive sight) --------------------------------------------
## How far this variant sees an UPRIGHT player — standing, walking or
## sprinting alike; sprinting buys speed, not visibility. Only in Wander and
## Investigate, only at night (Zombie._update_sight). The player says what
## state it is in; this resource alone decides what that means in metres.
@export var sight_range: float = 12.0
## A crouched player, still or moving, is seen at range x this.
@export var sight_crouch_mult: float = 0.5
## Half the cone. 60 = a 120-degree cone around the way the zombie faces;
## walk up behind one and it does not see you (it can still HEAR you).
@export var sight_half_angle_deg: float = 60.0
## Seconds the player must stay in view before the zombie commits to Chase.
@export var notice_threshold: float = 0.75
## Seen at least this long but lost before notice: the zombie goes to look
## where it last saw you. Below it, a glimpse is nothing.
@export var suspicion_threshold: float = 0.25

## Structural sanity, called once from Main._ready() — the same shape as
## FighterType.validate(). `chase_lose_range` is passed in rather than read
## off Zombie so this resource takes no dependency on the node that uses it.
func validate(chase_lose_range: float) -> void:
	assert(sight_range > 0.0,
		"[ZOMBIETYPE] %s: sight_range must be positive." % id)
	assert(sight_crouch_mult > 0.0 and sight_crouch_mult <= 1.0,
		"[ZOMBIETYPE] %s: sight_crouch_mult must be in (0, 1] — crouching never makes you MORE visible." % id)
	assert(sight_half_angle_deg > 0.0 and sight_half_angle_deg <= 180.0,
		"[ZOMBIETYPE] %s: sight_half_angle_deg must be in (0, 180]." % id)
	assert(suspicion_threshold > 0.0 and suspicion_threshold < notice_threshold,
		"[ZOMBIETYPE] %s: suspicion_threshold must be positive and below notice_threshold, or a glimpse would outrank a sighting." % id)
	# A zombie that could acquire beyond the range at which Chase gives up
	# would flip Chase -> Investigate the moment line of sight blinked.
	assert(sight_range <= chase_lose_range,
		"[ZOMBIETYPE] %s: sight_range (%.1f) must not exceed Zombie.CHASE_LOSE_RANGE (%.1f)." % [id, sight_range, chase_lose_range])

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
