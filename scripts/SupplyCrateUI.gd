extends CanvasLayer
class_name SupplyCrateUI
## Supply-crate shop (Day-only). Buy weapons from the arsenal and fit a
## suppressor to the currently-equipped weapon. Buttons are built once and just
## re-labelled/enabled in _refresh, so a purchase never frees a live button.
## See PROJECT_SPEC.md "Weapons" / "Attachments" / "Economy".

const SUPPRESSOR_COST := 3

var _player = null  # untyped: the player exposes a custom API off CharacterBody3D
var _points_label: Label
var _status_label: Label
var _supp_button: Button
var _weapon_buttons: Dictionary = {}   # weapon id -> Button
var _ammo_buttons: Dictionary = {}     # weapon id -> Button (buy 1 magazine)

func _ready() -> void:
	layer = 20
	visible = false

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(520, 560)
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)

	var title := Label.new()
	title.text = "— SUPPLY CRATE (Day) —"
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	_points_label = Label.new()
	_points_label.add_theme_font_size_override("font_size", 18)
	vb.add_child(_points_label)

	# One button per weapon in the roster (buy / owned / equipped).
	for id in Arsenal.order:
		var btn := Button.new()
		btn.pressed.connect(_on_buy_weapon.bind(id))
		_weapon_buttons[id] = btn
		vb.add_child(btn)

	var sep := HSeparator.new()
	vb.add_child(sep)

	# One ammo button per weapon — priced per magazine, only useful once owned.
	for id in Arsenal.order:
		var btn := Button.new()
		btn.pressed.connect(_on_buy_ammo.bind(id))
		_ammo_buttons[id] = btn
		vb.add_child(btn)

	_supp_button = Button.new()
	_supp_button.pressed.connect(_on_buy_suppressor)
	vb.add_child(_supp_button)

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
	if _player == null:
		return
	var owned = _player.owned_weapons()

	for i in Arsenal.order.size():
		var id: String = Arsenal.order[i]
		var w = Arsenal.get_weapon(id)
		var btn: Button = _weapon_buttons[id]
		if id in owned:
			btn.disabled = true
			if id == _player.current_weapon_id:
				btn.text = "%s — EQUIPPED" % w.display_name
			else:
				btn.text = "%s — owned (press %d)" % [w.display_name, i + 1]
		else:
			btn.disabled = PointsManager.points < w.cost
			btn.text = "Buy %s — %d pts" % [w.display_name, w.cost]

	# Ammo: one magazine at a time, only for weapons you actually own.
	for id in Arsenal.order:
		var w = Arsenal.get_weapon(id)
		var btn: Button = _ammo_buttons[id]
		if id in owned:
			btn.disabled = PointsManager.points < w.ammo_cost
			btn.text = "%s ammo: +1 mag (%d rds) — %d pts  [reserve %d]" % [
				w.display_name, w.mag_size, w.ammo_cost, AmmoManager.get_reserve(id)]
		else:
			btn.disabled = true
			btn.text = "%s ammo — weapon not owned" % w.display_name

	if _player.has_suppressor():
		_supp_button.disabled = true
		_supp_button.text = "%s — suppressed" % _player.weapon.display_name
	else:
		_supp_button.disabled = PointsManager.points < SUPPRESSOR_COST
		_supp_button.text = "Suppress %s — %d pts" % [_player.weapon.display_name, SUPPRESSOR_COST]

func _on_buy_weapon(id: String) -> void:
	if _player == null or id in _player.owned_weapons():
		return
	var w = Arsenal.get_weapon(id)
	# Generic prerequisite gate — unused by weapons today, but this is the hook
	# future enablers (e.g. UAV requires Radio) purchase through unchanged.
	var missing := _missing_prerequisite(w)
	if missing != "":
		_status_label.text = "Requires %s first." % missing
		return
	if PointsManager.spend_points(w.cost):
		_player.acquire_weapon(id)
		_status_label.text = "%s acquired & equipped (%d mags)." % [w.display_name, w.starting_mags]
	else:
		_status_label.text = "Not enough points."
	_refresh()

func _on_buy_ammo(id: String) -> void:
	if _player == null or not (id in _player.owned_weapons()):
		return
	var w = Arsenal.get_weapon(id)
	if PointsManager.spend_points(w.ammo_cost):
		# ALL ammo grants route through AmmoManager — never a direct write.
		var rounds: int = AmmoManager.grant_ammo(id, 1)
		_status_label.text = "+%d rounds of %s ammo." % [rounds, w.display_name]
	else:
		_status_label.text = "Not enough points."
	_refresh()

## Returns the display name of an unmet prerequisite, or "" if satisfiable.
## Items may declare `requires` (an id the player must already own).
func _missing_prerequisite(item) -> String:
	if item == null:
		return ""
	var req: String = item.requires
	if req == "":
		return ""
	if req in _player.owned_weapons():
		return ""
	var req_item = Arsenal.get_weapon(req)
	return req_item.display_name if req_item else str(req)

func _on_buy_suppressor() -> void:
	if _player == null or _player.has_suppressor():
		return
	if PointsManager.spend_points(SUPPRESSOR_COST):
		_player.attach_suppressor()
		_status_label.text = "Suppressor fitted to %s." % _player.weapon.display_name
	else:
		_status_label.text = "Not enough points."
	_refresh()
