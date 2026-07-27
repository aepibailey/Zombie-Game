extends CharacterBody3D
## Walker zombie: enum state machine (Wander / Investigate / Chase / Attack)
## driven by the noise bus and line-of-sight. See PROJECT_SPEC.md "Zombie AI".

signal died   ## emitted just before this zombie frees itself (wave tracking)

const SFX_DEATH := "res://audio/zombie_death.wav"
const FOOTSTEP_DIR := "res://assets/audio/zombie/"
const FOOTSTEP_COUNT := 5

# --- Footstep audio (tunable per-instance in the inspector) ---------------
## Attenuation: inverse-distance so proximity reads sharply in the last few
## metres. First audible ~20m; tune by ear with unit_size / volume_db.
@export var footstep_max_distance: float = 20.0
@export var footstep_unit_size: float = 1.5
@export var footstep_volume_db: float = 6.0
## Step cadence is derived from ACTUAL velocity, interpolated between these two
## anchors (wander speed -> chase speed), so steps never desync from movement.
@export var step_interval_wander: float = 0.75
@export var step_interval_chase: float = 0.45
@export var step_min_speed: float = 0.15   # below this the zombie is standing still
@export var step_pitch_variance: float = 0.08   # +/- 8%

enum State { WANDER, INVESTIGATE, CHASE, ATTACK }

# --- Tuning ---------------------------------------------------------------
const BASE_HP := 100                # night-scaled by the spawner via `max_hp`
const HEADSHOT_MULT := 2            # PROJECT_SPEC.md "Combat & Scoring"
const WANDER_SPEED := 1.6
const CHASE_SPEED := 3.6
const CHASE_LOSE_RANGE := 26.0     # drop chase past this with no LOS
const ATTACK_RANGE := 1.8
const ATTACK_DAMAGE := 20          # PROJECT_SPEC.md "Combat & Scoring"
const ATTACK_INTERVAL := 1.0
const INVESTIGATE_TIMEOUT := 10.0  # give up on a noise after ~10s
const WANDER_RADIUS := 26.0        # roam within the map bounds
const REPATH_INTERVAL := 0.3

## Set by the spawner BEFORE add_child(); _ready() seeds `hp` from it.
var max_hp := BASE_HP
var hp := BASE_HP
var state: int = State.WANDER
var active := false                # only true at night (spec: dormant by day)
var last_hit_headshot := false

# Shots-to-kill telemetry (logged on death to tune the HP step).
var _hits_head := 0
var _hits_body := 0

# Footstep audio state.
var _footstep_player: AudioStreamPlayer3D
var _footstep_samples: Array = []
var _step_timer := 0.0
var _hitbox_debug: Node3D

var _investigate_timer := 0.0
var _attack_timer := 0.0
var _repath_timer := 0.0
var _target_pos: Vector3 = Vector3.ZERO      # fixed nav goal (wander pt or noise loc)
var _last_noise_radius := 0.0                # radius of the noise being investigated
var _last_known_player: Vector3 = Vector3.ZERO
var _hit_flash := 0.0                         # brief white flash timer when shot
var _dead := false                            # set once, in _die()
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 24.0)

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var body_mesh: MeshInstance3D = $Body
@onready var head_hitbox: Area3D = $HeadHitbox

func _ready() -> void:
	add_to_group("zombies")
	# The head Area3D is tagged so weapon rays can identify a headshot from the
	# collider itself — no hit-height guessing.
	head_hitbox.add_to_group("zombie_heads")
	head_hitbox.set_meta("zombie", self)
	hp = max_hp   # spawner set max_hp for this night's scaling
	_build_footsteps()
	agent.path_desired_distance = 0.6
	agent.target_desired_distance = 0.8
	agent.radius = 0.5
	agent.avoidance_enabled = false
	NoiseManager.noise_emitted.connect(_on_noise_emitted)
	# Sub-resources are shared across scene instances; give each zombie its
	# own material so tinting one doesn't recolour them all.
	if body_mesh.material_override:
		body_mesh.material_override = body_mesh.material_override.duplicate()
	_pick_wander_target()
	_refresh_tint()

func set_active(a: bool) -> void:
	active = a
	_refresh_tint()

func _refresh_tint() -> void:
	if body_mesh.material_override is StandardMaterial3D:
		var m: StandardMaterial3D = body_mesh.material_override
		# Dim/greyed while dormant during the day, sickly green when hunting.
		m.albedo_color = Color(0.25, 0.6, 0.25) if active else Color(0.35, 0.38, 0.35)

func _physics_process(delta: float) -> void:
	# Brief white hit-flash fade back to the normal tint.
	if _hit_flash > 0.0:
		_hit_flash -= delta
		if _hit_flash <= 0.0:
			_refresh_tint()

	# Gravity keeps them grounded.
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0

	# Dormant during the day (or before night activation): stand still.
	if not active or GameManager.is_day():
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	match state:
		State.WANDER:
			_do_wander(delta)
		State.INVESTIGATE:
			_do_investigate(delta)
		State.CHASE:
			_do_chase(delta)
		State.ATTACK:
			_do_attack(delta)

	move_and_slide()
	# After move_and_slide so cadence tracks ACTUAL movement — a zombie stuck
	# against geometry goes quiet instead of running in place.
	_update_footsteps(delta)

# --- States ---------------------------------------------------------------
func _do_wander(delta: float) -> void:
	# Pure roaming. Zombies never read the player's position here — a silent
	# (crouching) player can pass right by. Chase is only entered through a
	# confirmed contact (laser reveal or being shot).
	_move_toward(_target_pos, WANDER_SPEED, delta)
	if global_position.distance_to(_target_pos) < 1.2:
		_pick_wander_target()

func _do_investigate(delta: float) -> void:
	# Path to the FIXED location the noise came from — not the player's live
	# transform. If nothing is found before the timeout (or on arrival), give
	# up and return to Wander.
	_investigate_timer -= delta
	_move_toward(_target_pos, WANDER_SPEED, delta)
	var arrived := global_position.distance_to(_target_pos) < 1.5
	if arrived or _investigate_timer <= 0.0:
		state = State.WANDER
		_pick_wander_target()

func _do_chase(delta: float) -> void:
	var player = _get_player()
	if player == null:
		state = State.WANDER
		_pick_wander_target()
		return

	var dist := global_position.distance_to(player.global_position)
	if _has_los_to(player):
		_last_known_player = player.global_position

	if dist <= ATTACK_RANGE:
		state = State.ATTACK
		_attack_timer = 0.0
		return

	if dist > CHASE_LOSE_RANGE and not _has_los_to(player):
		# Lost them — go poke around where we last saw them.
		state = State.INVESTIGATE
		_investigate_timer = INVESTIGATE_TIMEOUT
		_target_pos = _last_known_player
		return

	_move_toward(player.global_position, CHASE_SPEED, delta)

func _do_attack(delta: float) -> void:
	var player = _get_player()
	if player == null:
		state = State.WANDER
		_pick_wander_target()
		return

	var dist := global_position.distance_to(player.global_position)
	if dist > ATTACK_RANGE * 1.3:
		_enter_chase()
		return

	# Stop and face the target while swinging.
	velocity.x = 0.0
	velocity.z = 0.0
	_face(player.global_position)

	_attack_timer -= delta
	if _attack_timer <= 0.0:
		_attack_timer = ATTACK_INTERVAL
		if player.has_method("take_damage"):
			player.take_damage(ATTACK_DAMAGE, global_position)

# --- Movement helper (nav agent w/ direct fallback) -----------------------
func _move_toward(target: Vector3, speed: float, delta: float) -> void:
	_repath_timer -= delta
	if _repath_timer <= 0.0:
		_repath_timer = REPATH_INTERVAL
		agent.target_position = target

	var next := agent.get_next_path_position()
	var dir := next - global_position
	dir.y = 0.0
	# If the navmesh has no path yet, steer straight at the goal.
	if dir.length() < 0.1:
		dir = target - global_position
		dir.y = 0.0
	dir = dir.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	if dir.length() > 0.01:
		_face(global_position + dir)

func _face(target: Vector3) -> void:
	var flat := Vector3(target.x, global_position.y, target.z)
	if flat.distance_to(global_position) > 0.05:
		look_at(flat, Vector3.UP)

# --- Perception -----------------------------------------------------------
# NOTE: line-of-sight is only consulted from Chase (to track/lose a target the
# zombie already has a confirmed fix on). Wander/Investigate never look at the
# player, so noise events are the only thing that can move an un-alerted zombie.
func _has_los_to(player: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3(0, 1.4, 0)
	var to := player.global_position + Vector3(0, 1.2, 0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	return hit and hit.collider == player

func _get_player() -> Player:
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return null
	return players[0] as Player

# --- External triggers ----------------------------------------------------
## Noise bus callback: alerts to a location, not to the player specifically.
## Stores the noise's fixed (position, radius) and heads there. A newer noise
## within range while wandering/investigating simply replaces the target with
## its own fixed location — each event is independent of the player's transform.
func _on_noise_emitted(position: Vector3, radius: float) -> void:
	if not active or GameManager.is_day():
		return
	if state == State.CHASE or state == State.ATTACK:
		return
	if global_position.distance_to(position) <= radius:
		state = State.INVESTIGATE
		_investigate_timer = INVESTIGATE_TIMEOUT
		_target_pos = position
		_last_noise_radius = radius

## Red-laser proximity reveal (from Player): confirmed player position -> chase.
func reveal_player(player_pos: Vector3) -> void:
	if not active or GameManager.is_day():
		return
	_last_known_player = player_pos
	_enter_chase()

func _enter_chase() -> void:
	state = State.CHASE
	var player = _get_player()
	if player:
		_last_known_player = player.global_position

# --- Footstep audio -------------------------------------------------------
func _build_footsteps() -> void:
	_footstep_player = AudioStreamPlayer3D.new()
	# Inverse-distance: loudness climbs sharply in the last few metres rather
	# than fading linearly, so "it's close" is unmistakable.
	_footstep_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_footstep_player.max_distance = footstep_max_distance
	_footstep_player.unit_size = footstep_unit_size
	_footstep_player.volume_db = footstep_volume_db
	_footstep_player.position = Vector3(0, 0.2, 0)   # at the feet
	add_child(_footstep_player)

	for i in range(1, FOOTSTEP_COUNT + 1):
		var path := "%sfootstep_%02d.wav" % [FOOTSTEP_DIR, i]
		if ResourceLoader.exists(path):
			_footstep_samples.append(load(path))

	# Random phase per zombie so a converging group sounds like many creatures,
	# not one giant one stomping in lockstep.
	_step_timer = randf() * step_interval_wander

func _update_footsteps(delta: float) -> void:
	if _footstep_samples.is_empty():
		return
	var speed := Vector2(velocity.x, velocity.z).length()
	if speed < step_min_speed:
		return   # standing still makes no sound

	_step_timer -= delta
	if _step_timer > 0.0:
		return

	# Cadence derived from real velocity: interpolate the two anchors between
	# wander and chase speed, so a chasing zombie steps faster in real time.
	var t: float = clampf(inverse_lerp(WANDER_SPEED, CHASE_SPEED, speed), 0.0, 1.0)
	_step_timer = lerpf(step_interval_wander, step_interval_chase, t)

	_footstep_player.stream = _footstep_samples[randi() % _footstep_samples.size()]
	_footstep_player.pitch_scale = randf_range(1.0 - step_pitch_variance, 1.0 + step_pitch_variance)
	_footstep_player.play()

## Distance at which this zombie's steps become audible (for the debug overlay).
func footstep_range() -> float:
	return footstep_max_distance

# --- Combat ---------------------------------------------------------------
## Returns the damage actually dealt, so the shooter can report it.
func take_damage(amount: int, headshot: bool) -> int:
	var dmg := amount * (HEADSHOT_MULT if headshot else 1)
	hp -= dmg
	last_hit_headshot = headshot
	if headshot:
		_hits_head += 1
	else:
		_hits_body += 1
	_flash_white()
	# Being shot is a confirmed contact — start chasing the shooter.
	if active and not GameManager.is_day():
		_enter_chase()
	if hp <= 0:
		_die()
	return dmg

## True until this zombie has actually died. `queue_free()` is deferred, so a
## corpse stays instance-valid for the rest of the frame — callers must use
## this rather than is_instance_valid() to decide whether it still counts.
func is_alive() -> bool:
	return not _dead

## Human-readable current state, for the all-clear debug line.
func state_name() -> String:
	match state:
		State.WANDER: return "WANDER"
		State.INVESTIGATE: return "INVESTIGATE"
		State.CHASE: return "CHASE"
		State.ATTACK: return "ATTACK"
		_: return "UNKNOWN(%d)" % state

## Toggle translucent hitbox volumes (debug affordance).
func set_hitbox_debug(on: bool) -> void:
	if _hitbox_debug == null and on:
		_build_hitbox_debug()
	if _hitbox_debug:
		_hitbox_debug.visible = on

func _build_hitbox_debug() -> void:
	_hitbox_debug = Node3D.new()
	add_child(_hitbox_debug)

	var body_vis := MeshInstance3D.new()
	var bm := CapsuleMesh.new()
	bm.radius = 0.4
	bm.height = 1.56
	body_vis.mesh = bm
	body_vis.position = Vector3(0, 0.78, 0)
	body_vis.material_override = _debug_material(Color(0.2, 0.6, 1.0, 0.25))
	_hitbox_debug.add_child(body_vis)

	var head_vis := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.12
	hm.height = 0.24
	head_vis.mesh = hm
	head_vis.position = Vector3(0, 1.68, 0)
	head_vis.material_override = _debug_material(Color(1.0, 0.9, 0.1, 0.45))
	_hitbox_debug.add_child(head_vis)

func _debug_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = color
	return m

func _flash_white() -> void:
	_hit_flash = 0.12
	if body_mesh.material_override is StandardMaterial3D:
		body_mesh.material_override.albedo_color = Color(1, 1, 1)

func _die() -> void:
	# Re-entry guard. queue_free() is DEFERRED, so this node stays valid for the
	# rest of the frame — and a shotgun blast delivers all 9 pellets within a
	# single frame. Without this, every pellet landing after the killing one
	# re-ran the whole death path: duplicate `died` signals (which drove the
	# wave's alive count below zero) and duplicate point awards.
	if _dead:
		return
	_dead = true
	# Headshot kill = 3 pts, body kill = 1 pt (not additive) — spec scoring.
	PointsManager.add_points(3 if last_hit_headshot else 1)
	# Shots-to-kill telemetry for tuning the HP step size.
	print("[Night %d] zombie down — maxHP %d, shots: %d head + %d body = %d total (killing blow: %s)" % [
		GameManager.night_number, max_hp, _hits_head, _hits_body,
		_hits_head + _hits_body, "HEAD" if last_hit_headshot else "BODY"])
	_play_death_sound()
	died.emit()   # let the wave tracker decrement the live count
	queue_free()

func _play_death_sound() -> void:
	if not ResourceLoader.exists(SFX_DEATH):
		return
	# Detached from the zombie so it survives queue_free(); frees itself when done.
	var p := AudioStreamPlayer3D.new()
	var res = load(SFX_DEATH)  # untyped: avoids a Resource->AudioStream downcast error
	p.stream = res
	p.max_distance = 45.0
	get_tree().current_scene.add_child(p)
	p.global_position = global_position + Vector3(0, 1.0, 0)
	p.finished.connect(p.queue_free)
	p.play()

# --- Wander target --------------------------------------------------------
func _pick_wander_target() -> void:
	var angle := randf() * TAU
	var r := randf_range(4.0, WANDER_RADIUS)
	_target_pos = Vector3(cos(angle) * r, global_position.y, sin(angle) * r)
