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

func _build_visual() -> void:
	var size: Vector3 = obstacle_type.size
	_visual = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	_visual.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = obstacle_type.color
	_visual.material_override = mat

	# The ditch reads as a trench: the box is sunk below ground rather than
	# cutting real geometry (runtime CSG isn't worth it).
	if type_id == "ditch":
		_visual.position.y = -size.y * 0.5
	else:
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

## Footprint corners on the ground plane, for bounds and seal tests.
func footprint_corners() -> Array:
	var size: Vector3 = obstacle_type.size
	return corners_for(global_position, rotation.y, size)

static func corners_for(origin: Vector3, yaw: float, size: Vector3) -> Array:
	var hx: float = size.x * 0.5
	var hz: float = size.z * 0.5
	var out: Array = []
	for c in [Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz)]:
		var rotated := c.rotated(yaw)
		out.append(Vector3(origin.x + rotated.x, origin.y, origin.z + rotated.y))
	return out
