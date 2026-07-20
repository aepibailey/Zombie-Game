extends CharacterBody3D
## First-person operator controller: movement/noise states, ADS red laser, and
## the M17 pistol (fire / reload / headshot detection). See PROJECT_SPEC.md
## "Movement & Noise", "Combat & Scoring" and "V1 Thin-Slice Scope".

signal ammo_changed(loaded: int, reserve: int)
signal health_changed(hp: int, max_hp: int)
signal state_changed(state_name: String)
signal suppressor_changed(has_suppressor: bool)
signal message(text: String)

enum MoveState { CROUCH, WALK, SPRINT }

# --- Movement tuning ------------------------------------------------------
const SPEED := {
	MoveState.CROUCH: 2.0,
	MoveState.WALK: 4.5,
	MoveState.SPRINT: 7.5,
}
# Noise radius per movement state (PROJECT_SPEC.md noise table).
const MOVE_NOISE := {
	MoveState.CROUCH: 0.0,   # silent
	MoveState.WALK: 5.0,
	MoveState.SPRINT: 15.0,
}
const FOOTSTEP_INTERVAL := 0.45
const MOUSE_SENSITIVITY := 0.0025
const STAND_HEAD_Y := 1.6
const CROUCH_HEAD_Y := 1.0
const HEAD_LERP := 12.0

# Branch-snap random event: only while moving standing/sprinting through the
# woods (perimeter). 20m single burst (PROJECT_SPEC.md noise table).
const BRANCH_SNAP_NOISE := 20.0
const BRANCH_SNAP_CHANCE := 0.20        # per second while eligible
const WOODS_INNER_RADIUS := 22.0        # beyond this from map centre = woods

# Red laser: any zombie within 10m + line of sight instantly knows your exact
# position while you're aiming (PROJECT_SPEC.md "Laser visibility").
const LASER_REVEAL_RANGE := 10.0
const LASER_MAX_DRAW := 100.0

# --- Weapon (M17) tuning --------------------------------------------------
const MAG_SIZE := 17
const STARTING_RESERVE := 85            # ~5 spare mags
const FIRE_INTERVAL := 0.15             # semi-auto cadence cap
const RELOAD_TIME := 1.6
const BODY_DAMAGE := 34                 # 3 body shots kill a 100hp zombie
const HEADSHOT_MULT := 2                # -> 2 headshots kill (spec 2x)
const HEAD_LOCAL_Y := 1.45              # hit height (feet-relative) = headshot
const SHOT_NOISE_UNSUPPRESSED := 40.0
const MAX_HP := 100
const WEAPON_RANGE := 150.0             # max shot distance

# Hip-fire accuracy penalty. On each unaimed shot we pick a random point inside
# a screen-space circle of this pixel radius (centered on screen-centre) and
# fire toward it instead of dead-centre. Bigger = looser. Tune by playtest.
# (ADS ignores this entirely and fires pinpoint down the laser.)
const HIP_FIRE_SPREAD_RADIUS := 80.0    # pixels

# Tracer (only visual feedback for hip-fire, since there's no reticle).
const TRACER_WIDTH := 0.03
const TRACER_LIFETIME := 0.08

# --- Runtime state --------------------------------------------------------
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 24.0)
var move_state: int = MoveState.WALK
var is_crouching := false
var is_moving := false
var control_enabled := true
var mouse_captured := true
var ads_active := false

var hp := MAX_HP
var ammo := MAG_SIZE
var reserve := STARTING_RESERVE
var reloading := false
var fire_cooldown := 0.0
var suppressor: SuppressorResource = null

var _footstep_timer := 0.0
var _branch_timer := 1.0
var _spawn_point := Vector3.ZERO

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var laser_ray: RayCast3D = $Head/Camera3D/LaserRay
@onready var laser_dot: MeshInstance3D = $LaserDot

func _ready() -> void:
	add_to_group("player")
	_spawn_point = global_position
	camera.current = true
	laser_dot.visible = false
	_set_mouse_captured(true)
	laser_ray.target_position = Vector3(0, 0, -LASER_MAX_DRAW)
	# Prime the HUD.
	ammo_changed.emit(ammo, reserve)
	health_changed.emit(hp, MAX_HP)
	suppressor_changed.emit(false)
	state_changed.emit("WALK")

func _physics_process(delta: float) -> void:
	fire_cooldown = maxf(0.0, fire_cooldown - delta)

	# Gravity always applies.
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0

	if control_enabled:
		_handle_movement(delta)
		_handle_noise(delta)
		if ads_active:
			_handle_laser_reveal()
	else:
		velocity.x = 0.0
		velocity.z = 0.0

	move_and_slide()

	# Smooth crouch camera.
	var target_y := CROUCH_HEAD_Y if is_crouching else STAND_HEAD_Y
	head.position.y = lerpf(head.position.y, target_y, delta * HEAD_LERP)

	_update_laser_dot()

func _handle_movement(_delta: float) -> void:
	var input_dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		input_dir.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		input_dir.z += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		input_dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		input_dir.x += 1.0

	is_moving = input_dir.length() > 0.0
	var sprint_held := Input.is_physical_key_pressed(KEY_SHIFT)

	var new_state: int
	if is_crouching:
		new_state = MoveState.CROUCH
	elif sprint_held and is_moving:
		new_state = MoveState.SPRINT
	else:
		new_state = MoveState.WALK

	if new_state != move_state:
		move_state = new_state
		state_changed.emit(_state_label())

	var speed: float = SPEED[move_state]
	var dir := (transform.basis * input_dir).normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed

func _handle_noise(delta: float) -> void:
	if not (is_moving and is_on_floor()):
		_footstep_timer = 0.0
		return

	# Footstep noise at the current movement state's radius (crouch = 0 = silent).
	_footstep_timer -= delta
	if _footstep_timer <= 0.0:
		_footstep_timer = FOOTSTEP_INTERVAL
		NoiseManager.emit_noise(global_position, MOVE_NOISE[move_state])

	# Branch-snap: only while standing/sprinting through the woods.
	if move_state != MoveState.CROUCH:
		_branch_timer -= delta
		if _branch_timer <= 0.0:
			_branch_timer = 1.0
			if _in_woods() and randf() < BRANCH_SNAP_CHANCE:
				NoiseManager.emit_noise(global_position, BRANCH_SNAP_NOISE)
				message.emit("*SNAP* — a branch breaks underfoot")

func _in_woods() -> bool:
	var flat := Vector2(global_position.x, global_position.z)
	return flat.length() > WOODS_INNER_RADIUS

func _handle_laser_reveal() -> void:
	var space := get_world_3d().direct_space_state
	var from := head.global_position
	for node in get_tree().get_nodes_in_group("zombies"):
		var z = node  # untyped so the custom zombie API resolves dynamically
		if not is_instance_valid(z):
			continue
		if from.distance_to(z.global_position) > LASER_REVEAL_RANGE:
			continue
		# Line of sight: nothing solid between the operator's eye and the target.
		var to: Vector3 = z.global_position + Vector3(0, 1.0, 0)
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.exclude = [self]
		var hit := space.intersect_ray(q)
		if hit and hit.collider == z:
			if z.has_method("reveal_player"):
				z.reveal_player(global_position)

# --- Input ----------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mouse_captured and control_enabled:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		head.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		head.rotation.x = clampf(head.rotation.x, -1.4, 1.4)
	elif event is InputEventMouseButton and event.pressed:
		if not (mouse_captured and control_enabled):
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			_fire()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_toggle_ads()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_C:
				if control_enabled:
					is_crouching = not is_crouching
					_handle_movement(0.0)
			KEY_R:
				if control_enabled:
					_reload()
			KEY_ESCAPE:
				# When the tent shop owns the mouse, let it handle Esc instead.
				if control_enabled:
					_set_mouse_captured(not mouse_captured)

func _toggle_ads() -> void:
	ads_active = not ads_active
	camera.fov = 55.0 if ads_active else 75.0
	message.emit("ADS " + ("ON — red laser hot (10m tell)" if ads_active else "OFF"))

# --- Weapon ---------------------------------------------------------------
func _fire() -> void:
	if reloading or fire_cooldown > 0.0:
		return
	if ammo <= 0:
		message.emit("*click* — empty. Press R to reload.")
		return

	ammo -= 1
	fire_cooldown = FIRE_INTERVAL
	ammo_changed.emit(ammo, reserve)

	var noise_radius := suppressor.shot_noise_radius if suppressor else SHOT_NOISE_UNSUPPRESSED
	NoiseManager.emit_noise(global_position, noise_radius)

	# Aim point: ADS is pinpoint (screen-centre, down the laser); hip-fire draws
	# a random point inside a screen-space spread circle for an accuracy penalty.
	var screen_centre := get_viewport().get_visible_rect().size * 0.5
	var screen_point := screen_centre
	if not ads_active:
		var ang := randf() * TAU
		var rad := sqrt(randf()) * HIP_FIRE_SPREAD_RADIUS   # sqrt = uniform in disk
		screen_point += Vector2(cos(ang), sin(ang)) * rad

	var from := camera.project_ray_origin(screen_point)
	var dir := camera.project_ray_normal(screen_point)
	var to := from + dir * WEAPON_RANGE

	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [self]
	var hit := space.intersect_ray(q)

	# Impact/damage logic is unchanged — only the ray direction above differs.
	var impact := to
	if hit:
		impact = hit.position
		var col = hit.collider  # Variant: may be world or a zombie
		if col and col.is_in_group("zombies"):
			var local_y: float = hit.position.y - col.global_position.y
			var headshot: bool = local_y >= HEAD_LOCAL_Y
			if col.has_method("take_damage"):
				col.take_damage(BODY_DAMAGE, headshot)

	_spawn_tracer(_muzzle_position(), impact)

func _reload() -> void:
	if reloading or ammo >= MAG_SIZE or reserve <= 0:
		return
	reloading = true
	message.emit("Reloading…")
	await get_tree().create_timer(RELOAD_TIME).timeout
	var needed := MAG_SIZE - ammo
	var take: int = mini(needed, reserve)
	ammo += take
	reserve -= take
	reloading = false
	ammo_changed.emit(ammo, reserve)

func _update_laser_dot() -> void:
	if not ads_active:
		laser_dot.visible = false
		return
	laser_ray.force_raycast_update()
	if laser_ray.is_colliding():
		laser_dot.global_position = laser_ray.get_collision_point()
	else:
		laser_dot.global_position = laser_ray.global_position + \
			(-laser_ray.global_transform.basis.z) * LASER_MAX_DRAW
	laser_dot.visible = true

# --- Tracer ---------------------------------------------------------------
# Approximate muzzle: offset down/right/forward of the eye so the tracer reads
# as coming from a held pistol rather than the centre of the screen.
func _muzzle_position() -> Vector3:
	var b := camera.global_transform.basis
	return camera.global_position + b * Vector3(0.2, -0.18, -0.35)

func _spawn_tracer(from: Vector3, to: Vector3) -> void:
	var length := from.distance_to(to)
	if length < 0.05:
		return

	var tracer := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(TRACER_WIDTH, TRACER_WIDTH, length)
	tracer.mesh = box
	tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.85, 0.35, 0.9)
	tracer.material_override = mat

	get_tree().current_scene.add_child(tracer)
	tracer.global_position = (from + to) * 0.5
	# Orient the box's local Z along the shot line (avoid a vertical-parallel up).
	var up := Vector3.UP
	if absf((to - from).normalized().dot(Vector3.UP)) > 0.99:
		up = Vector3.RIGHT
	tracer.look_at(to, up)

	# Quick fade-out, then free.
	var tw := tracer.create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, TRACER_LIFETIME)
	tw.tween_callback(tracer.queue_free)

# --- Damage / life --------------------------------------------------------
func take_damage(amount: int) -> void:
	hp = maxi(0, hp - amount)
	health_changed.emit(hp, MAX_HP)
	if hp <= 0:
		_respawn()

func _respawn() -> void:
	message.emit("You died — respawning at base.")
	hp = MAX_HP
	ammo = MAG_SIZE
	reserve = STARTING_RESERVE
	global_position = _spawn_point
	velocity = Vector3.ZERO
	health_changed.emit(hp, MAX_HP)
	ammo_changed.emit(ammo, reserve)

# --- Attachment pipeline --------------------------------------------------
func attach_suppressor(res: SuppressorResource) -> void:
	suppressor = res
	suppressor_changed.emit(true)
	message.emit("Suppressor attached — gunshots now %dm." % int(res.shot_noise_radius))

func has_suppressor() -> bool:
	return suppressor != null

# --- Helpers --------------------------------------------------------------
func set_control_enabled(enabled: bool) -> void:
	control_enabled = enabled
	if not enabled:
		velocity.x = 0.0
		velocity.z = 0.0

func _set_mouse_captured(captured: bool) -> void:
	mouse_captured = captured
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE

func _state_label() -> String:
	match move_state:
		MoveState.CROUCH: return "CROUCH (silent)"
		MoveState.SPRINT: return "SPRINT (15m)"
		_: return "WALK (5m)"
