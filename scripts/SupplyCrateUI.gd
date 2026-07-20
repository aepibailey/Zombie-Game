extends CanvasLayer
class_name SupplyCrateUI
## Minimal supply-crate shop (Day-only). Shows current points and a single
## purchase: the M17 suppressor. Buying it attaches a SuppressorResource to the
## player, proving the attachment pipeline end-to-end (PROJECT_SPEC.md acceptance).

const SUPPRESSOR_COST := 3

var _player = null  # untyped: the player exposes a custom API off CharacterBody3D
var _panel: PanelContainer
var _points_label: Label
var _status_label: Label
var _buy_button: Button

func _ready() -> void:
	layer = 20
	visible = false

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(360, 220)
	add_child(_panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	_panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	margin.add_child(vb)

	var title := Label.new()
	title.text = "— SUPPLY CRATE (Day) —"
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	_points_label = Label.new()
	_points_label.add_theme_font_size_override("font_size", 18)
	vb.add_child(_points_label)

	_buy_button = Button.new()
	_buy_button.text = "Buy Suppressor — %d pts" % SUPPRESSOR_COST
	_buy_button.pressed.connect(_on_buy_pressed)
	vb.add_child(_buy_button)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	vb.add_child(_status_label)

	var close := Button.new()
	close.text = "Close (Esc)"
	close.pressed.connect(close_crate)
	vb.add_child(close)

	PointsManager.points_changed.connect(func(_p): _refresh())

func open_crate(player) -> void:
	_player = player
	visible = true
	player.set_control_enabled(false)
	player._set_mouse_captured(false)
	_status_label.text = ""
	_refresh()

func close_crate() -> void:
	if not visible:
		return
	visible = false
	if _player:
		_player.set_control_enabled(true)
		_player._set_mouse_captured(true)

func is_open() -> bool:
	return visible

func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_crate()
		get_viewport().set_input_as_handled()

func _refresh() -> void:
	_points_label.text = "Points available: %d" % PointsManager.points
	var owned: bool = _player != null and _player.has_suppressor()
	if owned:
		_buy_button.disabled = true
		_buy_button.text = "Suppressor — OWNED"
	else:
		_buy_button.disabled = PointsManager.points < SUPPRESSOR_COST
		_buy_button.text = "Buy Suppressor — %d pts" % SUPPRESSOR_COST

func _on_buy_pressed() -> void:
	if _player == null or _player.has_suppressor():
		return
	if PointsManager.spend_points(SUPPRESSOR_COST):
		# Load the resource asset and hand a fresh copy to the weapon.
		var res = load("res://resources/Suppressor.tres").duplicate()
		_player.attach_suppressor(res)
		_status_label.text = "Purchased! Next shot is quiet (8m)."
	else:
		_status_label.text = "Not enough points."
	_refresh()
