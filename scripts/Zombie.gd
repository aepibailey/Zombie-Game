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

enum State {
	WANDER, INVESTIGATE, CHASE, ATTACK,
	ENTANGLED,          # held in C-wire: alive, immobile, can still swing
	FALLEN,             # fell into a ditch pit: alive, gravity-driven, one-way
	ATTACK_STRUCTURE,   # no path to the player — breaking through sandbags
}

# --- Fallen (ditch pit) -----------------------------------------------------
const FALLEN_DRIFT_SPEED := 0.35
const FALLEN_DRIFT_RADIUS := 1.0
const FALLEN_DRIFT_INTERVAL_MIN := 2.0
const FALLEN_DRIFT_INTERVAL_MAX := 4.0
const FALLEN_NOISE_RADIUS := 10.0

# --- Tuning ---------------------------------------------------------------
const BASE_HP := 100                # night-scaled by the spawner via `max_hp`
const HEADSHOT_MULT := 2            # PROJECT_SPEC.md "Combat & Scoring"
const WANDER_SPEED := 1.6
const CHASE_SPEED := 3.6
const CHASE_LOSE_RANGE := 26.0     # drop chase past this with no LOS
## Sight range used ONLY while investigating a laser dot — an alerted zombie
## that spots the operator switches to Chase by the normal rules.
const LASER_INVESTIGATE_SIGHT := 16.0
const ATTACK_RANGE := 1.8
const ATTACK_DAMAGE := 20          # PROJECT_SPEC.md "Combat & Scoring"
const ATTACK_INTERVAL := 1.0
const INVESTIGATE_TIMEOUT := 10.0  # give up on a noise after ~10s
const WANDER_RADIUS := 26.0        # roam within the map bounds
const REPATH_INTERVAL := 0.3

# --- Structure attack ------------------------------------------------------
## Damage dealt to sandbags, deliberately separate from ATTACK_DAMAGE (20) so
## anti-structure and anti-player pacing can be tuned independently.
@export var structure_damage: int = 15
@export var structure_attack_interval: float = 1.2
const STRUCTURE_REACH := 2.2
## How often to re-check whether a route to the player has opened up.
const REPATH_CHECK_INTERVAL := 1.0

# --- Speed modifiers -------------------------------------------------------
## Permanent multipliers compound (mine survivor 0.5, wire exit 0.85);
## temporary ones apply only while inside a volume (wire 0.4, full ditch 0.4).
## Total reduction is capped so a mined-then-wired zombie never becomes a
## de-facto stationary prop.
@export var min_speed_mult: float = 0.30   # never slower than 30% of base

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

# Obstacle interaction state.
var _perm_speed_mult := 1.0      # compounding permanent slows
var _temp_speed_mult := 1.0      # while inside a slowing volume
var _held_by = null              # the wire section holding us, if Entangled
var _fallen_landed := false      # true once gravity has settled us on the pit floor
var _fallen_landing_pos: Vector3 = Vector3.ZERO
var _fallen_drift_target: Vector3 = Vector3.ZERO
var _fallen_drift_timer := 0.0
var _structure_target = null     # sandbag section being attacked
var _structure_timer := 0.0
var _repath_check := 0.0
## True while investigating a laser dot specifically. Scoped so only this kind
## of investigation watches for the player — see _do_investigate.
var _investigating_laser := false
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 24.0)

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var body_mesh: MeshInstance3D = $Body
@onready var head_hitbox: Area3D = $HeadHitbox

func _ready() -> void:
	add_to_group("zombies")
	# World (layer 1) plus the ditch revetment (layer 6). NOT the player-only
	# barrier layer — wire must stay walk-into-able for the entangle mechanic.
	collision_mask = 1 | Obstacle.SOLID_NO_NAV_LAYER
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

	# Gravity keeps them grounded. Deliberately NOT short-circuited for FALLEN
	# (unlike the old TRAPPED state) — a pit zombie must actually fall.
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
		State.ENTANGLED:
			_do_entangled(delta)
		State.FALLEN:
			_do_fallen(delta)
		State.ATTACK_STRUCTURE:
			_do_attack_structure(delta)

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
	# Path to the FIXED location that drew us — noise origin or laser dot — not
	# the player's live transform. If nothing is found before the timeout (or on
	# arrival), give up and return to Wander.
	#
	# The player-sighting check is scoped to LASER investigations only. Noise
	# investigation deliberately never looks for the player: that is what makes
	# crouch-past-undetected work, and re-adding it globally would reintroduce
	# the old "investigate silently becomes a homing chase" bug.
	if _investigating_laser and _can_see_player():
		_investigating_laser = false
		_enter_chase()
		return

	_investigate_timer -= delta
	_move_toward(_target_pos, WANDER_SPEED, delta)
	var arrived := global_position.distance_to(_target_pos) < 1.5
	if arrived or _investigate_timer <= 0.0:
		_investigating_laser = false
		state = State.WANDER
		_pick_wander_target()

## Only used while investigating a laser dot.
func _can_see_player() -> bool:
	var player = _get_player()
	if player == null:
		return false
	if global_position.distance_to(player.global_position) > LASER_INVESTIGATE_SIGHT:
		return false
	return _has_los_to(player)

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

	# Walled in? Break through instead of milling against the sandbags.
	_repath_check -= delta
	if _repath_check <= 0.0:
		_repath_check = REPATH_CHECK_INTERVAL
		if not _player_reachable() and _try_enter_attack_structure():
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

# --- Obstacle states -------------------------------------------------------
## Held in wire: immobile and permanent, but still dangerous at melee range.
## Don't hug your own wire.
func _do_entangled(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	var player = _get_player()
	if player == null:
		return
	if global_position.distance_to(player.global_position) <= ATTACK_RANGE:
		_face(player.global_position)
		_attack_timer -= delta
		if _attack_timer <= 0.0:
			_attack_timer = ATTACK_INTERVAL
			player.take_damage(ATTACK_DAMAGE, global_position)

## Fell into a ditch pit. NavigationAgent3D is never touched here — no target
## is ever set and get_next_path_position() is never called, so there is no
## pathing at all, by construction, not by disabling a node. Gravity (applied
## above, in _physics_process) does the actual falling; once it lands, it
## mills aimlessly within a small radius of the spot it landed — a sitting
## duck. Never leaves this state — see is_immobilised(), which gates every
## transition out (noise, laser, being shot).
func _do_fallen(delta: float) -> void:
	if not _fallen_landed:
		velocity.x = 0.0
		velocity.z = 0.0
		if is_on_floor():
			_fallen_landed = true
			_fallen_landing_pos = global_position
			_fallen_drift_target = global_position
			_fallen_drift_timer = 0.0
			# A body hitting the bottom of a pit makes a sound — and pulling
			# more zombies toward the same lane is a feature, not a bug.
			NoiseManager.emit_noise(global_position, FALLEN_NOISE_RADIUS)
		return

	_fallen_drift_timer -= delta
	if _fallen_drift_timer <= 0.0:
		_fallen_drift_timer = randf_range(FALLEN_DRIFT_INTERVAL_MIN, FALLEN_DRIFT_INTERVAL_MAX)
		var angle := randf() * TAU
		var r := randf_range(0.0, FALLEN_DRIFT_RADIUS)
		_fallen_drift_target = _fallen_landing_pos + Vector3(cos(angle) * r, 0.0, sin(angle) * r)

	var dir := _fallen_drift_target - global_position
	dir.y = 0.0
	if dir.length() < 0.15:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	dir = dir.normalized()
	velocity.x = dir.x * FALLEN_DRIFT_SPEED
	velocity.z = dir.z * FALLEN_DRIFT_SPEED
	_face(global_position + dir)

## No route to the player, so break the wall instead. Re-evaluates pathing
## periodically and abandons the wall the moment a gap opens elsewhere.
func _do_attack_structure(delta: float) -> void:
	if _structure_target == null or not is_instance_valid(_structure_target):
		_structure_target = null
		_enter_chase()
		return

	_repath_check -= delta
	if _repath_check <= 0.0:
		_repath_check = REPATH_CHECK_INTERVAL
		if _player_reachable():
			_structure_target = null
			_enter_chase()
			return

	var point: Vector3 = _structure_target.nearest_point(global_position)
	var dist := global_position.distance_to(point)
	if dist > STRUCTURE_REACH:
		_move_toward(point, CHASE_SPEED, delta)
		return

	velocity.x = 0.0
	velocity.z = 0.0
	_face(point)
	_structure_timer -= delta
	if _structure_timer <= 0.0:
		_structure_timer = structure_attack_interval
		_structure_target.take_structure_damage(structure_damage, global_position)

## True when the nav agent can reach the player rather than stopping short.
func _player_reachable() -> bool:
	var player = _get_player()
	if player == null:
		return false
	var target := NavigationServer3D.map_get_closest_point(
		agent.get_navigation_map(), player.global_position)
	var path := NavigationServer3D.map_get_path(
		agent.get_navigation_map(), global_position, target, true)
	if path.size() == 0:
		return false
	return path[path.size() - 1].distance_to(target) < 2.0

## Called by Chase when the path stops short of the player: find a sandbag
## section to break through.
func _try_enter_attack_structure() -> bool:
	var best = null
	var best_d := INF
	for s in get_tree().get_nodes_in_group("sandbags"):
		if not is_instance_valid(s) or s.destroyed:
			continue
		var d: float = global_position.distance_to(s.nearest_point(global_position))
		if d < best_d:
			best_d = d
			best = s
	if best == null:
		return false
	_structure_target = best
	_structure_timer = 0.0
	_repath_check = REPATH_CHECK_INTERVAL
	state = State.ATTACK_STRUCTURE
	return true

# --- Obstacle hooks (called by the obstacles) ------------------------------
func enter_entangled(wire) -> void:
	if state == State.ENTANGLED or _dead:
		return
	_held_by = wire
	state = State.ENTANGLED
	_attack_timer = ATTACK_INTERVAL

## Called by ZombieDitch's trigger. One-way: if the body is a zombie and isn't
## already fallen, transition it — the guard below is exactly that check.
func enter_fallen(_pit) -> void:
	if state == State.FALLEN or _dead:
		return
	state = State.FALLEN
	_fallen_landed = false
	_investigating_laser = false

func is_immobilised() -> bool:
	return state == State.ENTANGLED or state == State.FALLEN

## Compounding and permanent — a mine survivor stays slow for the rest of its life.
func apply_permanent_slow(mult: float) -> void:
	_perm_speed_mult *= clampf(mult, 0.05, 1.0)

## Applies only while inside a volume; 1.0 clears it.
func set_temp_slow(mult: float) -> void:
	_temp_speed_mult = clampf(mult, 0.05, 1.0)

## Combined multiplier, floored so stacked slows can't approach zero.
func speed_mult() -> float:
	return maxf(min_speed_mult, _perm_speed_mult * _temp_speed_mult)

# --- Movement helper (nav agent w/ direct fallback) -----------------------
func _move_toward(target: Vector3, speed: float, delta: float) -> void:
	_repath_timer -= delta
	if _repath_timer <= 0.0:
		_repath_timer = REPATH_INTERVAL
		agent.target_position = target

	# Obstacle slows apply to every movement state.
	speed *= speed_mult()

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
	# Entangled and trapped zombies aren't going anywhere.
	if is_immobilised():
		return
	if global_position.distance_to(position) <= radius:
		state = State.INVESTIGATE
		# A noise redirect supersedes any laser curiosity.
		_investigating_laser = false
		_investigate_timer = INVESTIGATE_TIMEOUT
		_target_pos = position
		_last_noise_radius = radius

## The zombie noticed the laser DOT — not the player. It goes to look at the
## light out of curiosity; it has no idea where the operator is.
##
## Deliberately NOT a noise event: this never touches NoiseManager.
func notice_laser_dot(dot_pos: Vector3) -> void:
	if not active or GameManager.is_day() or _dead or is_immobilised():
		return
	if state == State.CHASE or state == State.ATTACK:
		return   # already has a confirmed fix; the light tells it nothing new
	state = State.INVESTIGATE
	_investigating_laser = true
	_investigate_timer = INVESTIGATE_TIMEOUT
	_target_pos = dot_pos

func _enter_chase() -> void:
	state = State.CHASE
	_investigating_laser = false
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
	# Being shot is a confirmed contact — start chasing the shooter, unless
	# we're held fast, in which case there's nowhere to go.
	if active and not GameManager.is_day() and not is_immobilised():
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
		State.ENTANGLED: return "ENTANGLED"
		State.FALLEN: return "FALLEN"
		State.ATTACK_STRUCTURE: return "ATTACK_STRUCTURE"
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
	# Killing a held zombie frees the slot it occupied. FALLEN has no capacity
	# to release — the pit is a real hole, not a limited number of slots.
	if _held_by and is_instance_valid(_held_by):
		_held_by.release(self)
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
