extends CharacterBody3D
## First-person operator controller: movement/noise states, ADS red laser, and
## data-driven weapons (fire / reload / headshot detection, switching). See
## PROJECT_SPEC.md "Movement & Noise", "Combat & Scoring" and "Weapons".

signal ammo_changed(loaded: int, reserve: int)
signal health_changed(hp: int, max_hp: int)
signal state_changed(state_name: String)
signal suppressor_changed(has_suppressor: bool)
signal weapon_changed(display_name: String, fire_mode: String)
signal message(text: String)
signal damaged                       ## player took a hit (HUD flash / shake)
signal zombie_hit                    ## a shot connected with a zombie (hitmarker)

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

# --- Weapon tuning (per-weapon stats live in WeaponData / Arsenal) --------
const HEAD_LOCAL_Y := 1.45              # hit height (feet-relative) = headshot
const STARTING_WEAPON := "m17"
const MAX_HP := 100

# Hip-fire accuracy penalty: each unaimed shot is aimed at a random point in a
# screen-space circle (per-weapon `hip_spread_radius`) instead of dead-centre.
# ADS ignores this and fires pinpoint down the laser.

# Tracer (only visual feedback for hip-fire, since there's no reticle).
const TRACER_WIDTH := 0.03
const TRACER_LIFETIME := 0.08

# --- Juice / feedback -----------------------------------------------------
const FIRE_SHAKE := 0.12             # trauma added per shot
const HURT_SHAKE := 0.55             # trauma added when hit
const SHAKE_DECAY := 1.6             # trauma bled off per second
const MAX_SHAKE_ROT := 0.06          # radians at full trauma
const MAX_SHAKE_POS := 0.05          # metres at full trauma
const MAX_RECOIL := 0.12
const RECOIL_RECOVER := 12.0
const MUZZLE_FLASH_TIME := 0.05

# First-person weapon viewmodel (camera-local placement).
const VM_HIP_POS := Vector3(0.22, -0.22, -0.45)
const VM_ADS_POS := Vector3(0.0, -0.13, -0.32)
const VM_RECOIL_KICK := 0.05         # metres kicked back on fire
const VM_LERP := 16.0

# Loaded at runtime (not preload) so a missing/failed import degrades to
# "no sound" instead of breaking the whole script.
const SFX_GUNSHOT := "res://audio/gunshot.wav"
const SFX_HURT := "res://audio/player_hurt.wav"
const SFX_IMPACT := "res://audio/impact.wav"

# --- Runtime state --------------------------------------------------------
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 24.0)
var move_state: int = MoveState.WALK
var is_crouching := false
var is_moving := false
var control_enabled := true
var mouse_captured := true
var ads_active := false

var hp := MAX_HP

# Weapon state. `ammo`/`reserve` mirror the CURRENT weapon. Loaded magazines
# live here per weapon; RESERVE ammo is owned by the AmmoManager autoload.
var weapon: WeaponData
var current_weapon_id := STARTING_WEAPON
var owned: Array[String] = [STARTING_WEAPON]
var ammo := 0                         # rounds in the current weapon's magazine
var reserve := 0                      # mirror of AmmoManager reserve for the current weapon
var reloading := false
var fire_cooldown := 0.0
var _auto_selected := false           # for BOTH-mode weapons: is auto selected?
var _mag: Dictionary = {}             # weapon id -> loaded rounds
var _suppressed: Dictionary = {}      # weapon id -> bool

var _footstep_timer := 0.0
var _branch_timer := 1.0
var _spawn_point := Vector3.ZERO

# Feedback runtime state.
var _shake_trauma := 0.0
var _recoil := 0.0
var _muzzle_timer := 0.0
var _vm_recoil := 0.0
var _muzzle_flash: Node3D
var _viewmodel: Node3D
var _sfx_fire: AudioStreamPlayer
var _sfx_hurt: AudioStreamPlayer
var _sfx_impact: AudioStreamPlayer

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
	_build_listener()
	_build_viewmodel()
	_build_audio()

	# Starting loadout: M17 only, 2 mags total (one loaded, one spare).
	_grant_starting_ammo(STARTING_WEAPON)
	_equip(STARTING_WEAPON)
	# Reserve changes (crate purchases, supply drops) keep the HUD honest.
	AmmoManager.reserve_changed.connect(_on_reserve_changed)

	# Prime the HUD.
	health_changed.emit(hp, MAX_HP)
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
		# Full-auto: keep firing while the trigger is held (rate-limited in _fire).
		if _wants_auto_fire() and mouse_captured and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_fire()
	else:
		velocity.x = 0.0
		velocity.z = 0.0

	move_and_slide()

	# Smooth crouch camera.
	var target_y := CROUCH_HEAD_Y if is_crouching else STAND_HEAD_Y
	head.position.y = lerpf(head.position.y, target_y, delta * HEAD_LERP)

	_update_feedback(delta)
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
			if not _wants_auto_fire():   # semi: one shot per click (auto is in _physics_process)
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
			KEY_B:
				if control_enabled:
					_toggle_fire_mode()
			KEY_1:
				_try_equip_slot(0)
			KEY_2:
				_try_equip_slot(1)
			KEY_3:
				_try_equip_slot(2)
			KEY_4:
				_try_equip_slot(3)
			KEY_ESCAPE:
				# When the crate shop owns the mouse, let it handle Esc instead.
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
	fire_cooldown = weapon.fire_interval
	ammo_changed.emit(ammo, reserve)

	# Fire feedback: muzzle flash, recoil kick, a touch of shake, and the report.
	_muzzle_flash.visible = true
	_muzzle_timer = MUZZLE_FLASH_TIME
	_recoil = minf(MAX_RECOIL, _recoil + weapon.recoil_per_shot)
	_vm_recoil = VM_RECOIL_KICK
	add_shake(FIRE_SHAKE)
	if _sfx_fire.stream:
		_sfx_fire.play()

	var suppressed: bool = _suppressed.get(current_weapon_id, false)
	var noise_radius := weapon.noise_suppressed if suppressed else weapon.noise_unsuppressed
	NoiseManager.emit_noise(global_position, noise_radius)

	# Aim base: ADS is pinpoint (screen-centre); hip-fire scatters within the
	# weapon's screen-space spread circle.
	var screen_centre := get_viewport().get_visible_rect().size * 0.5
	var screen_point := screen_centre
	if not ads_active:
		var ang := randf() * TAU
		var rad := sqrt(randf()) * weapon.hip_spread_radius   # sqrt = uniform in disk
		screen_point += Vector2(cos(ang), sin(ang)) * rad

	var from := camera.project_ray_origin(screen_point)
	var base_dir := camera.project_ray_normal(screen_point)

	# Shotguns fire multiple pellets, each jittered inside a cone.
	for i in weapon.pellets:
		var dir := base_dir
		if weapon.pellet_spread_deg > 0.0:
			dir = _jitter_dir(base_dir, weapon.pellet_spread_deg)
		_fire_ray(from, dir)

# Traces one round/pellet, applies damage, and draws a tracer.
func _fire_ray(from: Vector3, dir: Vector3) -> void:
	var to := from + dir * weapon.max_range
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [self]
	var hit := space.intersect_ray(q)

	var impact := to
	if hit:
		impact = hit.position
		var col = hit.collider  # Variant: may be world or a zombie
		if col and col.is_in_group("zombies"):
			var local_y: float = hit.position.y - col.global_position.y
			var headshot: bool = local_y >= HEAD_LOCAL_Y
			if col.has_method("take_damage"):
				col.take_damage(weapon.body_damage, headshot)
			zombie_hit.emit()       # hitmarker
			if _sfx_impact.stream:
				_sfx_impact.play()

	_spawn_tracer(_muzzle_position(), impact)

# Random direction within a cone of the given half-angle (degrees).
func _jitter_dir(dir: Vector3, spread_deg: float) -> Vector3:
	var a := deg_to_rad(spread_deg)
	var up_ref := Vector3.UP
	if absf(dir.dot(Vector3.UP)) > 0.99:
		up_ref = Vector3.RIGHT
	var right := dir.cross(up_ref).normalized()
	var up := right.cross(dir).normalized()
	return dir.rotated(up, randf_range(-a, a)).rotated(right, randf_range(-a, a)).normalized()

func _reload() -> void:
	if reloading or ammo >= weapon.mag_size or reserve <= 0:
		return
	reloading = true
	var id := current_weapon_id
	message.emit("Reloading…")
	await get_tree().create_timer(weapon.reload_time).timeout
	if not reloading or current_weapon_id != id:
		return   # cancelled by a weapon switch mid-reload
	# Reserve is owned by AmmoManager — pull the rounds from it.
	var needed := weapon.mag_size - ammo
	ammo += AmmoManager.take(id, needed)
	reserve = AmmoManager.get_reserve(id)
	reloading = false
	ammo_changed.emit(ammo, reserve)

# --- Weapon inventory -----------------------------------------------------
func _equip(id: String) -> void:
	if weapon and id == current_weapon_id:
		return
	# Stash the outgoing weapon's loaded magazine before swapping.
	if weapon:
		_mag[current_weapon_id] = ammo
	current_weapon_id = id
	weapon = Arsenal.get_weapon(id)
	ammo = _mag.get(id, weapon.mag_size)
	reserve = AmmoManager.get_reserve(id)
	reloading = false
	fire_cooldown = 0.0
	_auto_selected = weapon.fire_mode == WeaponData.FireMode.AUTO
	ammo_changed.emit(ammo, reserve)
	suppressor_changed.emit(has_suppressor())
	weapon_changed.emit(weapon.display_name, _fire_mode_label())

func acquire_weapon(id: String) -> void:
	if id in owned:
		return
	var w := Arsenal.get_weapon(id)
	if w == null:
		return
	owned.append(id)
	_grant_starting_ammo(id)
	_equip(id)

## Loads one magazine into the weapon and routes the remaining starting mags
## through AmmoManager — the single ammo-granting path.
func _grant_starting_ammo(id: String) -> void:
	var w := Arsenal.get_weapon(id)
	if w == null:
		return
	_mag[id] = w.mag_size
	_suppressed[id] = false
	AmmoManager.grant_ammo(id, maxi(0, w.starting_mags - 1))

func _on_reserve_changed(weapon_id: String, rounds: int) -> void:
	if weapon_id == current_weapon_id:
		reserve = rounds
		ammo_changed.emit(ammo, reserve)

func _try_equip_slot(index: int) -> void:
	if not control_enabled or index >= Arsenal.order.size():
		return
	var id: String = Arsenal.order[index]
	if id in owned:
		_equip(id)
	elif Arsenal.get_weapon(id):
		message.emit("%s — not owned (buy it at the crate)." % Arsenal.get_weapon(id).display_name)

func _toggle_fire_mode() -> void:
	if weapon.fire_mode != WeaponData.FireMode.BOTH:
		return
	_auto_selected = not _auto_selected
	weapon_changed.emit(weapon.display_name, _fire_mode_label())
	message.emit("Fire mode: %s" % _fire_mode_label())

func _wants_auto_fire() -> bool:
	if weapon == null:
		return false
	if weapon.fire_mode == WeaponData.FireMode.AUTO:
		return true
	return weapon.fire_mode == WeaponData.FireMode.BOTH and _auto_selected

func _fire_mode_label() -> String:
	match weapon.fire_mode:
		WeaponData.FireMode.AUTO:
			return "AUTO"
		WeaponData.FireMode.BOTH:
			return "AUTO" if _auto_selected else "SEMI"
		_:
			return "SEMI"

func owned_weapons() -> Array:
	return owned

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

# --- Feedback (shake / recoil / muzzle / viewmodel / audio) ---------------
func add_shake(amount: float) -> void:
	_shake_trauma = minf(1.0, _shake_trauma + amount)

func _update_feedback(delta: float) -> void:
	# Recoil and trauma bleed back toward rest.
	_recoil = lerpf(_recoil, 0.0, delta * RECOIL_RECOVER)
	_shake_trauma = maxf(0.0, _shake_trauma - SHAKE_DECAY * delta)

	# Camera-local shake + recoil (independent of head mouse-look and ADS fov).
	var shake := _shake_trauma * _shake_trauma
	camera.rotation = Vector3(
		-_recoil + randf_range(-1.0, 1.0) * shake * MAX_SHAKE_ROT,
		randf_range(-1.0, 1.0) * shake * MAX_SHAKE_ROT,
		randf_range(-1.0, 1.0) * shake * MAX_SHAKE_ROT * 0.5)
	camera.position = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * shake * MAX_SHAKE_POS

	# Muzzle flash lifetime.
	if _muzzle_timer > 0.0:
		_muzzle_timer -= delta
		if _muzzle_timer <= 0.0:
			_muzzle_flash.visible = false

	# Viewmodel: settle toward the hip/ADS pose with a recovering recoil kick.
	_vm_recoil = lerpf(_vm_recoil, 0.0, delta * VM_LERP)
	var base_pos := VM_ADS_POS if ads_active else VM_HIP_POS
	var desired := base_pos + Vector3(0.0, _vm_recoil * 0.3, _vm_recoil)
	_viewmodel.position = _viewmodel.position.lerp(desired, delta * VM_LERP)

func _build_viewmodel() -> void:
	_viewmodel = Node3D.new()
	camera.add_child(_viewmodel)
	_viewmodel.position = VM_HIP_POS

	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.09, 0.09, 0.11)
	metal.metallic = 0.6
	metal.roughness = 0.5

	var slide := MeshInstance3D.new()
	var sb := BoxMesh.new()
	sb.size = Vector3(0.05, 0.06, 0.22)
	slide.mesh = sb
	slide.material_override = metal
	slide.position = Vector3(0, 0, -0.05)
	_viewmodel.add_child(slide)

	var grip := MeshInstance3D.new()
	var gb := BoxMesh.new()
	gb.size = Vector3(0.045, 0.13, 0.06)
	grip.mesh = gb
	grip.material_override = metal
	grip.position = Vector3(0, -0.08, 0.04)
	grip.rotation_degrees = Vector3(18, 0, 0)
	_viewmodel.add_child(grip)

	# Muzzle flash lives at the front of the slide so recoil carries it.
	_muzzle_flash = Node3D.new()
	_muzzle_flash.position = Vector3(0, 0.005, -0.18)
	_muzzle_flash.visible = false
	_viewmodel.add_child(_muzzle_flash)

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.8, 0.4)
	light.light_energy = 4.0
	light.omni_range = 6.0
	_muzzle_flash.add_child(light)

	var flash := MeshInstance3D.new()
	var fmesh := SphereMesh.new()
	fmesh.radius = 0.05
	fmesh.height = 0.1
	flash.mesh = fmesh
	var fmat := StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.albedo_color = Color(1.0, 0.85, 0.4)
	fmat.emission_enabled = true
	fmat.emission = Color(1.0, 0.8, 0.3)
	fmat.emission_energy_multiplier = 6.0
	flash.material_override = fmat
	_muzzle_flash.add_child(flash)

## Explicit 3D audio listener, parented to the HEAD rather than the camera.
## A Camera3D is the implicit listener, but: (a) an explicit node keeps the
## listener pinned to the operator's head if we ever add a second camera
## (viewmodel/cutscene), and (b) the head carries yaw+pitch but NOT the
## per-shot camera shake/recoil, so directionality doesn't jitter when firing.
func _build_listener() -> void:
	var listener := AudioListener3D.new()
	head.add_child(listener)
	listener.make_current()

func _build_audio() -> void:
	_sfx_fire = _make_sfx(SFX_GUNSHOT, -6.0)
	_sfx_hurt = _make_sfx(SFX_HURT, 0.0)
	_sfx_impact = _make_sfx(SFX_IMPACT, -3.0)

func _make_sfx(path: String, volume_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	if ResourceLoader.exists(path):
		var res = load(path)  # untyped: avoids a Resource->AudioStream downcast error
		p.stream = res
	p.volume_db = volume_db
	add_child(p)
	return p

# --- Damage / life --------------------------------------------------------
func take_damage(amount: int) -> void:
	hp = maxi(0, hp - amount)
	health_changed.emit(hp, MAX_HP)
	add_shake(HURT_SHAKE)
	damaged.emit()
	if _sfx_hurt.stream:
		_sfx_hurt.play()
	if hp <= 0:
		_respawn()

func _respawn() -> void:
	message.emit("You died — respawning at base. Ammo is NOT replenished.")
	hp = MAX_HP
	# Ammo deliberately does NOT regenerate — not on death, not at dawn.
	global_position = _spawn_point
	velocity = Vector3.ZERO
	health_changed.emit(hp, MAX_HP)

# --- Attachment pipeline --------------------------------------------------
## Suppressor is fitted to the CURRENTLY equipped weapon (proves per-weapon
## attachments). `_res` is accepted for compatibility with the crate shop.
func attach_suppressor(_res = null) -> void:
	_suppressed[current_weapon_id] = true
	suppressor_changed.emit(true)
	message.emit("Suppressor fitted to %s — now %dm." % [
		weapon.display_name, int(weapon.noise_suppressed)])

func has_suppressor() -> bool:
	return _suppressed.get(current_weapon_id, false)

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
