extends Obstacle
class_name CWireSection
## Triple-strand concertina wire. Permanent and indestructible.
##
## Holds up to `capacity` zombies permanently. Once full the wire is trampled
## at that point and further zombies push through — slowed while inside, and
## permanently slower afterwards. The wire still shreds them on the way past
## even when it can no longer hold them. No effect on the player.

@export var capacity: int = 4
@export var inside_speed_mult: float = 0.40     # -60% while in the volume
@export var exit_speed_penalty: float = 0.85    # permanent -15% on the way out

var held: Array = []

var _trigger: Area3D

func setup(t) -> void:
	super.setup(t)
	add_to_group("cwire")
	_build_player_barrier()
	_build_trigger()

## Wire is a hard barrier to the PLAYER only — it sits on the dedicated
## player-barrier layer, so zombies still walk in and get held, the navmesh
## still treats it as passable, bullets still pass through, and the mantle
## probes (which mask layer 1) can never find a surface to climb.
func _build_player_barrier() -> void:
	var size: Vector3 = obstacle_type.size
	var body := StaticBody3D.new()
	body.collision_layer = Obstacle.PLAYER_BARRIER_LAYER
	body.collision_mask = 0
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position.y = size.y * 0.5
	body.add_child(col)
	add_child(body)

func _build_trigger() -> void:
	var size: Vector3 = obstacle_type.size
	_trigger = Area3D.new()
	_trigger.collision_layer = 0
	_trigger.collision_mask = 1        # detect zombie/player bodies
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position.y = size.y * 0.5
	_trigger.add_child(col)
	_trigger.body_entered.connect(_on_entered)
	_trigger.body_exited.connect(_on_exited)
	add_child(_trigger)

func is_trampled() -> bool:
	_prune()
	return held.size() >= capacity

func _prune() -> void:
	held = held.filter(func(z): return is_instance_valid(z) and z.is_alive())

func _on_entered(body: Node3D) -> void:
	if not body.is_in_group("zombies"):
		return   # the player walks straight through
	var z = body
	if not z.has_method("enter_entangled"):
		return
	_prune()
	if held.size() < capacity:
		# Caught. Permanent — only death frees the slot.
		held.append(z)
		z.enter_entangled(self)
	else:
		# Trampled section: pushes through, but slowly.
		z.set_temp_slow(inside_speed_mult)

func _on_exited(body: Node3D) -> void:
	if not body.is_in_group("zombies"):
		return
	var z = body
	if not z.has_method("set_temp_slow"):
		return
	if z in held:
		return   # entangled zombies never really leave
	z.set_temp_slow(1.0)
	z.apply_permanent_slow(exit_speed_penalty)

## Called by a zombie's death to free its slot.
func release(z) -> void:
	held.erase(z)
