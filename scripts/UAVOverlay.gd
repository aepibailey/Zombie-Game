extends CanvasLayer
class_name UAVOverlay
## Offscreen contact indicators while a UAV is on station — the other half of
## the reveal alongside each Zombie's own through-wall silhouette (see
## Zombie._build_uav_silhouette()). Draws nothing while UAVSystem is inactive.
##
## Built entirely in code, matching every other UI in this project (HUD,
## RadioMenu). A single custom-drawn Control rather than a pool of
## TextureRect nodes: the contact set changes every frame as zombies spawn,
## die, or cross on/offscreen, and redrawing from scratch needs no pool to
## keep in sync.

const MARGIN := 28.0     # inset from the screen edge, so markers don't clip
const MARKER_SIZE := 14.0

var _player: Player
var _canvas: Control

func setup(player: Player) -> void:
	_player = player

func _ready() -> void:
	layer = 12   # above HUD (10), below RadioMenu (15) — a battlefield overlay, not a dialog
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_on_draw)
	add_child(_canvas)

func _process(_delta: float) -> void:
	# Cheap even while inactive: _on_draw() early-returns immediately, and
	# this is what clears the last frame's markers the instant the UAV goes
	# off station instead of leaving a stale set on screen.
	_canvas.queue_redraw()

func _on_draw() -> void:
	if not UAVSystem.active or _player == null or not is_instance_valid(_player):
		return
	var cam := _player.camera
	if cam == null:
		return
	var centre: Vector2 = _canvas.size * 0.5
	for c in _offscreen_contacts(cam):
		_draw_marker(centre, c["dir2d"], c["color"])

## Nearest N offscreen zombies, by 3D distance to the player. Onscreen
## contacts need no indicator — each one's own silhouette already covers it.
func _offscreen_contacts(cam: Camera3D) -> Array:
	var out: Array = []
	var max_dist: float = UAVSystem.CONFIG.uav_max_reveal_distance
	for node in get_tree().get_nodes_in_group("zombies"):
		var zombie := node as Zombie
		if zombie == null or not is_instance_valid(zombie) or not zombie.is_alive():
			continue
		var dist := _player.global_position.distance_to(zombie.global_position)
		if max_dist > 0.0 and dist > max_dist:
			continue
		var behind := cam.is_position_behind(zombie.global_position)
		var screen_pos := cam.unproject_position(zombie.global_position)
		if not behind and _canvas.get_rect().has_point(screen_pos):
			continue   # onscreen — the silhouette itself covers it
		out.append({
			"dist": dist,
			"dir2d": _screen_direction(screen_pos, behind),
			"color": zombie.zombie_type.uav_silhouette_color if zombie.zombie_type else Color.WHITE,
		})
	out.sort_custom(func(a, b): return a["dist"] < b["dist"])
	var cap: int = maxi(0, UAVSystem.CONFIG.uav_offscreen_indicator_cap)
	if out.size() > cap:
		out.resize(cap)
	return out

## Direction from screen centre toward the contact. unproject_position()
## mirrors through the origin for points BEHIND the camera, which reads as
## exactly backwards on screen — flipping it here is what corrects that, so
## a contact behind the player still points the right way around the border.
func _screen_direction(screen_pos: Vector2, behind: bool) -> Vector2:
	var centre: Vector2 = _canvas.size * 0.5
	var d := screen_pos - centre
	if behind:
		d = -d
	if d.length_squared() < 0.0001:
		d = Vector2.UP   # dead-centre-behind is a real, if rare, case
	return d.normalized()

func _draw_marker(centre: Vector2, dir: Vector2, color: Color) -> void:
	var half: Vector2 = _canvas.size * 0.5 - Vector2(MARGIN, MARGIN)
	# Clamp to the inset rectangle border — scale by whichever axis hits its
	# bound first, the standard "point on a box toward a direction" solve.
	var sx: float = (half.x / absf(dir.x)) if absf(dir.x) > 0.0001 else INF
	var sy: float = (half.y / absf(dir.y)) if absf(dir.y) > 0.0001 else INF
	var pos: Vector2 = centre + dir * minf(sx, sy)

	# A small triangle pointing along `dir`, in the contact's own colour —
	# the same amber/red split as the through-wall silhouette, so an edge
	# indicator and the silhouette it becomes (once the player turns toward
	# it) never disagree about what's coming.
	var perp := Vector2(-dir.y, dir.x)
	var tip: Vector2 = pos + dir * MARKER_SIZE * 0.6
	var a: Vector2 = pos - dir * MARKER_SIZE * 0.4 + perp * MARKER_SIZE * 0.5
	var b: Vector2 = pos - dir * MARKER_SIZE * 0.4 - perp * MARKER_SIZE * 0.5
	_canvas.draw_colored_polygon(PackedVector2Array([tip, a, b]), color)
