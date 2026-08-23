extends CharacterBody3D
class_name Fighter
## An allied irregular: a stationary, permanently-statted shooter the player
## places and loses.
##
## STATIONARY BY DESIGN, NOT BY OMISSION. A fighter never paths, roams, flees
## or repositions itself under any circumstance — there is no movement code in
## this file and none should be added. The player repositions them by hand
## during Day (see PROJECT_SPEC.md "Allied fighters"). `velocity` is never
## written; CharacterBody3D is the base only because it gives the same
## collider/raycast surface Zombie and Player already present.
##
## STATS ARE ROLLED ONCE, AT RECRUITMENT, AND NEVER RE-ROLL. Hit chance,
## damage and reaction delay are drawn from the bands on FighterType and then
## belong to this individual permanently — they survive nights, they are shown
## in the roster, and they are what makes two fighters recruited in the same
## session perform observably differently.
##
## THE COMPETENCE GAP IS THE POINT. When this fighter shoots (phase 2) it
## resolves a HIT-CHANCE ROLL, never a raycast. The player raycasts. Those two
## paths must not be collapsed into shared code — a fighter that aimed like
## the player would erase the reason to be careful about who you recruit.

const GROUP := "fighters"

## Emitted just before this fighter frees itself — the roster menu's cue to
## move it from the live list to the memorial and stop reading its stats.
## Matches Zombie's own `died` signal in spirit.
signal died

@export var fighter_type: FighterType

# --- Rolled at recruitment, permanent --------------------------------------
## Fraction, not percent. Never reaches 1.0 — see FighterType.hit_chance_max.
## CURRENT effective value — what engagement (a later phase) actually reads.
## Upgrades move this toward the type's band ceiling; see upgrade().
var hit_chance := 0.0
var damage := 0
var reaction_delay := 0.0
var fighter_name := ""

## The AS-ROLLED values, captured once at recruitment and never touched
## again. upgrade() interpolates FROM these TOWARD the type's band ceiling,
## rather than repeatedly nudging the current value — so three tiers produce
## the same result regardless of the order effects a naive "move X% closer
## each time" would introduce, and tier 3 always lands EXACTLY at the type's
## max, never asymptotically approaching but missing it.
var _base_hit_chance := 0.0
var _base_damage := 0

# --- Live state ------------------------------------------------------------
## Named `health`/`max_health` deliberately: that is the convention every
## damageable in this project follows (SandbagPanel, Player, Zombie), and it
## is what HealthBar3D.attach_to() reads by default. Phase 5 attaches it.
var max_health := 100
var health := 100

## Purchased per fighter from the roster menu, lost permanently on death.
## Independent of the stat upgrade tiers — see PROJECT_SPEC.md.
var suppressed := false
## 0-3. Raises hit_chance and damage WITHIN the type's bands; never past them.
var upgrade_tier := 0

# --- Lifetime stats, persisted across nights for the roster ----------------
## Written by the engagement loop in phase 2; declared here because they are
## part of what a fighter IS, and the roster reads them straight off this.
var shots_fired := 0
var hits_landed := 0
var kills := 0

var _dead := false
var _body_mesh: MeshInstance3D
var _facing_marker: MeshInstance3D

## Rolls this fighter's permanent statline and gives it a name. Called ONCE,
## by whatever recruits it. Calling it twice would re-roll a fighter the
## player has already been shown, so it refuses.
##
## `rng_seed` is optional and exists only so a test can reproduce a specific
## fighter; recruitment in play leaves it at -1 and uses the global RNG.
func recruit(type: FighterType, rng_seed: int = -1) -> void:
	assert(fighter_type == null or hit_chance == 0.0,
		"[FIGHTER] recruit() called twice — a fighter's stats are permanent and must never re-roll.")
	fighter_type = type

	var rng := RandomNumberGenerator.new()
	if rng_seed >= 0:
		rng.seed = rng_seed
	else:
		rng.randomize()

	hit_chance = rng.randf_range(type.hit_chance_min, type.hit_chance_max)
	damage = rng.randi_range(type.damage_min, type.damage_max)
	_base_hit_chance = hit_chance
	_base_damage = damage
	reaction_delay = rng.randf_range(type.reaction_delay_min, type.reaction_delay_max)
	fighter_name = _roll_name(rng, type)

	max_health = type.max_health
	health = max_health

	print("[FIGHTER] recruited %s — hit %.0f%%, dmg %d, reaction %.2fs, HP %d" % [
		fighter_name, hit_chance * 100.0, damage, reaction_delay, max_health])

func _roll_name(rng: RandomNumberGenerator, type: FighterType) -> String:
	if type.names.is_empty():
		return "Fighter"
	return type.names[rng.randi_range(0, type.names.size() - 1)]

func _ready() -> void:
	add_to_group(GROUP)
	# What blasts (grenades, claymores, the mortar, WP, the Apache) can
	# damage. Joining this group is the ENTIRE integration — AreaDamageSystem
	# queries the group and duck-types take_area_damage()/is_alive() rather
	# than special-casing anything, so no change to that system was needed.
	#
	# NOT joined to Damageable.GROUP_BULLET or Zombie.GROUP_HOSTILE_TARGET —
	# player bullets hitting fighters and zombies targeting fighters are both
	# later phases, out of scope for this pass ("no new spatial or AI
	# logic"). Both groups exist and are ready for a fighter to join with no
	# further refactor when that phase happens.
	add_to_group(AreaDamageSystem.GROUP_DAMAGEABLE)
	# A hand-placed fighter with no type assigned still has to work, matching
	# Zombie's own fallback.
	if fighter_type == null:
		fighter_type = load("res://resources/fighter_irregular.tres")
	if hit_chance == 0.0:
		recruit(fighter_type)
	# Layer 1 so the player's rounds and the world both see it as solid; the
	# same layer Zombie and the base geometry occupy.
	collision_layer = 1
	collision_mask = 1
	_build_body()

# --- Queries ---------------------------------------------------------------
## True until this fighter has actually died. Matches Zombie.is_alive() and
## the optional liveness convention AreaDamageSystem checks for.
func is_alive() -> bool:
	return not _dead

# --- Damage ------------------------------------------------------------------
## AreaDamageSystem's uniform blast entry point — the SAME contract Zombie
## and Player implement. Faction-blind by construction: a grenade at a
## fighter's feet kills it exactly as it would the player.
func take_area_damage(amount: int, _origin: Vector3) -> void:
	if _dead:
		return
	health = maxi(0, health - amount)
	if health <= 0:
		_die()

## Feet/centre/head sample points for a blast's line-of-sight test, same
## shape as Player.area_damage_points() and Zombie.area_damage_points().
func area_damage_points() -> Array:
	var t := fighter_type
	return [
		global_position + Vector3(0.0, 0.2, 0.0),
		global_position + Vector3(0.0, t.body_center_y(), 0.0),
		global_position + Vector3(0.0, t.total_height(), 0.0),
	]

## PERMANENT. No revival, no recovery of spent points — and that needs no
## code of its own: nothing anywhere refunds an upgrade or suppressor
## purchase, so freeing this node is what forfeiture IS. There is no balance
## to roll back.
func _die() -> void:
	if _dead:
		return
	_dead = true
	print("[FIGHTER] %s KIA — %s" % [fighter_name, stat_line()])
	died.emit()
	queue_free()

## The noise radius a shot from this fighter emits right now.
##
## SUPPRESSED BINDS TO THE M17 SPECIFICALLY, not to an average across the
## roster and not to whatever the player currently carries. The M17 is the
## free starter weapon and the project's reference sidearm, so it is the one
## stable number to tie to; the player's other four weapons all suppress to
## different values (10/12/14/11), which means "the player's suppressed
## radius" is not a single quantity to match. Phase 6 asserts these stay
## equal, so changing one changes both.
func noise_radius() -> float:
	return fighter_type.noise_radius_suppressed if suppressed \
		else fighter_type.noise_radius_unsuppressed

## Applies the next upgrade tier. Purely a stat mutation — the roster menu
## owns charging points for it; this never touches PointsManager itself, the
## same separation FireMissionSystem keeps between "can I afford this" and
## "what does this actually change."
##
## Interpolates from the AS-ROLLED base toward the type's band ceiling, so
## tier 3 lands exactly at hit_chance_max/damage_max — never past it, which
## is the whole mechanism behind "a fighter's effective hit chance can never
## reach 100% at any tier": hit_chance_max itself is always < 1.0.
func upgrade() -> bool:
	if upgrade_tier >= 3:
		return false
	upgrade_tier += 1
	var t: float = float(upgrade_tier) / 3.0
	hit_chance = lerpf(_base_hit_chance, fighter_type.hit_chance_max, t)
	damage = int(round(lerpf(float(_base_damage), float(fighter_type.damage_max), t)))
	assert(hit_chance < 1.0,
		"[FIGHTER] upgrade produced a hit chance >= 100% — FighterType.hit_chance_max must stay below 1.0.")
	print("[FIGHTER] %s upgraded to T%d — hit %.0f%%, dmg %d" % [
		fighter_name, upgrade_tier, hit_chance * 100.0, damage])
	return true

## One-time. The roster menu checks `not suppressed` before charging points —
## this only refuses a redundant call defensively.
func apply_suppressor() -> bool:
	if suppressed:
		return false
	suppressed = true
	print("[FIGHTER] %s suppressed — noise %.0fm -> %.0fm" % [
		fighter_name, fighter_type.noise_radius_unsuppressed, fighter_type.noise_radius_suppressed])
	return true

## Half-angle of the firing sector, which is what an arc test actually wants.
func sector_half_angle_rad() -> float:
	return deg_to_rad(fighter_type.sector_arc_degrees * 0.5)

## Forward vector the sector is centred on. Flattened: a fighter's arc is a
## ground sector, so pitch never affects what it can engage.
func facing() -> Vector3:
	var f := -global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length_squared() > 0.0001 else Vector3.FORWARD

# --- Placeholder visuals ---------------------------------------------------
## Deliberately unmistakable against a zombie: blue, upright, and carrying a
## facing wedge on the ground. Art is out of scope — this only has to be
## identifiable at NVG range and show which way the fighter is pointed.
func _build_body() -> void:
	var t := fighter_type

	var shape := CapsuleShape3D.new()
	shape.radius = t.body_radius
	shape.height = t.body_height
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = t.body_center_y()
	add_child(col)

	var mesh := CapsuleMesh.new()
	mesh.radius = t.body_radius
	mesh.height = t.body_height
	_body_mesh = MeshInstance3D.new()
	_body_mesh.mesh = mesh
	_body_mesh.position.y = t.body_center_y()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = t.albedo
	mat.emission_enabled = true
	mat.emission = t.albedo
	mat.emission_energy_multiplier = 0.6
	_body_mesh.material_override = mat
	add_child(_body_mesh)

	# A short bar out the front, so facing is readable without entering
	# placement mode. The full sector arc is drawn during placement (phase 4).
	var nose := BoxMesh.new()
	nose.size = Vector3(0.08, 0.08, 0.7)
	_facing_marker = MeshInstance3D.new()
	_facing_marker.mesh = nose
	_facing_marker.position = Vector3(0.0, t.body_height * 0.75, -0.5)
	var nmat := StandardMaterial3D.new()
	nmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	nmat.albedo_color = t.facing_marker
	_facing_marker.material_override = nmat
	add_child(_facing_marker)

## Roster/debug one-liner. Kept here rather than in the menu so the same
## string is available to a console dump before the menu exists.
func stat_line() -> String:
	return "%s — hit %.0f%% · dmg %d · react %.2fs · HP %d/%d · T%d%s · %d/%d shots, %d kills" % [
		fighter_name, hit_chance * 100.0, damage, reaction_delay,
		health, max_health, upgrade_tier, " · SUPP" if suppressed else "",
		hits_landed, shots_fired, kills]
