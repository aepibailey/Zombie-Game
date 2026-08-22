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

@export var fighter_type: FighterType

# --- Rolled at recruitment, permanent --------------------------------------
## Fraction, not percent. Never reaches 1.0 — see FighterType.hit_chance_max.
var hit_chance := 0.0
var damage := 0
var reaction_delay := 0.0
var fighter_name := ""

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
