extends CanvasLayer
class_name RosterMenu
## The fighter roster: Day-only, F to open, lists every living fighter with
## its permanent rolled stats and lifetime record, and is where recruiting,
## upgrading and suppressor purchases happen.
##
## MINIMAL BY DESIGN. This is the roster the pricing/pause step (Step 7)
## needs to make Decision A and Decision B real and testable — not the full
## original spec (world-space selection highlight, sort/group at the 8-cap,
## a dedicated memorial UI). Those are deferred; see the memorial note below
## for what stands in for them here.
##
## OWNS NO PLACEMENT OR COMBAT CODE. Recruiting spawns a fighter via a
## Callable supplied by Main (the same spawn-in-front-of-player logic the
## debug F6 key already uses) — this menu does not reason about world space
## itself. Damage and death are Fighter's own (via the shared
## AreaDamageSystem); this menu only reads the result.

const ACTION_OPEN := "roster_menu"

@export var economy: FighterEconomyConfig

var _player: Player
var _hud: HUD
## Supplied by Main: spawns and returns a freshly-recruited Fighter positioned
## in the world. This menu never touches world space itself.
var _spawn_fighter_fn: Callable

var _open := false
var _panel: PanelContainer
var _points_label: Label
var _rows_box: VBoxContainer
## Fighters that have died since the menu was last built are listed here for
## the session — a lightweight stand-in for the original spec's dedicated
## memorial screen. {name, hit_chance, damage, upgrade_tier, kills} snapshots,
## taken in _on_fighter_died() before the node frees.
var _memorial: Array = []

func setup(player: Player, hud: HUD, econ: FighterEconomyConfig,
		spawn_fighter_fn: Callable) -> void:
	_player = player
	_hud = hud
	economy = econ
	_spawn_fighter_fn = spawn_fighter_fn
	economy.validate()
	# Every LIVE fighter at setup time (debug-spawned ones from before the
	# menu existed) needs its death caught too.
	for f in get_tree().get_nodes_in_group(Fighter.GROUP):
		_watch(f as Fighter)

func _ready() -> void:
	layer = 18   # above the HUD (10) and the roster's own world markers,
	             # below the crate store (20) — the two never overlap in
	             # practice since the crate has its own Day/open-menu gate.
	visible = false

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(420, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.05, 0.92)
	sb.border_color = Color(0.5, 0.7, 0.75, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 16
	sb.content_margin_bottom = 16
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	_panel.add_child(root)

	var title := Label.new()
	title.text = "— FIGHTER ROSTER —"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)

	_points_label = Label.new()
	_points_label.add_theme_font_size_override("font_size", 14)
	_points_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_points_label)
	root.add_child(HSeparator.new())

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 4)
	root.add_child(_rows_box)

	var hint := Label.new()
	hint.text = "[F] / [Esc] Close"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(hint)

func _process(_delta: float) -> void:
	if _open:
		_refresh()   # live stats — points balance and any mid-view change

func is_open() -> bool:
	return _open

# --- Open / close --------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		if event.is_action_pressed(ACTION_OPEN):
			_try_open()
			get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE or event.is_action_pressed(ACTION_OPEN):
			_close()
			get_viewport().set_input_as_handled()

func _try_open() -> void:
	if not GameManager.is_day():
		if _hud:
			_hud.show_message("The roster is only reachable by day.")
		return
	if _player == null or not _player.control_enabled:
		return
	_open = true
	visible = true
	GameManager.request_clock_halt("roster_menu")
	_player.set_control_enabled(false)
	_player._set_mouse_captured(false)
	_refresh()

func _close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	# Matched 1:1 with the request in _try_open() — every exit path (Esc, the
	# open key toggling closed, and _exit_tree() below for a scene teardown
	# mid-session) routes through this one function, so there is exactly one
	# place the release can be forgotten rather than N.
	GameManager.release_clock_halt("roster_menu")
	if _player:
		_player.set_control_enabled(true)
		_player._set_mouse_captured(true)

## Belt-and-suspenders: if this node is freed while open (scene teardown),
## the halt must not outlive it and silently block Night forever.
func _exit_tree() -> void:
	if _open:
		GameManager.release_clock_halt("roster_menu")

# --- Fighter death tracking -----------------------------------------------
func _watch(f: Fighter) -> void:
	if f == null or not is_instance_valid(f):
		return
	if not f.died.is_connected(_on_fighter_died):
		f.died.connect(_on_fighter_died.bind(f))

func _on_fighter_died(f: Fighter) -> void:
	_memorial.append({
		"name": f.fighter_name, "hit_chance": f.hit_chance, "damage": f.damage,
		"upgrade_tier": f.upgrade_tier, "kills": f.kills,
	})

# --- Rows ------------------------------------------------------------------
func _refresh() -> void:
	_points_label.text = "Points: %d" % PointsManager.points
	for c in _rows_box.get_children():
		c.queue_free()

	var fighters := _live_fighters()
	if fighters.is_empty():
		var empty := Label.new()
		empty.text = "No fighters recruited."
		empty.add_theme_font_size_override("font_size", 13)
		empty.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_rows_box.add_child(empty)
	else:
		for f in fighters:
			_rows_box.add_child(_build_fighter_row(f as Fighter))

	_rows_box.add_child(HSeparator.new())
	_rows_box.add_child(_build_recruit_row(fighters.size()))

	if not _memorial.is_empty():
		_rows_box.add_child(HSeparator.new())
		var mtitle := Label.new()
		mtitle.text = "— Memorial —"
		mtitle.add_theme_font_size_override("font_size", 12)
		mtitle.add_theme_color_override("font_color", Color(0.55, 0.5, 0.5))
		mtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_rows_box.add_child(mtitle)
		for m in _memorial:
			var row := Label.new()
			row.add_theme_font_size_override("font_size", 12)
			row.add_theme_color_override("font_color", Color(0.55, 0.5, 0.5))
			row.text = "  %s — T%d, hit %.0f%%, dmg %d, %d kills" % [
				m["name"], m["upgrade_tier"], m["hit_chance"] * 100.0,
				m["damage"], m["kills"]]
			_rows_box.add_child(row)

func _live_fighters() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group(Fighter.GROUP):
		var f := node as Fighter
		if f != null and is_instance_valid(f) and f.is_alive():
			out.append(f)
	return out

func _build_fighter_row(f: Fighter) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)

	var stat := Label.new()
	stat.add_theme_font_size_override("font_size", 13)
	stat.text = f.stat_line()
	box.add_child(stat)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)

	if f.upgrade_tier < 3:
		var cost := _upgrade_cost(f.upgrade_tier)
		var btn := Button.new()
		btn.text = "Upgrade T%d (%d pts)" % [f.upgrade_tier + 1, cost]
		btn.disabled = PointsManager.points < cost
		btn.pressed.connect(_on_upgrade_pressed.bind(f, cost))
		buttons.add_child(btn)

	if not f.suppressed:
		var sbtn := Button.new()
		sbtn.text = "Suppress (%d pts)" % economy.suppressor_cost
		sbtn.disabled = PointsManager.points < economy.suppressor_cost
		sbtn.pressed.connect(_on_suppress_pressed.bind(f))
		buttons.add_child(sbtn)

	box.add_child(buttons)
	return box

func _build_recruit_row(live_count: int) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 13)

	if live_count >= FighterEconomyConfig.FIGHTER_CAP:
		label.text = "Roster full (%d/%d)" % [live_count, FighterEconomyConfig.FIGHTER_CAP]
		row.add_child(label)
		return row

	# Fighters 1-4 are free (debug/Position-Two-stand-in grants); the recruit
	# curve applies from the 5th onward — index 0 of recruit_costs IS the 5th
	# fighter's price. A live_count below that free allotment shows as free
	# rather than indexing before the array.
	var free_slots := FighterEconomyConfig.FIGHTER_CAP - economy.recruit_costs.size()
	var cost := 0
	if live_count >= free_slots:
		cost = economy.recruit_costs[live_count - free_slots]

	var btn := Button.new()
	btn.text = "Recruit (%s)" % ("free" if cost == 0 else "%d pts" % cost)
	btn.disabled = PointsManager.points < cost
	btn.pressed.connect(_on_recruit_pressed.bind(cost))
	row.add_child(btn)
	return row

func _upgrade_cost(current_tier: int) -> int:
	match current_tier:
		0: return economy.upgrade_tier1_cost
		1: return economy.upgrade_tier2_cost
		_: return economy.upgrade_tier3_cost

# --- Purchases ---------------------------------------------------------------
func _on_upgrade_pressed(f: Fighter, cost: int) -> void:
	if not is_instance_valid(f) or not f.is_alive():
		return
	if not PointsManager.spend_points(cost):
		return
	f.upgrade()
	_refresh()

func _on_suppress_pressed(f: Fighter) -> void:
	if not is_instance_valid(f) or not f.is_alive():
		return
	if not PointsManager.spend_points(economy.suppressor_cost):
		return
	f.apply_suppressor()
	_refresh()

func _on_recruit_pressed(cost: int) -> void:
	if cost > 0 and not PointsManager.spend_points(cost):
		return
	if not _spawn_fighter_fn.is_valid():
		return
	var f: Fighter = _spawn_fighter_fn.call()
	_watch(f)
	_refresh()
