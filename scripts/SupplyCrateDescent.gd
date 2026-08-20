extends Node3D
class_name SupplyCrateDescent
## The crate coming down under canopy: a chute and a slung crate that descend
## to the landing point over `descent_time`, then hand off to the real
## lootable SupplyDrop and free themselves.
##
## THIS IS A TELL, NOT DECORATION. The descent is deliberately slow, visible
## from across the map, and NOISY — it emits repeating NoiseManager pulses the
## whole way down, so calling a drop pulls zombies toward the LZ. That cost is
## the counterweight to being able to designate the LZ anywhere.
##
## OWNS NO DAMAGE AND NO PICKUP CODE. Touchdown optionally routes one
## AreaDamageSystem.detonate() through the caller's profile, and always hands
## the contents to a SupplyDrop — both are existing systems.

## Height above the landing point the crate appears at. High enough to be
## skylined from across the base rather than popping in at head height.
const START_HEIGHT := 45.0
## Descent noise pulse cadence and radius. Comparable to a rifle shot (40m)
## rather than a mortar impact (60m) — loud enough to reliably pull nearby
## zombies to the LZ, not loud enough to summon the whole map.
const DESCENT_NOISE_RADIUS := 40.0
const DESCENT_NOISE_INTERVAL := 1.0

var _landing: Vector3
var _duration := 1.0
var _elapsed := 0.0
var _noise_accum := 0.0
var _on_land: Callable
var _landed := false

## `on_land` is invoked once, at touchdown, with no arguments. The caller
## does the spawning; this node only gets it there.
static func spawn(parent: Node, landing: Vector3, duration: float,
		on_land: Callable) -> SupplyCrateDescent:
	var d := SupplyCrateDescent.new()
	d.name = "SupplyCrateDescent"
	d._landing = landing
	d._duration = maxf(0.1, duration)
	d._on_land = on_land
	parent.add_child(d)
	d.global_position = landing + Vector3(0.0, START_HEIGHT, 0.0)
	d._build_visuals()
	return d

func _build_visuals() -> void:
	# Slung crate: the same emissive orange as the lootable SupplyDrop, so the
	# thing descending visibly IS the thing that lands.
	var crate := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.9, 0.7, 0.9)
	crate.mesh = box
	crate.position.y = 0.35
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(1.0, 0.5, 0.05)
	cmat.emission_enabled = true
	cmat.emission = Color(1.0, 0.45, 0.05)
	cmat.emission_energy_multiplier = 2.0
	crate.material_override = cmat
	add_child(crate)

	# Canopy: a wide, shallow, double-sided dome. Unshaded so it reads as a
	# bright shape against a night sky without needing a light on it.
	var chute := MeshInstance3D.new()
	var dome := SphereMesh.new()
	dome.radius = 2.6
	dome.height = 2.6          # hemisphere: height == radius gives a half-sphere
	dome.is_hemisphere = true
	dome.radial_segments = 20
	dome.rings = 8
	chute.mesh = dome
	chute.position.y = 3.4
	var pmat := StandardMaterial3D.new()
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pmat.albedo_color = Color(0.92, 0.90, 0.82, 0.85)
	chute.material_override = pmat
	add_child(chute)

	# Rigging: four thin lines from the crate up to the canopy skirt. Cheap,
	# but it's what makes the silhouette read as a parachute at distance.
	for i in 4:
		var ang := TAU * float(i) / 4.0
		var line := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.02
		cyl.bottom_radius = 0.02
		cyl.height = 2.8
		line.mesh = cyl
		line.position = Vector3(cos(ang) * 1.1, 2.0, sin(ang) * 1.1)
		line.rotation.z = -cos(ang) * 0.35
		line.rotation.x = sin(ang) * 0.35
		line.material_override = pmat
		add_child(line)

func _process(delta: float) -> void:
	if _landed:
		return
	_elapsed += delta
	var t: float = clampf(_elapsed / _duration, 0.0, 1.0)
	# Ease-out: fast at release, slowing as the canopy takes the weight.
	var eased: float = 1.0 - pow(1.0 - t, 2.0)
	global_position = _landing + Vector3(0.0, START_HEIGHT * (1.0 - eased), 0.0)
	# Slow drift under canopy, so it isn't a rigid elevator ride.
	rotation.y += delta * 0.35

	_noise_accum += delta
	if _noise_accum >= DESCENT_NOISE_INTERVAL:
		_noise_accum = 0.0
		# Sourced at the CRATE, not the player — this is what makes the LZ
		# itself the thing zombies converge on.
		NoiseManager.emit_noise(global_position, DESCENT_NOISE_RADIUS)

	if t >= 1.0:
		_touchdown()

func _touchdown() -> void:
	_landed = true
	if _on_land.is_valid():
		_on_land.call()
	queue_free()
