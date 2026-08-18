extends Node3D
class_name Claymore
## An emplaced M18A1 claymore: a directional, autonomous proximity mine.
##
## Instantiated into the WORLD, never parented to the player — once emplaced
## it is a fixture like an obstacle, and the player walking away or dying does
## not move or free it.
##
## Deliberately NOT an Obstacle subclass. Obstacle carries ObstacleCatalog
## pricing, a placement footprint on layer 4, and BuildMode's placement cap —
## none of which apply to a store-bought item emplaced from the equip state.
## Same reasoning that keeps SandbagPanel out of that hierarchy.
##
## PERSISTENCE IS FREE: night transitions are phase changes on a live scene,
## never a reload, so an emplaced claymore survives dawn by simply not being
## freed. There is no save step here, matching how placed obstacles already
## persist.
##
## It owns no damage code — see Claymore.detonate() in the detection pass.

## Front plate faces local -Z, matching Node3D's forward convention, so
## `facing()` and the AreaMath arc (which treats +Z as facing on its own fan
## geometry, oriented by the wedge child's own rotation) stay consistent.
const GROUP := "claymores"

## Greybox dimensions — a small curved front plate on two wire legs.
const BODY_SIZE := Vector3(0.30, 0.14, 0.05)
const LEG_HEIGHT := 0.12
const LEG_OFFSET := 0.10

## Front face colour, so "which way is it pointing" is readable at a glance
## without reading the wedge. The back is deliberately drab.
const COLOR_FRONT := Color(0.72, 0.26, 0.18)
const COLOR_BODY := Color(0.24, 0.26, 0.22)
## Ground wedge tint while emplaced — dim, and the same discipline as the
## grenade arc: alpha-blended, never additive.
const WEDGE_COLOR := Color(0.85, 0.35, 0.25, 0.10)

## Height the blast originates from and the detection ray is cast from — the
## middle of the body, not the ground, so neither is clipped by the surface
## the mine is standing on.
const EMIT_HEIGHT := 0.19

## Arming indicator: blinks while arming, steady and dim once live.
const INDICATOR_RADIUS := 0.022
const INDICATOR_BLINK_HZ := 4.0
const COLOR_ARMING := Color(1.0, 0.65, 0.1)
const COLOR_ARMED := Color(0.3, 1.0, 0.4)

var config: ClaymoreConfig

var _wedge: ArcWedge
var _player: Node3D
var _interact_area: Area3D

# --- Runtime state ---------------------------------------------------------
var _arm_remaining := 0.0
var _armed := false
## Committed: once the trigger delay starts it runs to detonation whether or
## not the zombie that tripped it is still in the arc.
var _triggered := false
var _trigger_remaining := 0.0
var _detonated := false
## Accumulates to config.detection_interval — the sweep is NOT per-frame.
var _detect_accum := 0.0

var _indicator: MeshInstance3D
var _indicator_mat: StandardMaterial3D
var _blink := 0.0

func setup(cfg: ClaymoreConfig) -> void:
	config = cfg
	_validate_config()
	add_to_group(GROUP)
	_build_visual()
	_build_indicator()
	_build_wedge()
	_build_interact_collider()
	_arm_remaining = config.arming_delay
	_armed = false

## The direction the front plate points, flattened to the ground plane. This
## is what gets handed to AreaDamageSystem.detonate() as `facing`, and what
## the detection arc is measured against.
func facing() -> Vector3:
	var f := -global_transform.basis.z
	f.y = 0.0
	return f.normalized()

## INVARIANT: the detection wedge and the damage wedge must describe the SAME
## volume. They are configured in two different resources — detection here,
## damage on the AreaDamageProfile — because this project keeps blast geometry
## in exactly one kind of resource. That split is only safe if the two agree,
## and a silent disagreement would be brutal to diagnose from play: zombies
## would trip a mine that then failed to damage them, or die to a mine that
## never should have seen them.
func _validate_config() -> void:
	if config == null:
		push_error("[CLAYMORE] setup() with a null config")
		return
	var p := config.damage_profile
	if p == null:
		push_error("[CLAYMORE] config has no damage_profile")
		return
	assert(is_equal_approx(config.detection_range, p.max_radius),
		"CLAYMORE CONFIG MISMATCH: detection_range %.2f but damage max_radius %.2f — the mine would trigger and damage over different distances." % [config.detection_range, p.max_radius])
	assert(is_equal_approx(config.detection_arc_degrees, p.arc_degrees),
		"CLAYMORE CONFIG MISMATCH: detection_arc %.1f but damage arc %.1f — the mine would trigger and damage over different arcs." % [config.detection_arc_degrees, p.arc_degrees])
	# Asserts are stripped from release builds; fail loudly there too.
	if not is_equal_approx(config.detection_range, p.max_radius) \
			or not is_equal_approx(config.detection_arc_degrees, p.arc_degrees):
		push_error("[CLAYMORE] detection geometry does not match damage geometry — see ClaymoreConfig.")

# --- Visual ----------------------------------------------------------------
## Builds the greybox body. Static so the placement ghost can render the exact
## same silhouette without instancing a live claymore — a ghost that looked
## different from the thing it previews would be its own small lie.
static func build_body(front_color: Color, body_color: Color,
		alpha: float = 1.0) -> Node3D:
	var root := Node3D.new()

	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = BODY_SIZE
	body.mesh = box
	body.position.y = LEG_HEIGHT + BODY_SIZE.y * 0.5
	body.material_override = _flat_mat(body_color, alpha)
	root.add_child(body)

	# Front plate: a thin slab on the -Z face, so which way it points reads
	# instantly from any angle.
	var front := MeshInstance3D.new()
	var fbox := BoxMesh.new()
	fbox.size = Vector3(BODY_SIZE.x * 0.94, BODY_SIZE.y * 0.8, 0.015)
	front.mesh = fbox
	front.position = Vector3(0.0, LEG_HEIGHT + BODY_SIZE.y * 0.5,
		-BODY_SIZE.z * 0.5 - 0.008)
	front.material_override = _flat_mat(front_color, alpha)
	root.add_child(front)

	for side in [-1.0, 1.0]:
		var leg := MeshInstance3D.new()
		var lbox := BoxMesh.new()
		lbox.size = Vector3(0.012, LEG_HEIGHT, 0.012)
		leg.mesh = lbox
		leg.position = Vector3(side * LEG_OFFSET, LEG_HEIGHT * 0.5, 0.0)
		leg.material_override = _flat_mat(body_color, alpha)
		root.add_child(leg)

	return root

static func _flat_mat(c: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _build_visual() -> void:
	add_child(build_body(COLOR_FRONT, COLOR_BODY))

## A ray-detectable-only Area3D (monitoring off — this is never used for
## overlap signals, only so Player's look-at raycast can hit something
## precise). Sized a little larger than the visual body: the greybox plate is
## tiny, and a hitbox that exactly matched it would make "look at it" fussier
## than the interaction deserves. Tagged with a meta key rather than relying
## on get_parent(), so the ray-hit resolution is a single dictionary lookup
## regardless of how this node's own hierarchy is built.
func _build_interact_collider() -> void:
	_interact_area = Area3D.new()
	_interact_area.collision_layer = Obstacle.INTERACT_LAYER
	_interact_area.collision_mask = 0
	_interact_area.monitoring = false
	_interact_area.monitorable = false
	_interact_area.set_meta("claymore", self)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = BODY_SIZE * 2.2
	shape.shape = box
	shape.position.y = LEG_HEIGHT + BODY_SIZE.y * 0.5
	_interact_area.add_child(shape)
	add_child(_interact_area)

## Small emissive dot on top of the body. Blinks amber while arming, then goes
## steady green — so "is this thing live yet" is readable from across the base
## without a HUD element or a sound.
func _build_indicator() -> void:
	_indicator = MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = INDICATOR_RADIUS
	s.height = INDICATOR_RADIUS * 2.0
	s.radial_segments = 8
	s.rings = 4
	_indicator.mesh = s
	_indicator.position = Vector3(0.0, LEG_HEIGHT + BODY_SIZE.y + INDICATOR_RADIUS, 0.0)
	_indicator_mat = StandardMaterial3D.new()
	_indicator_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_indicator_mat.albedo_color = COLOR_ARMING
	_indicator.material_override = _indicator_mat
	_indicator.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_indicator)

func _set_indicator_color(c: Color) -> void:
	if _indicator_mat:
		_indicator_mat.albedo_color = c

## Blink only while arming. Once live it holds steady — a mine that kept
## flashing all night would be a beacon, and the state it needs to communicate
## ("not yet dangerous") is over.
func _update_indicator(delta: float) -> void:
	if _indicator == null or _armed or _detonated:
		return
	_blink += delta * INDICATOR_BLINK_HZ
	_indicator.visible = fmod(_blink, 1.0) < 0.5

## The emplaced ground wedge is behind config.show_emplaced_arc, and only
## drawn when the player is close, so a base with a dozen mines doesn't turn
## the night view into a light show. The PLACEMENT wedge is not behind this —
## see ClaymorePlacer.
func _build_wedge() -> void:
	if not config.show_emplaced_arc:
		return
	_wedge = ArcWedge.new()
	add_child(_wedge)
	# The fan is built with +Z as facing; the plate points -Z, so the wedge is
	# turned to match rather than the geometry being rebuilt mirrored.
	_wedge.rotation.y = PI
	_wedge.setup(config.detection_arc_degrees, config.detection_range, WEDGE_COLOR)
	_wedge.visible = false

func _process(delta: float) -> void:
	_update_indicator(delta)
	if _wedge == null:
		return
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return
	_wedge.visible = global_position.distance_to(_player.global_position) \
		<= config.emplaced_arc_visible_range

# --- Arming, detection, detonation ----------------------------------------
func _physics_process(delta: float) -> void:
	if _detonated or config == null:
		return

	# ARMING. Nothing below runs until this elapses, so the mine genuinely
	# cannot detonate for any reason during the window — not by proximity,
	# not by a trigger already in flight, because neither can have started.
	if not _armed:
		_arm_remaining -= delta
		if _arm_remaining > 0.0:
			return
		_armed = true
		_set_indicator_color(COLOR_ARMED)
		if _indicator:
			_indicator.visible = true   # end the blink on-state, not mid-flash

	# Committed trigger: runs to detonation regardless of whether whatever
	# tripped it is still there. That is the point of the delay — a cluster
	# walking in together gets caught, not just whoever crossed the line.
	if _triggered:
		_trigger_remaining -= delta
		if _trigger_remaining <= 0.0:
			_detonate()
		return

	# Detection sweep on an interval, not per frame.
	_detect_accum += delta
	if _detect_accum < config.detection_interval:
		return
	_detect_accum = 0.0
	if _scan():
		_triggered = true
		_trigger_remaining = config.trigger_delay

## Returns true the moment ANY zombie passes all three tests. Ordered
## cheapest-first and returns on the first hit, so the raycast — the only
## expensive part — runs rarely and never more than once per candidate.
##
## THE PLAYER IS NOT CONSIDERED. Only the "zombies" group is scanned, so no
## amount of standing in front of your own claymore trips it. The player can
## still be killed by one, but only ever by something else setting it off.
func _scan() -> bool:
	var origin := global_position + Vector3(0.0, EMIT_HEIGHT, 0.0)
	var face := facing()
	var range_sq: float = config.detection_range * config.detection_range
	var zombies := get_tree().get_nodes_in_group("zombies")

	# Built once per sweep, not per candidate: zombies must not shield each
	# other from detection, matching the blast's own rule that only real
	# geometry provides cover.
	var zombie_rids: Array[RID] = []
	for z in zombies:
		if z is CollisionObject3D:
			zombie_rids.append((z as CollisionObject3D).get_rid())

	var space := get_world_3d().direct_space_state
	for node in zombies:
		var z := node as Node3D
		if z == null or not is_instance_valid(z):
			continue
		if z.has_method("is_alive") and not z.is_alive():
			continue   # a corpse this frame is not a target
		# 1. Distance — squared, no sqrt.
		if origin.distance_squared_to(z.global_position) > range_sq:
			continue
		# 2. Height band. A leaper at the apex of its 5m jump is far above
		#    this and passes over untriggered; the same leaper standing in the
		#    arc is caught. Uses the zombie's origin, which sits at its feet.
		if not AreaMath.in_height_band(global_position.y, z.global_position.y,
				config.detection_height):
			continue
		# 3. Arc — same function the blast uses, so trigger and damage can
		#    never disagree about the wedge.
		if not AreaMath.in_horizontal_arc(origin, face, z.global_position,
				config.detection_arc_degrees):
			continue
		# 4. Line of sight. Last because it is the only expensive test.
		if _has_los(space, origin, z, zombie_rids):
			return true
	return false

## Sandbags, structures and terrain block detection; C-wire does not. That is
## exactly AreaDamageSystem's COVER_MASK, referenced rather than re-derived —
## a mine that can SEE further than its blast can REACH would trigger on
## targets it then fails to damage.
func _has_los(space: PhysicsDirectSpaceState3D, origin: Vector3,
		z: Node3D, zombie_rids: Array[RID]) -> bool:
	var target: Vector3 = z.global_position + Vector3(0.0, 0.7, 0.0)
	if z.has_method("area_damage_points"):
		var pts: Array = z.area_damage_points()
		if pts.size() >= 2:
			target = pts[1]   # centre of mass, sized to this variant
	var q := PhysicsRayQueryParameters3D.create(origin, target)
	q.collision_mask = AreaDamageSystem.COVER_MASK
	q.collide_with_areas = false
	q.exclude = zombie_rids
	return space.intersect_ray(q).is_empty()

## Single use. Hands the shared system an origin and a facing vector and owns
## no damage logic of its own — the arc, the falloff curve, the cover test,
## the faction-blind targeting and the "does not touch obstacles" opt-out are
## all in claymore_blast.tres.
func _detonate() -> void:
	if _detonated:
		return
	_detonated = true
	var origin := global_position + Vector3(0.0, EMIT_HEIGHT, 0.0)
	var face := facing()
	_spawn_burst(origin, face)
	AreaDamageSystem.detonate(origin, config.damage_profile, face, "claymore")
	queue_free()

## Placeholder directional VFX: a one-shot cone of particles along the facing
## vector. Detached from this node and self-freeing, because the claymore is
## queue_free()'d in the same breath — same pattern as
## AreaDamageSystem._play_detonation() and Zombie._play_death_sound().
func _spawn_burst(origin: Vector3, face: Vector3) -> void:
	var p := GPUParticles3D.new()
	p.amount = 48
	p.lifetime = 0.45
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = true

	var mat := ParticleProcessMaterial.new()
	mat.direction = face
	mat.spread = config.detection_arc_degrees * 0.5
	mat.initial_velocity_min = 14.0
	mat.initial_velocity_max = 26.0
	mat.gravity = Vector3(0.0, -6.0, 0.0)
	mat.scale_min = 0.4
	mat.scale_max = 1.0
	p.process_material = mat

	var quad := QuadMesh.new()
	quad.size = Vector2(0.06, 0.06)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.albedo_color = Color(1.0, 0.85, 0.5)
	quad.material = qm
	p.draw_pass_1 = quad

	get_tree().current_scene.add_child(p)
	p.global_position = origin
	p.finished.connect(p.queue_free)

# --- Placement validity ----------------------------------------------------
# --- Recovery --------------------------------------------------------------
## Can this claymore be picked back up right now?
##
## REVISED (playtest fix pass): this used to also refuse a TRIGGERED mine, on
## the reasoning that "walk up and defuse a mine that's already fired" wasn't
## a mechanic worth having even by accident. That's been explicitly
## overridden — recovery is now required to be able to cancel a pending
## detonation, and it does so for free: completing recovery queue_free()'s
## this node, which halts _physics_process before _detonate() can run.
##
## In practice this rarely matters: trigger_delay (0.15s) is far shorter than
## the recovery hold (0.5s), so a mine can only be triggered AND recovered
## before it goes off if it triggers in roughly the last third of an already
## in-progress hold. Otherwise the mine wins the race and detonates — and if
## the player is in the blast, that's the same friendly-fire outcome any
## other bystander gets, nothing special-cased here.
##
## Arming state is still not a barrier: a mine you just put down in the wrong
## place is exactly the one you want back. Only a fully DETONATED (already
## freed in spirit, about to be freed in fact) mine refuses — there's nothing
## left to recover.
func can_recover() -> bool:
	return not _detonated

## Is `pos` far enough from every claymore already emplaced? Static because
## the placement ghost needs to answer this before any claymore exists there.
static func separation_clear(tree: SceneTree, pos: Vector3, min_sep: float) -> bool:
	for c in tree.get_nodes_in_group(GROUP):
		var n := c as Node3D
		if n == null or not is_instance_valid(n):
			continue
		if n.global_position.distance_to(pos) < min_sep:
			return false
	return true
