extends Node
## Shared area-effect damage resolver (autoload).
##
## ONE code path for every explosive in the game. Grenades are the first
## consumer; the 120mm mortar, white phosphorus and directional claymores are
## meant to arrive as AreaDamageProfile .tres files, not as new systems.
##
## THE TARGETING RULE IS: NO FACTION FILTERING, EVER. Everything in the
## `damageable` group is hit — zombies, the player, and allied fighters the
## moment they exist. There is deliberately no "friendly" concept to forget to
## update; a fighter is picked up automatically by joining the group and
## implementing take_area_damage().
##
## WHY A CONVENTION METHOD RATHER THAN CALLING take_damage() DIRECTLY:
## the two existing take_damage() signatures are incompatible in a way that
## fails SILENTLY —
##     Player.take_damage(amount: int, source_pos = null)
##     Zombie.take_damage(amount: int, headshot: bool, falloff_mult := 1.0)
## Passing a Vector3 origin to a zombie would bind it to `headshot`, and a
## non-null Vector3 is truthy, so every blast would register as a headshot and
## deal DOUBLE damage with no error. take_area_damage(amount, origin) is
## uniform across all damageables and cannot be called wrongly.

## Every actor that can be hurt by a blast. Joined by Player and Zombie in
## their _ready(); future allied fighters join the same group and are picked
## up with no change here.
const GROUP_DAMAGEABLE := "damageable"
## Destructible structures. Only sandbags today (wire/ditch/minefield are
## indestructible by design — see PROJECT_SPEC.md "The obstacles").
const GROUP_STRUCTURES := "sandbags"

## LOS mask: world geometry + sandbags (layer 1) and the ditch pit shell
## (layer 6). Deliberately EXCLUDES the C-wire player-barrier layer (5) —
## wire is strands, not cover, and must not stop fragmentation.
const COVER_MASK := 1 | Obstacle.SOLID_NO_NAV_LAYER

## Fallback body sample points (metres above origin) for a damageable that
## doesn't implement area_damage_points(). Roughly feet / centre / head of a
## 1.8m humanoid.
const FALLBACK_SAMPLE_HEIGHTS := [0.2, 0.9, 1.6]

## Set true to print a per-target breakdown of every detonation.
@export var debug_log: bool = true

## Fire an area-damage event.
##
## `facing` only matters for a profile with arc_degrees < 360 (claymores);
## omnidirectional profiles ignore it. `source` is used for logging only —
## it is NOT excluded from damage, because nothing is.
##
## Returns a summary Dictionary: {actors, structures, total_damage, killed}.
func detonate(origin: Vector3, profile: AreaDamageProfile,
		facing: Vector3 = Vector3.ZERO, source_name: String = "") -> Dictionary:
	if profile == null:
		push_warning("[AREADMG] detonate() called with a null profile")
		return {"actors": 0, "structures": 0, "total_damage": 0, "killed": 0}

	_play_detonation(origin, profile)
	if profile.noise_radius > 0.0:
		NoiseManager.emit_noise(origin, profile.noise_radius)

	# A damage-over-time zone is the same event applied repeatedly. Spawning a
	# ticker keeps the instant path free of any per-frame bookkeeping.
	if profile.duration > 0.0:
		_spawn_dot_zone(origin, profile, facing, source_name)
		return {"actors": 0, "structures": 0, "total_damage": 0, "killed": 0, "dot": true}

	return _apply_once(origin, profile, facing, source_name)

## One application of the profile at `origin`. Used directly for an instant
## detonation and once per tick by a DoT zone.
func _apply_once(origin: Vector3, profile: AreaDamageProfile,
		facing: Vector3, source_name: String) -> Dictionary:
	var space := get_tree().root.world_3d.direct_space_state
	# Actors never provide cover to each other: bodies are excluded from the
	# LOS trace so only real geometry blocks a blast. Gathered once and reused
	# for every ray rather than rebuilt per target.
	var actors := get_tree().get_nodes_in_group(GROUP_DAMAGEABLE)
	var actor_rids: Array[RID] = []
	for a in actors:
		if a is CollisionObject3D:
			actor_rids.append((a as CollisionObject3D).get_rid())

	var total := 0
	var hit_actors := 0
	var killed := 0

	for node in actors:
		var actor := node as Node3D
		if actor == null or not is_instance_valid(actor):
			continue
		if not actor.has_method("take_area_damage"):
			push_warning("[AREADMG] %s is in '%s' but has no take_area_damage()"
				% [actor.name, GROUP_DAMAGEABLE])
			continue
		# Immobilised zombies (FALLEN in a ditch, ENTANGLED in wire) are
		# deliberately NOT skipped — they are valid targets and must be
		# killable by a blast. Nothing here filters on state.
		var dist := origin.distance_to(actor.global_position)
		if dist > profile.max_radius:
			continue
		if not profile.in_arc(origin, facing, actor.global_position):
			continue

		var base := profile.damage_at(dist)
		if base <= 0.0:
			continue
		var exposure := _exposure(space, origin, actor, actor_rids)
		var mult: float = lerpf(profile.blocked_damage_mult, 1.0, exposure)
		var dmg: int = int(round(base * mult))
		if dmg <= 0:
			if debug_log:
				print("[AREADMG]   %s @ %.1fm — fully covered, no damage" % [actor.name, dist])
			continue

		var was_alive := true
		if actor.has_method("is_alive"):
			was_alive = actor.is_alive()
		actor.take_area_damage(dmg, origin)
		total += dmg
		hit_actors += 1
		if was_alive and actor.has_method("is_alive") and not actor.is_alive():
			killed += 1
		if debug_log:
			print("[AREADMG]   %s @ %.1fm — %d dmg (exposure %.0f%%)"
				% [actor.name, dist, dmg, exposure * 100.0])

	var hit_structures := 0
	if profile.damages_obstacles:
		hit_structures = _damage_structures(origin, profile, facing)

	if debug_log:
		print("[AREADMG] %s at (%.1f, %.1f, %.1f): %d actors (%d killed), %d structures, %d total dmg"
			% [profile.display_name if profile.display_name != "" else profile.id,
			origin.x, origin.y, origin.z, hit_actors, killed, hit_structures, total])

	return {"actors": hit_actors, "structures": hit_structures,
		"total_damage": total, "killed": killed}

## Spatialised detonation report. Detached from any thrower so it survives the
## projectile's queue_free(), and frees itself when done — the same pattern
## Zombie._play_death_sound() uses.
func _play_detonation(origin: Vector3, profile: AreaDamageProfile) -> void:
	if profile.sfx_detonate == "" or not ResourceLoader.exists(profile.sfx_detonate):
		return
	var p := AudioStreamPlayer3D.new()
	var res = load(profile.sfx_detonate)
	p.stream = res
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.max_distance = 120.0
	p.unit_size = 14.0
	p.volume_db = 8.0
	get_tree().current_scene.add_child(p)
	p.global_position = origin
	p.finished.connect(p.queue_free)
	p.play()

## Fraction of this actor's body with line of sight to the blast (0..1).
##
## Sampled at several points rather than one, so a zombie with only its head
## over a sandbag wall takes partial damage instead of an all-or-nothing
## result keyed off whichever single point was chosen.
func _exposure(space: PhysicsDirectSpaceState3D, origin: Vector3,
		actor: Node3D, actor_rids: Array[RID]) -> float:
	var points: Array = []
	if actor.has_method("area_damage_points"):
		points = actor.area_damage_points()
	if points.is_empty():
		for h in FALLBACK_SAMPLE_HEIGHTS:
			points.append(actor.global_position + Vector3(0.0, h, 0.0))

	var visible := 0
	for p in points:
		var target: Vector3 = p
		var q := PhysicsRayQueryParameters3D.create(origin, target)
		q.collision_mask = COVER_MASK
		q.collide_with_areas = false
		q.exclude = actor_rids
		if space.intersect_ray(q).is_empty():
			visible += 1
	return float(visible) / float(maxi(1, points.size()))

## Blast damage to destructible structures.
##
## Distance is measured to the NEAREST POINT on the wall, not its centre — a
## grenade at one end of a wall should damage that end, not be judged against
## a point several metres away.
##
## No LOS test here: a structure taking a blast on its own face is exactly the
## case being modelled, and tracing to it would just hit itself.
func _damage_structures(origin: Vector3, profile: AreaDamageProfile, facing: Vector3) -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group(GROUP_STRUCTURES):
		var s := node as Node3D
		if s == null or not is_instance_valid(s):
			continue
		if not s.has_method("take_structure_damage") or not s.has_method("nearest_point"):
			continue
		if s.get("destroyed"):
			continue
		var point: Vector3 = s.nearest_point(origin)
		var dist := origin.distance_to(point)
		if dist > profile.max_radius:
			continue
		if not profile.in_arc(origin, facing, point):
			continue
		var dmg: float = profile.damage_at(dist) * profile.obstacle_damage_mult
		if dmg <= 0.0:
			continue
		s.take_structure_damage(dmg, origin)
		n += 1
		if debug_log:
			# Position + instance id, not just s.name: every SandbagPanel is
			# named identically ("Panel0".."Panel4") across every wall, which
			# makes it impossible to tell WHICH panel on WHICH wall a log line
			# refers to — exactly the ambiguity that made an earlier
			# "destroyed but still standing" report hard to pin down. (See
			# SandbagPanel.take_structure_damage()'s remaining-HP line and
			# _destroy()'s DESTROYED line for the rest of the trail.)
			print("[AREADMG]   %s#%d @ (%.1f,%.1f,%.1f), %.1fm — %.0f structure dmg" % [
				s.name, s.get_instance_id(), s.global_position.x, s.global_position.y,
				s.global_position.z, dist, dmg])
	return n

## Persistent damage-over-time zone. Structurally complete but UNEXERCISED —
## nothing ships with duration > 0 yet. White phosphorus is the intended
## first consumer; it should need only a .tres, not changes here.
func _spawn_dot_zone(origin: Vector3, profile: AreaDamageProfile,
		facing: Vector3, source_name: String) -> void:
	var zone := Node3D.new()
	zone.name = "AreaDoT_" + profile.id
	get_tree().current_scene.add_child(zone)
	zone.global_position = origin
	if debug_log:
		print("[AREADMG] DoT zone '%s' at (%.1f, %.1f, %.1f) for %.1fs every %.2fs"
			% [profile.id, origin.x, origin.y, origin.z, profile.duration, profile.tick_interval])
	# Clamped: a profile authored with tick_interval 0 would never advance
	# `elapsed` and would burn forever. create_timer(0) still yields a frame,
	# so it wouldn't hard-hang — it would just quietly become a permanent
	# damage zone, which is worse to diagnose than a crash.
	var tick: float = maxf(0.05, profile.tick_interval)
	var elapsed := 0.0
	while elapsed < profile.duration and is_instance_valid(zone):
		_apply_once(origin, profile, facing, source_name)
		await get_tree().create_timer(tick).timeout
		elapsed += tick
	if is_instance_valid(zone):
		zone.queue_free()
