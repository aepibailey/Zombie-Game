extends CharacterBody3D
## Walker zombie: enum state machine (Wander / Investigate / Chase / Attack)
## driven by the noise bus and line-of-sight. See PROJECT_SPEC.md "Zombie AI".

signal died   ## emitted just before this zombie frees itself (wave tracking)

const SFX_DEATH := "res://audio/zombie_death.wav"
const FOOTSTEP_DIR := "res://assets/audio/zombie/"
const FOOTSTEP_COUNT := 5

## What a zombie chases, attacks, leaps at and paths toward. The player is the
## sole member today; an allied fighter joins it later with no change to this
## file.
##
## DELIBERATELY NOT AreaDamageSystem.GROUP_DAMAGEABLE and deliberately not
## Damageable.GROUP_BULLET. Those are the blast axis and the bullet axis; this
## is the AI-target axis, and merging any two of them would immediately make a
## zombie a valid target for another zombie. See Damageable.gd's own note on
## why the axes stay separate.
const GROUP_HOSTILE_TARGET := "hostile_target"

## LIVENESS IS EXPRESSED BY GROUP MEMBERSHIP, NOT BY is_alive().
##
## _acquire_target() deliberately does NOT filter on is_alive(). Player's
## is_alive() is a ONE-FRAME DEATH LATCH (`not _died_this_frame`) rather than a
## persistent state — take_damage() respawns synchronously at 0 HP — so
## filtering on it would leave every chasing zombie with no target for exactly
## one frame on player death, dropping them all to Wander and re-rolling their
## wander targets. That is a visible behavioural change, and this refactor's
## binding constraint is that behaviour with one group member is identical to
## before it.
##
## So the contract is: a member of this group is a valid target. Anything that
## dies permanently removes itself from the group as it dies.

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
	LEAP,               # committed ballistic arc over an obstruction
	LEAP_RECOVER,       # landed, briefly immobile
}

# --- Fallen (ditch pit) -----------------------------------------------------
const FALLEN_DRIFT_SPEED := 0.35
const FALLEN_DRIFT_RADIUS := 1.0
const FALLEN_DRIFT_INTERVAL_MIN := 2.0
const FALLEN_DRIFT_INTERVAL_MAX := 4.0
const FALLEN_NOISE_RADIUS := 10.0

# --- Variant definition ----------------------------------------------------
## Per-variant stats (health, speeds, melee, scoring, leap, appearance) live
## in a ZombieType resource — see scripts/ZombieType.gd. The spawner assigns
## one before add_child(); the fallback below only matters for a zombie
## dropped into a scene by hand.
const DEFAULT_TYPE := "res://resources/zombie_walker.tres"
@export var zombie_type: ZombieType

# --- Tuning (shared by every variant — deliberately NOT per-type) ---------
const BASE_HP := 100                # night-scaled by the spawner via `max_hp`
const HEADSHOT_MULT := 2            # PROJECT_SPEC.md "Combat & Scoring"
const CHASE_LOSE_RANGE := 26.0     # drop chase past this with no LOS
## Sight range used ONLY while investigating a laser dot — an alerted zombie
## that spots the operator switches to Chase by the normal rules.
const LASER_INVESTIGATE_SIGHT := 16.0
const ATTACK_RANGE := 1.8
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

# --- Target re-evaluation --------------------------------------------------
## How often, in seconds, this zombie reconsiders WHICH hostile target it is
## pursuing.
##
## 0.0 = re-evaluate on every query, which is exactly what the pre-abstraction
## code did (the old _get_player() ran a fresh group lookup at every call
## site, every frame). It is the default precisely because any positive value
## would change behaviour on day one, and this refactor must not.
##
## Exported now, unused-in-effect at 0.0, so the step that adds a second
## target to the group can tune re-acquisition cadence without reopening this
## file.
@export var target_reevaluate_interval: float = 0.0

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
var _last_known_target: Vector3 = Vector3.ZERO
## Populated only when target_reevaluate_interval > 0.0 — see _acquire_target().
var _target_cache: Node3D = null
var _target_timer := 0.0
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

# Chase ramp state (leaper). The walker's type has 0 for both, so these are
# inert for it and its speed resolves to move_speed_chase immediately.
var _chase_elapsed := 0.0        # seconds since entering Chase
# Leap state.
var _leap_cooldown := 0.0        # counts down; leap only when <= 0
var _leap_airborne := false      # true once we've actually left the ground
var _leap_recover := 0.0
var _leap_screech: AudioStreamPlayer3D
var _structure_timer := 0.0
var _repath_check := 0.0
## True while investigating a laser dot specifically. Scoped so only this kind
## of investigation watches for the player — see _do_investigate.
var _investigating_laser := false
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 24.0)

# UAV reveal state. See _build_uav_silhouette().
var _uav_silhouette: MeshInstance3D
var _uav_revealed := false   # what UAVSystem wants; distance cutoff can still hide it

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var body_mesh: MeshInstance3D = $Body
@onready var head_hitbox: Area3D = $HeadHitbox

func _ready() -> void:
	add_to_group("zombies")
	add_to_group(AreaDamageSystem.GROUP_DAMAGEABLE)
	# What a PLAYER ROUND can damage. This is what _fire_ray resolves against;
	# the legacy "zombies" group below is retained for the many other systems
	# that query it (Claymore, Minefield, UAVOverlay, ApacheSystem, ...) but
	# the weapon path no longer names it.
	#
	# NOT joined to GROUP_HOSTILE_TARGET, and that omission is load-bearing:
	# that group is what zombies HUNT, so a zombie in it would be hunted by
	# other zombies. See Damageable.gd on why the axes stay separate.
	add_to_group(Damageable.GROUP_BULLET)
	# A hand-placed zombie with no type assigned still has to work.
	if zombie_type == null:
		zombie_type = load(DEFAULT_TYPE)
	add_to_group("zombie_" + zombie_type.id)
	# World (layer 1) plus the ditch revetment (layer 6). NOT the player-only
	# barrier layer — wire must stay walk-into-able for the entangle mechanic.
	collision_mask = 1 | Obstacle.SOLID_NO_NAV_LAYER
	# The head Area3D is tagged so weapon rays can identify a headshot from the
	# collider itself — no hit-height guessing.
	# The legacy group is RETAINED, not vestigial: BuildMode's placement
	# overlap check still tests it to ignore a zombie's head when deciding
	# whether a spot is blocked. The legacy "zombie" META is gone — _fire_ray
	# was its only reader and now resolves through Damageable.HEAD_META.
	head_hitbox.add_to_group("zombie_heads")
	head_hitbox.add_to_group(Damageable.GROUP_BULLET_HEAD)
	head_hitbox.set_meta(Damageable.HEAD_META, self)
	hp = max_hp   # spawner set max_hp for this night's scaling
	_build_footsteps()
	_build_screech()
	agent.path_desired_distance = 0.6
	agent.target_desired_distance = 0.8
	agent.radius = 0.5
	agent.avoidance_enabled = false
	NoiseManager.noise_emitted.connect(_on_noise_emitted)
	_apply_type_appearance()
	_pick_wander_target()
	_refresh_tint()
	_build_uav_silhouette()

## Resize the capsule/head to this variant's silhouette and recolour it.
##
## EVERY resource touched here is duplicated first. Sub-resources declared in
## a .tscn are SHARED across instances of that scene, so mutating them in
## place would resize/recolour every zombie in the world at once — the same
## trap the material duplication below was already guarding against.
func _apply_type_appearance() -> void:
	var t := zombie_type
	var body_y := t.body_center_y()
	var head_y := t.head_center_y()

	# Body collision.
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is CapsuleShape3D:
		var cs: CapsuleShape3D = col.shape.duplicate()
		cs.radius = t.body_radius
		cs.height = t.body_height
		col.shape = cs
		col.position.y = body_y

	# Body mesh + its own material instance.
	if body_mesh.mesh is CapsuleMesh:
		var cm: CapsuleMesh = body_mesh.mesh.duplicate()
		cm.radius = t.body_radius
		cm.height = t.body_height
		body_mesh.mesh = cm
	body_mesh.position.y = body_y
	if body_mesh.material_override:
		body_mesh.material_override = body_mesh.material_override.duplicate()

	# Head hitbox + mesh. Kept tangent to the top of the capsule so the two
	# volumes never overlap (headshot resolution depends on that).
	head_hitbox.position.y = head_y
	var hcol := head_hitbox.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if hcol and hcol.shape is SphereShape3D:
		var hs: SphereShape3D = hcol.shape.duplicate()
		hs.radius = t.head_radius
		hcol.shape = hs
	var hmesh := head_hitbox.get_node_or_null("HeadMesh") as MeshInstance3D
	if hmesh and hmesh.mesh is SphereMesh:
		var hm: SphereMesh = hmesh.mesh.duplicate()
		hm.radius = t.head_radius
		hm.height = t.head_radius * 2.0
		hmesh.mesh = hm

## The UAV's through-wall reveal: a simplified capsule clone, hidden by
## default, toggled by UAVSystem — NOT a post-process pass, per the brief.
## no_depth_test plus a high render_priority is the entire trick: the body
## mesh keeps its normal depth-tested material for everyone without a UAV
## up, and this sits alongside it, invisible until switched on.
##
## Built once at spawn time and just shown/hidden after that — cheaper than
## rebuilding it per UAV call, and it naturally frees itself as a child when
## the zombie dies (Zombie._die() calls queue_free() the same frame, no
## corpse lingers — see the class docstring on `died`).
func _build_uav_silhouette() -> void:
	var t := zombie_type
	var mesh := CapsuleMesh.new()
	mesh.radius = t.body_radius
	mesh.height = t.body_height

	_uav_silhouette = MeshInstance3D.new()
	_uav_silhouette.name = "UAVSilhouette"
	_uav_silhouette.mesh = mesh
	_uav_silhouette.position.y = t.body_center_y()
	_uav_silhouette.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_uav_silhouette.visible = false

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = t.uav_silhouette_color
	mat.no_depth_test = true
	mat.render_priority = 100
	_uav_silhouette.material_override = mat
	add_child(_uav_silhouette)

	UAVSystem.uav_state_changed.connect(_on_uav_state_changed)
	# Zombies spawning mid-night while a UAV is already up are revealed on
	# spawn, not just on the next activate/deactivate broadcast.
	_set_uav_revealed(UAVSystem.active)

func _on_uav_state_changed(is_active: bool) -> void:
	_set_uav_revealed(is_active)

func _set_uav_revealed(revealed: bool) -> void:
	_uav_revealed = revealed
	_update_uav_silhouette()

## Re-evaluates visibility against the reveal flag AND the optional distance
## cutoff every physics frame while revealed, so a zombie that wanders back
## into range comes back onto the overlay without waiting for another
## activate broadcast. Skipped entirely once _uav_revealed is false — this is
## not a per-frame cost while no UAV is up.
func _update_uav_silhouette() -> void:
	if _uav_silhouette == null:
		return
	if not _uav_revealed:
		_uav_silhouette.visible = false
		return
	var max_dist: float = UAVSystem.CONFIG.uav_max_reveal_distance
	if max_dist <= 0.0:
		_uav_silhouette.visible = true
		return
	# The PLAYER specifically, not this zombie's AI target: the reveal radius
	# is a property of the player's own UAV feed. Looked up by group rather
	# than through _acquire_target(), which would measure to a fighter once
	# fighters exist.
	var viewer := get_tree().get_first_node_in_group("player") as Node3D
	_uav_silhouette.visible = viewer != null \
		and global_position.distance_to(viewer.global_position) <= max_dist

## Chase-entry screech. A player-facing tell only: deliberately NOT a
## NoiseManager event, so it never pulls other zombies in.
func _build_screech() -> void:
	if zombie_type.sfx_chase_entry == "" or not ResourceLoader.exists(zombie_type.sfx_chase_entry):
		return
	_leap_screech = AudioStreamPlayer3D.new()
	_leap_screech.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_leap_screech.max_distance = 55.0
	_leap_screech.unit_size = 6.0
	_leap_screech.volume_db = 6.0
	_leap_screech.position.y = 1.4
	var res = load(zombie_type.sfx_chase_entry)
	_leap_screech.stream = res
	add_child(_leap_screech)

func set_active(a: bool) -> void:
	active = a
	_refresh_tint()

func _refresh_tint() -> void:
	if body_mesh.material_override is StandardMaterial3D:
		var m: StandardMaterial3D = body_mesh.material_override
		# Dim/greyed while dormant during the day, variant colour when hunting.
		# Dormant grey is shared on purpose — "asleep" should read the same for
		# every variant; it's the ACTIVE silhouette that must be tellable apart.
		m.albedo_color = zombie_type.albedo_active if active else Color(0.35, 0.38, 0.35)

func _physics_process(delta: float) -> void:
	# Brief white hit-flash fade back to the normal tint.
	if _hit_flash > 0.0:
		_hit_flash -= delta
		if _hit_flash <= 0.0:
			_refresh_tint()

	# Only meaningful when a re-evaluation cadence was configured; at the 0.0
	# default _acquire_target() ignores the cache entirely.
	if _target_timer > 0.0:
		_target_timer -= delta

	# Only does anything while a UAV has revealed this zombie — see
	# _update_uav_silhouette()'s own guard.
	if _uav_revealed:
		_update_uav_silhouette()

	if _leap_cooldown > 0.0:
		_leap_cooldown -= delta

	# Gravity keeps them grounded. Deliberately NOT short-circuited for FALLEN
	# (unlike the old TRAPPED state) — a pit zombie must actually fall.
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0

	# A committed leap is resolved BEFORE the dormant check: dawn breaking
	# mid-arc must not freeze a zombie in the air.
	if state == State.LEAP:
		_do_leap(delta)
		move_and_slide()
		return

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
		State.LEAP_RECOVER:
			_do_leap_recover(delta)

	move_and_slide()
	# After move_and_slide so cadence tracks ACTUAL movement — a zombie stuck
	# against geometry goes quiet instead of running in place.
	_update_footsteps(delta)

# --- States ---------------------------------------------------------------
func _do_wander(delta: float) -> void:
	# Pure roaming. Zombies never read the player's position here — a silent
	# (crouching) player can pass right by. Chase is only entered through a
	# confirmed contact (laser reveal or being shot).
	_move_toward(_target_pos, zombie_type.move_speed_wander, delta)
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
	if _investigating_laser and _can_see_target():
		_investigating_laser = false
		_enter_chase()
		return

	_investigate_timer -= delta
	_move_toward(_target_pos, zombie_type.move_speed_wander, delta)
	var arrived := global_position.distance_to(_target_pos) < 1.5
	if arrived or _investigate_timer <= 0.0:
		_investigating_laser = false
		state = State.WANDER
		_pick_wander_target()

## Only used while investigating a laser dot.
func _can_see_target() -> bool:
	var target := _acquire_target()
	if target == null:
		return false
	if global_position.distance_to(target.global_position) > LASER_INVESTIGATE_SIGHT:
		return false
	return _has_los_to(target)

func _do_chase(delta: float) -> void:
	var target := _acquire_target()
	if target == null:
		state = State.WANDER
		_pick_wander_target()
		return

	_chase_elapsed += delta
	var dist := global_position.distance_to(target.global_position)
	if _has_los_to(target):
		_last_known_target = target.global_position

	if dist <= ATTACK_RANGE:
		state = State.ATTACK
		_attack_timer = 0.0
		return

	if dist > CHASE_LOSE_RANGE and not _has_los_to(target):
		# Lost them — go poke around where we last saw them.
		state = State.INVESTIGATE
		_investigate_timer = INVESTIGATE_TIMEOUT
		_target_pos = _last_known_target
		return

	# Blocked by something leapable? Going OVER beats going around or through,
	# so this is evaluated before the break-the-wall fallback. Returns false
	# outright for non-leapers, so the walker's path here is unchanged.
	if _try_enter_leap(target):
		return

	# Walled in? Break through instead of milling against the sandbags.
	_repath_check -= delta
	if _repath_check <= 0.0:
		_repath_check = REPATH_CHECK_INTERVAL
		if not _target_reachable() and _try_enter_attack_structure():
			return

	_move_toward(target.global_position, _current_chase_speed(), delta)

func _do_attack(delta: float) -> void:
	var target := _acquire_target()
	if target == null:
		state = State.WANDER
		_pick_wander_target()
		return

	var dist := global_position.distance_to(target.global_position)
	if dist > ATTACK_RANGE * 1.3:
		_enter_chase()
		return

	# Stop and face the target while swinging.
	velocity.x = 0.0
	velocity.z = 0.0
	_face(target.global_position)

	_attack_timer -= delta
	if _attack_timer <= 0.0:
		_attack_timer = zombie_type.melee_cooldown
		if target.has_method("take_damage"):
			target.take_damage(zombie_type.melee_damage, global_position)

# --- Obstacle states -------------------------------------------------------
## Held in wire: immobile and permanent, but still dangerous at melee range.
## Don't hug your own wire.
func _do_entangled(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	var target := _acquire_target()
	if target == null:
		return
	if global_position.distance_to(target.global_position) <= ATTACK_RANGE:
		_face(target.global_position)
		_attack_timer -= delta
		if _attack_timer <= 0.0:
			_attack_timer = zombie_type.melee_cooldown
			# Guarded to match _do_attack(): a target that doesn't implement
			# take_damage() is simply never damaged rather than crashing the
			# state machine. The two melee sites disagreed before this
			# refactor — only _do_attack() guarded — which was harmless while
			# the sole target was the player but would not survive a second
			# member of the group.
			if target.has_method("take_damage"):
				target.take_damage(zombie_type.melee_damage, global_position)

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
##
## Checks `.destroyed` explicitly, not just is_instance_valid(): sandbag
## sections used to queue_free() on destruction, so invalidation was the
## re-acquire signal. They now persist (destroyed-but-repairable, so the
## player can rebuild a wall), so a destroyed panel stays instance-valid
## forever — without this check a zombie would stand at a pile of rubble
## "attacking" it indefinitely instead of re-acquiring or walking through
## the gap it just made.
func _do_attack_structure(delta: float) -> void:
	if _structure_target == null or not is_instance_valid(_structure_target) \
			or _structure_target.destroyed:
		_structure_target = null
		_enter_chase()
		return

	_repath_check -= delta
	if _repath_check <= 0.0:
		_repath_check = REPATH_CHECK_INTERVAL
		if _target_reachable():
			_structure_target = null
			_enter_chase()
			return

	var point: Vector3 = _structure_target.nearest_point(global_position)
	var dist := global_position.distance_to(point)
	if dist > STRUCTURE_REACH:
		_move_toward(point, _current_chase_speed(), delta)
		return

	velocity.x = 0.0
	velocity.z = 0.0
	_face(point)
	_structure_timer -= delta
	if _structure_timer <= 0.0:
		_structure_timer = structure_attack_interval
		_structure_target.take_structure_damage(structure_damage, global_position)

## True when the nav agent can reach the player rather than stopping short.
func _target_reachable() -> bool:
	var target := _acquire_target()
	if target == null:
		return false
	# `goal`, not `target`: the parameter is the entity, this is the navmesh
	# point nearest to it. Same distinction as in _path_is_obstructed().
	var goal := NavigationServer3D.map_get_closest_point(
		agent.get_navigation_map(), target.global_position)
	var path := NavigationServer3D.map_get_path(
		agent.get_navigation_map(), global_position, goal, true)
	if path.size() == 0:
		return false
	return path[path.size() - 1].distance_to(goal) < 2.0

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

# --- Chase speed ramp ------------------------------------------------------
## Chase speed for this frame.
##
## Walker: acceleration_time and chase_entry_delay are both 0, so this
## returns move_speed_chase on the very first frame of Chase — bit-identical
## to the old `CHASE_SPEED` constant.
##
## Leaper: holds at WANDER speed for chase_entry_delay (the screech-and-lurch
## tell — it has committed to you but hasn't wound up yet), then ramps to
## full chase speed over acceleration_time.
func _current_chase_speed() -> float:
	var t := zombie_type
	var top := t.resolved_chase_speed()
	if t.chase_entry_delay <= 0.0 and t.acceleration_time <= 0.0:
		return top
	if _chase_elapsed < t.chase_entry_delay:
		return t.move_speed_wander
	if t.acceleration_time <= 0.0:
		return top
	var ramp: float = clampf(
		(_chase_elapsed - t.chase_entry_delay) / t.acceleration_time, 0.0, 1.0)
	return lerpf(t.move_speed_wander, top, ramp)

# --- Leap ------------------------------------------------------------------
## Vertical launch speed needed to reach the type's apex, straight from the
## project's real gravity: v = sqrt(2 * g * h).
func _leap_vertical_speed() -> float:
	return sqrt(2.0 * gravity * zombie_type.jump_apex_height)

## Time for the whole arc, launching and landing at the same height.
func _leap_arc_time() -> float:
	return 2.0 * _leap_vertical_speed() / gravity

## Should we leap, and if so, launch. Returns true if a leap started.
##
## Every one of the five gate conditions must hold. The expensive ones (path
## query, arc trace) are checked last so the common case — a leaper running
## at an unobstructed player — costs almost nothing.
func _try_enter_leap(target: Node3D) -> bool:
	var t := zombie_type
	# 1. can this variant leap at all, 2. is it off cooldown
	if not t.can_leap or _leap_cooldown > 0.0:
		return false

	# 3. Is the path actually obstructed? Never leap at an open player: the
	#    leap is traversal, not an attack. A straight run that the navmesh
	#    agrees with means there is nothing to leap over.
	var straight := global_position.distance_to(target.global_position)
	if straight < 2.0 or straight > t.max_horizontal_distance * 2.5:
		return false
	if not _path_is_obstructed(target, t.leap_path_ratio_threshold):
		return false

	# 4. Is the obstruction close enough to clear?
	var to_target := target.global_position - global_position
	to_target.y = 0.0
	var dir := to_target.normalized()
	if not _obstruction_within(dir, t.max_horizontal_distance):
		return false

	# 5. Is there a clear arc to a real navmesh point on the far side?
	var landing := _find_leap_landing(dir)
	if landing == Vector3.INF:
		return false

	_launch_leap(landing)
	return true

## True when the navmesh route is meaningfully longer than the straight line
## (it's detouring around something) or there's no route at all.
func _path_is_obstructed(target: Node3D, ratio_threshold: float) -> bool:
	var straight := global_position.distance_to(target.global_position)
	if straight <= 0.01:
		return false
	var map := agent.get_navigation_map()
	# `goal`, not `target`: the parameter is the entity, this is the navmesh
	# point nearest to it.
	var goal := NavigationServer3D.map_get_closest_point(map, target.global_position)
	var path := NavigationServer3D.map_get_path(map, global_position, goal, true)
	if path.size() < 2:
		return true   # no route at all — definitively blocked
	# Path stops short of the target: blocked.
	if path[path.size() - 1].distance_to(goal) > 2.0:
		return true
	var walked := 0.0
	for i in range(1, path.size()):
		walked += path[i - 1].distance_to(path[i])
	return walked / straight >= ratio_threshold

## Is there solid geometry between us and the player, within `max_dist`?
## Masks world geometry (layer 1) plus the ditch revetment / pit shells
## (layer 6) — both are things worth jumping over.
func _obstruction_within(dir: Vector3, max_dist: float) -> bool:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3(0, 1.0, 0)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * max_dist)
	q.collision_mask = 1 | Obstacle.SOLID_NO_NAV_LAYER
	q.exclude = [get_rid()]
	return not space.intersect_ray(q).is_empty()

## Find the furthest valid landing spot along `dir`, within the hard cap.
## Returns Vector3.INF when nothing works.
##
## Searched far-to-near so the leaper clears the obstruction outright rather
## than landing on top of it.
func _find_leap_landing(dir: Vector3) -> Vector3:
	var t := zombie_type
	var map := agent.get_navigation_map()
	var d: float = t.max_horizontal_distance
	while d >= 2.0:
		var probe := global_position + dir * d
		var nav_point := NavigationServer3D.map_get_closest_point(map, probe)
		# Must be REAL navmesh near where we aimed, not the nearest polygon
		# half the map away — that's the "valid navmesh point" requirement.
		var flat_off := Vector2(nav_point.x - probe.x, nav_point.z - probe.z).length()
		if flat_off <= 1.5 and absf(nav_point.y - global_position.y) <= t.jump_apex_height * 0.5:
			if _arc_is_clear(nav_point):
				return nav_point
		d -= 1.0
	return Vector3.INF

## Sample the parabola and make sure nothing intersects it. Without this a
## leaper would happily launch into the underside of a roof.
func _arc_is_clear(landing: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var steps := 8
	var start := global_position + Vector3(0, 1.0, 0)
	var flat := landing - global_position
	flat.y = 0.0
	var dist := flat.length()
	if dist < 0.01:
		return false
	var t_total := _leap_arc_time()
	var vy := _leap_vertical_speed()
	var prev := start
	for i in range(1, steps + 1):
		var f: float = float(i) / float(steps)
		var tt: float = t_total * f
		var y: float = vy * tt - 0.5 * gravity * tt * tt
		var pt: Vector3 = start + flat * f + Vector3(0, y, 0)
		var q := PhysicsRayQueryParameters3D.create(prev, pt)
		q.collision_mask = 1 | Obstacle.SOLID_NO_NAV_LAYER
		q.exclude = [get_rid()]
		if not space.intersect_ray(q).is_empty():
			return false
		prev = pt
	return true

## Commit the arc. Horizontal speed is derived from the arc time and the
## clamped distance, so total travel physically cannot exceed
## max_horizontal_distance — the cap is enforced here, not merely aimed at.
##
## This is why a leap can never beat a run over the same ground: arc time is
## fixed by the apex (independent of distance), so horizontal speed is
## distance/arc_time, which at the 6m cap is well under chase speed. See
## PROJECT_SPEC.md "Leaper" for the worked numbers.
func _launch_leap(landing: Vector3) -> void:
	var t := zombie_type
	var flat := landing - global_position
	flat.y = 0.0
	var dist: float = minf(flat.length(), t.max_horizontal_distance)
	var dir := flat.normalized()
	var arc := _leap_arc_time()
	var h_speed: float = dist / arc

	state = State.LEAP
	_leap_airborne = false
	_leap_cooldown = t.jump_cooldown
	agent.target_position = global_position   # park the agent; it steers nothing now
	velocity = dir * h_speed + Vector3.UP * _leap_vertical_speed()
	_face(global_position + dir)

## Pure ballistics. NO mid-air steering, deliberately: the arc is committed at
## launch, which makes an airborne leaper a predictable, high-value target.
## Gravity was already applied this frame in _physics_process.
func _do_leap(_delta: float) -> void:
	if not _leap_airborne:
		if not is_on_floor():
			_leap_airborne = true
		return
	if is_on_floor():
		state = State.LEAP_RECOVER
		_leap_recover = zombie_type.landing_recovery
		velocity.x = 0.0
		velocity.z = 0.0

## Immobile after touchdown, then back to the hunt.
func _do_leap_recover(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_leap_recover -= delta
	if _leap_recover > 0.0:
		return
	# FALLBACK: landed somewhere the navmesh doesn't cover (a structure roof,
	# say). Pathing can't rescue us from there, so re-leap immediately toward
	# the player instead of stranding. The cooldown is waived for exactly this
	# case — being stuck on a roof is worse than an off-cadence leap.
	if not _on_navmesh():
		var target := _acquire_target()
		if target != null:
			var away := target.global_position - global_position
			away.y = 0.0
			if away.length() > 0.5:
				_leap_cooldown = 0.0
				var landing := _find_leap_landing(away.normalized())
				# No validated arc available — take the capped hop toward the
				# player anyway. Anything is better than standing on a roof.
				if landing == Vector3.INF:
					landing = global_position + away.normalized() * zombie_type.max_horizontal_distance
				_launch_leap(landing)
				return
	_enter_chase()

## Is this zombie standing on navigable ground?
func _on_navmesh() -> bool:
	var map := agent.get_navigation_map()
	var closest := NavigationServer3D.map_get_closest_point(map, global_position)
	return closest.distance_to(global_position) <= 1.5

# --- Obstacle hooks (called by the obstacles) ------------------------------
func enter_entangled(wire) -> void:
	if state == State.ENTANGLED or _dead:
		return
	_held_by = wire
	state = State.ENTANGLED
	_attack_timer = zombie_type.melee_cooldown

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

## States where the zombie already has a confirmed fix on the player and must
## not be redirected by an external stimulus. LEAP/LEAP_RECOVER are here
## because a committed arc cannot be steered — see _do_leap(). Walkers never
## reach those two, so this reads exactly as the old CHASE-or-ATTACK test for
## them.
func _is_committed() -> bool:
	return state == State.CHASE or state == State.ATTACK \
		or state == State.LEAP or state == State.LEAP_RECOVER

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
func _has_los_to(target: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3(0, 1.4, 0)
	var to := target.global_position + Vector3(0, 1.2, 0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	return hit and hit.collider == target

## The hostile target this zombie is currently pursuing, or null.
##
## THE INTERFACE A TARGET MUST SATISFY is deliberately small, and is the whole
## contract this file depends on:
##   - it is a Node3D (global_position is read constantly)
##   - it IS the collider, not the owner of one (_has_los_to compares the
##     raycast's hit.collider against it by identity)
##   - take_damage(amount: int, source_pos) — guarded with has_method() at
##     both melee sites, so a target without it is simply never damaged
##     rather than crashing the state machine
##
## Returned as Node3D rather than a widened base class: GDScript has no
## interfaces, and duck-typing against a documented contract is what
## AreaDamageSystem already does for take_area_damage()/is_alive(). Every
## internal use goes through this one boundary.
func _acquire_target() -> Node3D:
	# Cache only when a cadence was actually asked for. At the 0.0 default
	# this branch never runs and every query re-scans, matching the old
	# per-call _get_player() exactly.
	if target_reevaluate_interval > 0.0 and _target_timer > 0.0 \
			and _target_cache != null and is_instance_valid(_target_cache):
		return _target_cache
	_target_cache = _nearest_hostile_target()
	_target_timer = target_reevaluate_interval
	return _target_cache

## Nearest member of the hostile-target group, by 3D distance.
##
## With exactly one member this returns that member, which is what the old
## _get_player()'s `players[0]` did — so single-target behaviour is unchanged.
## See GROUP_HOSTILE_TARGET's note on why there is no is_alive() filter here.
func _nearest_hostile_target() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group(GROUP_HOSTILE_TARGET):
		if not (node is Node3D):
			continue
		var candidate: Node3D = node as Node3D
		if not is_instance_valid(candidate):
			continue
		var d := global_position.distance_to(candidate.global_position)
		if d < best_d:
			best_d = d
			best = candidate
	return best

# --- External triggers ----------------------------------------------------
## Noise bus callback: alerts to a location, not to the player specifically.
## Stores the noise's fixed (position, radius) and heads there. A newer noise
## within range while wandering/investigating simply replaces the target with
## its own fixed location — each event is independent of the player's transform.
func _on_noise_emitted(position: Vector3, radius: float) -> void:
	if not active or GameManager.is_day():
		return
	if _is_committed():
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
	if _is_committed():
		return   # already has a confirmed fix; the light tells it nothing new
	state = State.INVESTIGATE
	_investigating_laser = true
	_investigate_timer = INVESTIGATE_TIMEOUT
	_target_pos = dot_pos

func _enter_chase() -> void:
	# Only a genuine entry (not a re-entry from leap recovery mid-chase) resets
	# the acceleration ramp and fires the screech.
	var fresh := state != State.CHASE and state != State.LEAP and state != State.LEAP_RECOVER
	state = State.CHASE
	_investigating_laser = false
	if fresh:
		_chase_elapsed = 0.0
		if _leap_screech and _leap_screech.stream:
			_leap_screech.play()
	var target := _acquire_target()
	if target:
		_last_known_target = target.global_position

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
	# Anchors are the variant's speed RANGE, not the instantaneous ramped
	# speed: during the leaper's chase-entry delay the current speed equals
	# wander speed, and inverse_lerp(a, a, v) is a divide-by-zero. maxf keeps
	# that true even if a variant is ever configured with chase <= wander.
	var top: float = maxf(zombie_type.resolved_chase_speed(),
		zombie_type.move_speed_wander + 0.01)
	var t: float = clampf(inverse_lerp(zombie_type.move_speed_wander, top, speed), 0.0, 1.0)
	_step_timer = lerpf(step_interval_wander, step_interval_chase, t)

	_footstep_player.stream = _footstep_samples[randi() % _footstep_samples.size()]
	_footstep_player.pitch_scale = randf_range(1.0 - step_pitch_variance, 1.0 + step_pitch_variance)
	_footstep_player.play()

## Distance at which this zombie's steps become audible (for the debug overlay).
func footstep_range() -> float:
	return footstep_max_distance

# --- Combat ---------------------------------------------------------------
## Returns the damage actually dealt, so the shooter can report it.
##
## `falloff_mult` is applied AFTER the headshot multiplier, not before —
## callers must pass the weapon's raw, un-multiplied damage here rather than
## pre-multiplying by falloff themselves. Rounding only happens once, at the
## end, in this function. Applying falloff first and rounding to an int
## before the headshot multiplier (the previous behaviour, with callers
## pre-multiplying) silently produced different final damage than this order
## whenever the intermediate round truncated a fraction — e.g. 34 body dmg at
## a 0.4 falloff multiplier: round(34*0.4)*2 = 28, but round(34*2*0.4) = 27.
func take_damage(amount: int, headshot: bool, falloff_mult: float = 1.0) -> int:
	var dmg: int = maxi(1, int(round(float(amount) * (HEADSHOT_MULT if headshot else 1) * falloff_mult)))
	hp -= dmg
	last_hit_headshot = headshot
	if headshot:
		_hits_head += 1
	else:
		_hits_body += 1
	_flash_white()
	# Being shot is a confirmed contact — start chasing the shooter, unless
	# we're held fast, in which case there's nowhere to go.
	# Airborne/recovering leapers are excluded specifically: the arc is
	# committed, and yanking them into Chase mid-flight would cancel it.
	# Walkers never enter those states, so this is a no-op for them.
	if active and not GameManager.is_day() and not is_immobilised() \
			and state != State.LEAP and state != State.LEAP_RECOVER:
		_enter_chase()
	if hp <= 0:
		_die()
	return dmg

## Uniform blast entry point (AreaDamageSystem convention).
##
## Explosions are never headshots — frag doesn't care where it lands, and
## routing this through take_damage(amount, headshot) directly would be a
## silent bug: a Vector3 origin binds to `headshot` and is truthy, doubling
## every blast. Immobilised zombies (FALLEN in a ditch, ENTANGLED in wire)
## take this normally; nothing here checks state.
func take_area_damage(amount: int, _origin: Vector3) -> void:
	take_damage(amount, false)

## World-space points the blast tests line of sight against, sized to this
## variant's actual silhouette so a tall leaper is harder to fully cover than
## a walker. Feet / centre of mass / head.
func area_damage_points() -> Array:
	var t := zombie_type
	return [
		global_position + Vector3(0.0, 0.2, 0.0),
		global_position + Vector3(0.0, t.body_center_y(), 0.0),
		global_position + Vector3(0.0, t.head_center_y(), 0.0),
	]

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
		State.LEAP: return "LEAP"
		State.LEAP_RECOVER: return "LEAP_RECOVER"
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

	# Driven by the variant, not hardcoded — otherwise F4 would draw walker
	# volumes around a leaper and misreport exactly what it exists to verify.
	var t := zombie_type
	var body_vis := MeshInstance3D.new()
	var bm := CapsuleMesh.new()
	bm.radius = t.body_radius
	bm.height = t.body_height
	body_vis.mesh = bm
	body_vis.position = Vector3(0, t.body_center_y(), 0)
	body_vis.material_override = _debug_material(Color(0.2, 0.6, 1.0, 0.25))
	_hitbox_debug.add_child(body_vis)

	var head_vis := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = t.head_radius
	hm.height = t.head_radius * 2.0
	head_vis.mesh = hm
	head_vis.position = Vector3(0, t.head_center_y(), 0)
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
	PointsManager.add_points(zombie_type.points_headshot_kill if last_hit_headshot else zombie_type.points_body_kill)
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
