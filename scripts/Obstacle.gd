extends Node3D
class_name Obstacle
## A placed defensive obstacle. This section covers geometry, footprint and
## placement bookkeeping; health, entanglement, trapping and mines follow.
##
## Every obstacle carries a `footprint` Area3D on collision layer 4 used purely
## for placement-overlap tests, kept separate from any solid collision so that
## non-solid obstacles (wire, ditch, minefield) still reject overlapping
## placements without physically blocking anything.

const FOOTPRINT_LAYER := 8      # collision layer 4
## Collision layer 5. A barrier on this layer blocks the PLAYER ONLY:
##   - zombie bodies mask layer 1, so they walk through it untouched
##   - the navmesh parses layer 1, so it stays navmesh-passable (essential —
##     carving it would break both the held-in-wire mechanic and the
##     seal-perimeter logic)
##   - weapon rays mask 1|4, so bullets pass straight through
##   - the mantle probes mask layer 1, so it can never be climbed
## Only the player's collision_mask includes it.
const PLAYER_BARRIER_LAYER := 16
## Collision layer 6. Solid to BOTH actors, but deliberately invisible to the
## navmesh (which parses layer 1 only). Used by the ditch revetment walls:
## zombies must still *path into* the trench, so the walls cannot be baked —
## but once inside, they physically cannot climb back out.
const SOLID_NO_NAV_LAYER := 32

## Every surface a physical object can rest on, bounce off, or be emplaced on:
## world geometry and sandbags (layer 1) plus the ditch revetment. C-wire's
## PLAYER_BARRIER_LAYER is deliberately absent — wire is strands, so a grenade
## rolls under it and a claymore cannot stand on it.
##
## Named here because Obstacle already owns every other layer constant, and
## because the thrown grenade and the claymore placer must agree on what
## counts as ground. They were about to hold two copies of the same number.
const SOLID_SURFACE_MASK := 1 | SOLID_NO_NAV_LAYER

## Collision layer 7. Ray-detectable only — an Area3D with monitoring off,
## used purely so a short "what am I looking at" interaction raycast can hit
## a small object precisely (a claymore) without either colliding physically
## (bullets and bodies still pass straight through) or requiring the caller
## to scan every candidate in the world every frame. World geometry (layer 1)
## belongs in the same query mask alongside this one, so the ray is naturally
## occluded by a wall between the player and the thing they're aiming at.
const INTERACT_LAYER := 64

## Collision layer 8 (Step 8A). Cover: blocks projectiles AND line of sight —
## sandbags, walls, vehicle hulks, large rocks. See CoverSurface.gd. Carried
## ALONGSIDE an object's own solid layer (sandbags stay on layer 1 too, for
## the movement/projectile collision that already worked before this layer
## existed) — this bit is what the shared LOS helper (Phase 2) tests against.
const COVER_SOLID_LAYER := 128
## Collision layer 9 (Step 8A). Concealment: blocks line of sight ONLY —
## rounds and bodies pass through. Foliage, brush, smoke, tarps, tall grass.
## Must NEVER appear in a projectile collision mask (Phase 2 asserts this).
const CONCEALMENT_LAYER := 256

var type_id: String = ""
var obstacle_type                # ObstacleCatalog.ObstacleType

var _visual: MeshInstance3D
var _footprint: Area3D
var _solid: StaticBody3D

func setup(t) -> void:
	obstacle_type = t
	type_id = t.id
	add_to_group("obstacles")
	_build_visual()
	_build_footprint()
	if t.solid:
		_build_solid()

## Generic single-box visual. ZombieDitch overrides this entirely — a pit is
## real geometry (walls, floor, ramp), not a single sunken box — so this path
## never runs for "ditch".
func _build_visual() -> void:
	var size: Vector3 = obstacle_type.size
	_visual = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	_visual.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = obstacle_type.color
	_visual.material_override = mat
	_visual.position.y = size.y * 0.5
	add_child(_visual)

	if type_id == "minefield":
		_build_minefield_markers(size)

## Clear boundary markers — the engineers marked the field, and the player
## needs to see where it is.
func _build_minefield_markers(size: Vector3) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.35, 0.1)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.35, 0.1)
	mat.emission_energy_multiplier = 2.0
	# Handed to Minefield so a spent field can grey its own markers.
	set("_post_mat", mat)
	var hx: float = size.x * 0.5
	var hz: float = size.z * 0.5
	for corner in [Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz)]:
		var post := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.06
		cyl.bottom_radius = 0.06
		cyl.height = 0.9
		post.mesh = cyl
		post.material_override = mat
		post.position = Vector3(corner.x, 0.45, corner.y)
		add_child(post)

## Layer-4 volume used only by placement validation.
func _build_footprint() -> void:
	var size: Vector3 = obstacle_type.size
	_footprint = Area3D.new()
	_footprint.collision_layer = FOOTPRINT_LAYER
	_footprint.collision_mask = 0
	_footprint.monitoring = false
	_footprint.add_to_group("obstacle_footprints")
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, maxf(0.5, size.y), size.z)
	col.shape = shape
	col.position.y = maxf(0.5, size.y) * 0.5
	_footprint.add_child(col)
	add_child(_footprint)

## Real collision — sandbags only. Layer 1 so it blocks the player, zombies,
## and weapon rays like any other world geometry.
func _build_solid() -> void:
	var size: Vector3 = obstacle_type.size
	_solid = StaticBody3D.new()
	_solid.collision_layer = 1
	_solid.collision_mask = 1
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position.y = size.y * 0.5
	_solid.add_child(col)
	add_child(_solid)

# --- Persistence ----------------------------------------------------------
## Serialise to a plain Dictionary. Subclasses add their own mutable state
## (sandbag health, remaining mines) by overriding and merging.
func to_dict() -> Dictionary:
	return {
		"type": type_id,
		"pos": global_position,
		"yaw": rotation.y,
	}

## Apply the mutable part of a saved dict. Position and rotation are applied by
## GameState before this is called.
func apply_dict(_d: Dictionary) -> void:
	pass

## Footprint corners on the ground plane, for bounds and seal tests.
func footprint_corners() -> Array[Vector3]:
	var size: Vector3 = obstacle_type.size
	return corners_for(global_position, rotation.y, size)

## Returns a TYPED array so callers get Vector3 elements rather than Variants.
static func corners_for(origin: Vector3, yaw: float, size: Vector3) -> Array[Vector3]:
	var hx: float = size.x * 0.5
	var hz: float = size.z * 0.5
	var local: Array[Vector2] = [
		Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz),
	]
	var out: Array[Vector3] = []
	for c in local:
		var r := c.rotated(yaw)
		out.append(Vector3(origin.x + r.x, origin.y, origin.z + r.y))
	return out
