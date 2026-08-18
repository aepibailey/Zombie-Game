extends Resource
class_name ClaymoreConfig
## Every claymore tunable in one editable place.
##
## A Resource rather than @export vars on the script, because Claymore is
## INSTANTIATED IN CODE — exports on a code-instantiated node never appear in
## the inspector, so they would not actually be tunable. This is the same
## pattern WeaponData, ZombieType and AreaDamageProfile already use.
##
## DAMAGE lives on the AreaDamageProfile (`damage_profile` below), not here —
## there is exactly one place in this project that describes a blast, and
## duplicating radii into a second resource is how the two drift apart. The
## detection numbers here that MUST agree with that profile are checked at
## runtime; see Claymore._validate_config().

# --- Placement -------------------------------------------------------------
## How far ahead of the player a claymore can be emplaced. Short on purpose:
## you emplace it where you are standing, you do not lob it into a field.
@export var placement_max_range: float = 2.5
## Minimum spacing between two emplaced claymores, so a stack of them in one
## spot can't be used as a single super-mine.
@export var min_separation: float = 1.0
## Steeper than this and it won't sit — cos of the surface normal against UP.
@export var max_ground_slope_deg: float = 40.0

# --- Arming ----------------------------------------------------------------
## Dead time after emplacement during which nothing can detonate it, for any
## reason. Long enough that you can walk out of your own arc.
@export var arming_delay: float = 2.0

# --- Detection -------------------------------------------------------------
## MUST equal damage_profile.max_radius — validated at runtime.
@export var detection_range: float = 10.0
## Total arc width, not half. MUST equal damage_profile.arc_degrees.
@export var detection_arc_degrees: float = 60.0
## Height band above the claymore's own ground plane. A leaper at the apex of
## its 5m jump is far above this and passes over untriggered; the same leaper
## on the ground in the arc is caught.
@export var detection_height: float = 2.0
## Delay between first valid detection and detonation, so a cluster walking in
## together is caught rather than only whoever tripped it. Once started it is
## committed — detection does NOT have to persist through the window.
@export var trigger_delay: float = 0.15
## How often the detection sweep runs. Not per-frame: this is a distance cull,
## then an arc test, then a height test, then a raycast, per zombie per
## emplaced claymore, and the cheap tests exist to keep the raycast rare.
@export var detection_interval: float = 0.1

# --- Recovery ----------------------------------------------------------------
## Recovery is available at ANY time now (Day or Night) — the earlier
## Day-only restriction was a playtest-pass call, not a mechanic reason, and
## has been removed. Interaction changed from "walk near it" to "look at it
## within this range and hold interact" — see Player._find_recovery_target().
@export var recovery_range: float = 2.0
## How long interact must be held, continuously, while still looking at the
## same claymore. Releasing early cancels with no penalty — see
## Player._update_claymore_recovery().
@export var recovery_hold_time: float = 0.5
## Noise emitted at the PLAYER's position the moment recovery completes (not
## on starting the hold — browsing/holding is silent, same convention the
## radio transmission work will use for "committing makes noise, looking
## doesn't"). Deliberately smaller than the blast's own noise: this is a
## person quietly pocketing a mine, not a detonation.
@export var recovery_noise_radius: float = 3.0

# --- Readability -----------------------------------------------------------
## Draw the ground wedge on EMPLACED claymores when the player is close.
## The placement-mode wedge is always drawn and is NOT behind this flag —
## committing to an arc you can't see would be indefensible.
@export var show_emplaced_arc: bool = true
## How close the player must be for the above.
@export var emplaced_arc_visible_range: float = 3.0

# --- Damage ----------------------------------------------------------------
## The blast itself. Routed through AreaDamageSystem unchanged; the claymore
## contributes only the origin and the facing vector.
@export var damage_profile: AreaDamageProfile
