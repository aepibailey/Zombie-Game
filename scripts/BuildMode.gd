extends Node3D
class_name BuildMode
## Top-down build mode, opened at the Engineers' Tent during Day.
##
## This is the shell: camera, pan/zoom, enter/exit and the day-timer hold.
## The obstacle palette, ghost placement and validation live on top of it.

signal opened
signal closed

## Orthogonal size = metres of world visible vertically. The map is 60x60, so
## the default frames it with margin.
@export var default_zoom: float = 72.0
@export var min_zoom: float = 24.0
@export var max_zoom: float = 90.0
@export var zoom_step: float = 6.0
@export var pan_speed: float = 28.0        # metres/sec at default zoom
@export var camera_height: float = 60.0
## How far the view may pan from map centre, so you can't lose the base.
@export var pan_limit: float = 34.0

# --- Placement ------------------------------------------------------------
@export var rotation_step_deg: float = 15.0
## Placement is rejected outside this half-extent (the map is 60x60).
@export var map_half_extent: float = 29.0
## Ground normals flatter than this are "too steep" to build on.
@export var max_ground_slope_dot: float = 0.9
@export var max_obstacles: int = 30
## Partial refill of a spent minefield, cheaper than a fresh emplacement.
## Deliberately profitable over repeated use — 20 mines for 10 pts is by
## design, not an oversight. Do not "correct" this upward.
const REPLENISH_COST := 10

const SFX_CONFIRM := "res://assets/audio/ui/ui_confirm.wav"
const SFX_DENY := "res://assets/audio/ui/ui_deny.wav"

## Typed so the flood-fill's loop variable is a Vector2i rather than a Variant
## (an untyped array literal makes `d.x` uninferrable).
var NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

var active := false

var _cam: Camera3D
var _player: Player = null
var _hud: HUD = null
var _ui: CanvasLayer
var _title: Label
var _points_label: Label
var _hint: Label
var _reason_label: Label
var _seal_label: Label
var _count_label: Label
var _palette: VBoxContainer
var _palette_buttons: Dictionary = {}

var _selected_id := ""
var _ghost: Node3D
var _ghost_mat: StandardMaterial3D
var _ghost_yaw := 0.0            # persists between placements
var _ghost_valid := false
var _ghost_pos := Vector3.ZERO
var _placed: Array = []
var _obstacles_root: Node3D
var _world: Node = null
var _sfx_confirm: AudioStreamPlayer
var _sfx_deny: AudioStreamPlayer
var _seal_cache_key := ""
var _seal_cached := false

func _ready() -> void:
	_build_camera()
	_build_ui()
	_sfx_confirm = _mk_sfx(SFX_CONFIRM)
	_sfx_deny = _mk_sfx(SFX_DENY)
	set_process(false)
	set_process_unhandled_input(false)

func _mk_sfx(path: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	if ResourceLoader.exists(path):
		var res = load(path)
		p.stream = res
	add_child(p)
	return p

## `obstacles_root` must live under the NavigationRegion3D so a rebake sees
## placed obstacles; `world` is the node that owns the rebake request.
func setup(player: Player, hud: HUD, obstacles_root: Node3D, world: Node) -> void:
	_player = player
	_hud = hud
	_obstacles_root = obstacles_root
	_world = world

func _build_camera() -> void:
	_cam = Camera3D.new()
	# Orthogonal rather than perspective: a build view wants consistent scale
	# across the map, and zoom becomes a single clean `size` value.
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = default_zoom
	_cam.position = Vector3(0, camera_height, 0)
	_cam.rotation_degrees = Vector3(-90, 0, 0)   # straight down
	_cam.far = 200.0
	_cam.current = false
	add_child(_cam)

func _build_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.layer = 25
	_ui.visible = false
	add_child(_ui)

	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.05, 0.85)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	bar.add_theme_stylebox_override("panel", sb)
	_ui.add_child(bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	bar.add_child(row)

	_title = Label.new()
	_title.text = "ENGINEERS' TENT — BUILD MODE"
	_title.add_theme_font_size_override("font_size", 18)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_title)

	_points_label = Label.new()
	_points_label.add_theme_font_size_override("font_size", 18)
	_points_label.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	row.add_child(_points_label)

	_count_label = Label.new()
	_count_label.add_theme_font_size_override("font_size", 14)
	_count_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	row.add_child(_count_label)

	# Palette down the left side.
	var pal_panel := PanelContainer.new()
	pal_panel.position = Vector2(16, 64)
	var psb := StyleBoxFlat.new()
	psb.bg_color = Color(0.05, 0.06, 0.05, 0.85)
	psb.set_corner_radius_all(6)
	for side in ["left", "right", "top", "bottom"]:
		psb.set("content_margin_" + side, 12)
	pal_panel.add_theme_stylebox_override("panel", psb)
	_ui.add_child(pal_panel)

	_palette = VBoxContainer.new()
	_palette.add_theme_constant_override("separation", 6)
	pal_panel.add_child(_palette)

	var pal_title := Label.new()
	pal_title.text = "OBSTACLES"
	pal_title.add_theme_font_size_override("font_size", 14)
	_palette.add_child(pal_title)

	for id in ObstacleCatalog.ORDER:
		var t = ObstacleCatalog.get_type(id)
		var btn := Button.new()
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(300, 0)
		btn.tooltip_text = t.description
		btn.pressed.connect(_select.bind(id))
		_palette_buttons[id] = btn
		_palette.add_child(btn)

	# Reason line sits just under the cursor area, centred.
	_reason_label = Label.new()
	_reason_label.add_theme_font_size_override("font_size", 16)
	_reason_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_reason_label.add_theme_constant_override("outline_size", 4)
	_reason_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_reason_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reason_label.position.y = -76
	_reason_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_reason_label)

	# Informational only — sealing the perimeter is allowed.
	_seal_label = Label.new()
	_seal_label.text = "PERIMETER WILL BE SEALED"
	_seal_label.add_theme_font_size_override("font_size", 16)
	_seal_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	_seal_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_seal_label.add_theme_constant_override("outline_size", 4)
	_seal_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_seal_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_seal_label.position.y = -100
	_seal_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_seal_label.visible = false
	_ui.add_child(_seal_label)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	_hint.text = "WASD pan   Wheel rotate 15°   Shift+Wheel free   [ ] zoom   LMB place   RMB repair/replenish   Esc leave"
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.position.y = -28
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_hint)

	PointsManager.points_changed.connect(func(_p): _refresh())

# --- Enter / exit ---------------------------------------------------------
func open() -> void:
	if active or _player == null:
		return
	active = true
	# The day clock stops: planning shouldn't burn daylight.
	GameManager.set_paused(true)
	_cam.size = default_zoom
	_cam.position = Vector3(0, camera_height, 0)
	_cam.current = true
	# The player body stays exactly where it is; only control is suspended.
	_player.set_control_enabled(false)
	_player._set_mouse_captured(false)
	_ui.visible = true
	# Every minefield shows its remaining count while planning.
	for m in get_tree().get_nodes_in_group("minefields"):
		m.set_readout_forced(true)
	set_process(true)
	set_process_unhandled_input(true)
	_refresh()
	opened.emit()

func close() -> void:
	if not active:
		return
	active = false
	_selected_id = ""
	_clear_ghost()
	for m in get_tree().get_nodes_in_group("minefields"):
		m.set_readout_forced(false)
	GameManager.set_paused(false)
	_cam.current = false
	if _player:
		_player.camera.current = true
		_player.set_control_enabled(true)
		_player._set_mouse_captured(true)
	_ui.visible = false
	set_process(false)
	set_process_unhandled_input(false)
	closed.emit()

func is_open() -> bool:
	return active

func _refresh() -> void:
	_points_label.text = "Points: %d" % PointsManager.points
	_count_label.text = "Placed: %d / %d" % [_placed.size(), max_obstacles]
	for id in ObstacleCatalog.ORDER:
		var t = ObstacleCatalog.get_type(id)
		var btn: Button = _palette_buttons[id]
		btn.button_pressed = (id == _selected_id)
		var afford: bool = PointsManager.points >= t.cost
		btn.text = "%s — %d pts" % [t.display_name, t.cost]
		btn.add_theme_color_override("font_color",
			Color(1, 1, 1) if afford else Color(1.0, 0.45, 0.4))

# --- Selection & ghost ----------------------------------------------------
func _select(id: String) -> void:
	if _selected_id == id:
		_selected_id = ""      # click again to deselect
		_clear_ghost()
	else:
		_selected_id = id
		_build_ghost(id)
	_refresh()

func _clear_ghost() -> void:
	if _ghost and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	_reason_label.text = ""
	_seal_label.visible = false

func _build_ghost(id: String) -> void:
	_clear_ghost()
	var t = ObstacleCatalog.get_type(id)
	if t == null:
		return
	_ghost = Node3D.new()
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = t.size
	mesh.mesh = box
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ghost_mat.albedo_color = Color(0.2, 1.0, 0.3, 0.45)
	mesh.material_override = _ghost_mat
	# Ditch ghost sits below ground like the real thing.
	mesh.position.y = -t.size.y * 0.5 if id == "ditch" else t.size.y * 0.5
	_ghost.add_child(mesh)
	_obstacles_root.add_child(_ghost)

func _update_ghost() -> void:
	if _ghost == null or _selected_id == "":
		return
	var t = ObstacleCatalog.get_type(_selected_id)
	_ghost_pos = cursor_ground_point()
	_ghost.global_position = _ghost_pos
	_ghost.rotation.y = _ghost_yaw

	var result := _validate(t, _ghost_pos, _ghost_yaw)
	_ghost_valid = result["valid"]
	_ghost_mat.albedo_color = Color(0.2, 1.0, 0.3, 0.45) if _ghost_valid \
		else Color(1.0, 0.2, 0.15, 0.5)
	_reason_label.text = result["reason"]
	_reason_label.add_theme_color_override("font_color",
		Color(0.6, 1.0, 0.6) if _ghost_valid else Color(1.0, 0.5, 0.45))

	# Seal notice is informational only and never blocks placement.
	if _ghost_valid and t.blocks_pathing:
		_seal_label.visible = _would_seal(t, _ghost_pos, _ghost_yaw)
	else:
		_seal_label.visible = false

# --- Validation -----------------------------------------------------------
## Placement is rejected ONLY for overlap, out-of-bounds, steep ground, the
## obstacle cap, or affordability. Sealing the base is explicitly allowed.
func _validate(t, pos: Vector3, yaw: float) -> Dictionary:
	if _placed.size() >= max_obstacles:
		return {"valid": false, "reason": "Obstacle limit reached (%d)" % max_obstacles}
	if PointsManager.points < t.cost:
		return {"valid": false, "reason": "Not enough points (%d needed)" % t.cost}

	# Bounds: every corner must be on the map.
	for c in Obstacle.corners_for(pos, yaw, t.size):
		if absf(c.x) > map_half_extent or absf(c.z) > map_half_extent:
			return {"valid": false, "reason": "Outside the map"}

	# Ground must exist and be flat enough under each corner.
	var space := get_world_3d().direct_space_state
	for c in Obstacle.corners_for(pos, yaw, t.size):
		var from := Vector3(c.x, 6.0, c.z)
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3(0, -12.0, 0))
		q.collision_mask = 1
		var hit := space.intersect_ray(q)
		if not hit:
			return {"valid": false, "reason": "No ground here"}
		var n: Vector3 = hit.normal
		if n.dot(Vector3.UP) < max_ground_slope_dot:
			return {"valid": false, "reason": "Ground too steep"}

	# Overlap: world geometry (layer 1) and other obstacle footprints (layer 4).
	# The test box is lifted clear of the ground plane so the ground itself
	# never counts as an overlap.
	var blocker := _overlap_blocker(space, t, pos, yaw)
	if blocker != "":
		return {"valid": false, "reason": "Overlaps %s" % blocker}

	# Two DISTINCT player-safety checks, deliberately not merged: one is
	# "you're standing in it", the other is "you'd be walled in".
	if t.blocks_player and _overlaps_player(t, pos, yaw):
		return {"valid": false, "reason": "CAN'T BUILD ON YOURSELF"}
	if _would_trap_player(t, pos, yaw):
		return {"valid": false, "reason": "WOULD TRAP PLAYER"}

	return {"valid": true, "reason": "%s — %d pts" % [t.display_name, t.cost]}

## Returns a human-readable description of the first blocking collider, or "".
func _overlap_blocker(space: PhysicsDirectSpaceState3D, t, pos: Vector3, yaw: float) -> String:
	var size: Vector3 = t.size
	var test_h: float = maxf(0.6, size.y)
	var shape := BoxShape3D.new()
	# Shrink slightly so obstacles can sit flush against each other.
	shape.size = Vector3(size.x * 0.96, test_h * 0.9, size.z * 0.96)

	var basis := Basis(Vector3.UP, yaw)
	var centre := Vector3(pos.x, 0.12 + test_h * 0.45, pos.z)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(basis, centre)
	# Layer 1 = world geometry, layer 2 = the crate/tent/drop triggers (so the
	# rejection message can name them), layer 4 = other obstacle footprints.
	params.collision_mask = 1 | 2 | Obstacle.FOOTPRINT_LAYER
	params.collide_with_areas = true
	params.collide_with_bodies = true
	if _player:
		params.exclude = [_player.get_rid()]

	for hit in space.intersect_shape(params, 16):
		var col = hit.collider
		if col == null:
			continue
		# The player and dormant zombies are not obstructions.
		if col.is_in_group("zombies") or col.is_in_group("player"):
			continue
		if col.is_in_group("zombie_heads"):
			continue
		if col.is_in_group("obstacle_footprints"):
			return "another obstacle"
		if col is EngineersTentZone:
			return "the engineers' tent"
		if col is SupplyCrateZone or col is SupplyDrop:
			return "the supply crate"
		return "existing structures"
	return ""

const SEAL_CELL := 2.0

## Coarse flood-fill on a 2m grid: is `target` still connected to the map edge
## once `runs` are treated as walls? Shared by both connectivity checks —
## the zombie "perimeter sealed" notice and the player "would trap" rejection —
## which differ only in which obstacles count as walls and where they start.
func _reaches_border(runs: Array, target: Vector3) -> bool:
	var half := int(map_half_extent / SEAL_CELL)
	var dim := half * 2 + 1

	var blocked := {}
	for r in runs:
		var s: Vector3 = r["size"]
		var rpos: Vector3 = r["pos"]
		var ryaw: float = r["yaw"]
		# Walk the run's length, marking every cell it covers.
		var steps: int = int(ceil(s.x / (SEAL_CELL * 0.5)))
		for i in range(steps + 1):
			var along: float = -s.x * 0.5 + s.x * (float(i) / float(maxi(1, steps)))
			var offset := Vector2(along, 0.0).rotated(ryaw)
			var gx := int(round((rpos.x + offset.x) / SEAL_CELL)) + half
			var gz := int(round((rpos.z + offset.y) / SEAL_CELL)) + half
			if gx >= 0 and gz >= 0 and gx < dim and gz < dim:
				blocked[gx * dim + gz] = true

	var tx: int = clampi(int(round(target.x / SEAL_CELL)) + half, 0, dim - 1)
	var tz: int = clampi(int(round(target.z / SEAL_CELL)) + half, 0, dim - 1)
	var target_cell := tx * dim + tz
	# A wall laid straight through the target cell isn't a connectivity answer.
	if blocked.has(target_cell):
		return true

	# Flood from the map border inward.
	var seen := {}
	var queue: Array = []
	for i in range(dim):
		for cell in [i * dim, i * dim + (dim - 1), i, (dim - 1) * dim + i]:
			if not blocked.has(cell) and not seen.has(cell):
				seen[cell] = true
				queue.append(cell)

	while queue.size() > 0:
		var c: int = queue.pop_back()
		if c == target_cell:
			return true
		var cx := c / dim
		var cz := c % dim
		for d in NEIGHBOURS:
			var nx := cx + d.x
			var nz := cz + d.y
			if nx < 0 or nz < 0 or nx >= dim or nz >= dim:
				continue
			var n := nx * dim + nz
			if blocked.has(n) or seen.has(n):
				continue
			seen[n] = true
			queue.append(n)
	return false

func _runs_for(pos: Vector3, yaw: float, t, player_barriers: bool) -> Array:
	var runs: Array = []
	for o in _placed:
		if not is_instance_valid(o):
			continue
		var counts: bool = o.obstacle_type.blocks_player if player_barriers \
			else o.obstacle_type.blocks_pathing
		if counts:
			runs.append({"pos": o.global_position, "yaw": o.rotation.y,
				"size": o.obstacle_type.size})
	runs.append({"pos": pos, "yaw": yaw, "size": t.size})
	return runs

## Would this placement cut the base off from the map edge for ZOMBIES?
## Informational only — sealing is explicitly allowed.
func _would_seal(t, pos: Vector3, yaw: float) -> bool:
	var key := "%d_%d_%d_%d" % [
		int(pos.x), int(pos.z), int(rad_to_deg(yaw)), _placed.size()]
	if key == _seal_cache_key:
		return _seal_cached
	_seal_cache_key = key
	_seal_cached = not _reaches_border(_runs_for(pos, yaw, t, false), Vector3.ZERO)
	return _seal_cached

## Would this placement leave the PLAYER with no route to the map edge?
## Unlike sealing, this is a hard rejection — wire is a barrier the player
## cannot climb, so walling yourself in is unrecoverable.
func _would_trap_player(t, pos: Vector3, yaw: float) -> bool:
	if _player == null or not t.blocks_player:
		return false
	return not _reaches_border(_runs_for(pos, yaw, t, true), _player.global_position)

## Would the obstacle's volume land on top of the player?
func _overlaps_player(t, pos: Vector3, yaw: float) -> bool:
	if _player == null:
		return false
	var local := (_player.global_position - pos).rotated(Vector3.UP, -yaw)
	var half_x: float = t.size.x * 0.5 + 0.5    # + player radius margin
	var half_z: float = t.size.z * 0.5 + 0.5
	return absf(local.x) <= half_x and absf(local.z) <= half_z

# --- Placement ------------------------------------------------------------
func _try_place() -> void:
	if _selected_id == "" or _ghost == null:
		return
	var t = ObstacleCatalog.get_type(_selected_id)
	var result := _validate(t, _ghost_pos, _ghost_yaw)
	if not result["valid"]:
		if _sfx_deny.stream:
			_sfx_deny.play()
		return
	# Points are deducted ONLY here, on a committed placement.
	if not PointsManager.spend_points(t.cost):
		if _sfx_deny.stream:
			_sfx_deny.play()
		return

	var o := ObstacleCatalog.create(_selected_id)
	if o == null:
		return
	_obstacles_root.add_child(o)
	o.global_position = _ghost_pos
	o.rotation.y = _ghost_yaw
	_placed.append(o)
	# A destroyed section opens a gap: rebake so zombies path through it.
	if o is SandbagSection:
		o.destroyed_section.connect(_on_section_destroyed)
	# The ditch's ground hole and navmesh mouth patch are both world-space and
	# can only be computed now that global_position/rotation.y are final.
	if o is ZombieDitch:
		o.finalize_in_world(_world)
	if _sfx_confirm.stream:
		_sfx_confirm.play()
	_seal_cache_key = ""      # roster changed; recompute the seal test
	# Only solid obstacles change pathing, so only they need a rebake.
	# (The ditch triggers its own rebake via finalize_in_world(), above.)
	if t.solid and _world and _world.has_method("request_navmesh_rebake"):
		_world.request_navmesh_rebake("placed %s" % t.id)
	_refresh()

func _on_section_destroyed(section) -> void:
	_placed.erase(section)
	if _world and _world.has_method("request_navmesh_rebake"):
		_world.request_navmesh_rebake("sandbag breached")

func placed_obstacles() -> Array:
	_placed = _placed.filter(func(o): return is_instance_valid(o))
	return _placed

## Take ownership of obstacles that were rebuilt from a saved snapshot rather
## than placed by hand. Everything the placement path wires up has to be wired
## up here too, or restored sandbags would silently stop triggering a rebake
## when breached and the placement cap would under-count the real base.
func adopt(obstacles: Array) -> void:
	for entry in obstacles:
		if not is_instance_valid(entry):
			continue
		_placed.append(entry)
		var section := entry as SandbagSection
		if section != null and not section.destroyed_section.is_connected(_on_section_destroyed):
			section.destroyed_section.connect(_on_section_destroyed)
		# A restored ditch needs its ground hole and navmesh mouth patch
		# re-registered against the FRESH scene's ground/navmesh — GameState
		# only persists {type, pos, yaw}, not those world-level side effects.
		var ditch := entry as ZombieDitch
		if ditch != null:
			ditch.finalize_in_world(_world)
	_seal_cache_key = ""      # roster changed; recompute the seal test
	_refresh()

## Snapshot the current base into GameState. Call before any scene change.
func capture_state() -> void:
	GameState.capture(placed_obstacles())

# --- Camera control -------------------------------------------------------
func _process(delta: float) -> void:
	if not active:
		return
	var pan := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		pan.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		pan.z += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		pan.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		pan.x += 1.0
	if pan != Vector3.ZERO:
		# Scale pan with zoom so it feels the same at any magnification.
		var scale := _cam.size / default_zoom
		_move_camera(pan.normalized() * pan_speed * scale * delta)
	_update_ghost()

## Panning is keyboard-only. Middle-mouse drag was tried and removed: the
## build UI sits on a CanvasLayer above the viewport and swallowed the motion
## events before _unhandled_input saw them, and the mouse is needed for ghost
## placement anyway.
func _move_camera(delta_pos: Vector3) -> void:
	var p := _cam.position + delta_pos
	p.x = clampf(p.x, -pan_limit, pan_limit)
	p.z = clampf(p.z, -pan_limit, pan_limit)
	p.y = camera_height
	_cam.position = p

func _zoom(step: float) -> void:
	_cam.size = clampf(_cam.size + step, min_zoom, max_zoom)

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				close()
			KEY_BRACKETLEFT:
				_zoom(-zoom_step)
			KEY_BRACKETRIGHT:
				_zoom(zoom_step)
			_:
				return
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton and event.pressed:
		# With an obstacle selected the wheel rotates it; otherwise it zooms.
		# [ ] always zoom, so rotation never costs you camera control.
		var rotating: bool = _selected_id != ""
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if rotating:
				_rotate_ghost(1, event.shift_pressed)
			else:
				_zoom(-zoom_step)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if rotating:
				_rotate_ghost(-1, event.shift_pressed)
			else:
				_zoom(zoom_step)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_try_place()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			# Right-click a damaged section to repair it, or a spent
			# minefield to replenish it.
			_try_service_under_cursor()
			get_viewport().set_input_as_handled()

## Repair / replenish whatever is under the cursor, priced by what's missing.
func _try_service_under_cursor() -> void:
	var p := cursor_ground_point()
	var best = null
	var best_d := 3.0
	for o in placed_obstacles():
		var d: float = Vector2(o.global_position.x - p.x, o.global_position.z - p.z).length()
		if o is SandbagSection:
			d = Vector2(o.nearest_point(p).x - p.x, o.nearest_point(p).z - p.z).length()
		if d < best_d:
			best_d = d
			best = o
	if best == null:
		return

	if best is SandbagSection:
		if best.health_fraction() >= 0.999:
			_reason_label.text = "That section is undamaged"
			return
		var cost: int = best.repair_cost(ObstacleCatalog.get_type("sandbags").cost)
		if not PointsManager.spend_points(cost):
			_fail("Repair needs %d pts" % cost)
			return
		best.repair()
		_status("Section repaired — %d pts" % cost)
	elif best is Minefield:
		if best.mines_remaining >= best.mine_count:
			_reason_label.text = "That field is fully stocked"
			return
		var cost2: int = REPLENISH_COST
		if not PointsManager.spend_points(cost2):
			_fail("Replenish needs %d pts" % cost2)
			return
		best.replenish()
		_status("Minefield replenished — %d pts" % cost2)
	_refresh()

func _status(msg: String) -> void:
	_reason_label.text = msg
	_reason_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	if _sfx_confirm.stream:
		_sfx_confirm.play()

func _fail(msg: String) -> void:
	_reason_label.text = msg
	_reason_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.45))
	if _sfx_deny.stream:
		_sfx_deny.play()
	# Panning is WASD only — see the note on _move_camera.

## Rotation persists between placements so parallel runs are quick to lay.
func _rotate_ghost(dir: int, free: bool) -> void:
	if free:
		_ghost_yaw += dir * deg_to_rad(2.0)
	else:
		# Snap to the step grid, then advance one step.
		var step := deg_to_rad(rotation_step_deg)
		_ghost_yaw = (round(_ghost_yaw / step) + dir) * step
	_ghost_yaw = wrapf(_ghost_yaw, 0.0, TAU)
	_seal_cache_key = ""

## World point under the cursor on the ground plane (y = 0). Used by the ghost
## placement in the next section.
func cursor_ground_point() -> Vector3:
	var mouse := get_viewport().get_mouse_position()
	var from := _cam.project_ray_origin(mouse)
	var dir := _cam.project_ray_normal(mouse)
	if absf(dir.y) < 0.0001:
		return Vector3.ZERO
	var t := -from.y / dir.y
	return from + dir * t
