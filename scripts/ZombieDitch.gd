extends Obstacle
class_name ZombieDitch
## A real pit. Permanent and indestructible.
##
## Previous version: a decorative sunken box with above-ground "revetment"
## walls on a non-navmesh layer. Its collision was invisible to the navmesh
## (correct), but it was ALSO invisible to the zombie's actual path — the
## walls just weren't where a zombie ever expected to walk, so nothing about
## the design routed a zombie INTO the pit. Reported result: zombies stuck to
## the wall edge instead of falling in.
##
## This version is a literal hole:
## - The ground gets a REAL gap punched in its collision at the pit's footprint
##   (Main.punch_ground_hole / _ground_holes) — nothing physically supports a
##   body there any more.
## - A second, physics-free NavigationRegion3D (Main._mouth_region) gets a
##   thin, invisible MeshInstance3D patch over exactly the same footprint, so
##   the BAKED navmesh still shows flat, walkable ground there — permanently,
##   across every future rebake, because nothing about it depends on a live
##   collider. Godot's navmesh and physics systems are independent: a zombie's
##   PATH can say "flat ground here" while its PHYSICS BODY falls through,
##   because pathing never consults collision to decide walkability.
## - The pit itself (walls + floor + ramp) is real collision on
##   SOLID_NO_NAV_LAYER — solid to both actors, invisible to the navmesh, same
##   layer the old revetment used.
## - An Area3D over the mouth transitions any zombie that enters into the new
##   FALLEN state (Zombie.gd) — a one-way trapdoor, never left.
##
## Ramp: always at the LOCAL -X end (fixed, not auto-oriented toward the
## base) — rotate the ghost before placing so the ramp faces where you want
## it. Auto-detecting "the base-facing end" would need a world-space heuristic
## that's fragile for an arbitrarily-placed, arbitrarily-rotated obstacle;
## giving the player direct control via the existing rotation control is
## simpler and more reliable. Flagged in PROJECT_SPEC.md in case a fixed
## orientation was actually wanted.

const WALL_THICKNESS := 0.3
const RAMP_THICKNESS := 0.3
const MAX_RAMP_RUN := 4.0     # metres of the pit's length the ramp is allowed to eat
const MAX_RAMP_SLOPE_DEG := 40.0   # stays under CharacterBody3D's 45 deg default
## Fall-landing noise and the FALLEN shuffle are entirely Zombie.gd's concern
## (Zombie._do_fallen()) — nothing here duplicates those constants.

var _length: float
var _depth: float
var _width: float
var _ramp_run: float

var _trigger: Area3D
var _finalized := false

func setup(t) -> void:
	super.setup(t)   # calls _build_visual() (overridden below) + _build_footprint()
	add_to_group("ditches")
	_build_trigger()

## Overrides Obstacle's generic single-box visual entirely: a pit needs real
## geometry (walls, floor, ramp), not a decorative sunken box.
func _build_visual() -> void:
	var size: Vector3 = obstacle_type.size   # x=length, y=depth, z=width
	_length = size.x
	_depth = size.y
	_width = size.z
	# Ramp run is whatever keeps the slope at or under MAX_RAMP_SLOPE_DEG,
	# capped so it can't eat more than MAX_RAMP_RUN or half the pit's length.
	var slope_run: float = _depth / tan(deg_to_rad(MAX_RAMP_SLOPE_DEG))
	_ramp_run = minf(minf(slope_run, MAX_RAMP_RUN), _length * 0.5)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = obstacle_type.color

	_build_floor(mat)
	_build_side_walls(mat)
	_build_end_wall(mat)     # only at the +X end — -X is the open ramp end
	_build_ramp(mat)

## Flat floor spanning the pit minus the ramp's run. The floor occupies local
## x in [-L/2 + ramp_run, +L/2], so its centre is at ramp_run/2.
func _build_floor(mat: StandardMaterial3D) -> void:
	var floor_len: float = _length - _ramp_run
	var floor_x: float = _ramp_run * 0.5
	_add_pit_piece(Vector3(floor_len, WALL_THICKNESS, _width),
		Vector3(floor_x, -_depth - WALL_THICKNESS * 0.5, 0.0), Vector3.ZERO, mat)

## Two vertical walls running the FULL length (including alongside the ramp,
## like a sunken ramp cut between retaining walls) so nothing can slide out
## the sides while climbing.
func _build_side_walls(mat: StandardMaterial3D) -> void:
	var half_w: float = _width * 0.5 + WALL_THICKNESS * 0.5
	for side in [-1.0, 1.0]:
		_add_pit_piece(Vector3(_length, _depth, WALL_THICKNESS),
			Vector3(0.0, -_depth * 0.5, side * half_w), Vector3.ZERO, mat)

## One end wall at the closed (+X) end. The -X end is deliberately open — the
## ramp is the only way in or out there.
func _build_end_wall(mat: StandardMaterial3D) -> void:
	_add_pit_piece(Vector3(WALL_THICKNESS, _depth, _width),
		Vector3(_length * 0.5 + WALL_THICKNESS * 0.5, -_depth * 0.5, 0.0), Vector3.ZERO, mat)

## A single sloped slab from ground level (at the pit's -X edge) down to the
## floor (at -X + ramp_run). Right-triangle geometry: run = _ramp_run,
## rise = _depth, so the slab's length is the hypotenuse and its tilt angle
## is atan(_depth / _ramp_run) around the local Z axis.
func _build_ramp(mat: StandardMaterial3D) -> void:
	var slab_len: float = sqrt(_ramp_run * _ramp_run + _depth * _depth)
	var angle := atan2(-_depth, _ramp_run)   # rotation.z aligning +X with the slope
	var top := Vector3(-_length * 0.5, 0.0, 0.0)
	var dir := Vector3(_ramp_run, -_depth, 0.0).normalized()
	var center: Vector3 = top + dir * (slab_len * 0.5)
	_add_pit_piece(Vector3(slab_len, RAMP_THICKNESS, _width), center,
		Vector3(0.0, 0.0, angle), mat)

## One StaticBody3D + mesh + collision, on SOLID_NO_NAV_LAYER: solid to both
## actors, invisible to the navmesh (which only parses layer 1) — same layer
## the old revetment used, so the pit's own walls/floor/ramp never appear as
## navmesh geometry, matching "the pit interior has no navmesh at all".
func _add_pit_piece(size: Vector3, pos: Vector3, rot: Vector3, mat: StandardMaterial3D) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = Obstacle.SOLID_NO_NAV_LAYER
	body.collision_mask = 0
	body.position = pos
	body.rotation = rot

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = mat
	body.add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)

	add_child(body)

## Area3D over the mouth, inset from the edges so the trigger doesn't fire on
## a body just grazing the rim. Spans from just above ground down through the
## full pit depth so it catches anything falling anywhere in that column.
func _build_trigger() -> void:
	_trigger = Area3D.new()
	_trigger.collision_layer = 0
	_trigger.collision_mask = 1
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(_length * 0.85, _depth + 1.0, _width * 0.85)
	col.shape = shape
	col.position.y = -_depth * 0.5 + 0.25
	_trigger.add_child(col)
	_trigger.body_entered.connect(_on_entered)
	add_child(_trigger)

func _on_entered(body: Node3D) -> void:
	if not body.is_in_group("zombies"):
		return   # the player just falls in and uses the ramp — see item 5
	if body.has_method("enter_fallen"):
		body.enter_fallen(self)

## Called once global_position/rotation.y are final (BuildMode after a fresh
## placement, or BuildMode.adopt() after a GameState restore) — the ground
## hole and navmesh mouth patch both live in WORLD space, which isn't known
## yet at setup()/_build_visual() time.
func finalize_in_world(world) -> void:
	if _finalized or world == null:
		return
	_finalized = true
	var corners := footprint_corners()
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for c in corners:
		min_x = minf(min_x, c.x)
		max_x = maxf(max_x, c.x)
		min_z = minf(min_z, c.z)
		max_z = maxf(max_z, c.z)
	# The axis-aligned bounding box of the (possibly rotated) footprint. At a
	# non-cardinal rotation this is conservatively larger than the visible
	# pit at its corners — a known approximation, tune later if a rotated
	# ditch reads as having "extra" invisible hole at the corners.
	var rect := Rect2(min_x, min_z, max_x - min_x, max_z - min_z)
	if world.has_method("register_ditch_mouth"):
		world.register_ditch_mouth(rect)
