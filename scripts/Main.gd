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
@export var spawn_interval_max: float = 20.0  # ceiling, so tiny nights still trickle
@export var spawn_jitter: float = 0.35        # ±35% randomisation per spawn

# --- Zombie health scaling (tunable) --------------------------------------
#   zombie_hp = zombie_base_hp + hp_per_step * floor((night_number - 1) / nights_per_step)
@export var zombie_base_hp: int = 100
@export var hp_per_step: int = 8
@export var nights_per_step: int = 2

# --- Zombie variant mix ----------------------------------------------------
## Leapers debut on this night; everything before it is 100% walkers.
@export var leaper_first_night: int = 4
@export var leaper_start_fraction: float = 0.10   # 10% of the budget on debut
@export var leaper_fraction_step: float = 0.05    # +5% per subsequent night
@export var leaper_max_fraction: float = 0.30     # hard ceiling
var _type_walker: ZombieType = preload("res://resources/zombie_walker.tres")
var _type_leaper: ZombieType = preload("res://resources/zombie_leaper.tres")

# All-clear prompt keybinds (shown on the prompt). Deliberately kept as raw
# keycodes rather than input-map actions: they are a modal yes/no answer that
# only exists while the prompt is up, not a rebindable game control.
#
# N NOW DOUBLE-BOOKS. It answers "finish the night" here AND, since the NVG
# toggle moved off G, it is the global nvg_toggle bind. The prompt wins while
# it is visible — see _unhandled_input(), which checks the prompt FIRST and
# marks the event handled. Y/N is kept rather than re-lettering "finish the
# night" to something free, because yes/no IS the mnemonic and a prompt
# answered with Y and, say, F reads worse than one gated by visibility.
const KEY_SKIP_TO_DAY := KEY_Y
const KEY_FINISH_NIGHT := KEY_N

## Night-vision toggle (v1: always-on, no battery — PROJECT_SPEC.md "NVGs").
## Moved from G to N; G is now the grenade equip toggle. Both live in the
## input map (project.godot `[input]`) so they stay remappable — this is the
## action NAME, not a keycode, and nothing here assumes which key it is.
const ACTION_NVG_TOGGLE := "nvg_toggle"

# Debug: show distance to every zombie within footstep-audible range.
const KEY_DEBUG_AUDIO := KEY_J
# Debug: translucent head/body hitbox volumes on every zombie.
const KEY_DEBUG_HITBOX := KEY_K
## Debug: detonate a test blast at the player's feet, to exercise the shared
## area-damage system without needing a thrown grenade. Safe to remove once
## grenades are in the player's hands.
const KEY_DEBUG_BLAST := KEY_L
const DEBUG_BLAST_PROFILE := preload("res://resources/frag_grenade.tres")

# ---------------------------------------------------------------------------
# TEMPORARY SCAFFOLDING — DELETE WHEN POSITION TWO EXISTS.
#
# Fighters are narratively local irregulars rescued at Position Two, and the
# real grant happens on arrival there. Position Two does not exist yet, so
# this spawns them at Position One instead, behind a debug key, purely so the
# system can be built and tested. Everything in this block and in
# _debug_spawn_fighter() is throwaway — no other code should come to depend
# on it. See PROJECT_SPEC.md "Allied fighters".
const KEY_DEBUG_SPAWN_FIGHTER := KEY_M
const FIGHTER_TYPE_IRREGULAR := preload("res://resources/fighter_irregular.tres")
## How far in front of the player a debug fighter appears.
const DEBUG_FIGHTER_SPAWN_DISTANCE := 4.0
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# TEMPORARY SCAFFOLDING — DELETE ONCE POSITION TWO SHIPS REAL CONCEALMENT.
#
# Step 8A (cover & concealment) has exactly one real cover candidate today
# (sandbags — SOLID). Nothing in ObstacleCatalog is CONCEALMENT: no trees, no
# foliage, no brush exist anywhere in this project yet (confirmed by audit).
# This spawns one throwaway CONCEALMENT test box so the mechanic — and the
# TEST GATE 1 "brush blocks sight but not rounds" check — can be verified at
# all before Position Two adds real foliage. Not in ObstacleCatalog, not
# buildable, not persisted, not art. See _debug_spawn_cover_test().
const KEY_DEBUG_SPAWN_COVER_TEST := KEY_O
const DEBUG_COVER_TEST_SPAWN_DISTANCE := 4.0
const DEBUG_COVER_TEST_SIZE := Vector3(1.5, 1.8, 1.5)
# ---------------------------------------------------------------------------

## Step 8A phase 4. Tints every cover_solid / concealment volume in the world
## so the layers are legible while authoring geometry — explicitly for
## building Position Two in step 8B. See CoverDebugDraw.gd.
const KEY_DEBUG_COVER_DRAW := KEY_P
## Step 8A phase 4. Shows every live fighter's sector-of-fire wedge, carved by
## whatever cover actually intrudes on it. Player-facing in intent — it
## belongs to a fighter PLACEMENT mode, which does not exist yet (fighters
## spawn in front of the player); on a toggle until it does. See
## SectorPreview.gd.
const KEY_DEBUG_SECTOR_PREVIEW := KEY_U
const COVER_PREVIEW_CONFIG := preload("res://resources/cover_preview.tres")

var zombie_scene: PackedScene = preload("res://scenes/Zombie.tscn")

var _sun: DirectionalLight3D
var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _nav_region: NavigationRegion3D
## Second, physics-free navmesh region: ditch mouths only. Baked from plain
## MeshInstance3D geometry (PARSED_GEOMETRY_MESH_INSTANCES), never from
## colliders, so a ditch's flat "mouth" patch stays in the navmesh forever,
## independent of the fact that it has no physical collision at all — see
## ZombieDitch.gd and register_ditch_mouth() below.
var _mouth_region: NavigationRegion3D
## Parent for placed obstacles — sits under the nav region so rebakes see them.
var obstacles_root: Node3D
var _nav_rebake_pending := false
var _nav_rebake_queued := false
var _nav_baking := false
var _nav_bake_started_us := 0
var _nav_rebake_reason := ""
## How many of the (main + mouth) region bakes from the current rebake are
## still outstanding. A rebake is "finished" only once both report in.
var _nav_bakes_in_flight := 0

# --- Ground (rebuildable so a placed ditch can punch a real hole) ---------
var _ground_body: StaticBody3D
var _ground_holes: Array = []   # Array[Rect2], one per placed ditch (XZ, world space)
var _zombies: Array = []
var _hud: HUD
var _crate_ui: SupplyCrateUI
var _pending_crate_zone: SupplyCrateZone
var _pending_tent_zone: EngineersTentZone
var _build_mode: BuildMode
var _radio_menu: RadioMenu
var _target_painter: TargetPainter
var _fire_missions: FireMissionSystem
var _uav_overlay: UAVOverlay
var _supply_drop_system: SupplyDropSystem
var _apache_system: ApacheSystem
var _roster_menu: RosterMenu

## Radio-callable fire missions, in menu order. Adding one is a .tres plus a
## line in _fire_mission_list() — FireMissionSystem registers whatever it's
## handed, and the radio menu renders whatever is registered.
const MISSION_MORTAR := preload("res://resources/mission_mortar.tres")
const MISSION_SHAKE_AND_BAKE := preload("res://resources/mission_shake_and_bake.tres")
const SUPPLY_DROP_CONFIG := preload("res://resources/supply_drop.tres")
const TARGET_PAINT_CONFIG := preload("res://resources/target_paint.tres")
const APACHE_CONFIG := preload("res://resources/apache.tres")
const FIGHTER_ECONOMY_CONFIG := preload("res://resources/fighter_economy.tres")

## Built as a typed local rather than a typed `const` array: FireMissionSystem
## .missions is Array[FireMissionConfig], and handing it an untyped literal
## fails the assignment at runtime.
##
## Order here is menu order — these become [1] and [2] under the radio.
func _fire_mission_list() -> Array[FireMissionConfig]:
	var list: Array[FireMissionConfig] = []
	list.append(MISSION_MORTAR)
	list.append(MISSION_SHAKE_AND_BAKE)
	return list
var _nvg_on := false
var _nvg_overlay: CanvasLayer
var _nvg_whiteout: ColorRect
var _gain_limit := 0.0          # 0 = normal, 1 = full daylight whiteout
var _hitbox_debug_on := false
## Step 8A phase 4 visualizations.
var _cover_debug: CoverDebugDraw
var _sector_previews_on := false

const NVG_GAIN_RAMP := 0.5      # seconds to ramp into/out of the whiteout

@export var drop_radius: float = 5.0   # resupply lands within this of the crate
var _crate_position := Vector3.ZERO

# --- Nightly wave state ---------------------------------------------------
var _wave_total := 0            # zombies to spawn this night
var _wave_spawned := 0          # how many have spawned so far
var _spawn_timer := 0.0         # countdown to the next trickle spawn
var _spawn_interval := 4.0      # this night's base interval (scaled to pool size)
var _all_clear_shown := false   # prompt fires once per all-clear event

@onready var player: Player = $Player

func _ready() -> void:
	randomize()
	# Before anything can raycast: the cover/concealment mask invariants and
	# the crouch eye-height invariant. Startup, so a regression shows up on
	# launch rather than as "the gun sometimes misses through a bush".
	#
	# The masks are gathered HERE and passed in rather than read inside
	# LineOfSight, so that file stays a leaf depending only on Obstacle — see
	# the note on assert_masks_sane(). Main already depends on all of these.
	# Add any new projectile-traced mask to this list.
	LineOfSight.assert_masks_sane({
		"Player.HIT_MASK": Player.HIT_MASK,
		"Grenade.COLLISION_MASK": Grenade.COLLISION_MASK,
		"AreaDamageSystem.COVER_MASK": AreaDamageSystem.COVER_MASK,
		"Obstacle.SOLID_SURFACE_MASK": Obstacle.SOLID_SURFACE_MASK,
	}, Player.CROUCH_HEAD_Y, Player.STAND_HEAD_Y)
	_build_lighting()
	_build_world()
	_build_ui()
	_apply_lighting(GameManager.is_day())

	GameManager.phase_changed.connect(_on_phase_changed)

	# Bake the navmesh after the geometry is in the tree, then let the
	# NavigationServer sync for a frame before anything queries a path.
	# Synchronous here only: nothing is moving yet, and the first path query
	# must not race an unfinished bake.
	await get_tree().physics_frame
	_nav_rebake_reason = "initial bake"
	_nav_bake_started_us = Time.get_ticks_usec()
	_nav_bakes_in_flight = 2
	_nav_region.bake_navigation_mesh(false)
	_mouth_region.bake_navigation_mesh(false)

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
	# Parse STATIC COLLIDERS, not mesh instances. Only things with real
	# collision on layer 1 should block pathing — a sandbag wall carves the
	# navmesh; the minefield's marker plate (collider-less) and the ditch's
	# pit (real collision, but on the solid-but-non-navmesh layer) correctly
	# do not. The ditch mouth's own navmesh contribution comes from the
	# separate _mouth_region below, not from this one.
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_collision_mask = 1
	_nav_region.navigation_mesh = nav_mesh
	add_child(_nav_region)
	_nav_region.bake_finished.connect(_on_navmesh_baked)

	# Ditch-mouth region: same agent tuning, but baked from plain mesh
	# instances rather than colliders (see the field comment on
	# _mouth_region). Uses the default navigation map, same as _nav_region, so
	# Godot stitches the two regions' polygons into one connected graph.
	_mouth_region = NavigationRegion3D.new()
	var mouth_mesh := NavigationMesh.new()
	mouth_mesh.cell_size = nav_mesh.cell_size
	mouth_mesh.agent_radius = nav_mesh.agent_radius
	mouth_mesh.agent_height = nav_mesh.agent_height
	mouth_mesh.agent_max_climb = nav_mesh.agent_max_climb
	mouth_mesh.agent_max_slope = nav_mesh.agent_max_slope
	mouth_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES
	_mouth_region.navigation_mesh = mouth_mesh
	add_child(_mouth_region)
	_mouth_region.bake_finished.connect(_on_navmesh_baked)

	# Placed obstacles live UNDER the nav region so a rebake picks them up.
	obstacles_root = Node3D.new()
	obstacles_root.name = "Obstacles"
	_nav_region.add_child(obstacles_root)

	# Ground: 60x60 clearing, rebuilt whenever a ditch punches a hole in it.
	_build_ground()

	# Patrol base structures near the centre + a little sandbag cover.
	_add_box(_nav_region, Vector3(4, 3, 6), Vector3(-6, 1.5, -2), Color(0.4, 0.4, 0.42))
	_add_box(_nav_region, Vector3(5, 2.5, 4), Vector3(7, 1.25, -4), Color(0.45, 0.43, 0.4))
	_add_box(_nav_region, Vector3(3, 2, 3), Vector3(4, 1.0, 6), Color(0.42, 0.4, 0.38))
	_add_box(_nav_region, Vector3(6, 0.8, 1), Vector3(0, 0.4, 4), Color(0.5, 0.45, 0.3))   # sandbags
	_add_box(_nav_region, Vector3(1, 0.8, 5), Vector3(-3, 0.4, 1), Color(0.5, 0.45, 0.3))  # sandbags

	# The air-dropped supply crate + its trigger zone.
	_build_crate(Vector3(6, 0, 6))

	# The Engineers' Tent, across the base from the crate.
	_build_engineers_tent(Vector3(-7, 0, 7))

	# Perimeter woods to break sightlines and give wander routes.
	for i in TREE_COUNT:
		var angle := randf() * TAU
		var r := randf_range(TREE_RING_MIN, TREE_RING_MAX)
		_add_tree(_nav_region, Vector3(cos(angle) * r, 0, sin(angle) * r))

# --- Rebuildable ground (so a ditch can punch a real hole in it) ---------
## One shared StaticBody3D holding N rectangular collision pieces instead of
## one giant slab, so a placed ditch can remove real floor collision at its
## footprint without any runtime CSG — the remainder of a rectangle minus a
## rectangle decomposes cleanly into up to 4 rectangles (west/east/north/south
## strips), applied iteratively per hole in _rebuild_ground_pieces().
func _build_ground() -> void:
	_ground_body = StaticBody3D.new()
	_ground_body.collision_layer = 1
	_ground_body.collision_mask = 0
	_nav_region.add_child(_ground_body)
	_rebuild_ground_pieces()

## Call when a ditch is placed (or restored) with its world-space AABB. Real
## ground collision goes away at that footprint permanently — there is no
## "un-punch"; ditches are indestructible, same as before.
func punch_ground_hole(rect: Rect2) -> void:
	_ground_holes.append(rect)
	_rebuild_ground_pieces()

func _rebuild_ground_pieces() -> void:
	for c in _ground_body.get_children():
		c.queue_free()
	var full := Rect2(-MAP_HALF, -MAP_HALF, MAP_HALF * 2.0, MAP_HALF * 2.0)
	var pieces: Array = [full]
	for hole in _ground_holes:
		var next: Array = []
		for r in pieces:
			next.append_array(_subtract_rect(r, hole))
		pieces = next
	for r in pieces:
		_add_ground_piece(r)

## Rectangle `r` minus rectangle `hole`, as up to 4 non-overlapping remainder
## rectangles (west/east/north/south strips around the hole). Returns [r]
## unchanged if they don't actually overlap.
func _subtract_rect(r: Rect2, hole: Rect2) -> Array:
	var inter := r.intersection(hole)
	if inter.size.x <= 0.0 or inter.size.y <= 0.0:
		return [r]
	var out: Array = []
	var r_right: float = r.position.x + r.size.x
	var r_bottom: float = r.position.y + r.size.y
	var inter_right: float = inter.position.x + inter.size.x
	var inter_bottom: float = inter.position.y + inter.size.y
	if inter.position.x > r.position.x:
		out.append(Rect2(r.position.x, r.position.y, inter.position.x - r.position.x, r.size.y))
	if inter_right < r_right:
		out.append(Rect2(inter_right, r.position.y, r_right - inter_right, r.size.y))
	if inter.position.y > r.position.y:
		out.append(Rect2(inter.position.x, r.position.y, inter.size.x, inter.position.y - r.position.y))
	if inter_bottom < r_bottom:
		out.append(Rect2(inter.position.x, inter_bottom, inter.size.x, r_bottom - inter_bottom))
	return out

func _add_ground_piece(r: Rect2) -> void:
	var center := Vector3(r.position.x + r.size.x * 0.5, -0.5, r.position.y + r.size.y * 0.5)
	var size := Vector3(r.size.x, 1.0, r.size.y)

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.28, 0.32, 0.22)
	mesh.material_override = mat
	mesh.position = center
	_ground_body.add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position = center
	_ground_body.add_child(col)

## Called by ZombieDitch.finalize_in_world() once its position/rotation are
## final. Punches the real ground hole AND adds a permanent, physics-free
## navmesh patch over the same footprint — see the _mouth_region field
## comment for why both are needed together.
func register_ditch_mouth(rect: Rect2) -> void:
	punch_ground_hole(rect)
	_add_mouth_patch(rect)
	request_navmesh_rebake("ditch mouth")

## A thin, fully transparent MeshInstance3D — visible (so it's guaranteed to
## still be parsed for navmesh baking) but invisible to the eye, so the
## player sees straight down into the pit rather than a floor patch sitting
## over the hole.
func _add_mouth_patch(rect: Rect2) -> void:
	var patch := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(rect.size.x, 0.05, rect.size.y)
	patch.mesh = box
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.0)
	patch.material_override = mat
	patch.position = Vector3(rect.position.x + rect.size.x * 0.5, 0.0,
		rect.position.y + rect.size.y * 0.5)
	_mouth_region.add_child(patch)

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
	_crate_position = pos   # fallback LZ pad for SupplyDropSystem, last resort only
	# Blockout crate: a wooden box with a lighter lid. (No parachute for v1.)
	_add_box(_nav_region, Vector3(1.6, 1.4, 1.6), pos + Vector3(0, 0.7, 0), Color(0.5, 0.35, 0.18))
	_add_box(_nav_region, Vector3(1.7, 0.15, 1.7), pos + Vector3(0, 1.45, 0), Color(0.62, 0.46, 0.26))

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

## Khaki canvas tent with a peaked roof — deliberately nothing like the
## crate's brown box, so the two are never confused at a glance.
func _build_engineers_tent(pos: Vector3) -> void:
	_add_box(_nav_region, Vector3(4.5, 2.2, 3.2), pos + Vector3(0, 1.1, 0), Color(0.55, 0.5, 0.3))

	# Peaked roof: a 3-sided prism laid on its side.
	var roof := MeshInstance3D.new()
	var prism := CylinderMesh.new()
	prism.top_radius = 2.0
	prism.bottom_radius = 2.0
	prism.height = 4.6
	prism.radial_segments = 3
	roof.mesh = prism
	roof.position = pos + Vector3(0, 2.6, 0)
	roof.rotation_degrees = Vector3(0, 0, 90)   # lay the prism along X
	var roof_mat := StandardMaterial3D.new()
	roof_mat.albedo_color = Color(0.35, 0.34, 0.22)
	roof.material_override = roof_mat
	add_child(roof)

	var zone := EngineersTentZone.new()
	zone.position = pos
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(6.5, 3, 5.2)
	col.shape = shape
	col.position.y = 1.5
	zone.add_child(col)
	add_child(zone)
	_pending_tent_zone = zone

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

	_build_mode = BuildMode.new()
	add_child(_build_mode)
	_build_mode.setup(player, _hud, obstacles_root, self)
	if _pending_tent_zone:
		_pending_tent_zone.build_mode = _build_mode
		_pending_tent_zone.hud = _hud

	# T-triggered, not tied to any spatial zone — unlike the crate/tent it
	# needs no _pending_*_zone wiring, just the player and HUD refs it opens
	# the "No radio."/list rows with.
	_radio_menu = RadioMenu.new()
	add_child(_radio_menu)
	_radio_menu.setup(player, _hud)

	# Shared target-painting mode. Deliberately NOT owned by the radio menu or
	# by any one mission — the Apache patrol box is the next consumer, and it
	# is a different enabler entirely. Handed to whoever needs to paint.
	_target_painter = TargetPainter.new()
	_target_painter.name = "TargetPainter"
	_target_painter.config = TARGET_PAINT_CONFIG
	add_child(_target_painter)
	_target_painter.setup(player, player.camera)

	# Registers its own missions into EnablerManager.callable_enablers, so
	# they appear in the radio menu with no menu-side changes.
	_fire_missions = FireMissionSystem.new()
	_fire_missions.name = "FireMissionSystem"
	_fire_missions.missions = _fire_mission_list()
	add_child(_fire_missions)
	_fire_missions.setup(player, _hud, _target_painter, _radio_menu)

	# UAV: an autoload, not a scene child — every Zombie subscribes to it
	# directly (see Zombie._build_uav_silhouette()), so its state has to be
	# reachable without a reference threaded through the spawner. Only the
	# call-in wiring (HUD/radio refs, EnablerManager registration) happens
	# here, same as every other enabler's setup().
	_uav_overlay = UAVOverlay.new()
	_uav_overlay.name = "UAVOverlay"
	add_child(_uav_overlay)
	_uav_overlay.setup(player)
	UAVSystem.setup(_hud, _radio_menu)

	# Registers itself into EnablerManager.callable_enablers, same as every
	# other enabler. The player DESIGNATES the LZ with the shared painter;
	# _crate_position/drop_radius are handed in only as the last-resort
	# fallback pad, not as the normal destination.
	_supply_drop_system = SupplyDropSystem.new()
	_supply_drop_system.name = "SupplyDropSystem"
	_supply_drop_system.config = SUPPLY_DROP_CONFIG
	add_child(_supply_drop_system)
	_supply_drop_system.setup(player, _hud, _radio_menu, _target_painter,
		_crate_position, drop_radius)

	# Registers itself into EnablerManager.callable_enablers, same as every
	# other enabler, and paints its patrol box with the same shared painter.
	_apache_system = ApacheSystem.new()
	_apache_system.name = "ApacheSystem"
	_apache_system.config = APACHE_CONFIG
	add_child(_apache_system)
	_apache_system.setup(player, _hud, _radio_menu, _target_painter)

	# Day-only, F to open. Recruiting calls back into _spawn_fighter() —
	# the same placement the debug M key uses — so this menu never makes a
	# spatial decision of its own.
	_roster_menu = RosterMenu.new()
	_roster_menu.name = "RosterMenu"
	add_child(_roster_menu)
	_roster_menu.setup(player, _hud, FIGHTER_ECONOMY_CONFIG, _spawn_fighter)

	# Step 8A phase 4 debug overlay (P). Built here rather than lazily on
	# first toggle so it is in the tree with everything else and its own
	# _process is running when the key is hit.
	_cover_debug = CoverDebugDraw.new()
	_cover_debug.name = "CoverDebugDraw"
	_cover_debug.setup(COVER_PREVIEW_CONFIG)
	add_child(_cover_debug)

	_restore_base()

## Rebuild the base from GameState if a snapshot exists. Runs inside
## _build_ui(), i.e. BEFORE the initial navmesh bake in _ready(), so restored
## sandbags are baked in on the first pass and no extra rebake is needed.
func _restore_base() -> void:
	if not GameState.has_snapshot():
		return
	GameState.restore_meta()
	var rebuilt: Array = GameState.restore(obstacles_root)
	_build_mode.adopt(rebuilt)

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
	# Snapshot at every phase boundary so a scene change never has to hunt for
	# a safe moment to serialise the base — GameState is always current.
	capture_state()

## Public: snapshot the run into GameState. Called at every phase boundary and
## available to whatever drives a level transition later.
func capture_state() -> void:
	if _build_mode:
		_build_mode.capture_state()

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
	# alive count is derived (see alive_count()), never tracked separately.
	_spawn_timer = FIRST_SPAWN_DELAY
	_spawn_interval = _compute_spawn_interval(new_pool)
	_all_clear_shown = false
	PointsManager.begin_night_tally()
	var lf := leaper_fraction_for_night(GameManager.night_number)
	print("[Night %d] to spawn %d (pool %d + carryover %d), cap %d, zombie HP %d, interval %.2fs" % [
		GameManager.night_number, _wave_total, new_pool, carryover,
		max_concurrent, _zombie_hp_for_night(), _spawn_interval])
	print("[Night %d] mix: %d%% leapers (walker %d HP / leaper %d HP)" % [
		GameManager.night_number, int(round(lf * 100.0)),
		_zombie_hp_for_type(_type_walker.max_health),
		_zombie_hp_for_type(_type_leaper.max_health)])
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
	# Per-night earnings telemetry — the data pricing decisions need.
	print("[ECONOMY] night %d earned %d pts, spent %d, balance %d" % [
		GameManager.night_number, PointsManager.earned_this_night,
		PointsManager.spent_this_night, PointsManager.points])
	_update_wave_hud()

	_hud.show_message("DAY — safe. Open the supply crate to spend points.")

# --- Nightly wave: trickle spawn + all-clear -----------------------------
func _process(delta: float) -> void:
	_update_nvg_daylight(delta)
	if _hud and _hud.debug_audio_visible():
		_update_audio_debug()
	# Safety net: if the prompt is up while something is still alive, retract it.
	# Runs every frame so a stale prompt can't persist even if no death fires.
	if _all_clear_shown and not GameManager.is_day() and alive_count() > 0:
		_check_all_clear()

	if GameManager.is_day() or _wave_spawned >= _wave_total:
		return
	_spawn_timer -= delta
	# Remaining spawns queue while we're at the concurrent cap; the timer stays
	# elapsed so the next slot fills as soon as a zombie dies.
	if _spawn_timer <= 0.0 and alive_count() < max_concurrent:
		_spawn_zombie()
		_wave_spawned += 1
		_spawn_timer = _spawn_interval * randf_range(1.0 - spawn_jitter, 1.0 + spawn_jitter)
		_update_wave_hud()

# --- Navmesh ---------------------------------------------------------------
## Rebake the navigation mesh so zombies path around newly placed obstacles —
## and back through the gap when a sandbag section is destroyed.
##
## THREADED on purpose: destruction happens mid-night in an unpaused context,
## and a synchronous bake there would hitch the frame. While the thread runs
## the OLD navmesh stays live, so zombies keep moving on stale paths for a
## few hundred milliseconds and then re-route — which is exactly the desired
## "they notice the breach a moment later" behaviour.
##
## Calls are coalesced: several placements or simultaneous breaches produce a
## single bake rather than one each.
func request_navmesh_rebake(reason: String = "") -> void:
	_nav_rebake_reason = reason
	if _nav_rebake_pending:
		return
	_nav_rebake_pending = true
	_do_navmesh_rebake.call_deferred()

func _do_navmesh_rebake() -> void:
	_nav_rebake_pending = false
	if _nav_baking:
		# A bake is already running; queue one more pass behind it.
		_nav_rebake_queued = true
		return
	_nav_baking = true
	_nav_bake_started_us = Time.get_ticks_usec()
	# Both regions rebake together — the mouth region is tiny (thin patches
	# only) so this costs almost nothing extra.
	_nav_bakes_in_flight = 2
	_nav_region.bake_navigation_mesh(true)     # on_thread
	_mouth_region.bake_navigation_mesh(true)   # on_thread

## Shared by both regions' bake_finished signal. A rebake isn't "done" until
## BOTH report in.
func _on_navmesh_baked() -> void:
	_nav_bakes_in_flight -= 1
	if _nav_bakes_in_flight > 0:
		return
	var ms := float(Time.get_ticks_usec() - _nav_bake_started_us) / 1000.0
	print("[NAVMESH] rebake finished in %.1f ms%s" % [
		ms, "  (%s)" % _nav_rebake_reason if _nav_rebake_reason != "" else ""])
	_nav_baking = false
	if _nav_rebake_queued:
		_nav_rebake_queued = false
		request_navmesh_rebake(_nav_rebake_reason)

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
	return _zombie_hp_for_type(zombie_base_hp)

## Same per-night step, applied to whatever the variant's BASE health is.
## The step is absolute (+8 per 2 nights), not proportional, so a leaper's
## 60 HP and a walker's 100 HP both gain the same amount and the leaper stays
## exactly 40 HP squishier for the whole run.
func _zombie_hp_for_type(base: int) -> int:
	var steps: int = int(floor(float(GameManager.night_number - 1) / float(maxi(1, nights_per_step))))
	return base + hp_per_step * maxi(0, steps)

## Fraction of tonight's spawns that should be leapers. Nights 1-3 are pure
## walkers; from night 4 it opens at 10% and climbs 5%/night to a 30% ceiling.
func leaper_fraction_for_night(night: int) -> float:
	if night < leaper_first_night:
		return 0.0
	var extra: int = night - leaper_first_night
	return minf(leaper_start_fraction + leaper_fraction_step * float(extra), leaper_max_fraction)

## Roll this spawn's variant against tonight's leaper share.
func _pick_zombie_type() -> ZombieType:
	if randf() < leaper_fraction_for_night(GameManager.night_number):
		return _type_leaper
	return _type_walker

func _spawn_zombie() -> void:
	var angle := randf() * TAU
	var r := randf_range(TREE_RING_MIN - 2.0, TREE_RING_MAX)
	var z = zombie_scene.instantiate()  # untyped for the zombie's custom API
	# Both BEFORE add_child: _ready() seeds hp from max_hp and builds the
	# variant's silhouette from zombie_type.
	var zt := _pick_zombie_type()
	z.zombie_type = zt
	z.max_hp = _zombie_hp_for_type(zt.max_health)
	add_child(z)
	z.global_position = Vector3(cos(angle) * r, 0.3, sin(angle) * r)
	z.died.connect(_on_zombie_died)
	z.set_active(true)
	if _hitbox_debug_on:
		z.set_hitbox_debug(true)
	_zombies.append(z)

## THE single source of truth for "how many zombies are alive". Derived from
## the actual roster every time rather than a running counter, so it cannot
## drift out of step with reality. Both the HUD and the all-clear read this.
## Uses is_alive() rather than is_instance_valid() because queue_free() is
## deferred — a corpse stays valid for the rest of the frame.
func alive_count() -> int:
	var n := 0
	for z in _zombies:
		if is_instance_valid(z) and z.is_alive():
			n += 1
	return n

func _on_zombie_died() -> void:
	_prune_zombies()
	_update_wave_hud()
	_check_all_clear()

func _check_all_clear() -> void:
	if GameManager.is_day():
		return
	var alive := alive_count()
	var remaining := maxi(0, _wave_total - _wave_spawned)

	# Safety re-check: if the prompt is up but something is still alive, pull
	# it down. Unreachable while the condition below is correct — this turns a
	# future regression into a flicker instead of a game-breaking prompt.
	if _all_clear_shown and alive > 0:
		_all_clear_shown = false
		_hud.hide_all_clear()
		print("[ALL-CLEAR] retracted — %d still alive" % alive)
		return
	if _all_clear_shown:
		return

	# BOTH conditions required: the spawn queue is exhausted AND nothing is
	# left alive. Neither alone is sufficient.
	if remaining <= 0 and alive <= 0:
		_all_clear_shown = true
		_hud.show_all_clear(char(KEY_SKIP_TO_DAY), char(KEY_FINISH_NIGHT))
		print("[ALL-CLEAR] shown — queue remaining 0, alive 0")
	else:
		var states: Array = []
		for z in _zombies:
			if is_instance_valid(z) and z.is_alive():
				states.append(z.state_name())
		print("[ALL-CLEAR] not yet — queue remaining %d, alive %d, states: %s" % [
			remaining, alive, ", ".join(states) if states.size() > 0 else "none"])

func _update_wave_hud() -> void:
	_hud.set_wave_status(GameManager.night_number, _wave_spawned, _wave_total, alive_count())

# --- Global key input (NVG toggle + all-clear prompt) --------------------
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# MODAL FIRST. The all-clear prompt owns Y/N while it is visible, and N is
	# also the global NVG bind — without this ordering the NVG toggle would
	# swallow "finish the night" and the prompt would look broken. Handled
	# events stop here so nothing downstream sees the answer either.
	if _hud and _hud.all_clear_visible():
		if event.keycode == KEY_SKIP_TO_DAY:
			_hud.hide_all_clear()
			GameManager.force_phase(GameManager.Phase.DAY)
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_FINISH_NIGHT:
			_hud.hide_all_clear()
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed(ACTION_NVG_TOGGLE):
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
	if event.keycode == KEY_DEBUG_BLAST:
		# Faction-blind by design: this will hurt the player too.
		var r: Dictionary = AreaDamageSystem.detonate(
			player.global_position, DEBUG_BLAST_PROFILE, Vector3.ZERO, "debug")
		_hud.show_message("DEBUG BLAST — %d actors, %d killed, %d structures" % [
			r.get("actors", 0), r.get("killed", 0), r.get("structures", 0)])
		return
	if event.keycode == KEY_DEBUG_SPAWN_FIGHTER:
		_debug_spawn_fighter()
		return
	if event.keycode == KEY_DEBUG_SPAWN_COVER_TEST:
		_debug_spawn_cover_test()
		return
	if event.keycode == KEY_DEBUG_COVER_DRAW:
		var on := _cover_debug.toggle()
		_hud.show_message("Cover/concealment overlay " + ("ON" if on else "OFF"))
		return
	if event.keycode == KEY_DEBUG_SECTOR_PREVIEW:
		_toggle_sector_previews()
		return

# ---------------------------------------------------------------------------
# TEMPORARY SCAFFOLDING — DELETE WHEN POSITION TWO EXISTS. See the constants
# block near the top of this file.
#
# Drops one freshly-recruited fighter in front of the player, facing the same
# way the player is, and dumps its rolled statline to the console. Placement
# rules, the 8-cap and the recruit economy are all phases of their own — this
# deliberately enforces NONE of them, because its only job is to put a fighter
# in the world so the entity itself can be verified.
func _debug_spawn_fighter() -> void:
	var f := _spawn_fighter()
	var live: int = get_tree().get_nodes_in_group(Fighter.GROUP).size()
	_hud.show_message("DEBUG FIGHTER — %s (%d live)" % [f.fighter_name, live])

## THE ONE place a Fighter is spawned into the world. Both the debug M key
## above and RosterMenu's recruit purchase (wired via a Callable in
## _ready()) call this — recruiting reuses the exact same spawn-in-front-of-
## the-player placement, not a second spatial decision. Placement UI (a real
## ghost preview the player aims) is a later phase; this is deliberately the
## simplest thing that puts a fighter somewhere reasonable.
func _spawn_fighter() -> Fighter:
	var f := Fighter.new()
	f.name = "Fighter"
	# recruit() BEFORE add_child() — same convention _spawn_zombie() already
	# uses (set config, then add_child, because _ready() consumes it
	# synchronously). Calling recruit() after add_child() used to trip
	# Fighter's own "recruit() called twice" assertion on every single
	# recruit: add_child() runs _ready() synchronously, whose fallback saw an
	# unrolled fighter and rolled it itself, so this call was already the
	# SECOND roll by the time it ran.
	f.recruit(FIGHTER_TYPE_IRREGULAR)
	add_child(f)

	var fwd := -player.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	f.global_position = player.global_position + fwd * DEBUG_FIGHTER_SPAWN_DISTANCE
	# Facing the same way the player is, so the sector points downrange rather
	# than back at whoever just spawned it.
	f.global_rotation.y = player.global_rotation.y

	# Sector-of-fire preview, one per fighter, hidden until toggled. Attached
	# here rather than inside Fighter so the entity keeps owning no
	# visualization — the same separation RosterMenu keeps from placement.
	var preview := SectorPreview.new()
	preview.name = "SectorPreview"
	preview.setup(f, COVER_PREVIEW_CONFIG)
	f.add_child(preview)
	preview.set_shown(_sector_previews_on)

	print("[FIGHTER] %s" % f.stat_line())
	return f

## Shows or hides every live fighter's sector-of-fire wedge at once.
##
## The state is remembered on _sector_previews_on so a fighter recruited
## while the previews are up comes in already showing one, rather than the
## display silently going inconsistent the moment the roster changes.
func _toggle_sector_previews() -> void:
	_sector_previews_on = not _sector_previews_on
	var n := 0
	for node in get_tree().get_nodes_in_group(Fighter.GROUP):
		var p := node.get_node_or_null("SectorPreview") as SectorPreview
		if p:
			p.set_shown(_sector_previews_on)
			n += 1
	if n == 0 and _sector_previews_on:
		_hud.show_message("Sector previews ON — no fighters to show (M spawns one).")
		return
	_hud.show_message("Sector-of-fire previews " + ("ON (%d)" % n if _sector_previews_on else "OFF"))

## See the KEY_DEBUG_SPAWN_COVER_TEST block above. A bare StaticBody3D + box
## mesh + CoverSurface, CONCEALMENT type — collision_layer starts at 0 (not
## even world-solid layer 1), so nothing about it blocks movement or rounds
## by itself; CoverSurface.attach_to() ORs in ONLY the concealment bit. Real
## foliage (Position Two) would look different but must wire up identically.
func _debug_spawn_cover_test() -> void:
	var fwd := -player.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()

	var body := StaticBody3D.new()
	body.name = "DebugConcealmentTest"
	body.collision_layer = 0
	body.collision_mask = 0
	body.global_position = player.global_position + fwd * DEBUG_COVER_TEST_SPAWN_DISTANCE
	body.global_position.y += DEBUG_COVER_TEST_SIZE.y * 0.5

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = DEBUG_COVER_TEST_SIZE
	col.shape = shape
	body.add_child(col)

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = DEBUG_COVER_TEST_SIZE
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.65, 0.25, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material_override = mat
	body.add_child(mesh)

	add_child(body)

	var cover := CoverSurface.new()
	cover.cover_type = CoverSurface.Type.CONCEALMENT
	cover.blocks_navigation = false
	body.add_child(cover)
	cover.attach_to(body)

	_hud.show_message("DEBUG CONCEALMENT TEST spawned (O) — layer bit only, no LOS gating until Phase 2.")

# --- Zombie bookkeeping ---------------------------------------------------
func _prune_zombies() -> void:
	_zombies = _zombies.filter(func(z): return is_instance_valid(z))
