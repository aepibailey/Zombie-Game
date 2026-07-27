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
	_build_trigger()

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
		z.enter_trapped(self)
		# Drop to the bottom of the trench.
		var floor_y: float = global_position.y - obstacle_type.size.y + 0.2
		z.global_position = Vector3(z.global_position.x, floor_y, z.global_position.z)
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
