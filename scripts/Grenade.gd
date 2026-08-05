extends RigidBody3D
class_name Grenade
## A thrown hand grenade: bounces and rolls off terrain, sandbags and the ditch
## revetment, then detonates through the shared area-damage system.
##
## IT OWNS NO DAMAGE CODE. Detonation is one AreaDamageSystem.detonate() call
## with an AreaDamageProfile — blast radii, falloff, cover, obstacle damage and
## the noise event all live in the .tres (resources/frag_grenade.tres), not
## here. See AreaDamageSystem.gd.
##
## The fuse is passed IN rather than started here: cooking and flight share one
## clock, so a grenade cooked for 2s of a 5s fuse has 3s of flight left. See
## Player._throw_grenade().

const RADIUS := 0.07
const MASS := 0.4

## Bounce/roll feel. A frag body is dense and doesn't bounce much — it takes a
## hop off a hard surface and then rolls, which is what lets it settle into the
## bottom of the ditch rather than skipping back out.
const BOUNCE := 0.28
const FRICTION := 0.65
## Rolling grenades that never settle are worse than ones that stop slightly
## early: without damping a sphere on a flat plane rolls indefinitely.
const ANGULAR_DAMP := 1.6
const LINEAR_DAMP := 0.25

var _fuse := 0.0
var _profile: AreaDamageProfile
var _detonated := false
## Nothing happens until launch() has run. Guards the case where a Grenade is
## added to the tree but never launched — without it the 0.0 default fuse
## would detonate a profile-less grenade at the world origin on the next tick.
var _launched := false

## `fuse` is the time REMAINING, not the full fuse length.
func launch(origin: Vector3, velocity: Vector3, fuse: float,
		profile: AreaDamageProfile, thrower: Node = null) -> void:
	_launched = true
	_fuse = fuse
	_profile = profile
	global_position = origin
	linear_velocity = velocity
	# A little tumble, purely visual — it also stops the sphere from looking
	# frozen while it flies.
	angular_velocity = Vector3(randf_range(-8.0, 8.0), randf_range(-4.0, 4.0),
		randf_range(-8.0, 8.0))
	# The thrower must not be shoved by their own grenade on the way out.
	if thrower is CollisionObject3D:
		add_collision_exception_with(thrower)

func _ready() -> void:
	mass = MASS
	# LAYER 0 ON PURPOSE. The grenade must not appear on layer 1, because
	# AreaDamageSystem's line-of-sight COVER_MASK includes layer 1 — a grenade
	# that was its own cover would block its own blast. Layer 0 also keeps it
	# out of weapon rays (Player.HIT_MASK) and the laser. Collision still
	# happens because the MASK below matches the world's layers.
	collision_layer = 0
	# World/sandbags (1) + the ditch revetment (SOLID_NO_NAV_LAYER) so it can
	# come to rest at the bottom of the pit. C-wire's player-barrier layer is
	# deliberately excluded — a grenade rolls under wire.
	collision_mask = 1 | Obstacle.SOLID_NO_NAV_LAYER
	continuous_cd = true   # a fast throw must not tunnel through a sandbag
	angular_damp = ANGULAR_DAMP
	linear_damp = LINEAR_DAMP
	can_sleep = true

	var phys := PhysicsMaterial.new()
	phys.bounce = BOUNCE
	phys.friction = FRICTION
	physics_material_override = phys

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = RADIUS
	shape.shape = sphere
	add_child(shape)

	var mesh := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = RADIUS
	sm.height = RADIUS * 2.0
	sm.radial_segments = 10
	sm.rings = 6
	mesh.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.22, 0.16)
	mesh.material_override = mat
	add_child(mesh)

func _physics_process(delta: float) -> void:
	if _detonated or not _launched:
		return
	_fuse -= delta
	if _fuse <= 0.0:
		_detonate()

func _detonate() -> void:
	if _detonated:
		return
	_detonated = true
	# Everything about the blast — radii, falloff, cover, obstacle damage and
	# the NoiseManager event — comes from the profile.
	AreaDamageSystem.detonate(global_position, _profile, Vector3.ZERO, "grenade")
	queue_free()
