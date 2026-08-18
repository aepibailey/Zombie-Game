extends Node3D
class_name WhitePhosphorusZone
## A persistent white-phosphorus burn zone left over the impact area after a
## shake-and-bake mission's last round.
##
## OWNS NO DAMAGE CODE. The burn is one AreaDamageSystem.detonate() call with
## a `duration > 0` profile, which takes that system's damage-over-time path —
## the branch its own docstring names white phosphorus as the intended first
## consumer of. This node exists for the two things that path does NOT do:
## be visible, and tie the visual's lifetime to the damage's.
##
## VISIBILITY IS A FUNCTIONAL REQUIREMENT HERE, not an art-pass item. An
## invisible damage zone the player walks into is a bug. The zone has to read
## at night, without NVGs, from outside its own radius.
##
## The damage profile is BUILT AT RUNTIME from FireMissionConfig rather than
## authored as a .tres. That is deliberate and is the opposite of what the
## HE round does: every number the burn needs (radius, duration, dps) is
## already a tunable on the mission config, so authoring a second resource
## would create two places to edit and let the visible radius drift from the
## damaged one. Here, one config drives both by construction.

## Ground glow tint. Unshaded and alpha-blended, never additive — the night
## NVG path has no glow stage, so the risk is washing out a dark scene rather
## than blooming. Same discipline as GrenadeArc, ArcWedge and TargetPainter.
const COLOR_GLOW := Color(1.0, 0.62, 0.18, 0.30)
const GLOW_SEGMENTS := 48
const GROUND_OFFSET := 0.06
## Glow pulses slightly so the zone reads as burning rather than as a decal.
const PULSE_HZ := 1.6
const PULSE_DEPTH := 0.10

## Particle budget scales with area so a 15m zone isn't sparse and a small one
## isn't a wall of smoke.
const PARTICLES_PER_SQ_M := 1.1
const PARTICLE_CAP := 420

var _radius := 0.0
var _duration := 0.0
var _elapsed := 0.0
var _glow_mat: StandardMaterial3D

## `dps` is the tunable; the profile's per-tick damage is derived from it.
## Returns the zone so a caller can inspect it; it frees itself on expiry.
static func spawn(parent: Node, centre: Vector3, radius: float,
		duration: float, dps: float, tick_interval: float) -> WhitePhosphorusZone:
	var z := WhitePhosphorusZone.new()
	z.name = "WPZone"
	parent.add_child(z)
	z.global_position = centre
	z._begin(radius, duration, dps, tick_interval)
	return z

func _begin(radius: float, duration: float, dps: float, tick_interval: float) -> void:
	_radius = maxf(0.5, radius)
	_duration = maxf(0.1, duration)
	_build_glow()
	_build_particles()

	var profile := _build_profile(dps, tick_interval)
	# duration > 0 sends this down AreaDamageSystem's DoT path: it applies the
	# profile every tick_interval for `duration`, re-querying the damageable
	# group each time, so anything that WALKS IN partway through is burned.
	# Faction-blind like everything else in that system — the player takes it
	# identically, which is the entire point of a denial area.
	AreaDamageSystem.detonate(global_position, profile, Vector3.ZERO, "wp")
	print("[WP] burn zone at (%.1f, %.1f, %.1f) — %.1fm, %.1fs, %.1f dps" % [
		global_position.x, global_position.y, global_position.z,
		_radius, _duration, dps])

## Built rather than authored — see the class docstring.
func _build_profile(dps: float, tick_interval: float) -> AreaDamageProfile:
	var p := AreaDamageProfile.new()
	p.id = "wp_burn"
	p.display_name = "White Phosphorus"
	# Flat damage across the whole zone, not a falloff curve: this is a
	# denial area with a hard edge, not a blast. lethal_radius == max_radius
	# means damage_at() returns full damage everywhere inside and exactly
	# zero outside, so the visible circle IS the damage boundary.
	p.lethal_radius = _radius
	p.max_radius = _radius
	p.arc_degrees = 360.0

	var tick: float = maxf(0.05, tick_interval)
	# max_damage is an int, so dps is quantised by the tick rate. 25 dps at a
	# 0.2s tick is exactly 5/tick; at the old 0.5s default it would have been
	# 12.5, which is not representable — hence the smaller default tick.
	p.max_damage = maxi(1, int(round(dps * tick)))
	p.duration = _duration
	p.tick_interval = tick
	var actual: float = float(p.max_damage) / tick
	if absf(actual - dps) > 0.5:
		push_warning("[WP] %.1f dps requested but tick %.2fs quantises to %.1f dps (%d/tick). Adjust wp_tick_interval." % [
			dps, tick, actual, p.max_damage])

	# Burning ground does not blow up sandbags — the HE portion already did
	# whatever demolition this mission is going to do.
	p.damages_obstacles = false
	# Cover does NOT protect you from standing in a fire. Unlike a blast,
	# there is nothing here for line of sight to block: the damage is the
	# ground you are standing on.
	p.blocked_damage_mult = 1.0
	# Silent to the AI. The six HE impacts already pulled every zombie in
	# earshot; a burn zone that re-emitted noise for 45 seconds would be a
	# permanent lure rather than a denial area.
	p.noise_radius = 0.0
	return p

# --- Visuals -----------------------------------------------------------------
## Flat ground disc, same geometry primitive the paint marker and the claymore
## wedge use, so "what a radius means" is one implementation project-wide.
func _build_glow() -> void:
	var pts := AreaMath.arc_fan_points(360.0, _radius, GLOW_SEGMENTS)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(1, pts.size() - 1):
		im.surface_add_vertex(pts[0])
		im.surface_add_vertex(pts[i])
		im.surface_add_vertex(pts[i + 1])
	im.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.position.y = GROUND_OFFSET
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_glow_mat = StandardMaterial3D.new()
	_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_glow_mat.albedo_color = COLOR_GLOW
	mi.material_override = _glow_mat
	add_child(mi)

## Two layers: dense low white smoke, and sparser bright embers rising out of
## it. The embers are what make the zone readable from outside its own radius
## at night — a ground glow alone is invisible edge-on.
func _build_particles() -> void:
	var area: float = PI * _radius * _radius
	var count: int = clampi(int(area * PARTICLES_PER_SQ_M), 24, PARTICLE_CAP)

	add_child(_make_particles(count, Color(0.92, 0.92, 0.90, 0.5),
		0.55, 2.6, 3.4, Vector2(0.9, 1.6), _radius * 0.95))
	add_child(_make_particles(int(count * 0.45), Color(1.0, 0.75, 0.3, 0.95),
		0.16, 4.5, 1.7, Vector2(0.3, 0.6), _radius * 0.9))

func _make_particles(count: int, color: Color, size: float, rise: float,
		lifetime: float, scale_range: Vector2, spread_radius: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = maxi(1, count)
	p.lifetime = lifetime
	p.preprocess = lifetime   # already burning when it appears, not ramping up
	p.local_coords = false

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	mat.emission_sphere_radius = spread_radius
	mat.direction = Vector3.UP
	mat.spread = 18.0
	mat.initial_velocity_min = rise * 0.5
	mat.initial_velocity_max = rise
	mat.gravity = Vector3(0.0, 0.25, 0.0)   # buoyant, not falling
	mat.scale_min = scale_range.x
	mat.scale_max = scale_range.y
	p.process_material = mat

	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.albedo_color = color
	quad.material = qm
	p.draw_pass_1 = quad
	return p

func _process(delta: float) -> void:
	_elapsed += delta
	if _glow_mat:
		# Subtle pulse so it reads as burning rather than as a painted decal.
		var pulse: float = 1.0 + sin(_elapsed * PULSE_HZ * TAU) * PULSE_DEPTH
		_glow_mat.albedo_color = Color(COLOR_GLOW.r, COLOR_GLOW.g, COLOR_GLOW.b,
			COLOR_GLOW.a * pulse)
	if _elapsed >= _duration:
		# The DoT ticker in AreaDamageSystem runs on its own copy of the same
		# duration and stops itself; this only tears down the visual.
		queue_free()
