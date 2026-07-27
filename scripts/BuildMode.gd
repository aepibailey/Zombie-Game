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

var active := false

var _cam: Camera3D
var _player: Player = null
var _hud: HUD = null
var _ui: CanvasLayer
var _title: Label
var _points_label: Label
var _hint: Label

func _ready() -> void:
	_build_camera()
	_build_ui()
	set_process(false)
	set_process_unhandled_input(false)

func setup(player: Player, hud: HUD) -> void:
	_player = player
	_hud = hud

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

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	_hint.text = "WASD: pan     Wheel or [ ]: zoom     Esc: leave"
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
	set_process(true)
	set_process_unhandled_input(true)
	_refresh()
	opened.emit()

func close() -> void:
	if not active:
		return
	active = false
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

	if event is InputEventMouseButton:
		# Wheel zooms while nothing is selected. Once the obstacle palette
		# exists the wheel rotates the ghost instead, and [ ] remain for zoom.
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom(-zoom_step)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom(zoom_step)
			get_viewport().set_input_as_handled()
	# Panning is WASD only — see the note on _move_camera.

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
