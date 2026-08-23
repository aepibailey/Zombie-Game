extends Node
class_name CoverSurface
## Reusable cover/concealment marker (Step 8A). NOT a replacement for an
## object's own health/damage/destruction — SandbagPanel keeps its own HP,
## its own StaticBody3D, its own destroy/repair. This component only owns
## that object's membership on the cover/concealment layer and guarantees it
## comes off cleanly when the object is destroyed.
##
## D1: SOLID stops rounds AND blocks LOS (sandbags, walls, hulks, rocks).
##     CONCEALMENT blocks LOS only — rounds pass through (foliage, smoke).
## D2: no cover-snapping, no attach state, no peek. This is a passive marker
##     read by raycasts (Phase 2) — it never reacts to player input itself.
##
## DESIGN NOTE ON THE THREE LAYERS THE PROMPT ASKS THIS TO CLEAN UP
## (cover/concealment layer, projectile-blocking layer, nav mesh):
## For an object like a sandbag panel, "projectile-blocking" is its EXISTING
## layer-1 solid body, and nav removal is its EXISTING shape-disable +
## `changed` signal -> BuildMode -> world.request_navmesh_rebake() pipeline —
## both already correct (that's what the earlier sandbag fix built). This
## component does not duplicate either: attach_to() ORs its own layer bit
## onto the SAME body the owner already built (never a second collider to
## drift out of sync), and notify_destroyed()'s assertion cross-checks that
## the owner's own collision shape is ALSO disabled by the time cover comes
## off — catching exactly the "one of the three lingers" bug class if a
## future retrofit forgets to disable its collider.
##
## `world`, if given to attach_to(), is used ONLY to request a rebake
## directly — for an object with no existing signal→rebake pipeline of its
## own. Sandbags don't pass one (their own pipeline already fires); a future
## standalone cover object (a rock, a hulk) that isn't wired into anything
## else would.

enum Type { SOLID, CONCEALMENT }

@export var cover_type: Type = Type.SOLID
@export var blocks_navigation: bool = true
@export var destroyed_removes_cover: bool = true

var _body: CollisionObject3D
var _world: Node
var _active := false

func attach_to(body: CollisionObject3D, world: Node = null) -> void:
	assert(body != null, "[COVER] CoverSurface.attach_to() needs a real body.")
	_body = body
	_world = world
	_active = true
	_body.collision_layer |= _layer_bit()
	if blocks_navigation:
		_request_rebake("cover attached")

## Re-adds the layer bit after a prior notify_destroyed() — the repair-half
## of a destructible SOLID cover object (SandbagPanel.repair()).
func restore() -> void:
	if _active or not is_instance_valid(_body):
		return
	_active = true
	_body.collision_layer |= _layer_bit()
	if blocks_navigation:
		_request_rebake("cover restored")

## Called by the owner's OWN destruction path (SandbagPanel._destroy(), a
## future tree's death, etc.) — never inferred from health here, since this
## component has no idea what "destroyed" means for an arbitrary object. If
## the owner's own collision-shape teardown is itself deferred (as
## SandbagPanel's is, since destruction can run from inside a physics query
## callback), call this deferred too so the assertion below observes the
## post-teardown state, not a stale pre-deferred one.
func notify_destroyed() -> void:
	if not destroyed_removes_cover or not _active:
		return
	_active = false
	if is_instance_valid(_body):
		_body.collision_layer &= ~_layer_bit()
	if blocks_navigation:
		_request_rebake("cover destroyed")
	assert(not blocks_cover_or_concealment(),
		"[COVER] destroyed CoverSurface still reports blocking on its cover/concealment layer.")
	assert(not _body_still_solid(),
		"[COVER] destroyed CoverSurface's body still has an enabled collision shape — cover/concealment came off but the projectile-blocking layer or nav mesh didn't follow.")

func _layer_bit() -> int:
	return Obstacle.COVER_SOLID_LAYER if cover_type == Type.SOLID else Obstacle.CONCEALMENT_LAYER

func blocks_cover_or_concealment() -> bool:
	return is_instance_valid(_body) and (_body.collision_layer & _layer_bit()) != 0

func _body_still_solid() -> bool:
	if not is_instance_valid(_body):
		return false
	for c in _body.get_children():
		if c is CollisionShape3D and not (c as CollisionShape3D).disabled:
			return true
	return false

func _request_rebake(reason: String) -> void:
	if _world and _world.has_method("request_navmesh_rebake"):
		_world.request_navmesh_rebake(reason)

func is_active() -> bool:
	return _active
