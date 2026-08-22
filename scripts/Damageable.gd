extends RefCounted
class_name Damageable
## The BULLET-damageable taxonomy: which colliders a player round can hit and
## damage, versus which stop it as cover.
##
## NEVER INSTANTIATED. This is a static holder for the group names, the head
## hitbox meta key, and the one resolution function both the weapon path and
## its assertions share. It exists as its own file rather than living on
## Player.gd because naming the target taxonomy after the shooter reads
## backwards, and because a future damageable (an allied fighter) must be able
## to join it without touching the weapon code at all.
##
## DELIBERATELY SEPARATE FROM AreaDamageSystem.GROUP_DAMAGEABLE. That group is
## the BLAST axis and the player is a member of it — a grenade at your own
## feet kills you. This group is the BULLET axis and the player must never be
## a member, or the moment a round clears the muzzle RID it would resolve the
## shooter as a target. Two axes, two groups, and they must not be merged into
## one "combatant" group as a convenience:
##
##   AreaDamageSystem.GROUP_DAMAGEABLE — blasts. Player IS a member.
##   Damageable.GROUP_BULLET           — player rounds. Player is NOT.
##
## A member must implement:
##   take_damage(amount: int, headshot: bool, falloff_mult: float) -> int
##   hp   (property, read for the hit-feedback signal)
## and MAY register a head hitbox — see GROUP_BULLET_HEAD.

## Entities a player round can damage. The round passes through or stops
## according to the weapon's own penetration rules; anything NOT in this group
## is cover and stops the round outright.
const GROUP_BULLET := "bullet_damageable"

## Head hitboxes. A separate collider (an Area3D on layer 3) belonging to a
## GROUP_BULLET entity, carrying HEAD_META pointing back at its owner. Head vs
## body comes from WHICH COLLIDER was struck, never from inferring a hit
## height — see Zombie's own geometry note.
##
## Registering a head is OPTIONAL. An entity with no head hitbox is simply
## never headshot; it resolves cleanly as a body hit.
const GROUP_BULLET_HEAD := "bullet_head"

## Meta key on a head hitbox naming the entity it belongs to.
const HEAD_META := "damageable_owner"

## Resolve a struck collider into the entity that should take the damage and
## whether it was a head hit.
##
## Returns {"entity": Node or null, "is_damageable": bool, "is_head": bool}.
##
##   is_damageable false  → cover. The round stops.
##   is_damageable true, entity null → a damageable collider that cannot be
##       resolved to an owner (a head hitbox with no meta). NOT cover: the
##       round is still considered to have struck flesh, matching the existing
##       behaviour where such a hit stops a non-penetrating round rather than
##       falling through to the cover branch.
##
## The head test runs FIRST because a head hitbox is an Area3D layered
## separately from its owner's body, and an entity could in principle be in
## both groups.
static func resolve_hit(collider: Object) -> Dictionary:
	if collider == null or not (collider is Node):
		return {"entity": null, "is_damageable": false, "is_head": false}
	var node: Node = collider as Node
	if node.is_in_group(GROUP_BULLET_HEAD):
		var owner_node = node.get_meta(HEAD_META, null)
		_assert_not_player(owner_node)
		return {
			"entity": owner_node,
			"is_damageable": true,
			"is_head": true,
		}
	if node.is_in_group(GROUP_BULLET):
		_assert_not_player(node)
		return {"entity": node, "is_damageable": true, "is_head": false}
	return {"entity": null, "is_damageable": false, "is_head": false}

## INVARIANT: a player round never resolves the player as a damageable target.
##
## The guard is group membership — the player is deliberately not in
## GROUP_BULLET — but the muzzle-RID exclude in _fire_ray used to be the only
## thing between a round and its shooter, and HIT_MASK admits the player's own
## layer. If the player is ever added to the bullet group (say by someone
## reaching for a single "combatant" group), this fires rather than quietly
## making the player self-shootable.
##
## assert() only, no push_error: this sits on the per-shot path and Godot
## strips asserts from release builds.
static func _assert_not_player(entity) -> void:
	assert(entity == null or not (entity is Node) or not (entity as Node).is_in_group("player"),
		"[DAMAGEABLE] a player round resolved the PLAYER as a damageable target. The player must never join GROUP_BULLET — that group is the bullet axis; AreaDamageSystem.GROUP_DAMAGEABLE is the blast axis and is where the player belongs.")

## True when `entity` has a head hitbox registered against it. Used by the
## hit-zone assertion: a "head" result must never come back for an entity that
## never registered one.
static func has_head_hitbox(tree: SceneTree, entity: Node) -> bool:
	if entity == null:
		return false
	for h in tree.get_nodes_in_group(GROUP_BULLET_HEAD):
		if h.get_meta(HEAD_META, null) == entity:
			return true
	return false
