extends Node3D
## World bootstrap. Builds the greybox map (floor, patrol-base structures,
## perimeter trees), bakes a runtime navmesh, wires the day/night lighting,
## spawns the HUD + supply crate, and runs the nightly zombie wave (trickle
## spawn + all-clear detection).

const MAP_HALF := 30.0          # 60x60m clearing
const TREE_RING_MIN := 23.0
const TREE_RING_MAX := 29.0
const TREE_COUNT := 44

# Wave sizing (tunable on the Main node in the inspector).
#   spawn_count = base_spawn + spawn_per_night * (night_number - 1)
@export var base_spawn: int = 6
@export var spawn_per_night: int = 3
@export var max_concurrent: int = 20     # hard cap on zombies alive at once

# Wave pacing — zombies trickle in rather than all at once. The interval scales
# with pool size so bigger nights still deliver their allotment: the pool is
# spread across `spawn_window_frac` of the night, clamped and jittered.
const FIRST_SPAWN_DELAY := 1.5
@export var spawn_window_frac: float = 0.75   # fraction of the night to spawn over
@export var spawn_interval_min: float = 0.6   # floor, so huge nights stay sane
@export var spawn_interval_max: float = 9.0   # ceiling, so tiny nights still trickle
@export var spawn_jitter: float = 0.35        # ±35% randomisation per spawn

# --- Zombie health scaling (tunable) --------------------------------------
#   zombie_hp = zombie_base_hp + hp_per_step * floor((night_number - 1) / nights_per_step)
@export var zombie_base_hp: int = 100
@export var hp_per_step: int = 8
@export var nights_per_step: int = 2

# All-clear prompt keybinds (shown on the prompt).
const KEY_SKIP_TO_DAY := KEY_Y
const KEY_FINISH_NIGHT := KEY_N

# Night-vision toggle (v1: always-on, no battery — PROJECT_SPEC.md "NVGs").
const KEY_NVG_TOGGLE := KEY_G

# Debug: show distance to every zombie within footstep-audible range.
const KEY_DEBUG_AUDIO := KEY_F3
# Debug: translucent head/body hitbox volumes on every zombie.
const KEY_DEBUG_HITBOX := KEY_F4

var zombie_scene: PackedScene = preload("res://scenes/Zombie.tscn")

var _sun: DirectionalLight3D
var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _nav_region: NavigationRegion3D
var _zombies: Array = []
var _hud: HUD
var _crate_ui: SupplyCrateUI
var _pending_crate_zone: SupplyCrateZone
var _nvg_on := false
var _nvg_overlay: CanvasLayer
var _nvg_whiteout: ColorRect
var _gain_limit := 0.0          # 0 = normal, 1 = full daylight whiteout
var _hitbox_debug_on := false

const NVG_GAIN_RAMP := 0.5      # seconds to ramp into/out of the whiteout

@export var drop_radius: float = 5.0   # resupply lands within this of the crate
var _crate_position := Vector3.ZERO

# --- Nightly wave state ---------------------------------------------------
var _wave_total := 0            # zombies to spawn this night
var _wave_spawned := 0          # how many have spawned so far
var _wave_alive := 0            # how many are currently alive
var _spawn_timer := 0.0         # countdown to the next trickle spawn
var _spawn_interval := 4.0      # this night's base interval (scaled to pool size)
var _all_clear_shown := false   # prompt fires once per all-clear event

@onready var player: Node3D = $Player

func _ready() -> void:
	randomize()
	_build_lighting()
	_build_world()
	_build_ui()
	_apply_lighting(GameManager.is_day())

	GameManager.phase_changed.connect(_on_phase_changed)

	# Bake the navmesh after the geometry is in the tree, then let the
	# NavigationServer sync for a frame before anything queries a path.
	await get_tree().physics_frame
	_nav_region.bake_navigation_mesh(false)

# --- Lighting / atmosphere -----------------------------------------------
func _build_lighting() -> void:
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-55, -40, 0)
	_sun.shadow_enabled = true
	add_child(_sun)

	_sky_mat = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = _sky_mat

	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)

func _apply_lighting(is_day: bool) -> void:
	if is_day:
		_sun.light_energy = 1.3
		_sun.light_color = Color(1.0, 0.96, 0.86)
		_env.ambient_light_energy = 1.0
		_sky_mat.sky_top_color = Color(0.38, 0.6, 0.98)
		_sky_mat.sky_horizon_color = Color(0.7, 0.8, 0.92)
		_sky_mat.ground_bottom_color = Color(0.3, 0.32, 0.28)
	else:
		_sun.light_energy = 0.12
		_sun.light_color = Color(0.6, 0.7, 1.0)
		_env.ambient_light_energy = 0.35
		_sky_mat.sky_top_color = Color(0.02, 0.03, 0.08)
		_sky_mat.sky_horizon_color = Color(0.05, 0.06, 0.12)
		_sky_mat.ground_bottom_color = Color(0.02, 0.02, 0.03)

	# Night-vision brightens the scene with a green cast on top of the base pass.
	if _nvg_on:
		_sun.light_energy = maxf(_sun.light_energy, 0.9)
		_sun.light_color = Color(0.55, 1.0, 0.55)
		_env.ambient_light_energy = maxf(_env.ambient_light_energy, 0.9)

# --- World geometry -------------------------------------------------------
func _build_world() -> void:
	_nav_region = NavigationRegion3D.new()
	var nav_mesh := NavigationMesh.new()
	nav_mesh.cell_size = 0.25
	nav_mesh.agent_radius = 0.6
	nav_mesh.agent_height = 1.8
	nav_mesh.agent_max_climb = 0.5
	nav_mesh.agent_max_slope = 45.0
	_nav_region.navigation_mesh = nav_mesh
	add_child(_nav_region)

	# Ground: 60x60 clearing.
	_add_box(_nav_region, Vector3(MAP_HALF * 2.0, 1.0, MAP_HALF * 2.0),
		Vector3(0, -0.5, 0), Color(0.28, 0.32, 0.22))

	# Patrol base structures near the centre + a little sandbag cover.
	_add_box(_nav_region, Vector3(4, 3, 6), Vector3(-6, 1.5, -2), Color(0.4, 0.4, 0.42))
	_add_box(_nav_region, Vector3(5, 2.5, 4), Vector3(7, 1.25, -4), Color(0.45, 0.43, 0.4))
	_add_box(_nav_region, Vector3(3, 2, 3), Vector3(4, 1.0, 6), Color(0.42, 0.4, 0.38))
	_add_box(_nav_region, Vector3(6, 0.8, 1), Vector3(0, 0.4, 4), Color(0.5, 0.45, 0.3))   # sandbags
	_add_box(_nav_region, Vector3(1, 0.8, 5), Vector3(-3, 0.4, 1), Color(0.5, 0.45, 0.3))  # sandbags

	# The air-dropped supply crate + its trigger zone.
	_build_crate(Vector3(6, 0, 6))

	# Perimeter woods to break sightlines and give wander routes.
	for i in TREE_COUNT:
		var angle := randf() * TAU
		var r := randf_range(TREE_RING_MIN, TREE_RING_MAX)
		_add_tree(_nav_region, Vector3(cos(angle) * r, 0, sin(angle) * r))

func _add_box(parent: Node, size: Vector3, pos: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material_override = mat
	body.add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)

	parent.add_child(body)
	return body

func _add_tree(parent: Node, pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = pos

	# Trunk.
	var trunk := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 0.35
	tm.bottom_radius = 0.45
	tm.height = 4.0
	trunk.mesh = tm
	trunk.position.y = 2.0
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.3, 0.22, 0.14)
	trunk.material_override = trunk_mat
	body.add_child(trunk)

	# Canopy.
	var canopy := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = 2.0
	cm.height = 3.5
	canopy.mesh = cm
	canopy.position.y = 5.0
	var canopy_mat := StandardMaterial3D.new()
	canopy_mat.albedo_color = Color(0.15, 0.35, 0.16)
	canopy.material_override = canopy_mat
	body.add_child(canopy)

	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.45
	shape.height = 4.0
	col.shape = shape
	col.position.y = 2.0
	body.add_child(col)

	parent.add_child(body)

func _build_crate(pos: Vector3) -> void:
	_crate_position = pos   # anchor for guaranteed resupply drops
	# Blockout crate: a wooden box with a lighter lid. (No parachute for v1.)
	_add_box(self, Vector3(1.6, 1.4, 1.6), pos + Vector3(0, 0.7, 0), Color(0.5, 0.35, 0.18))
	_add_box(self, Vector3(1.7, 0.15, 1.7), pos + Vector3(0, 1.45, 0), Color(0.62, 0.46, 0.26))

	var zone := SupplyCrateZone.new()
	zone.position = pos
	# Layer 2 keeps the trigger out of the weapon ray's mask (world + heads).
	zone.collision_layer = 2
	zone.collision_mask = 1     # still detects the player body
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(4, 3, 4)
	col.shape = shape
	col.position.y = 1.5
	zone.add_child(col)
	add_child(zone)
	_pending_crate_zone = zone

# --- UI -------------------------------------------------------------------
func _build_ui() -> void:
	_build_nvg_overlay()

	_hud = HUD.new()
	add_child(_hud)
	_hud.bind_player(player)

	_crate_ui = SupplyCrateUI.new()
	add_child(_crate_ui)

	if _pending_crate_zone:
		_pending_crate_zone.crate_ui = _crate_ui
		_pending_crate_zone.hud = _hud

func _build_nvg_overlay() -> void:
	# Green tint sits under the HUD (layer 5) so HUD text stays readable.
	_nvg_overlay = CanvasLayer.new()
	_nvg_overlay.layer = 5
	_nvg_overlay.visible = false
	add_child(_nvg_overlay)
	var rect := ColorRect.new()
	rect.color = Color(0.2, 0.85, 0.3, 0.16)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_nvg_overlay.add_child(rect)

	# Daylight gain-limit whiteout, layered over the green tint.
	_nvg_whiteout = ColorRect.new()
	_nvg_whiteout.color = Color(0.85, 1.0, 0.88, 0.0)
	_nvg_whiteout.set_anchors_preset(Control.PRESET_FULL_RECT)
	_nvg_whiteout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_nvg_whiteout.visible = false
	_nvg_overlay.add_child(_nvg_whiteout)

func _toggle_nvg() -> void:
	_nvg_on = not _nvg_on
	_nvg_overlay.visible = _nvg_on
	player.nvg_active = _nvg_on      # IR laser only renders under NVGs
	_apply_lighting(GameManager.is_day())
	if not _nvg_on:
		_clear_gain_limit()
	_hud.show_message("NVGs " + ("ON" if _nvg_on else "OFF"))

## NVGs in daylight: the tube gains out and blows the image to white. Punishing
## (aiming is effectively impossible) but still navigable.
func _update_nvg_daylight(delta: float) -> void:
	var overexposed := _nvg_on and GameManager.is_day()
	var target := 1.0 if overexposed else 0.0
	if is_equal_approx(_gain_limit, target):
		if overexposed:
			_hud.set_gain_limit(true)
		return
	# ~0.5s ramp, matching an auto-gain circuit catching up.
	_gain_limit = move_toward(_gain_limit, target, delta / NVG_GAIN_RAMP)
	_apply_gain_limit()

func _apply_gain_limit() -> void:
	var t := _gain_limit
	# Crushed contrast + blown highlights, layered over the green tint.
	_nvg_whiteout.color = Color(0.85, 1.0, 0.88, 0.92 * t)
	_nvg_whiteout.visible = t > 0.001
	_env.glow_enabled = t > 0.001
	_env.glow_intensity = 1.2 + 5.0 * t
	_env.glow_bloom = 0.6 * t
	_hud.set_gain_limit(t > 0.05)

func _clear_gain_limit() -> void:
	_gain_limit = 0.0
	_apply_gain_limit()

# --- Phase handling -------------------------------------------------------
func _on_phase_changed(phase: int) -> void:
	_apply_lighting(phase == GameManager.Phase.DAY)
	if phase == GameManager.Phase.NIGHT:
		_clear_gain_limit()   # whiteout ends immediately at nightfall
		_begin_night()
	else:
		_begin_day()

func _begin_night() -> void:
	# Survivors from previous nights carry over: reactivate them and fold them
	# into this night's totals on top of the fresh pool. They already count as
	# "spawned" and "alive", so the trickle only adds the new pool and the
	# all-clear still requires every carried-over zombie to be killed too.
	_prune_zombies()
	var carryover := _zombies.size()
	for z in _zombies:
		z.set_active(true)

	var new_pool: int = base_spawn + spawn_per_night * (GameManager.night_number - 1)
	_wave_total = carryover + new_pool
	_wave_spawned = carryover
	_wave_alive = carryover
	_spawn_timer = FIRST_SPAWN_DELAY
	_spawn_interval = _compute_spawn_interval(new_pool)
	_all_clear_shown = false
	print("[Night %d] to spawn %d (pool %d + carryover %d), cap %d, zombie HP %d, interval %.2fs" % [
		GameManager.night_number, _wave_total, new_pool, carryover,
		max_concurrent, _zombie_hp_for_night(), _spawn_interval])
	_update_wave_hud()
	if carryover > 0:
		_hud.show_message("NIGHT %d — %d inbound (+%d survivors carried over)." % [
			GameManager.night_number, new_pool, carryover])
	else:
		_hud.show_message("NIGHT %d — %d hostiles inbound." % [GameManager.night_number, new_pool])

func _begin_day() -> void:
	# Any survivors go dormant where they stand; the all-clear prompt is moot now.
	_prune_zombies()
	for z in _zombies:
		z.set_active(false)
	_hud.hide_all_clear()
	_update_wave_hud()

	# Guaranteed resupply at the dawn following certain nights. The schedule
	# lives on EnablerManager so this stopgap can be switched off wholesale
	# once the purchasable supply-drop enabler exists.
	if EnablerManager.is_guaranteed_drop_night(GameManager.night_number):
		_spawn_supply_drop()
	else:
		_hud.show_message("DAY — safe. Open the supply crate to spend points.")

## Instances the reusable SupplyDrop scene near the crate. The future
## purchasable enabler instances the same scene with a different anchor.
func _spawn_supply_drop() -> void:
	var drop := SupplyDrop.new()
	drop.setup(_hud, {"magazines": 1})
	add_child(drop)
	drop.global_position = SupplyDrop.find_spawn_point(
		get_world_3d(), _crate_position, drop_radius, player.global_position)
	_hud.show_message("RESUPPLY — DROPPED NEAR BASE")
	print("[RESUPPLY] drop spawned at %s (night %d)" % [
		drop.global_position, GameManager.night_number])

# --- Nightly wave: trickle spawn + all-clear -----------------------------
func _process(delta: float) -> void:
	_update_nvg_daylight(delta)
	if _hud and _hud.debug_audio_visible():
		_update_audio_debug()
	if GameManager.is_day() or _wave_spawned >= _wave_total:
		return
	_spawn_timer -= delta
	# Remaining spawns queue while we're at the concurrent cap; the timer stays
	# elapsed so the next slot fills as soon as a zombie dies.
	if _spawn_timer <= 0.0 and _wave_alive < max_concurrent:
		_spawn_zombie()
		_wave_spawned += 1
		_wave_alive += 1
		_spawn_timer = _spawn_interval * randf_range(1.0 - spawn_jitter, 1.0 + spawn_jitter)
		_update_wave_hud()

func _apply_hitbox_debug() -> void:
	for z in _zombies:
		if is_instance_valid(z):
			z.set_hitbox_debug(_hitbox_debug_on)

## Debug overlay: distance to every zombie inside its own footstep range, so
## the ~20m audible threshold can be confirmed by walking toward one.
func _update_audio_debug() -> void:
	var lines := PackedStringArray()
	var here := player.global_position
	var rows: Array = []
	for z in _zombies:
		if not is_instance_valid(z):
			continue
		var d: float = here.distance_to(z.global_position)
		if d <= z.footstep_range():
			rows.append({"d": d, "moving": Vector2(z.velocity.x, z.velocity.z).length() > z.step_min_speed})
	rows.sort_custom(func(a, b): return a["d"] < b["d"])
	for row in rows:
		lines.append("%5.1f m  %s" % [row["d"], "walking" if row["moving"] else "still"])
	_hud.set_debug_audio(lines, player.laser_debug_line())

## Spread this night's pool across most of the night so bigger waves still
## arrive, instead of a fixed interval that runs out of night on late waves.
func _compute_spawn_interval(pool: int) -> float:
	if pool <= 0:
		return spawn_interval_max
	var window: float = GameManager.NIGHT_LENGTH * spawn_window_frac
	return clampf(window / float(pool), spawn_interval_min, spawn_interval_max)

## Per-night zombie max HP: negligible early, compounding later.
##   100 / 100 / 108 / 108 / 116 / 116 ...
func _zombie_hp_for_night() -> int:
	var steps: int = int(floor(float(GameManager.night_number - 1) / float(maxi(1, nights_per_step))))
	return zombie_base_hp + hp_per_step * maxi(0, steps)

func _spawn_zombie() -> void:
	var angle := randf() * TAU
	var r := randf_range(TREE_RING_MIN - 2.0, TREE_RING_MAX)
	var z = zombie_scene.instantiate()  # untyped for the zombie's custom API
	# Set max_hp BEFORE add_child so the zombie's _ready() seeds hp from it.
	z.max_hp = _zombie_hp_for_night()
	add_child(z)
	z.global_position = Vector3(cos(angle) * r, 0.3, sin(angle) * r)
	z.died.connect(_on_zombie_died)
	z.set_active(true)
	if _hitbox_debug_on:
		z.set_hitbox_debug(true)
	_zombies.append(z)

func _on_zombie_died() -> void:
	_wave_alive = maxi(0, _wave_alive - 1)
	_update_wave_hud()
	_check_all_clear()

func _check_all_clear() -> void:
	if GameManager.is_day() or _all_clear_shown:
		return
	if _wave_spawned >= _wave_total and _wave_alive <= 0:
		_all_clear_shown = true
		_hud.show_all_clear(char(KEY_SKIP_TO_DAY), char(KEY_FINISH_NIGHT))

func _update_wave_hud() -> void:
	_hud.set_wave_status(GameManager.night_number, _wave_spawned, _wave_total, _wave_alive)

# --- Global key input (NVG toggle + all-clear prompt) --------------------
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_NVG_TOGGLE:
		_toggle_nvg()
		return
	if event.keycode == KEY_DEBUG_AUDIO:
		_hud.set_debug_audio_visible(not _hud.debug_audio_visible())
		return
	if event.keycode == KEY_DEBUG_HITBOX:
		_hitbox_debug_on = not _hitbox_debug_on
		_apply_hitbox_debug()
		_hud.show_message("Hitbox debug " + ("ON" if _hitbox_debug_on else "OFF"))
		return
	if _hud and _hud.all_clear_visible():
		if event.keycode == KEY_SKIP_TO_DAY:
			_hud.hide_all_clear()
			GameManager.force_phase(GameManager.Phase.DAY)
		elif event.keycode == KEY_FINISH_NIGHT:
			_hud.hide_all_clear()

# --- Zombie bookkeeping ---------------------------------------------------
func _prune_zombies() -> void:
	_zombies = _zombies.filter(func(z): return is_instance_valid(z))
