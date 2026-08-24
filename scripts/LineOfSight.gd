extends RefCounted
class_name LineOfSight
## THE line-of-sight implementation (Step 8A Phase 2). There is exactly one,
## and this is it — zombies, fighters and the laser-reveal rule all route
## through here. Do not add a second: a parallel LOS check is how cover
## silently stops working for one consumer while still working for another.
##
## NEVER INSTANTIATED. Static holder, same shape as Damageable.gd.
##
## D1 — TWO MASKS, AND THEY ARE NOT THE SAME MASK:
##   LOS_MASK        cover_solid + concealment + world solid. What SIGHT hits.
##   PROJECTILE_MASK cover_solid + world solid, NEVER concealment. What
##                   ROUNDS hit. Brush blocks the eye and not the bullet;
##                   that difference is the entire mechanic, and it exists
##                   because these two constants differ by exactly one bit.
##
## D3 — EYE POINTS, NEVER BODY ORIGINS. Every ray this file casts starts and
## ends at an eye point supplied by eye_point() below. A LOS ray from a
## capsule's origin is a ray from the entity's FEET: it sees under every
## waist-high wall in the game and makes crouching meaningless. That was the
## live bug this phase fixed (Zombie._has_los_to used global_position + a
## hardcoded 1.4/1.2 offset at both ends, blind to both zombie variant height
## and player crouch).

## Sight. Blocked by world geometry (layer 1), ditch walls
## (SOLID_NO_NAV_LAYER — standing in a pit really is out of sight), cover and
## concealment alike.
const LOS_MASK := 1 | Obstacle.SOLID_NO_NAV_LAYER \
	| Obstacle.COVER_SOLID_LAYER | Obstacle.CONCEALMENT_LAYER

## Rounds and blast fragments. Cover stops them; concealment does not.
## CONCEALMENT_LAYER must never be ORed into this — see assert_masks_sane().
const PROJECTILE_MASK := 1 | Obstacle.COVER_SOLID_LAYER

## How close a hit must land to a target POINT (rather than a target body) to
## count as reaching it. The laser dot sits ON a surface, so its ray is always
## expected to terminate at the dot; anything landing meaningfully short is a
## real occluder in between.
const SURFACE_POINT_TOLERANCE := 0.5

## The point sight enters and leaves an entity.
##
## CONTRACT: an entity participating in line of sight implements
##   eye_position() -> Vector3   (world space, already crouch-aware if it
##                                crouches at all)
## Player, Zombie and Fighter all implement it. An entity that does not is a
## bug rather than a fallback case — the assert names it, and the degraded
## return keeps a release build from raycasting from a NaN.
static func eye_point(node: Node3D) -> Vector3:
	if node != null and node.has_method("eye_position"):
		return node.eye_position()
	assert(false,
		"[LOS] eye_point() on an entity with no eye_position(). Every line-of-sight participant must supply a real eye point — a body origin is the feet, and sight from the feet ignores every waist-high wall in the game.")
	push_error("[LOS] entity has no eye_position(); LOS from this entity is unreliable.")
	return node.global_position if node != null else Vector3.ZERO

## Eye-to-eye. True when `observer` can see `target`.
##
## Both bodies are excluded from the trace so an entity never occludes itself
## or its own target — only real geometry blocks sight.
static func between(observer: Node3D, target: Node3D) -> bool:
	if observer == null or target == null:
		return false
	if not is_instance_valid(observer) or not is_instance_valid(target):
		return false
	var space := observer.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(eye_point(observer), eye_point(target))
	q.collision_mask = LOS_MASK
	q.collide_with_areas = false
	q.exclude = _rids_of([observer, target])
	return space.intersect_ray(q).is_empty()

## Eye-to-arbitrary-point, where the point is a position in space rather than
## an entity (a laser dot on a wall, a fan ray's endpoint in the placement
## preview). `tolerance` > 0 treats a hit landing that close to `to` as having
## reached it — required when `to` sits ON the surface the ray must reach.
static func clear_to_point(observer: Node3D, to: Vector3,
		tolerance: float = 0.0) -> bool:
	if observer == null or not is_instance_valid(observer):
		return false
	var space := observer.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(eye_point(observer), to)
	q.collision_mask = LOS_MASK
	q.collide_with_areas = false
	q.exclude = _rids_of([observer])
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	if tolerance <= 0.0:
		return false
	var at: Vector3 = hit.position
	return at.distance_to(to) < tolerance

## Point-to-point, for a caller that already holds both ends (the fighter
## placement preview casts from a prospective eye point that has no body in
## the world yet). `exclude` is passed straight through.
static func clear_between_points(space: PhysicsDirectSpaceState3D,
		from: Vector3, to: Vector3, exclude: Array[RID] = []) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = LOS_MASK
	q.collide_with_areas = false
	q.exclude = exclude
	return space.intersect_ray(q).is_empty()

static func _rids_of(nodes: Array) -> Array[RID]:
	var out: Array[RID] = []
	for n in nodes:
		if n is CollisionObject3D:
			out.append((n as CollisionObject3D).get_rid())
	return out

# --- Startup invariants ------------------------------------------------------
## Called once from Main._ready(). Startup, not hot path, so push_error backs
## the assert up — these must be visible in a release export too, since a mask
## regression here is silent in play (brush that stops bullets just reads as
## "the gun missed").
static func assert_masks_sane() -> void:
	# INVARIANT: concealment never stops a round.
	var projectile_clean: bool = (PROJECTILE_MASK & Obstacle.CONCEALMENT_LAYER) == 0
	assert(projectile_clean,
		"[LOS] CONCEALMENT_LAYER appears in PROJECTILE_MASK. Concealment blocks sight only — rounds pass through it. That is the difference between cover and concealment and it must not be collapsed.")
	if not projectile_clean:
		push_error("[LOS] CONCEALMENT_LAYER is in PROJECTILE_MASK — concealment is wrongly stopping rounds.")

	# The other projectile-carrying masks in the project must be equally clean.
	# Named individually rather than scanned, so adding a new one is a
	# deliberate act that shows up in this list.
	var others := {
		"Player.HIT_MASK": Player.HIT_MASK,
		"Grenade.COLLISION_MASK": Grenade.COLLISION_MASK,
		"AreaDamageSystem.COVER_MASK": AreaDamageSystem.COVER_MASK,
		"Obstacle.SOLID_SURFACE_MASK": Obstacle.SOLID_SURFACE_MASK,
	}
	for mask_name in others:
		var m: int = others[mask_name]
		var clean: bool = (m & Obstacle.CONCEALMENT_LAYER) == 0
		assert(clean,
			"[LOS] a projectile/physical mask includes CONCEALMENT_LAYER. Concealment must never stop a round, a grenade, or a thrown object.")
		if not clean:
			push_error("[LOS] %s includes CONCEALMENT_LAYER — concealment is wrongly physical." % mask_name)

	# INVARIANT: sight is stopped by strictly more than rounds are. If these
	# two masks ever become equal, cover and concealment have collapsed into
	# one thing and D1 is gone.
	var los_is_stricter: bool = (LOS_MASK & ~PROJECTILE_MASK) != 0
	assert(los_is_stricter,
		"[LOS] LOS_MASK stops nothing PROJECTILE_MASK does not. Cover and concealment have collapsed into a single category.")
	if not los_is_stricter:
		push_error("[LOS] LOS_MASK and PROJECTILE_MASK no longer differ — concealment does nothing.")

	# INVARIANT: crouching is worth doing. Asserted here rather than in Player
	# so every eye-height invariant sits in one place.
	var crouch_lower: bool = Player.CROUCH_HEAD_Y < Player.STAND_HEAD_Y
	assert(crouch_lower,
		"[LOS] the player's crouched eye height is not below the standing one. Crouching behind cover is the core defensive verb; if these are equal or inverted it does nothing.")
	if not crouch_lower:
		push_error("[LOS] CROUCH_HEAD_Y is not below STAND_HEAD_Y — crouching gains the player nothing.")
