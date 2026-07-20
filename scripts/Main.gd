extends Node3D
## World bootstrap. Builds the greybox map (floor, patrol-base structures,
## perimeter trees), bakes a runtime navmesh, wires the day/night lighting,
## spawns the HUD + supply crate, and runs the nightly zombie wave (trickle
## spawn + all-clear detection).

const MAP_HALF := 30.0          # 60x60m clearing
const TREE_RING_MIN := 23.0
const TREE_RING_MAX := 29.0
const TREE_COUNT := 44

# Wave pacing (pool size lives on GameManager.NIGHT_ZOMBIE_COUNT). Zombies
# trickle in rather than all spawning at once. Tune after playtest.
const FIRST_SPAWN_DELAY := 1.5
const SPAWN_INTERVAL_MIN := 4.0
const SPAWN_INTERVAL_MAX := 9.0

# All-clear prompt keybinds (shown on the prompt).
const KEY_SKIP_TO_DAY := KEY_Y
const KEY_FINISH_NIGHT := KEY_N

var zombie_scene: PackedScene = preload("res://scenes/Zombie.tscn")

var _sun: DirectionalLight3D
var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _nav_region: NavigationRegion3D
var _zombies: Array = []
var _hud: HUD
var _crate_ui: SupplyCrateUI
var _pending_crate_zone: SupplyCrateZone

# --- Nightly wave state ---------------------------------------------------
var _wave_total := 0            # zombies to spawn this night
var _wave_spawned := 0          # how many have spawned so far
var _wave_alive := 0            # how many are currently alive
var _spawn_timer := 0.0         # countdown to the next trickle spawn
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
	# Blockout crate: a wooden box with a lighter lid. (No parachute for v1.)
	_add_box(self, Vector3(1.6, 1.4, 1.6), pos + Vector3(0, 0.7, 0), Color(0.5, 0.35, 0.18))
	_add_box(self, Vector3(1.7, 0.15, 1.7), pos + Vector3(0, 1.45, 0), Color(0.62, 0.46, 0.26))

	var zone := SupplyCrateZone.new()
	zone.position = pos
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
	_hud = HUD.new()
	add_child(_hud)
	_hud.bind_player(player)

	_crate_ui = SupplyCrateUI.new()
	add_child(_crate_ui)

	if _pending_crate_zone:
		_pending_crate_zone.crate_ui = _crate_ui
		_pending_crate_zone.hud = _hud

# --- Phase handling -------------------------------------------------------
func _on_phase_changed(phase: int) -> void:
	_apply_lighting(phase == GameManager.Phase.DAY)
	if phase == GameManager.Phase.NIGHT:
		_begin_night()
	else:
		_begin_day()

func _begin_night() -> void:
	# Fresh wave each night: clear anything left over, then trickle in the pool.
	_clear_all_zombies()
	_wave_total = GameManager.zombies_for_night(GameManager.night_number)
	_wave_spawned = 0
	_wave_alive = 0
	_spawn_timer = FIRST_SPAWN_DELAY
	_all_clear_shown = false
	_update_wave_hud()
	_hud.show_message("NIGHT %d — %d hostiles inbound." % [GameManager.night_number, _wave_total])

func _begin_day() -> void:
	# Any survivors go dormant where they stand; the all-clear prompt is moot now.
	_prune_zombies()
	for z in _zombies:
		z.set_active(false)
	_hud.hide_all_clear()
	_update_wave_hud()
	_hud.show_message("DAY — safe. Open the supply crate to spend points.")

# --- Nightly wave: trickle spawn + all-clear -----------------------------
func _process(delta: float) -> void:
	if GameManager.is_day():
		return
	if _wave_spawned >= _wave_total:
		return
	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		_spawn_zombie()
		_wave_spawned += 1
		_wave_alive += 1
		_spawn_timer = randf_range(SPAWN_INTERVAL_MIN, SPAWN_INTERVAL_MAX)
		_update_wave_hud()

func _spawn_zombie() -> void:
	var angle := randf() * TAU
	var r := randf_range(TREE_RING_MIN - 2.0, TREE_RING_MAX)
	var z = zombie_scene.instantiate()  # untyped for the zombie's custom API
	add_child(z)
	z.global_position = Vector3(cos(angle) * r, 0.3, sin(angle) * r)
	z.died.connect(_on_zombie_died)
	z.set_active(true)
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

# --- All-clear prompt input ----------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if not _hud or not _hud.all_clear_visible():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SKIP_TO_DAY:
			_hud.hide_all_clear()
			GameManager.force_phase(GameManager.Phase.DAY)
		elif event.keycode == KEY_FINISH_NIGHT:
			_hud.hide_all_clear()

# --- Zombie bookkeeping ---------------------------------------------------
func _clear_all_zombies() -> void:
	for z in _zombies:
		if is_instance_valid(z):
			z.queue_free()
	_zombies.clear()

func _prune_zombies() -> void:
	_zombies = _zombies.filter(func(z): return is_instance_valid(z))
