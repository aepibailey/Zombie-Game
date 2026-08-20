extends Node3D
class_name TargetPainter
## Shared target-painting mode: aim at the ground, see the effect radius you
## are about to hit, LMB to confirm or RMB/Escape to cancel.
##
## GENERIC BY DESIGN — the Apache patrol box is the next consumer and this
## must not need changing for it. Nothing here knows what a mortar is, and
## nothing here knows what a supply drop is: a caller hands in a radius and a
## callback, and gets back a world position or a cancellation. `begin()` is
## the whole interface.
##
## CONTAINS NO COST, COOLDOWN OR NOISE. A consumer that wants a transmission
## pulse on entry, on confirm, or both, emits it itself around its own
## begin() call — which is exactly why the supply drop can be a two-pulse
## enabler while the mortar stays a one-pulse enabler with no branch here.
##
## NOT A MENU. The game does not pause, the player keeps full movement AND
## full mouse-look, and zombies keep coming. This is aiming, not browsing —
## which is why it deliberately does NOT go through
## Player.set_radio_menu_open() (that suppresses look, correctly, for a
## menu — exactly wrong here).
##
## The marker is a flat ground circle drawn with AreaMath.arc_fan_points() at
## 360 degrees, the same geometry the claymore's detection wedge uses. Shared
## on purpose: a circle that disagreed with the arc code about what a radius
## means would be a lie in the one place the player is committing points.

## Full circle — arc_fan_points takes a total arc width, and 360 is a disc.
const FULL_CIRCLE_DEGREES := 360.0
## Fan resolution. Higher than the wedge's default because this is a full
## circle at up to 20m, where a coarse fan reads as a visible polygon.
const CIRCLE_SEGMENTS := 48

## Emitted on confirm, carrying the designated world position. Consumers may
## subscribe to this OR pass an on_confirm callable to begin() — the callable
## is per-call and therefore unambiguous when several enablers can paint, so
## it stays the primary path; the signal exists for observers that want to
## watch every designation regardless of who asked for it.
signal target_confirmed(position: Vector3)
## Emitted on cancel. Same relationship to begin()'s on_cancel callable.
signal target_cancelled()

## All colours and the range/navmesh rules live on this — see
## TargetPaintConfig for why a Resource rather than @export vars here.
@export var config: TargetPaintConfig

## Lifted off the ground so the disc doesn't z-fight the terrain under it.
const GROUND_OFFSET := 0.05
## How far the aim ray is traced before giving up. Independent of the paint
## range limit: we trace far enough to FIND ground, then judge the range of
## whatever we found. Tracing only to max_range would make an out-of-range
## aim look identical to aiming at the sky.
const AIM_TRACE_LENGTH := 400.0

var _player: Player
var _cam: Camera3D

var _active := false
var _radius := 0.0
var _on_confirm: Callable
var _on_cancel: Callable
var _max_range := 150.0
## Per-call override of config.paint_requires_navmesh — a property of the
## ORDNANCE, not the designation. See begin().
var _requires_navmesh := true

var _fill: MeshInstance3D
var _fill_mat: StandardMaterial3D
var _rim: MeshInstance3D
var _rim_mat: StandardMaterial3D

var _valid := false
var _point := Vector3.ZERO
var _last_valid := true
## Suppresses the very first LMB read after entering paint mode, so the click
## that is still physically down from something else can't instantly confirm.
## Cleared on the first frame LMB is observed UP.
var _await_lmb_release := true

func setup(player: Player, cam: Camera3D) -> void:
	_player = player
	_cam = cam

func _ready() -> void:
	# World-space: the marker sits where the player is aiming, not where the
	# player is, so it must not inherit their transform.
	top_level = true
	global_transform = Transform3D.IDENTITY
	visible = false
	_build_marker()

func is_active() -> bool:
	return _active

## Enter paint mode.
##   radius     — the circle drawn, i.e. what the caller will actually cover
##   max_range  — furthest the player may paint from their own position.
##                <= 0 uses config.max_designation_range.
##   on_confirm — Callable(point: Vector3), invoked once on LMB over valid ground
##   on_cancel  — Callable(), invoked once on RMB/Escape. Never both.
##   requires_navmesh — per-call override of config.paint_requires_navmesh.
##                A property of the ORDNANCE, not of the designation:
##                indirect fire may legitimately land where nothing can walk
##                (a rooftop, the far side of the wire), a delivered crate may
##                not. Omit to take the config default.
##
## The caller charges nothing before this returns; on_confirm is where cost
## belongs, so a cancel is genuinely free. Noise is the caller's business
## too — see the class docstring.
func begin(radius: float, max_range: float, on_confirm: Callable, on_cancel: Callable,
		requires_navmesh: Variant = null) -> void:
	if _active:
		return
	_active = true
	_radius = maxf(0.5, radius)
	_max_range = max_range if max_range > 0.0 else config.max_designation_range
	_requires_navmesh = config.paint_requires_navmesh if requires_navmesh == null \
		else bool(requires_navmesh)
	_on_confirm = on_confirm
	_on_cancel = on_cancel
	# Only wait for a release if the button is ACTUALLY down right now. Set
	# unconditionally, this ate the player's first legitimate confirm click:
	# entry is normally via a number key, so LMB is up, and the flag would
	# have swallowed the next press and only cleared on its release.
	_await_lmb_release = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	_rebuild_marker_geometry()
	# Reset the tint cache too — _process only repaints on a CHANGE, so a
	# second paint could otherwise open showing the previous one's red.
	_valid = false
	_last_valid = true
	_apply_tint(true)
	visible = true
	_player.set_painting(true)

func cancel() -> void:
	if not _active:
		return
	var cb := _on_cancel
	_end()
	if cb.is_valid():
		cb.call()
	target_cancelled.emit()

func _confirm() -> void:
	if not _active or not _valid:
		return
	var cb := _on_confirm
	var p := _point
	_end()
	if cb.is_valid():
		cb.call(p)
	target_confirmed.emit(p)

## Common teardown. Clears state BEFORE the callback runs (see cancel() and
## _confirm()), so a callback that immediately starts another paint — or
## opens the radio menu again — isn't fighting a half-torn-down painter.
func _end() -> void:
	_active = false
	visible = false
	_on_confirm = Callable()
	_on_cancel = Callable()
	_player.set_painting(false)

# --- Marker -----------------------------------------------------------------
func _build_marker() -> void:
	_fill = MeshInstance3D.new()
	_fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fill_mat = _flat_mat(config.marker_valid_color)
	_fill.material_override = _fill_mat
	add_child(_fill)

	_rim = MeshInstance3D.new()
	_rim.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rim_mat = _flat_mat(config.marker_rim_valid_color)
	_rim.material_override = _rim_mat
	add_child(_rim)

## Unshaded and alpha-blended, deliberately NOT a lit decal and never
## additive: this has to read on unlit ground at night without NVGs, and
## without washing out the scene it's drawn over.
func _flat_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = c
	return m

func _rebuild_marker_geometry() -> void:
	_fill.mesh = _disc_mesh(_radius)
	_rim.mesh = _ring_mesh(maxf(0.1, _radius - config.marker_rim_width), _radius)
	_fill.position.y = GROUND_OFFSET
	_rim.position.y = GROUND_OFFSET + 0.005   # hair above the fill, same reason

## Filled disc, as a triangle fan around the centre.
func _disc_mesh(radius: float) -> ImmediateMesh:
	var pts := AreaMath.arc_fan_points(FULL_CIRCLE_DEGREES, radius, CIRCLE_SEGMENTS)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(1, pts.size() - 1):
		im.surface_add_vertex(pts[0])
		im.surface_add_vertex(pts[i])
		im.surface_add_vertex(pts[i + 1])
	im.surface_end()
	return im

## Flat annulus between two radii — the bright edge band. Built as a triangle
## strip between the inner and outer rings.
func _ring_mesh(inner: float, outer: float) -> ImmediateMesh:
	var out_pts := AreaMath.arc_fan_points(FULL_CIRCLE_DEGREES, outer, CIRCLE_SEGMENTS)
	var in_pts := AreaMath.arc_fan_points(FULL_CIRCLE_DEGREES, inner, CIRCLE_SEGMENTS)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	# Index 0 of a fan is the apex; the rim only wants the perimeter points.
	for i in range(1, out_pts.size()):
		im.surface_add_vertex(in_pts[i])
		im.surface_add_vertex(out_pts[i])
	im.surface_end()
	return im

func _apply_tint(valid: bool) -> void:
	_fill_mat.albedo_color = config.marker_valid_color if valid else config.marker_invalid_color
	_rim_mat.albedo_color = config.marker_rim_valid_color if valid else config.marker_rim_invalid_color

# --- Per-frame solve ---------------------------------------------------------
func _process(_delta: float) -> void:
	if not _active:
		return
	# Losing control mid-paint (death respawn, crate opened) cancels rather
	# than stranding a marker the player can no longer act on.
	if not _player.control_enabled:
		cancel()
		return
	_solve()
	global_position = _point
	if _valid != _last_valid:
		_last_valid = _valid
		_apply_tint(_valid)

func _solve() -> void:
	var space := get_world_3d().direct_space_state
	var from := _cam.global_position
	var dir := -_cam.global_transform.basis.z.normalized()
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * AIM_TRACE_LENGTH)
	# Same surface set the grenade lands on and the claymore stands on —
	# world geometry plus the ditch revetment, no C-wire (strands aren't
	# ground). One named constant, so "what counts as ground" can't drift
	# between the things that ask.
	q.collision_mask = Obstacle.SOLID_SURFACE_MASK
	q.collide_with_areas = false
	q.exclude = [_player.get_rid()]
	var hit := space.intersect_ray(q)

	if hit.is_empty():
		# Aiming at the sky. Park the marker at the range limit along the
		# flattened aim so it stays on screen and visibly red, rather than
		# vanishing or snapping to the world origin.
		_point = _fallback_point()
		_valid = false
		return

	_point = hit.position
	# Flat distance, not 3D: painting down into the ditch or up onto a
	# structure shouldn't spend range on the height difference.
	var flat := Vector2(_point.x - _player.global_position.x,
		_point.z - _player.global_position.z).length()
	# No minimum. Painting your own feet is legal and lethal, by design.
	_valid = flat <= _max_range
	# Navmesh gate, when the ordnance asks for it. This is what turns a tree
	# canopy, a rooftop or the far lip of the ditch red — the ray found solid
	# geometry there, but nothing can path to it, so nothing can be delivered
	# to it either.
	if _valid and _requires_navmesh:
		_valid = point_on_navmesh(get_world_3d(), _point, config.navmesh_tolerance)

## Is `pos` on (or within `tolerance` of) the baked navmesh?
##
## STATIC and public deliberately: the supply drop's landing solve needs the
## identical test on scattered candidate points, and "on the navmesh" must
## mean exactly one thing project-wide. ClaymorePlacer._on_navmesh() is the
## same test with the same tolerance and predates this — it is left alone
## only because it is a self-contained placement rule, not part of a
## designation flow.
static func point_on_navmesh(world: World3D, pos: Vector3, tolerance: float) -> bool:
	var map := world.navigation_map
	if not map.is_valid():
		return true   # no navmesh yet — don't block designation on it
	return NavigationServer3D.map_get_closest_point(map, pos).distance_to(pos) <= tolerance

## Nearest point ON the navmesh to `pos`. Returns `pos` unchanged when there
## is no baked navmesh to snap to.
static func snap_to_navmesh(world: World3D, pos: Vector3) -> Vector3:
	var map := world.navigation_map
	if not map.is_valid():
		return pos
	return NavigationServer3D.map_get_closest_point(map, pos)

func _fallback_point() -> Vector3:
	var fwd := -_cam.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = -_player.global_transform.basis.z
		fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	return _player.global_position + fwd.normalized() * _max_range

# --- Input -------------------------------------------------------------------
## LMB confirms, RMB and Escape cancel. Every one of them is marked handled so
## the same press cannot also fire a weapon, toggle ADS, or reach the player's
## mouse-capture Escape handler underneath.
func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if not event.pressed:
				_await_lmb_release = false
				return
			if _await_lmb_release:
				# The click that opened this is still down — don't let it
				# double as the confirm.
				get_viewport().set_input_as_handled()
				return
			_confirm()
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			cancel()
			get_viewport().set_input_as_handled()
			return
	elif event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		cancel()
		get_viewport().set_input_as_handled()
