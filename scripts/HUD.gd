extends CanvasLayer
class_name HUD
## Minimal greybox HUD: a day/night clock, a "Night N" + wave counter, points,
## health, ammo, movement state, an interaction prompt, a transient message
## line, and the center-screen all-clear prompt. Built entirely in code so
## there's no fragile .tscn wiring for v1. No always-on crosshair — hip-fire is
## deliberately blind; ADS shows the laser dot instead, except on the M110,
## which has no laser at all and shows a scope reticle instead (UI only, no
## gameplay effect — see _build_reticle()).

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
var _debug_label: Label
var _gain_label: Label
var _prompt_owner = null
var _dmg_dir: Label
var _dmg_dir_timer := 0.0
var _ifak_label: Label
var _ifak_bar: ProgressBar
var _reticle: Label
var _player: Player

const DMG_FLASH_TIME := 0.45
const DMG_MAX_ALPHA := 0.75
const HITMARKER_TIME := 0.6

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
	_ifak_label = _mk(panel)
	_state_label = _mk(panel)
	_supp_label = _mk(panel)

	_build_clock()
	_build_night_readout()
	_build_all_clear()
	_build_damage_vignette()
	_build_hitmarker()
	_build_debug_readout()
	_build_damage_direction()
	_build_ifak_bar()
	_build_reticle()

	_gain_label = _mk_centered(112, 18, Color(0.15, 0.15, 0.15))
	_gain_label.text = "NVG — GAIN LIMIT"
	_gain_label.add_theme_color_override("font_outline_color", Color(1, 1, 1))
	_gain_label.visible = false

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

# Debug overlay (right side): distance to every zombie within footstep range.
func _build_debug_readout() -> void:
	_debug_label = Label.new()
	_debug_label.add_theme_font_size_override("font_size", 14)
	_debug_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
	_debug_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_debug_label.add_theme_constant_override("outline_size", 4)
	_debug_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_debug_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_debug_label.position = Vector2(-16, 12)
	_debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_label.visible = false
	add_child(_debug_label)

# Directional damage marker (a wedge on a ring around screen centre).
func _build_damage_direction() -> void:
	_dmg_dir = Label.new()
	_dmg_dir.text = "▲"
	_dmg_dir.add_theme_font_size_override("font_size", 30)
	_dmg_dir.add_theme_color_override("font_color", Color(1.0, 0.2, 0.15))
	_dmg_dir.add_theme_color_override("font_outline_color", Color.BLACK)
	_dmg_dir.add_theme_constant_override("outline_size", 5)
	_dmg_dir.set_anchors_preset(Control.PRESET_CENTER)
	_dmg_dir.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_dmg_dir.grow_vertical = Control.GROW_DIRECTION_BOTH
	_dmg_dir.pivot_offset = Vector2(10, 18)
	_dmg_dir.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dmg_dir.visible = false
	# Layer above the store panel so it reads while shopping.
	add_child(_dmg_dir)

# IFAK application progress bar, shown only while applying.
func _build_ifak_bar() -> void:
	_ifak_bar = ProgressBar.new()
	_ifak_bar.min_value = 0.0
	_ifak_bar.max_value = 1.0
	_ifak_bar.show_percentage = false
	_ifak_bar.custom_minimum_size = Vector2(240, 18)
	_ifak_bar.set_anchors_preset(Control.PRESET_CENTER)
	_ifak_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_ifak_bar.grow_vertical = Control.GROW_DIRECTION_BOTH
	_ifak_bar.position.y = 90
	_ifak_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ifak_bar.visible = false
	add_child(_ifak_bar)

# The M110's scope reticle: UI only, no gameplay effect beyond aim assist
# (it does not feed the laser-detection system — the M110 has no laser at
# all, see Player._update_laser). Shown whenever ADS'd on the M110, hidden
# for every other weapon.
func _build_reticle() -> void:
	_reticle = Label.new()
	_reticle.text = "+"
	_reticle.add_theme_font_size_override("font_size", 28)
	_reticle.add_theme_color_override("font_color", Color(0.85, 1.0, 0.85))
	_reticle.add_theme_color_override("font_outline_color", Color.BLACK)
	_reticle.add_theme_constant_override("outline_size", 3)
	_reticle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reticle.set_anchors_preset(Control.PRESET_CENTER)
	_reticle.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_reticle.grow_vertical = Control.GROW_DIRECTION_BOTH
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reticle.visible = false
	add_child(_reticle)

# Brief hitmarker shown when a shot connects with a zombie.
func _build_hitmarker() -> void:
	_hitmarker = Label.new()
	_hitmarker.add_theme_font_size_override("font_size", 20)
	_hitmarker.add_theme_color_override("font_color", Color(1, 1, 1))
	_hitmarker.add_theme_color_override("font_outline_color", Color.BLACK)
	_hitmarker.add_theme_constant_override("outline_size", 4)
	_hitmarker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hitmarker.set_anchors_preset(Control.PRESET_CENTER)
	_hitmarker.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hitmarker.grow_vertical = Control.GROW_DIRECTION_BOTH
	_hitmarker.position.y = -46   # above centre so it never covers the aim point
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
func bind_player(player: Player) -> void:
	_player = player
	player.ammo_changed.connect(_on_ammo_changed)
	player.health_changed.connect(_on_health_changed)
	player.state_changed.connect(_on_state_changed)
	player.suppressor_changed.connect(_on_suppressor_changed)
	player.weapon_changed.connect(_on_weapon_changed)
	player.message.connect(show_message)
	player.damaged.connect(flash_damage)
	player.zombie_hit.connect(show_hitmarker)
	player.ifak_changed.connect(_on_ifak_changed)
	player.ifak_progress.connect(_on_ifak_progress)
	_on_ifak_changed(player.ifaks, player.ifak_max_carry)
	# The player's _ready() emitted its initial values before we connected,
	# so pull the current state once to seed the labels.
	_on_ammo_changed(player.ammo, player.reserve)
	_on_health_changed(player.hp, player.MAX_HP)
	_on_state_changed(player._state_label())
	_on_weapon_changed(player.weapon.display_name, player._fire_mode_label())
	_on_suppressor_changed(player.has_suppressor())

func _process(delta: float) -> void:
	if _player:
		_reticle.visible = _player.ads_active and _player.current_weapon_id == "m110"
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
	if _dmg_dir_timer > 0.0:
		_dmg_dir_timer -= delta
		_dmg_dir.modulate.a = clampf(_dmg_dir_timer / DMG_FLASH_TIME, 0.0, 1.0)
		if _dmg_dir_timer <= 0.0:
			_dmg_dir.visible = false

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
	# mag / reserve. Reserve turns red at zero so "no spare mags" is unmissable.
	_ammo_label.text = "Ammo: %d / %d" % [loaded, reserve]
	_ammo_label.add_theme_color_override("font_color",
		Color(1.0, 0.35, 0.3) if reserve <= 0 else Color(1, 1, 1))

func _on_state_changed(state_name: String) -> void:
	_state_label.text = "Move: %s" % state_name

func _on_ifak_changed(count: int, max_count: int) -> void:
	_ifak_label.text = "IFAK: %d / %d   [H]" % [count, max_count]
	_ifak_label.add_theme_color_override("font_color",
		Color(0.55, 0.55, 0.55) if count <= 0 else Color(1, 1, 1))

func _on_ifak_progress(active: bool, progress: float) -> void:
	_ifak_bar.visible = active
	_ifak_bar.value = progress

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

func show_prompt(text: String, owner = null) -> void:
	_prompt_owner = owner
	_prompt_label.text = text
	_prompt_label.visible = true

## Only the node that raised the prompt may clear it, so overlapping
## interactables (the crate and a supply drop landing beside it) don't fight
## over the prompt every frame.
func hide_prompt(owner = null) -> void:
	if owner != null and _prompt_owner != null and owner != _prompt_owner:
		return
	_prompt_owner = null
	_prompt_label.visible = false

# --- Debug: audible-zombie distances ---------------------------------------
func set_debug_audio(lines: PackedStringArray, laser_line: String = "") -> void:
	var text := ""
	if laser_line != "":
		text = laser_line + "\n\n"
	if lines.is_empty():
		text += "AUDIO DEBUG — no zombies in range"
	else:
		text += "AUDIO DEBUG (%d in range)\n%s" % [lines.size(), "\n".join(lines)]
	_debug_label.text = text

## Shown while NVGs are gained-out in daylight, so the whiteout reads as
## intentional rather than a rendering bug.
func set_gain_limit(on: bool) -> void:
	if _gain_label:
		_gain_label.visible = on

func set_debug_audio_visible(v: bool) -> void:
	_debug_label.visible = v

func debug_audio_visible() -> bool:
	return _debug_label.visible

# --- Combat feedback --------------------------------------------------------
func flash_damage(dir_angle: float = 0.0) -> void:
	_dmg_flash = DMG_FLASH_TIME
	_dmg_vignette.modulate.a = DMG_MAX_ALPHA
	# Directional marker: placed on a ring around screen centre at the angle
	# the hit came from, so you know roughly where the attacker is even with
	# the store open over the top of the view.
	_dmg_dir_timer = DMG_FLASH_TIME
	_dmg_dir.visible = true
	var radius := 130.0
	_dmg_dir.position = Vector2(sin(dir_angle) * radius, -cos(dir_angle) * radius)
	_dmg_dir.rotation = dir_angle

func show_hitmarker(headshot: bool = false, damage: int = 0, remaining_hp: int = 0) -> void:
	# HEAD hits read gold, body hits white, with damage and remaining HP so
	# headshot mechanics are verifiable at a glance.
	_hitmarker.text = "%s  %d dmg  (%d HP)" % [
		"HEAD" if headshot else "BODY", damage, remaining_hp]
	_hitmarker.add_theme_color_override("font_color",
		Color(1.0, 0.85, 0.2) if headshot else Color(1, 1, 1))
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
