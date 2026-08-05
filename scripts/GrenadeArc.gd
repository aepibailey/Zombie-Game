extends MeshInstance3D
class_name GrenadeArc
## Throw-trajectory preview for the hand grenade.
##
## WHAT IT IS: a trained soldier's instinct for where the thing will land. It
## INFORMS, it does not GUARANTEE. It draws the flight path up to the first
## surface the grenade would strike and stops there — it deliberately does not
## predict the bounce or the roll that follow, and it draws no impact marker or
## blast ring. Where it ends is where the grenade first touches, not where it
## comes to rest; reading the difference is the player's job.
##
## FIDELITY: the simulation below is not a lookalike. It reads its origin and
## initial velocity from Player.grenade_launch_origin()/grenade_launch_velocity()
## — the exact functions Player._throw_grenade() uses — its gravity from
## Grenade.projectile_gravity(), and it raycasts on Grenade.COLLISION_MASK. The
## projectile carries zero linear damping specifically so this plain ballistic
## integration stays exact (see Grenade._ready()).

## Drawn samples along the curve. 40 of them, each SUBSTEPS physics ticks
## apart, covers ~2.7s of flight — well past the point any throw on a 60x60m
## map has hit something.
const STEPS := 40
## Physics ticks per drawn sample.
##
## THE INTEGRATION RUNS AT THE PHYSICS RATE, not at the sample rate, and this
## is not fussiness. Godot integrates a RigidBody with semi-implicit Euler,
## whose drop is g*(t^2 + t*dt)/2 — the error term scales with the timestep.
## Integrating straight from sample to sample at ~0.067s instead of the
## engine's ~0.0167s adds an extra g*t*(dt_sample - dt_physics)/2 of droop:
## roughly 0.8m low after 1.5s of flight at gravity 24. The arc would have
## quietly pointed a metre short of where the grenade actually lands, which
## is exactly the kind of lie this preview must not tell.
const SUBSTEPS := 4

## Ribbon half-width in metres. Drawn as a camera-facing strip rather than a
## PRIMITIVE_LINE_STRIP because Godot 4 renders 3D lines at a fixed 1px, which
## is too thin to read against noisy greybox terrain at range.
const HALF_WIDTH := 0.018

## Deliberately dim, and deliberately NOT emissive or additive.
##
## The NVG night path is a green ColorRect over the scene with NO glow pass
## (Main._apply_gain_limit() only enables glow during the DAY gain-limit
## whiteout), so nothing here can bloom at night by construction. The real
## night risk is a bright unshaded line washing out a dark scene, which is
## what the low alpha and sub-1.0 albedo below are for. Keeping albedo under
## 1.0 also holds the ribbon below the HDR glow threshold, so it stays calm
## even if glow is ever enabled at night later.
const COLOR := Color(0.62, 0.85, 0.62)
## Per-vertex alpha runs from NEAR (at the hand) to FAR (at impact): a short
## throw reads as confident, a long one trails off into uncertainty.
const ALPHA_NEAR := 0.85
const ALPHA_FAR := 0.10
## Global dimmer on top of the fade. This is the knob that makes it "dim".
const OPACITY := 0.55

var _player: Player
var _cam: Camera3D
var _mesh: ImmediateMesh

func setup(player: Player, cam: Camera3D) -> void:
	_player = player
	_cam = cam

func _ready() -> void:
	# World-space vertices: the ribbon is rebuilt each frame in absolute
	# coordinates, so it must not inherit the player's transform.
	top_level = true
	global_transform = Transform3D.IDENTITY
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh = ImmediateMesh.new()
	mesh = _mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Per-vertex alpha is the whole point of the fade.
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Occluded by geometry like anything else — an arc drawn through a wall
	# would be lying about line of sight.
	mat.no_depth_test = false
	mat.disable_receive_shadows = true
	material_override = mat
	visible = false

func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		visible = false
		return
	# Only ever visible with a grenade actually in hand, and only when the
	# player hasn't switched the preview off for a playtest.
	if not (_player.grenade_arc_enabled and _player.grenade_equipped):
		if visible:
			visible = false
			_mesh.clear_surfaces()
		return
	visible = true
	_rebuild()

func _rebuild() -> void:
	# Which curve to draw comes from which button is held RIGHT NOW, so the
	# shape changes the instant the player switches between the overhand throw
	# and the underhand lob. With neither held, the overhand default.
	var points := _simulate(_player.grenade_preview_underhand())
	_mesh.clear_surfaces()
	if points.size() < 2:
		return

	var cam_pos: Vector3 = _cam.global_position if _cam else _player.global_position
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in points.size():
		var p: Vector3 = points[i]
		# Tangent along the curve, using whichever neighbour exists.
		var tangent: Vector3
		if i == 0:
			tangent = points[1] - p
		elif i == points.size() - 1:
			tangent = p - points[i - 1]
		else:
			tangent = points[i + 1] - points[i - 1]
		# Widen perpendicular to both the curve and the view, so the ribbon
		# always presents face-on instead of collapsing to a line edge-on.
		var to_cam := (cam_pos - p).normalized()
		var side := tangent.normalized().cross(to_cam)
		if side.length_squared() < 0.000001:
			side = Vector3.UP   # degenerate: looking straight down the curve
		side = side.normalized() * HALF_WIDTH

		var t: float = float(i) / float(points.size() - 1)
		var a: float = lerpf(ALPHA_NEAR, ALPHA_FAR, t) * OPACITY
		var c := Color(COLOR.r, COLOR.g, COLOR.b, a)
		_mesh.surface_set_color(c)
		_mesh.surface_add_vertex(p - side)
		_mesh.surface_set_color(c)
		_mesh.surface_add_vertex(p + side)
	_mesh.surface_end()

## Steps the throw forward and returns the path up to (and including) the
## first impact point.
##
## Semi-implicit Euler at the engine's own tick rate (velocity first, then
## position), which is precisely what Godot does to a RigidBody. Together with
## the projectile's zero linear damping, that makes this a reproduction of the
## real flight rather than a lookalike.
func _simulate(underhand: bool) -> PackedVector3Array:
	var out := PackedVector3Array()
	var pos: Vector3 = _player.grenade_launch_origin()
	var vel: Vector3 = _player.grenade_launch_velocity(underhand)
	var g: float = Grenade.projectile_gravity()
	var dt: float = 1.0 / float(maxi(1, Engine.physics_ticks_per_second))
	out.append(pos)

	var space := get_world_3d().direct_space_state
	# The thrower is excluded for the same reason the real grenade adds a
	# collision exception: you cannot block your own throw at the muzzle.
	var exclude: Array[RID] = [_player.get_rid()]

	for _sample in STEPS:
		for _sub in SUBSTEPS:
			vel.y -= g * dt
			var next: Vector3 = pos + vel * dt
			# Raycast every SUB-STEP, not just between drawn samples: a fast
			# throw crosses a metre per sample and would otherwise step
			# straight through a sandbag between two of them.
			var q := PhysicsRayQueryParameters3D.create(pos, next)
			q.collision_mask = Grenade.COLLISION_MASK
			q.collide_with_areas = false
			q.exclude = exclude
			var hit := space.intersect_ray(q)
			if hit:
				# Terminate AT the impact. No bounce, no roll, no marker — the
				# real grenade carries on past here and the player is expected
				# to account for that.
				out.append(hit.position)
				return out
			pos = next
		out.append(pos)
	return out
