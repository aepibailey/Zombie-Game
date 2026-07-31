extends Obstacle
class_name ZombieDitch
## A 2m trench. Permanent and indestructible.
##
## Built as a recessed visual plus a trigger volume — no real geometry is cut.
## Runtime CSG subtraction isn't worth it for a box-shaped hole.
##
## Holds up to `capacity` zombies at the bottom. Once full, the pile lets later
## zombies cross over the top, slowed only while crossing — they climbed over
## bodies, they weren't injured. The player can fall in and mantle out: at 2m
## it sits exactly at the mantle limit, so it takes real effort.

@export var capacity: int = 6
@export var crossing_speed_mult: float = 0.40   # -60% while crossing a full ditch

var trapped: Array = []

var _trigger: Area3D

func setup(t) -> void:
	super.setup(t)
	add_to_group("ditches")
	_build_revetment()
	_build_trigger()

## The trench is formed by 2m revetment walls ABOVE ground, not by a hole.
##
## There is no hole to dig: the ground is one solid box spanning y -1..0, and
## cutting real geometry is explicitly out of scope. The original "teleport the
## zombie 2m down" put it at y = -1.8 — below the ground collider entirely —
## so it fell out of the world forever, which is exactly the reported bug.
##
## Walls sit on SOLID_NO_NAV_LAYER so the navmesh ignores them (zombies still
## path *into* the trench) while physically containing anything inside. At 2m
## they're exactly at the player's mantle limit, so climbing out is possible
## but effortful — which is the behaviour the spec asked for.
func _build_revetment() -> void:
	var size: Vector3 = obstacle_type.size
	var wall_h: float = size.y            # 2m
	var t: float = 0.25
	var offset: float = size.z * 0.5 + t * 0.5

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.26, 0.19)

	for side in [-1.0, 1.0]:
		var body := StaticBody3D.new()
		body.collision_layer = Obstacle.SOLID_NO_NAV_LAYER
		body.collision_mask = 0
		body.position = Vector3(0, 0, side * offset)

		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(size.x, wall_h, t)
		mesh.mesh = box
		mesh.material_override = mat
		mesh.position.y = wall_h * 0.5
		body.add_child(mesh)

		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(size.x, wall_h, t)
		col.shape = shape
		col.position.y = wall_h * 0.5
		body.add_child(col)
		add_child(body)

func _build_trigger() -> void:
	var size: Vector3 = obstacle_type.size
	_trigger = Area3D.new()
	_trigger.collision_layer = 0
	_trigger.collision_mask = 1
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	# Spans the trench and a little above, so a zombie walking over a full
	# ditch is still detected for the crossing slow.
	shape.size = Vector3(size.x, size.y + 1.0, size.z)
	col.shape = shape
	col.position.y = -size.y * 0.5 + 0.5
	_trigger.add_child(col)
	_trigger.body_entered.connect(_on_entered)
	_trigger.body_exited.connect(_on_exited)
	add_child(_trigger)

func is_full() -> bool:
	_prune()
	return trapped.size() >= capacity

func _prune() -> void:
	trapped = trapped.filter(func(z): return is_instance_valid(z) and z.is_alive())

func _on_entered(body: Node3D) -> void:
	if not body.is_in_group("zombies"):
		return   # the player just falls in and mantles out
	var z = body
	if not z.has_method("enter_trapped"):
		return
	_prune()
	if trapped.size() < capacity:
		trapped.append(z)
		# NO teleport. The previous version dropped the zombie to y = -1.8,
		# which is below the ground collider (-1.0 .. 0.0), so it fell out of
		# the world and became unhittable. It stays exactly where it walked in,
		# on the trench floor, fully visible and shootable from the lip.
		z.enter_trapped(self)
	else:
		z.set_temp_slow(crossing_speed_mult)

func _on_exited(body: Node3D) -> void:
	if not body.is_in_group("zombies"):
		return
	var z = body
	if not z.has_method("set_temp_slow"):
		return
	if z in trapped:
		return
	# No lingering penalty: they walked over bodies, they weren't hurt.
	z.set_temp_slow(1.0)

func release(z) -> void:
	trapped.erase(z)
