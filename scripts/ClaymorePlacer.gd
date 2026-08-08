extends Node3D
class_name ClaymorePlacer
## Placement ghost for the claymore: where it would go, which way it would
## face, the arc it would cover, and whether that spot is legal.
##
## Owned by the Player but drawn in WORLD space (top_level), because the ghost
## previews a fixture that will not be parented to the player once committed.
##
## The ghost renders the SAME silhouette as a real claymore via
## Claymore.build_body(), and the SAME arc wedge via ArcWedge — a preview that
## looked different from the thing it previews would be a small lie in exactly
## the place the player is making a decision.

## Tints. Green/red rather than a subtle shade: this is a yes/no answer.
const COLOR_VALID_FRONT := Color(0.35, 1.0, 0.45)
const COLOR_VALID_BODY := Color(0.25, 0.75, 0.35)
const COLOR_INVALID_FRONT := Color(1.0, 0.35, 0.30)
const COLOR_INVALID_BODY := Color(0.8, 0.25, 0.22)
const GHOST_ALPHA := 0.5
## The placement wedge is brighter than the emplaced one — it is the thing
## being decided right now, not ambient information.
const WEDGE_VALID := Color(0.35, 1.0, 0.45, 0.16)
const WEDGE_INVALID := Color(1.0, 0.35, 0.30, 0.16)

## How far past placement_max_range to trace before giving up on finding a
## surface. The hit is clamped back to range afterwards; this only decides how
## far we bother looking.
const AIM_TRACE_LENGTH := 8.0
## Vertical probe used when the aim ray misses (or overshoots the clamp) and
## we have to find the ground under a clamped-forward point instead.
const DROP_PROBE_UP := 2.0
const DROP_PROBE_DOWN := 4.0
## Matches Zombie._on_navmesh()'s tolerance, so "outside the playspace" means
## the same thing to the placer as it does to the things that walk into it.
const NAVMESH_TOLERANCE := 1.5

var _player: Player
var _cam: Camera3D
var _config: ClaymoreConfig
var _body: Node3D
var _wedge: ArcWedge

var _valid := false
var _pos := Vector3.ZERO
var _yaw := 0.0
var _reason := ""
var _last_valid := true   # so tints are only rewritten when they change

func setup(player: Player, cam: Camera3D, config: ClaymoreConfig) -> void:
	_player = player
	_cam = cam
	_config = config

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	visible = false

	_body = Claymore.build_body(COLOR_VALID_FRONT, COLOR_VALID_BODY, GHOST_ALPHA)
	add_child(_body)

	_wedge = ArcWedge.new()
	add_child(_wedge)
	# Same +Z-is-facing correction the emplaced wedge makes.
	_wedge.rotation.y = PI
	_wedge.setup(_config.detection_arc_degrees, _config.detection_range, WEDGE_VALID)

func _process(_delta: float) -> void:
	# control_enabled is checked as well as the equip state: opening the crate
	# or entering build mode with a claymore in hand should not leave a ghost
	# tracking a player who can no longer move or place.
	if _player == null or not is_instance_valid(_player) \
			or not _player.claymore_equipped or not _player.control_enabled:
		visible = false
		return
	visible = true
	_solve()
	global_position = _pos
	rotation.y = _yaw
	if _valid != _last_valid:
		_last_valid = _valid
		_apply_tint(_valid)

func is_valid() -> bool:
	return _valid

func ghost_position() -> Vector3:
	return _pos

func ghost_yaw() -> float:
	return _yaw

## Why the current spot is rejected, for UI feedback. "" when valid.
func reason() -> String:
	return _reason

func _apply_tint(valid: bool) -> void:
	var front: Color = COLOR_VALID_FRONT if valid else COLOR_INVALID_FRONT
	var body: Color = COLOR_VALID_BODY if valid else COLOR_INVALID_BODY
	# Rebuilt rather than tracking every material: the ghost body is four
	# meshes and this only runs on a validity CHANGE, not per frame.
	if _body:
		# Detached immediately, freed deferred — queue_free() alone leaves the
		# old body in the tree for the rest of the frame, so the ghost would
		# render twice (green over red) on every validity flip.
		remove_child(_body)
		_body.queue_free()
	_body = Claymore.build_body(front, body, GHOST_ALPHA)
	add_child(_body)
	_wedge.set_color(WEDGE_VALID if valid else WEDGE_INVALID)

# --- Solve -----------------------------------------------------------------
## Facing is the PLAYER's yaw, not the camera pitch: you emplace by standing
## where you want it and turning to face the avenue of approach. Looking down
## to place it must not tip the mine toward the ground.
func _solve() -> void:
	_yaw = _player.rotation.y
	var ground := _find_ground()
	if ground.is_empty():
		_valid = false
		_reason = "no ground in range"
		# Park the ghost at the clamp limit so it doesn't snap to the origin.
		_pos = _clamped_forward_point()
		return
	_pos = ground["pos"]
	var normal: Vector3 = ground["normal"]

	if normal.dot(Vector3.UP) < cos(deg_to_rad(_config.max_ground_slope_deg)):
		_valid = false
		_reason = "too steep"
		return
	if not Claymore.separation_clear(get_tree(), _pos, _config.min_separation):
		_valid = false
		_reason = "too close to another claymore"
		return
	if _overlaps_obstacle(_pos):
		_valid = false
		_reason = "overlaps an obstacle"
		return
	if not _on_navmesh(_pos):
		_valid = false
		_reason = "outside the playspace"
		return
	_valid = true
	_reason = ""

## Ground point under the aim ray, clamped so the emplacement can never be
## further than placement_max_range from the player.
##
## Two passes on purpose: the aim ray finds what you are LOOKING at, and if
## that is out of range (or nothing at all) we fall back to probing straight
## down at the clamp limit — so aiming at the horizon still previews a spot at
## your feet rather than failing outright.
func _find_ground() -> Dictionary:
	var space := get_world_3d().direct_space_state
	var from := _cam.global_position
	var dir := -_cam.global_transform.basis.z.normalized()
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * AIM_TRACE_LENGTH)
	# World geometry and the ditch revetment — the same surfaces the grenade
	# collides with, minus C-wire, which is strands and cannot hold a mine.
	q.collision_mask = Obstacle.SOLID_SURFACE_MASK
	q.collide_with_areas = false
	q.exclude = [_player.get_rid()]
	var hit := space.intersect_ray(q)

	if hit:
		var p: Vector3 = hit.position
		if _flat_distance(p, _player.global_position) <= _config.placement_max_range:
			return {"pos": p, "normal": hit.normal}
	# Out of range, or nothing hit: probe down at the clamp limit instead.
	return _probe_down(_clamped_forward_point())

## A point placement_max_range ahead of the player, on the player's own ground
## plane. Uses the player's flattened forward, not the camera's, so looking
## straight up or down doesn't collapse the offset to nothing.
func _clamped_forward_point() -> Vector3:
	var fwd := -_player.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	return _player.global_position + fwd.normalized() * _config.placement_max_range

func _probe_down(at: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var from := at + Vector3(0.0, DROP_PROBE_UP, 0.0)
	var to := at - Vector3(0.0, DROP_PROBE_DOWN, 0.0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = Obstacle.SOLID_SURFACE_MASK
	q.collide_with_areas = false
	q.exclude = [_player.get_rid()]
	var hit := space.intersect_ray(q)
	if hit:
		return {"pos": hit.position, "normal": hit.normal}
	return {}

func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

## Reuses the obstacle FOOTPRINT layer that BuildMode's own placement test
## uses, so "overlaps an obstacle" means the same thing whether you are
## emplacing a sandbag wall or a claymore.
func _overlaps_obstacle(pos: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = 0.22
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, pos + Vector3(0.0, 0.18, 0.0))
	params.collision_mask = Obstacle.FOOTPRINT_LAYER
	params.collide_with_areas = true
	params.collide_with_bodies = false
	params.exclude = [_player.get_rid()]
	return space.intersect_shape(params, 1).size() > 0

## Same test and tolerance Zombie._on_navmesh() uses. A claymore emplaced
## somewhere nothing can path to is a wasted 15 points, so it is rejected
## rather than silently allowed.
func _on_navmesh(pos: Vector3) -> bool:
	var map := get_world_3d().navigation_map
	if not map.is_valid():
		return true   # no navmesh yet — don't block placement on it
	var closest := NavigationServer3D.map_get_closest_point(map, pos)
	return closest.distance_to(pos) <= NAVMESH_TOLERANCE
