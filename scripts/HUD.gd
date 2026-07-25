extends CanvasLayer
class_name HUD
## Minimal greybox HUD: a day/night clock, a "Night N" + wave counter, points,
## health, ammo, movement state, an interaction prompt, a transient message
## line, and the center-screen all-clear prompt. Built entirely in code so
## there's no fragile .tscn wiring for v1. No always-on crosshair — hip-fire is
## deliberately blind; ADS shows the laser dot instead.

var _clock_label: Label
var _night_label: Label
var _wave_label: Label
var _points_label: Label
var _health_label: Label
var _ammo_label: Label
var _state_label: Label
var _supp_label: Label
var _msg_label: Label
var _prompt_label: Label
var _all_clear_panel: PanelContainer
var _all_clear_label: Label
var _dmg_vignette: TextureRect
var _hitmarker: Label
var _msg_timer := 0.0
var _dmg_flash := 0.0
var _hitmarker_timer := 0.0
var _wpn_name := ""
var _wpn_mode := ""
var _wpn_suppressed := false

const DMG_FLASH_TIME := 0.45
const DMG_MAX_ALPHA := 0.75
const HITMARKER_TIME := 0.12

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
	_build_night_readout()
	_build_all_clear()
	_build_damage_vignette()
	_build_hitmarker()

	_msg_label = Label.new()
	_msg_label.add_theme_font_size_override("font_size", 18)
	_msg_label.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	_msg_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_msg_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_msg_label.position.y = -80
	_msg_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_msg_label)

	# Persistent interaction prompt (e.g. "Press E to open the supply crate"),
	# sits just below screen-centre. Shown/hidden by whatever is in range.
	_prompt_label = Label.new()
	_prompt_label.add_theme_font_size_override("font_size", 20)
	_prompt_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	_prompt_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_prompt_label.add_theme_constant_override("outline_size", 5)
	_prompt_label.set_anchors_preset(Control.PRESET_CENTER)
	_prompt_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_prompt_label.position.y = 48
	_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_label.visible = false
	add_child(_prompt_label)

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

# "Night N" plus the live wave count, stacked just under the clock.
func _build_night_readout() -> void:
	_night_label = _mk_centered(56, 20, Color(0.95, 0.9, 0.8))
	_wave_label = _mk_centered(82, 16, Color(0.9, 0.6, 0.55))
	_wave_label.visible = false   # only shown during a night

func _mk_centered(y: float, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 5)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.set_anchors_preset(Control.PRESET_CENTER_TOP)
	l.grow_horizontal = Control.GROW_DIRECTION_BOTH
	l.position.y = y
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l

# Center-screen "area clear" prompt with the two choices.
func _build_all_clear() -> void:
	_all_clear_panel = PanelContainer.new()
	_all_clear_panel.set_anchors_preset(Control.PRESET_CENTER)
	_all_clear_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_all_clear_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_all_clear_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_all_clear_panel.visible = false

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.08, 0.05, 0.85)
	sb.border_color = Color(0.5, 0.9, 0.5, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 26
	sb.content_margin_right = 26
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	_all_clear_panel.add_theme_stylebox_override("panel", sb)
	add_child(_all_clear_panel)

	_all_clear_label = Label.new()
	_all_clear_label.add_theme_font_size_override("font_size", 22)
	_all_clear_label.add_theme_color_override("font_color", Color(0.85, 1.0, 0.85))
	_all_clear_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_all_clear_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_all_clear_panel.add_child(_all_clear_label)

# Full-screen red edge vignette that flashes when the player is hit.
func _build_damage_vignette() -> void:
	var grad := Gradient.new()
	grad.set_offset(0, 0.55)
	grad.set_offset(1, 1.0)
	grad.set_color(0, Color(0.7, 0.0, 0.0, 0.0))
	grad.set_color(1, Color(0.7, 0.0, 0.0, 1.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 256
	tex.height = 256

	_dmg_vignette = TextureRect.new()
	_dmg_vignette.texture = tex
	_dmg_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dmg_vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_dmg_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_dmg_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dmg_vignette.modulate.a = 0.0
	add_child(_dmg_vignette)

# Brief hitmarker shown when a shot connects with a zombie.
func _build_hitmarker() -> void:
	_hitmarker = Label.new()
	_hitmarker.text = "X"
	_hitmarker.add_theme_font_size_override("font_size", 24)
	_hitmarker.add_theme_color_override("font_color", Color(1, 1, 1))
	_hitmarker.add_theme_color_override("font_outline_color", Color.BLACK)
	_hitmarker.add_theme_constant_override("outline_size", 4)
	_hitmarker.set_anchors_preset(Control.PRESET_CENTER)
	_hitmarker.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hitmarker.grow_vertical = Control.GROW_DIRECTION_BOTH
	_hitmarker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hitmarker.visible = false
	add_child(_hitmarker)

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
	player.weapon_changed.connect(_on_weapon_changed)
	player.message.connect(show_message)
	player.damaged.connect(flash_damage)
	player.zombie_hit.connect(show_hitmarker)
	# The player's _ready() emitted its initial values before we connected,
	# so pull the current state once to seed the labels.
	_on_ammo_changed(player.ammo, player.reserve)
	_on_health_changed(player.hp, player.MAX_HP)
	_on_state_changed(player._state_label())
	_on_weapon_changed(player.weapon.display_name, player._fire_mode_label())
	_on_suppressor_changed(player.has_suppressor())

func _process(delta: float) -> void:
	if _msg_timer > 0.0:
		_msg_timer -= delta
		if _msg_timer <= 0.0:
			_msg_label.text = ""
	if _dmg_flash > 0.0:
		_dmg_flash -= delta
		_dmg_vignette.modulate.a = maxf(0.0, _dmg_flash / DMG_FLASH_TIME) * DMG_MAX_ALPHA
	if _hitmarker_timer > 0.0:
		_hitmarker_timer -= delta
		if _hitmarker_timer <= 0.0:
			_hitmarker.visible = false

func _on_time_updated(time_left: float, phase: int) -> void:
	var t: int = maxi(0, int(ceil(time_left)))
	var is_day := phase == GameManager.Phase.DAY
	var phase_str := "DAY" if is_day else "NIGHT"
	_clock_label.text = "%s   %02d:%02d" % [phase_str, t / 60, t % 60]
	# Warm for day, cool for night — both stay bright over the backing panel.
	_clock_label.add_theme_color_override("font_color",
		Color(1.0, 0.95, 0.7) if is_day else Color(0.72, 0.86, 1.0))
	_night_label.text = "Night %d" % maxi(GameManager.night_number, 1)

func _on_points_changed(points: int) -> void:
	_points_label.text = "Points: %d" % points

func _on_health_changed(hp: int, max_hp: int) -> void:
	_health_label.text = "HP: %d / %d" % [hp, max_hp]

func _on_ammo_changed(loaded: int, reserve: int) -> void:
	_ammo_label.text = "Ammo: %d / %d" % [loaded, reserve]

func _on_state_changed(state_name: String) -> void:
	_state_label.text = "Move: %s" % state_name

func _on_weapon_changed(display_name: String, fire_mode: String) -> void:
	_wpn_name = display_name
	_wpn_mode = fire_mode
	_compose_weapon_label()

func _on_suppressor_changed(has_supp: bool) -> void:
	_wpn_suppressed = has_supp
	_compose_weapon_label()

func _compose_weapon_label() -> void:
	var supp := "  • Suppressed" if _wpn_suppressed else ""
	_supp_label.text = "%s  [%s]%s" % [_wpn_name, _wpn_mode, supp]

func show_message(text: String) -> void:
	_msg_label.text = text
	_msg_timer = 2.5

func show_prompt(text: String) -> void:
	_prompt_label.text = text
	_prompt_label.visible = true

func hide_prompt() -> void:
	_prompt_label.visible = false

# --- Combat feedback --------------------------------------------------------
func flash_damage() -> void:
	_dmg_flash = DMG_FLASH_TIME
	_dmg_vignette.modulate.a = DMG_MAX_ALPHA

func show_hitmarker() -> void:
	_hitmarker.visible = true
	_hitmarker_timer = HITMARKER_TIME

# --- Nightly wave -----------------------------------------------------------
func set_wave_status(_night: int, spawned: int, total: int, alive: int) -> void:
	_wave_label.text = "Hostiles: %d alive · %d/%d" % [alive, spawned, total]
	# Only meaningful during the night; hide the count during the day.
	_wave_label.visible = not GameManager.is_day()

func show_all_clear(skip_key: String, finish_key: String) -> void:
	_all_clear_label.text = "AREA CLEAR — all hostiles down\n\n[%s] Skip to Day     [%s] Finish the night" % [
		skip_key, finish_key]
	_all_clear_panel.visible = true

func hide_all_clear() -> void:
	_all_clear_panel.visible = false

func all_clear_visible() -> bool:
	return _all_clear_panel.visible
