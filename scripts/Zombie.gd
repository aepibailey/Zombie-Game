extends CharacterBody3D
## Walker zombie: enum state machine (Wander / Investigate / Chase / Attack)
## driven by the noise bus and line-of-sight. See PROJECT_SPEC.md "Zombie AI".

enum State { WANDER, INVESTIGATE, CHASE, ATTACK }

# --- Tuning ---------------------------------------------------------------
const MAX_HP := 100
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

var hp := MAX_HP
var state: int = State.WANDER
var active := false                # only true at night (spec: dormant by day)
var last_hit_headshot := false

var _investigate_timer := 0.0
var _attack_timer := 0.0
var _repath_timer := 0.0
var _target_pos: Vector3 = Vector3.ZERO      # fixed nav goal (wander pt or noise loc)
var _last_noise_radius := 0.0                # radius of the noise being investigated
var _last_known_player: Vector3 = Vector3.ZERO
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 24.0)

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var body_mesh: MeshInstance3D = $Body

func _ready() -> void:
	add_to_group("zombies")
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
			player.take_damage(ATTACK_DAMAGE)

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
	q.exclude = [self]
	var hit := space.intersect_ray(q)
	return hit and hit.collider == player

func _get_player():
	# Untyped return so callers get dynamic access to the player's custom API.
	var players := get_tree().get_nodes_in_group("player")
	return players[0] if players.size() > 0 else null

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

# --- Combat ---------------------------------------------------------------
func take_damage(amount: int, headshot: bool) -> void:
	var dmg := amount * (HEADSHOT_MULT if headshot else 1)
	hp -= dmg
	last_hit_headshot = headshot
	# Being shot is a confirmed contact — start chasing the shooter.
	if active and not GameManager.is_day():
		_enter_chase()
	if hp <= 0:
		_die()

func _die() -> void:
	# Headshot kill = 3 pts, body kill = 1 pt (not additive) — spec scoring.
	PointsManager.add_points(3 if last_hit_headshot else 1)
	queue_free()

# --- Wander target --------------------------------------------------------
func _pick_wander_target() -> void:
	var angle := randf() * TAU
	var r := randf_range(4.0, WANDER_RADIUS)
	_target_pos = Vector3(cos(angle) * r, global_position.y, sin(angle) * r)
