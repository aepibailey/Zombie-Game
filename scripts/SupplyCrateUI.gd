extends CanvasLayer
class_name SupplyCrateUI
## Supply-crate store (Day-only), built from the StoreCatalog autoload.
##
## Tabs are generated from `StoreCatalog.categories()`, so adding an item with
## a new category produces a working tab with NO changes here. Item rows render
## in one of four states: affordable / unaffordable / owned / locked.

const SFX_CONFIRM := "res://assets/audio/ui/ui_confirm.wav"
const SFX_DENY := "res://assets/audio/ui/ui_deny.wav"

var _player: Player = null
var _points_label: Label
var _hp_label: Label
var _status_label: Label
var _tab_bar: HBoxContainer
var _list: VBoxContainer
var _tab_buttons: Dictionary = {}   # category -> Button
var _categories: Array = []
var _hint_label: Label
var _current := ""
var _sfx_confirm: AudioStreamPlayer
var _sfx_deny: AudioStreamPlayer

func _ready() -> void:
	layer = 20
	visible = false

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(600, 520)
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "— SUPPLY CRATE —"
	title.add_theme_font_size_override("font_size", 20)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	# Points balance: always visible, on every tab.
	# HP is prominent because the store no longer pauses the game — zombies can
	# reach you while you shop.
	_hp_label = Label.new()
	_hp_label.add_theme_font_size_override("font_size", 20)
	header.add_child(_hp_label)

	var spacer := Label.new()
	spacer.text = "   "
	header.add_child(spacer)

	_points_label = Label.new()
	_points_label.add_theme_font_size_override("font_size", 20)
	_points_label.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	header.add_child(_points_label)

	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 6)
	root.add_child(_tab_bar)

	root.add_child(HSeparator.new())

	# Item rows live in a scroll container so long tabs stay usable.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	root.add_child(_status_label)

	_hint_label = Label.new()
	_hint_label.add_theme_font_size_override("font_size", 12)
	_hint_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	root.add_child(_hint_label)

	_build_tabs()
	# Blocked states can depend on the phase (Day-only items), so the rows
	# have to re-render when the sun goes down mid-shop — the crate stays
	# open across the boundary.
	GameManager.phase_changed.connect(func(_p):
		if visible:
			_refresh.call_deferred())
	_sfx_confirm = _mk_sfx(SFX_CONFIRM)
	_sfx_deny = _mk_sfx(SFX_DENY)
	PointsManager.points_changed.connect(func(_p): _refresh.call_deferred())

func _mk_sfx(path: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	if ResourceLoader.exists(path):
		var res = load(path)
		p.stream = res
	add_child(p)
	return p

# --- Tabs (generated from the catalog) ------------------------------------
func _build_tabs() -> void:
	for child in _tab_bar.get_children():
		child.queue_free()
	_tab_buttons.clear()
	_categories = StoreCatalog.categories()
	for c in _categories:
		var btn := Button.new()
		btn.text = c
		btn.toggle_mode = true
		btn.pressed.connect(_select_tab.bind(c))
		_tab_bar.add_child(btn)
		_tab_buttons[c] = btn
	if _current == "" or not (_current in _categories):
		_current = _categories[0] if _categories.size() > 0 else ""
	_refresh_hint()

## Number-key hint is DERIVED from the tab count, not spelled out. It used to
## read a literal "1/2/3", which silently became wrong the moment a fourth
## category was added to the catalog — the exact kind of hardcoding the
## "adding a tab is config" claim is supposed to rule out.
func _refresh_hint() -> void:
	if _hint_label == null:
		return
	var keys: Array = []
	# Bounded by the number keys _unhandled_input() actually binds (1-4).
	for i in range(mini(_categories.size(), 4)):
		keys.append(str(i + 1))
	var key_text: String = "/".join(keys) if keys.size() > 0 else "—"
	_hint_label.text = "Tabs: click · %s · ←/→     Esc to close" % key_text

func _select_tab(category: String) -> void:
	if category == "" or not (category in _categories):
		return
	_current = category
	_refresh()

func _cycle_tab(step: int) -> void:
	if _categories.is_empty():
		return
	var i: int = _categories.find(_current)
	if i < 0:
		i = 0
	_select_tab(_categories[wrapi(i + step, 0, _categories.size())])

# --- Open / close ---------------------------------------------------------
func open_crate(player: Player) -> void:
	_player = player
	if not player.died_while_busy.is_connected(_on_player_died):
		player.died_while_busy.connect(_on_player_died)
	visible = true
	# Cursor visible, camera look + movement disabled while shopping.
	player.set_control_enabled(false)
	player._set_mouse_captured(false)
	_status_label.text = ""
	_current = _categories[0] if _categories.size() > 0 else ""   # default: WEAPONS
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

## Player died mid-shop: shut cleanly so control and mouse capture are restored
## and the normal death flow isn't blocked behind a modal.
func _on_player_died() -> void:
	if visible:
		close_crate()

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey and event.pressed and not event.echo):
		return
	# NOTE: tab switching deliberately avoids E (the interact key).
	match event.keycode:
		KEY_ESCAPE:
			close_crate()
		KEY_LEFT:
			_cycle_tab(-1)
		KEY_RIGHT:
			_cycle_tab(1)
		KEY_1, KEY_2, KEY_3, KEY_4:
			var idx: int = event.keycode - KEY_1
			if idx < _categories.size():
				_select_tab(_categories[idx])
		_:
			return
	get_viewport().set_input_as_handled()

# --- Rendering ------------------------------------------------------------
func _process(_delta: float) -> void:
	# The game keeps running while the store is open, so HP must stay live.
	if visible and _player:
		_update_hp_label()

func _update_hp_label() -> void:
	var hp: int = _player.hp
	_hp_label.text = "HP: %d" % hp
	var danger: bool = hp <= 40
	_hp_label.add_theme_color_override("font_color",
		Color(1.0, 0.35, 0.3) if danger else Color(0.6, 1.0, 0.6))

func _refresh() -> void:
	_points_label.text = "Points: %d" % PointsManager.points
	if _player:
		_update_hp_label()
	for c in _categories:
		_tab_buttons[c].button_pressed = (c == _current)
	if _player == null:
		return

	# Detach immediately (so old rows don't render for a frame) but free
	# deferred — a row's own Button may be mid-`pressed` emission right now.
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	var owned_weapons = _player.owned_weapons()
	var last_group := ""
	for item in StoreCatalog.items_in(_current):
		# Attachments and ammo are hidden until the parent weapon is owned.
		if item.kind in ["ammo", "attachment"] and item.weapon_id != "":
			if not (item.weapon_id in owned_weapons):
				continue
			# Group visually by parent weapon.
			if item.weapon_id != last_group:
				last_group = item.weapon_id
				_add_group_header(Arsenal.get_weapon(item.weapon_id).display_name)
		_add_row(item)

	if _list.get_child_count() == 0:
		var empty := Label.new()
		empty.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
		# Only the weapon-gated tabs can be empty for that reason; a tab whose
		# items are unconditional (EQUIPMENT) would be lying with that copy.
		empty.text = "Nothing available here yet."
		if _current in ["ATTACHMENTS", "SUPPLIES"]:
			empty.text += " Attachments and ammo unlock with the weapon they fit."
		_list.add_child(empty)

func _add_group_header(text: String) -> void:
	var l := Label.new()
	l.text = "▸ " + text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	_list.add_child(l)

## Ammo cost/quantity is normally static (item.cost), but the Extended Drum
## scales both to match its 200-round belt — see Player.ammo_purchase_cost().
func _display_cost(item) -> int:
	if item.kind == "ammo":
		return _player.ammo_purchase_cost(item.weapon_id)
	return item.cost

func _add_row(item) -> void:
	var owned: bool = _player.owns_store_item(item)
	var locked_by := _missing_prerequisite(item)
	var blocked := _player.store_item_blocked(item)   # e.g. "CARRYING 3/3"
	var cost: int = _display_cost(item)
	var affordable: bool = PointsManager.points >= cost

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_list.add_child(row)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)

	var name_label := Label.new()
	name_label.text = item.display_name
	name_label.add_theme_font_size_override("font_size", 16)
	text.add_child(name_label)

	var desc := Label.new()
	desc.add_theme_font_size_override("font_size", 12)
	desc.text = item.description
	if item.kind == "ammo":
		var mags := _player.ammo_purchase_magazines(item.weapon_id)
		if mags > 1:
			var w = Arsenal.get_weapon(item.weapon_id)
			desc.text = "+%d rounds (full drum)." % (w.mag_size * mags)
		desc.text += "  ·  reserve: %d" % AmmoManager.get_reserve(item.weapon_id)
	if locked_by != "":
		desc.text = "Requires: %s" % locked_by
	desc.add_theme_color_override("font_color", Color(0.72, 0.72, 0.72))
	text.add_child(desc)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(150, 0)
	row.add_child(btn)

	# --- Visual states ---
	if blocked != "":
		btn.text = blocked
		btn.disabled = true
		row.modulate = Color(0.62, 0.62, 0.62)
		name_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	elif owned:
		btn.text = "OWNED"
		btn.disabled = true
		row.modulate = Color(0.62, 0.62, 0.62)
		name_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	elif locked_by != "":
		btn.text = "LOCKED"
		btn.disabled = true
		row.modulate = Color(0.5, 0.5, 0.5)
	elif not affordable:
		btn.text = "%d pts" % cost
		btn.disabled = true
		row.modulate = Color(0.62, 0.62, 0.62)
		# Cost highlighted so it's clear WHY it's unavailable.
		btn.add_theme_color_override("font_color_disabled", Color(1.0, 0.4, 0.35))
	else:
		btn.text = "Buy — %d pts" % cost
		btn.pressed.connect(_on_buy.bind(item))

# --- Purchase -------------------------------------------------------------
func _on_buy(item) -> void:
	if _player == null:
		return
	if _player.owns_store_item(item):
		return
	var blocked := _player.store_item_blocked(item)
	if blocked != "":
		_fail("%s — %s" % [item.display_name, blocked])
		return
	var locked_by := _missing_prerequisite(item)
	if locked_by != "":
		_fail("Requires %s first." % locked_by)
		return
	if not PointsManager.spend_points(_display_cost(item)):
		_fail("Not enough points for %s." % item.display_name)
		return
	_status_label.text = _player.apply_store_purchase(item)
	_status_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	if _sfx_confirm.stream:
		_sfx_confirm.play()
	# Deferred: we're inside the pressed-signal of a button this rebuild frees.
	# State still flips immediately (same frame) — no reopen needed.
	_refresh.call_deferred()

func _fail(msg: String) -> void:
	_status_label.text = msg
	_status_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	if _sfx_deny.stream:
		_sfx_deny.play()

## Returns the display name of an unmet prerequisite, or "" if satisfied.
func _missing_prerequisite(item) -> String:
	var req: String = item.requires
	if req == "" or _player == null:
		return ""
	if _player.owns_item_id(req):
		return ""
	var w = Arsenal.get_weapon(req)
	if w:
		return w.display_name
	var other = StoreCatalog.get_item(req)
	return other.display_name if other else req
