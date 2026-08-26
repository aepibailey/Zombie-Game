extends Node3D
class_name ApacheTracer
## Tracer streaks for one 30mm burst: a handful of bright lines travelling
## from the airframe's gun to the burst's impact point, with a ground flash
## as each lands. Frees itself when the last one has faded.
##
## COSMETIC ONLY, AND STRICTLY AFTER THE FACT. This node is spawned by
## ApacheSystem._fire_burst() AFTER AreaDamageSystem.detonate() has already
## resolved the burst. It reads the aircraft's position once, at spawn, purely
## to know where to draw a line FROM. Nothing it does can affect what was hit:
## a tracer cannot fail, cannot be blocked, and cannot miss.
##
## THIS IS THE ONLY PLACE THE AIRFRAME'S POSITION IS READ AT ALL, and it must
## stay that way. The Apache's core rule is that engagement is never gated on
## where the aircraft is — see ApacheSystem's note on _acquire_target's
## signature, which is deliberately unable to express a distance-to-airframe
## test. Drawing a line from the aircraft is safe precisely because the
## outcome was already decided before this node existed. Do not let a future
## change route targeting through here.
##
## Given a null or invalid airframe it simply draws nothing and frees itself:
## a missing cosmetic must never take a burst down with it.

var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _cfg: ApacheConfig
var _elapsed := 0.0
var _total := 0.0

var _lines: MeshInstance3D
var _flash: MeshInstance3D
var _flash_mat: StandardMaterial3D

## `muzzle` is the airframe's position, already resolved by the caller — this
## node never looks the aircraft up itself, so it cannot accidentally grow a
## dependency on one existing.
static func spawn(parent: Node, muzzle: Vector3, impact: Vector3,
		cfg: ApacheConfig) -> ApacheTracer:
	if cfg == null or not cfg.tracer_enabled:
		return null
	var t := ApacheTracer.new()
	t.name = "ApacheTracer"
	t._from = muzzle
	t._to = impact
	t._cfg = cfg
	parent.add_child(t)
	return t

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY

	# Last streak leaves at (count-1) * stagger and needs a full travel time.
	var stagger: float = _cfg.tracer_travel_time * _cfg.tracer_stagger
	_total = _cfg.tracer_travel_time + stagger * float(maxi(0, _cfg.tracer_count - 1))

	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	lm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	lm.albedo_color = _cfg.tracer_color
	_lines = MeshInstance3D.new()
	_lines.material_override = lm
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_lines)

	if _cfg.tracer_impact_flash:
		_flash_mat = StandardMaterial3D.new()
		_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_flash_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_flash_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_flash_mat.albedo_color = _cfg.tracer_impact_color
		var sphere := SphereMesh.new()
		sphere.radius = _cfg.tracer_impact_radius
		sphere.height = _cfg.tracer_impact_radius * 2.0
		sphere.radial_segments = 10
		sphere.rings = 5
		_flash = MeshInstance3D.new()
		_flash.mesh = sphere
		_flash.material_override = _flash_mat
		_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_flash.global_position = _to
		_flash.visible = false
		add_child(_flash)

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= _total:
		queue_free()
		return
	_rebuild()

func _rebuild() -> void:
	var path := _to - _from
	var dist := path.length()
	if dist < 0.001:
		return
	var dir := path / dist
	var travel: float = maxf(0.001, _cfg.tracer_travel_time)
	var stagger: float = travel * _cfg.tracer_stagger
	var streak: float = _cfg.tracer_length

	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var drew := 0
	var landed := 0

	for i in range(_cfg.tracer_count):
		var t: float = (_elapsed - stagger * float(i)) / travel
		if t < 0.0:
			continue          # hasn't left the gun yet
		if t >= 1.0:
			landed += 1
			continue          # already arrived
		# Head of the streak along the flight path; the tail trails behind it,
		# clipped at the muzzle so a streak never starts before the gun.
		var head: float = t * dist
		var tail: float = maxf(0.0, head - streak)
		im.surface_add_vertex(_from + dir * tail)
		im.surface_add_vertex(_from + dir * head)
		drew += 1

	im.surface_end()
	# An ImmediateMesh with no vertices is not a valid mesh to assign; clear
	# instead, so the last frame's streaks don't linger once all have landed.
	_lines.mesh = im if drew > 0 else null

	if _flash:
		# Flash while any streak is arriving, fading over one travel time
		# after the last one lands.
		var since_first_land: float = _elapsed - travel
		if landed > 0 and since_first_land >= 0.0:
			var fade: float = clampf(1.0 - since_first_land / maxf(0.001, travel), 0.0, 1.0)
			_flash.visible = true
			var c: Color = _cfg.tracer_impact_color
			c.a = fade
			_flash_mat.albedo_color = c
			_flash.scale = Vector3.ONE * (0.6 + 0.4 * fade)
		else:
			_flash.visible = false
