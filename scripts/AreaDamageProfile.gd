extends Resource
class_name AreaDamageProfile
## Configuration for one kind of area-effect damage event.
##
## This is the "what" — the "how" lives in the AreaDamageSystem autoload.
## Hand grenades are the first consumer; the 120mm mortar, white phosphorus
## and directional claymores are all meant to be NEW .tres FILES rather than
## new code. If one of them needs a code change here, that's a design gap
## worth fixing rather than special-casing.
##
## Every consumer gets, for free: distance falloff, real line-of-sight cover,
## indiscriminate faction-blind targeting, obstacle damage, a firing arc, and
## instant-vs-over-time application.

## How damage falls off between `lethal_radius` and `max_radius`.
##   LINEAR    — even taper. Predictable; good default.
##   QUADRATIC — drops fast then tails off. Reads like real frag.
##   CURVE     — arbitrary authored shape via `falloff_curve`.
enum FalloffMode { LINEAR, QUADRATIC, CURVE }

@export var id: String = ""
@export var display_name: String = ""

# --- Geometry --------------------------------------------------------------
## Inside this radius every target takes FULL damage.
@export var lethal_radius: float = 5.0
## At and beyond this radius damage is zero. Must exceed lethal_radius.
@export var max_radius: float = 12.0
@export var max_damage: int = 110

@export var falloff: FalloffMode = FalloffMode.LINEAR
## Sampled 0..1 across the lethal->max band. Only used when falloff == CURVE.
@export var falloff_curve: Curve

## Firing arc in degrees, centred on the `facing` vector passed to detonate().
## 360 = omnidirectional (grenades, mortar, WP). A directional claymore is
## then pure configuration — e.g. 60 degrees — with no code change.
@export_range(1.0, 360.0) var arc_degrees: float = 360.0

# --- Cover -----------------------------------------------------------------
## Master switch (Step 8A). true = run the exposure test below at all; false
## = every target is treated as fully exposed regardless of what's between it
## and the origin. Default true for every profile — WP included; see the
## note on blocked_damage_mult for why turning WP's occlusion off was never
## actually necessary.
@export var occlusion_enabled: bool = true

## Fraction of damage that still lands on a target with NO line of sight.
## 0.0 = intact cover is total protection — this is what makes "grenades
## don't kill through sandbags" true today: every combat profile
## (frag/claymore/apache_30mm/crate_crush) ships at 0.0. Raise it for
## something that should partially defeat cover (mortar_he ships at 0.35 — a
## 120mm HE round's overpressure isn't fully stopped by a sandbag wall).
##
## EXPOSURE ITSELF STAYS GRADUATED, NOT BINARY, ON PURPOSE: AreaDamageSystem
## samples several points per target (feet/centre/head, or
## area_damage_points() where a target implements it) rather than one, so a
## zombie with only its head over a sandbag wall takes partial damage instead
## of an all-or-nothing verdict keyed off whichever single point got picked.
## D5's "per-target, blast origin to candidate" is satisfied by this sampling
## being per-target; collapsing it to a single center-mass ray would be a
## strictly worse model for the exact "does not kill through it" behaviour
## D5 asks for, since a target half-exposed over low cover would read as
## fully hidden the instant its center point specifically was blocked.
##
## WP sets this to 1.0 at runtime (WhitePhosphorusZone._ready()) — the burn
## zone's tick damage is not meant to be stopped by cover at all, so its
## occlusion_enabled stays true (matching every other profile) but is
## already a no-op: lerpf(1.0, 1.0, exposure) is 1.0 regardless of exposure.
@export_range(0.0, 1.0) var blocked_damage_mult: float = 0.0

# --- Obstacles -------------------------------------------------------------
@export var damages_obstacles: bool = true
## Blast damage against structures is tuned separately from damage against
## flesh — a frag grenade shreds people but barely marks a sandbag wall.
@export var obstacle_damage_mult: float = 1.0

# --- Duration --------------------------------------------------------------
## 0.0 = instant, one-shot detonation.
## > 0.0 = damage-over-time zone: `max_damage` becomes damage PER TICK and is
## applied every `tick_interval` for `duration` seconds. Implemented but not
## yet used by anything — white phosphorus is the intended first consumer.
##
## NOT THE MORTAR. Every tick lands at the SAME origin, so this models a
## persistent burn zone (WP), not a barrage. A 120mm mission is N separate
## detonate() calls at N scattered origins, scheduled by the mortar itself —
## the delay before the first round and the spread between impacts are the
## caller's, because a profile describes ONE burst. Setting `duration` on a
## mortar profile would produce a pillar of fire at one point instead.
@export var duration: float = 0.0
## Clamped to a 0.05s floor by AreaDamageSystem — 0 would never terminate.
@export var tick_interval: float = 0.5

# --- Presentation ----------------------------------------------------------
@export var sfx_detonate: String = ""
## Radius of the NoiseManager event emitted on detonation. 0 = silent to the
## AI (the blast still damages, it just doesn't attract). Kept here so a
## suppressed/quiet future device is configuration too.
@export var noise_radius: float = 0.0

## Damage at a given distance from the blast origin, before cover.
func damage_at(distance: float) -> float:
	if distance <= lethal_radius:
		return float(max_damage)
	if distance >= max_radius:
		return 0.0
	var span: float = maxf(0.001, max_radius - lethal_radius)
	var t: float = clampf((distance - lethal_radius) / span, 0.0, 1.0)
	var f: float = 1.0 - t
	match falloff:
		FalloffMode.QUADRATIC:
			f = (1.0 - t) * (1.0 - t)
		FalloffMode.CURVE:
			f = falloff_curve.sample(t) if falloff_curve != null else (1.0 - t)
	return float(max_damage) * maxf(0.0, f)

## Is `point` inside the firing arc? Always true for a 360-degree profile, so
## omnidirectional consumers pay nothing for the claymore's existence.
##
## Delegates to AreaMath so this shares ONE implementation with the claymore's
## detection test — the damage arc and the detection arc describing the same
## wedge differently would be a genuinely nasty bug to see from the outside.
## Same signature and same answers as before; this is an internals change.
func in_arc(origin: Vector3, facing: Vector3, point: Vector3) -> bool:
	return AreaMath.in_horizontal_arc(origin, facing, point, arc_degrees)
