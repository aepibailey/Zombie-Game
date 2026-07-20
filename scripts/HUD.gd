extends CanvasLayer
class_name HUD
## Minimal greybox HUD: phase/time, points, health, ammo, movement state, a
## crosshair, and a transient message line. Built entirely in code so there's
## no fragile .tscn wiring for v1.

var _clock_label: Label
var _points_label: Label
var _health_label: Label
var _ammo_label: Label
var _state_label: Label
var _supp_label: Label
var _msg_label: Label
var _crosshair: Label
var _msg_timer := 0.0

func _ready() -> void:
	layer = 10
	var panel := VBoxContainer.new()
	panel.position = Vector2(16, 12)
	panel.add_theme_constant_override("separation", 2)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	_points_label = _mk(panel)
	_health_label = _mk(panel)
	_ammo_label = _mk(panel)
	_state_label = _mk(panel)
	_supp_label = _mk(panel)

	_build_clock()

	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.add_theme_font_size_override("font_size", 26)
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_crosshair.grow_vertical = Control.GROW_DIRECTION_BOTH
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_crosshair)

	_msg_label = Label.new()
	_msg_label.add_theme_font_size_override("font_size", 18)
	_msg_label.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	_msg_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_msg_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_msg_label.position.y = -80
	_msg_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_msg_label)

	# Autoload wiring.
	PointsManager.points_changed.connect(_on_points_changed)
	GameManager.time_updated.connect(_on_time_updated)
	_on_points_changed(PointsManager.points)

# Top-center day/night clock. A translucent backing panel keeps the readout
# legible against bright day skies as well as dark night lighting.
func _build_clock() -> void:
	var clock_panel := PanelContainer.new()
	clock_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	clock_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	clock_panel.position.y = 10
	clock_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.45)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	clock_panel.add_theme_stylebox_override("panel", sb)
	add_child(clock_panel)

	_clock_label = Label.new()
	_clock_label.add_theme_font_size_override("font_size", 30)
	_clock_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_clock_label.add_theme_constant_override("outline_size", 6)
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clock_panel.add_child(_clock_label)

func _mk(parent: Node) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l

## Called by Main once the player exists so we can subscribe to its signals.
## `player` is intentionally untyped so its custom signals/API resolve dynamically.
func bind_player(player) -> void:
	player.ammo_changed.connect(_on_ammo_changed)
	player.health_changed.connect(_on_health_changed)
	player.state_changed.connect(_on_state_changed)
	player.suppressor_changed.connect(_on_suppressor_changed)
	player.message.connect(show_message)
	# The player's _ready() emitted its initial values before we connected,
	# so pull the current state once to seed the labels.
	_on_ammo_changed(player.ammo, player.reserve)
	_on_health_changed(player.hp, player.MAX_HP)
	_on_state_changed(player._state_label())
	_on_suppressor_changed(player.has_suppressor())

func _process(delta: float) -> void:
	if _msg_timer > 0.0:
		_msg_timer -= delta
		if _msg_timer <= 0.0:
			_msg_label.text = ""

func _on_time_updated(time_left: float, phase: int) -> void:
	var t: int = maxi(0, int(ceil(time_left)))
	var is_day := phase == GameManager.Phase.DAY
	var phase_str := "DAY" if is_day else "NIGHT"
	_clock_label.text = "%s   %02d:%02d" % [phase_str, t / 60, t % 60]
	# Warm for day, cool for night — both stay bright over the backing panel.
	_clock_label.add_theme_color_override("font_color",
		Color(1.0, 0.95, 0.7) if is_day else Color(0.72, 0.86, 1.0))

func _on_points_changed(points: int) -> void:
	_points_label.text = "Points: %d" % points

func _on_health_changed(hp: int, max_hp: int) -> void:
	_health_label.text = "HP: %d / %d" % [hp, max_hp]

func _on_ammo_changed(loaded: int, reserve: int) -> void:
	_ammo_label.text = "Ammo: %d / %d" % [loaded, reserve]

func _on_state_changed(state_name: String) -> void:
	_state_label.text = "Move: %s" % state_name

func _on_suppressor_changed(has_supp: bool) -> void:
	_supp_label.text = "Weapon: M17" + ("  [Suppressed 8m]" if has_supp else "  [Unsupp. 40m]")

func show_message(text: String) -> void:
	_msg_label.text = text
	_msg_timer = 2.5
