extends CanvasLayer
class_name RadioMenu
## T opens a compact, NON-PAUSING transmission selector. Built entirely in
## code, matching every other UI in this project (HUD, SupplyCrateUI).
##
## Deliberately NOT a Control-driven point-and-click UI: every requirement
## here is keyboard/RMB-only (open on T, select with 1-9, close with Esc or
## RMB), so there are no Buttons and no mouse-click handling — the mouse
## stays captured the whole time, just with look-rotation suppressed (see
## Player.set_radio_menu_open()) so the camera doesn't spin while reading.
##
## Lists whatever is in EnablerManager.callable_enablers, which is genuinely
## empty until the first real enabler (UAV, Supply Drop, ...) registers one.
## "No transmissions available" is what an empty list renders as — this is
## NOT a fake/stub entry, it's the list telling the truth about its contents.

const ACTION_OPEN := "radio_menu"
const RADIO_ITEM_ID := "radio"

## Fixed radio noise: the sound of a human voice on a handset, identical for
## every transmission regardless of what's being called in. Lives here, NOT
## as a per-EnablerType field — a mortar strike and a supply drop sound
## exactly the same to key up. Fires on SELECTION CONFIRM only; browsing the
## list is silent, since you're only reading, not transmitting.
const TRANSMISSION_NOISE_RADIUS := 10.0
const TRANSMISSION_NOISE_DURATION := 3.0
const TRANSMISSION_NOISE_INTERVAL := 0.5

var _player: Player
var _hud: HUD

var _panel: PanelContainer
var _title_label: Label
var _rows_box: VBoxContainer
var _hint_label: Label

var _open := false
## Repeating noise pulse in progress after a confirmed selection. Tracked
## here (not a Timer node) because it needs to read the player's CURRENT
## position every pulse — the handset is on them, so the noise follows if
## they move mid-transmission, not fixed to where they stood when they keyed
## the mic.
var _noise_time_remaining := 0.0
var _noise_pulse_accum := 0.0

func setup(player: Player, hud: HUD) -> void:
	_player = player
	_hud = hud

func _ready() -> void:
	layer = 15   # above the HUD (10), below the store (20) — they shouldn't overlap in practice
	visible = false

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(280, 0)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.04, 0.88)
	sb.border_color = Color(0.5, 0.75, 0.55, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	_panel.add_child(root)

	_title_label = Label.new()
	_title_label.text = "— RADIO —"
	_title_label.add_theme_font_size_override("font_size", 18)
	_title_label.add_theme_color_override("font_color", Color(0.85, 1.0, 0.88))
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_title_label)
	root.add_child(HSeparator.new())

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 3)
	root.add_child(_rows_box)

	_hint_label = Label.new()
	_hint_label.add_theme_font_size_override("font_size", 12)
	_hint_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	_hint_label.text = "[Esc] / [RMB] Close"
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_hint_label)

func _process(delta: float) -> void:
	_update_noise_pulse(delta)

# --- Open / close -----------------------------------------------------------
func is_open() -> bool:
	return _open

func _open_menu() -> void:
	if _open:
		return
	_open = true
	visible = true
	_player.set_radio_menu_open(true)
	_refresh()

func _close_menu() -> void:
	if not _open:
		return
	_open = false
	visible = false
	_player.set_radio_menu_open(false)

# --- Input -------------------------------------------------------------------
## Entirely keyboard/RMB — no Button nodes, so no click handling anywhere
## here. Movement (WASD) is untouched; only camera rotation is suppressed,
## via Player.set_radio_menu_open(), not anything in this script.
func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		# T to open — but only while the player can actually act (mirrors
		# every other action key's own control_enabled gate) and only once
		# the Radio has actually been bought. is_action_pressed() already
		# excludes key-repeat echo events on its own.
		if event.is_action_pressed(ACTION_OPEN):
			_try_open()
			get_viewport().set_input_as_handled()
		return

	# From here down, the menu is OPEN and owns input.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_close_menu()
			get_viewport().set_input_as_handled()
			return
		# T while ALREADY open does nothing — the spec's own exit list is
		# "Escape or right mouse button", not T. Re-pressing T is simply
		# swallowed rather than falling through to anything else.
		if event.is_action_pressed(ACTION_OPEN):
			get_viewport().set_input_as_handled()
			return
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			_select(event.keycode - KEY_1)
			get_viewport().set_input_as_handled()
			return
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		_close_menu()
		get_viewport().set_input_as_handled()

func _try_open() -> void:
	if not _player.control_enabled:
		return
	if not _player.owns_item_id(RADIO_ITEM_ID):
		# Matches EngineersTentZone's own convention for external denial
		# feedback — straight to HUD, not through the player's own signal.
		if _hud:
			_hud.show_message("No radio.")
		return
	_open_menu()

# --- Rows --------------------------------------------------------------------
func _refresh() -> void:
	for c in _rows_box.get_children():
		c.queue_free()

	var entries: Array = EnablerManager.callable_enablers
	if entries.is_empty():
		var empty := Label.new()
		empty.text = "No transmissions available."
		empty.add_theme_font_size_override("font_size", 14)
		empty.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_rows_box.add_child(empty)
		return

	for i in entries.size():
		_rows_box.add_child(_build_row(i, entries[i]))

## Duck-typed against the minimal shape documented on
## EnablerManager.callable_enablers — reads id/display_name/cost, and treats
## an entry as available if it's affordable. Cooldown/travel-state greying
## has nothing to read yet (no enabler carries that data today) and will
## need a real field once one exists; not invented here.
func _build_row(index: int, entry) -> Label:
	var id: String = entry.get("id", "") if entry is Dictionary else str(entry.id)
	var name: String = entry.get("display_name", id) if entry is Dictionary else str(entry.display_name)
	var cost: int = entry.get("cost", 0) if entry is Dictionary else int(entry.cost)
	var affordable: bool = PointsManager.points >= cost

	var row := Label.new()
	row.add_theme_font_size_override("font_size", 15)
	row.text = "[%d] %s — %d pts" % [index + 1, name, cost]
	row.add_theme_color_override("font_color",
		Color(0.95, 0.95, 0.9) if affordable else Color(0.55, 0.55, 0.55))
	return row

## Selection HANDS OFF to the enabler's own call flow — this menu builds no
## targeting/paint logic of its own. Right now that hand-off has nothing to
## call, since callable_enablers is empty; index is always out of range and
## this is a silent no-op. Left fully wired (rather than commented out) so
## the day an entry registers, wiring an "on_selected" callback into it is
## the only change needed here.
func _select(index: int) -> void:
	var entries: Array = EnablerManager.callable_enablers
	if index < 0 or index >= entries.size():
		return
	var entry = entries[index]
	var cost: int = entry.get("cost", 0) if entry is Dictionary else int(entry.cost)
	if PointsManager.points < cost:
		return
	_close_menu()
	_start_transmission_noise()
	# TODO(future enabler pass): invoke the entry's own call flow here.

## Committing to a call makes noise; browsing never did. Pulses repeatedly
## rather than a single burst, so a zombie that enters the radius partway
## through the window still gets alerted — NoiseManager only supports a
## single instantaneous emit_noise(), so "sustained" is built as a repeating
## call on a short interval rather than a native duration parameter.
## Cancelling out of whatever the enabler does next does NOT retroactively
## silence this — the mic was already keyed.
func _start_transmission_noise() -> void:
	_noise_time_remaining = TRANSMISSION_NOISE_DURATION
	_noise_pulse_accum = 0.0
	_emit_noise_pulse()   # immediate first pulse, not delayed a full interval

func _update_noise_pulse(delta: float) -> void:
	if _noise_time_remaining <= 0.0:
		return
	_noise_time_remaining -= delta
	_noise_pulse_accum += delta
	if _noise_pulse_accum >= TRANSMISSION_NOISE_INTERVAL:
		_noise_pulse_accum = 0.0
		_emit_noise_pulse()

## Sourced from the player's CURRENT position every pulse — the handset
## follows the player if they move during the 3s window, not fixed to
## wherever they stood when they confirmed.
func _emit_noise_pulse() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	NoiseManager.emit_noise(_player.global_position, TRANSMISSION_NOISE_RADIUS)
