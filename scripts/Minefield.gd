extends Obstacle
class_name Minefield
## A marked 10x5m minefield. The emplacement is permanent; its ammunition is
## not. Player-safe — the engineers marked the field, so the operator never
## trips their own mines.
##
## Known property (deliberate, flagged for playtest): 125 damage one-shots a
## baseline zombie, but zombie HP reaches 132 by night 9 under the current
## scaling curve. From night 9 the minefield wounds rather than kills.

@export var mine_count: int = 20
@export var trigger_damage: int = 125
@export var splash_damage: int = 50
@export var splash_radius: float = 10.0
@export var survivor_speed_mult: float = 0.50   # permanent -50%
@export var blast_noise_radius: float = 60.0
@export var trigger_radius: float = 0.8

const SFX_BLAST := "res://audio/gunshot.wav"

var mines_remaining: int = 20

## How close the player must be for the world-space count to appear.
@export var readout_range: float = 5.0

var _mines: Array = []            # {pos: Vector3, live: bool, mesh: MeshInstance3D}
var _trigger: Area3D
var _inside: Array = []
var _sfx: AudioStreamPlayer3D
var _readout: Label3D
var _readout_forced := false      # build mode shows it regardless of distance
var _posts: Array = []            # boundary markers, greyed when spent
var _post_mat: StandardMaterial3D

func setup(t) -> void:
	super.setup(t)
	add_to_group("minefields")
	mines_remaining = mine_count
	_scatter_mines()
	_build_trigger()
	_build_audio()
	_build_readout()

## World-space count. Shown near the emplacement and always in build mode —
## the logic was always decrementing correctly, it just had no readout, which
## made the field look like it had unlimited mines.
func _build_readout() -> void:
	_readout = Label3D.new()
	_readout.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_readout.no_depth_test = true
	_readout.fixed_size = true
	_readout.pixel_size = 0.004
	_readout.font_size = 64
	_readout.outline_size = 12
	_readout.modulate = Color(1.0, 0.6, 0.2)
	_readout.position.y = 1.4
	_readout.visible = false
	add_child(_readout)
	_refresh_readout()

func _refresh_readout() -> void:
	if _readout == null:
		return
	_readout.text = "MINES %d / %d" % [mines_remaining, mine_count]
	var spent: bool = mines_remaining <= 0
	_readout.modulate = Color(0.6, 0.6, 0.6) if spent else Color(1.0, 0.6, 0.2)
	# A spent field must be distinguishable at a glance: the marker posts go
	# dark and stop glowing.
	if _post_mat:
		if spent:
			_post_mat.albedo_color = Color(0.35, 0.33, 0.3)
			_post_mat.emission_energy_multiplier = 0.0
		else:
			_post_mat.albedo_color = Color(1.0, 0.35, 0.1)
			_post_mat.emission_energy_multiplier = 2.0

## Build mode forces the readout on for every field, regardless of distance.
func set_readout_forced(on: bool) -> void:
	_readout_forced = on

func _process(_delta: float) -> void:
	if _readout == null:
		return
	if _readout_forced:
		_readout.visible = true
		return
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		_readout.visible = false
		return
	var p: Node3D = players[0]
	_readout.visible = p.global_position.distance_to(global_position) <= readout_range

## Roughly one mine per 2.5 m^2 over the 10x5m field.
func _scatter_mines() -> void:
	var size: Vector3 = obstacle_type.size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.22, 0.18)
	for i in mine_count:
		var local := Vector3(
			randf_range(-size.x * 0.45, size.x * 0.45), 0.04,
			randf_range(-size.z * 0.45, size.z * 0.45))
		var m := MeshInstance3D.new()
		var disc := CylinderMesh.new()
		disc.top_radius = 0.13
		disc.bottom_radius = 0.13
		disc.height = 0.07
		m.mesh = disc
		m.material_override = mat
		m.position = local
		add_child(m)
		_mines.append({"pos": local, "live": true, "mesh": m})

func _build_trigger() -> void:
	var size: Vector3 = obstacle_type.size
	_trigger = Area3D.new()
	_trigger.collision_layer = 0
	_trigger.collision_mask = 1
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, 2.0, size.z)
	col.shape = shape
	col.position.y = 1.0
	_trigger.add_child(col)
	_trigger.body_entered.connect(_on_entered)
	_trigger.body_exited.connect(_on_exited)
	add_child(_trigger)

func _build_audio() -> void:
	_sfx = AudioStreamPlayer3D.new()
	_sfx.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_sfx.max_distance = 90.0
	_sfx.unit_size = 12.0
	_sfx.volume_db = 8.0
	_sfx.pitch_scale = 0.55            # deeper than a gunshot
	if ResourceLoader.exists(SFX_BLAST):
		var res = load(SFX_BLAST)
		_sfx.stream = res
	add_child(_sfx)

func _on_entered(body: Node3D) -> void:
	if body.is_in_group("zombies"):
		_inside.append(body)

func _on_exited(body: Node3D) -> void:
	_inside.erase(body)

func _physics_process(_delta: float) -> void:
	if mines_remaining <= 0 or _inside.is_empty():
		return
	_inside = _inside.filter(func(z): return is_instance_valid(z) and z.is_alive())
	for z in _inside:
		# Explicit: `z` comes from an untyped array, so its global_position is
		# a Variant and the expression has no inferrable type.
		var zpos: Vector3 = z.global_position
		var local: Vector3 = (zpos - global_position).rotated(Vector3.UP, -rotation.y)
		for m in _mines:
			if not m["live"]:
				continue
			var p: Vector3 = m["pos"]
			if Vector2(local.x - p.x, local.z - p.z).length() <= trigger_radius:
				_detonate(m, z)
				return   # one mine per trigger event — no chain detonation

func _detonate(mine: Dictionary, trigger) -> void:
	mine["live"] = false
	mines_remaining = maxi(0, mines_remaining - 1)
	_refresh_readout()
	var mesh: MeshInstance3D = mine["mesh"]
	if is_instance_valid(mesh):
		mesh.queue_free()

	var blast_pos: Vector3 = trigger.global_position
	_sfx.global_position = blast_pos
	if _sfx.stream:
		_sfx.play()
	# The field announcing itself and pulling more zombies in is intended.
	NoiseManager.emit_noise(blast_pos, blast_noise_radius)

	# The triggering zombie takes the full charge; everything nearby takes
	# splash. Survivors of either are permanently crippled.
	_apply(trigger, trigger_damage)
	for other in get_tree().get_nodes_in_group("zombies"):
		if other == trigger or not is_instance_valid(other) or not other.is_alive():
			continue
		if other.global_position.distance_to(blast_pos) <= splash_radius:
			_apply(other, splash_damage)

func _apply(z, amount: int) -> void:
	if not is_instance_valid(z) or not z.is_alive():
		return
	z.take_damage(amount, false)
	# Mine kills award 1 point, same as a body-shot kill.
	if is_instance_valid(z) and z.is_alive():
		z.apply_permanent_slow(survivor_speed_mult)

## Partial refill at the crate/tent, priced by what's missing.
func replenish() -> void:
	for m in _mines:
		if not m["live"]:
			m["live"] = true
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.25, 0.22, 0.18)
			var mesh := MeshInstance3D.new()
			var disc := CylinderMesh.new()
			disc.top_radius = 0.13
			disc.bottom_radius = 0.13
			disc.height = 0.07
			mesh.mesh = disc
			mesh.material_override = mat
			mesh.position = m["pos"]
			add_child(mesh)
			m["mesh"] = mesh
	mines_remaining = mine_count
	_refresh_readout()

func is_spent() -> bool:
	return mines_remaining <= 0
