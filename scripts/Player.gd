extends CharacterBody3D
class_name Player
## First-person operator controller: movement/noise states, ADS red laser, and
## data-driven weapons (fire / reload / headshot detection, switching). See
## PROJECT_SPEC.md "Movement & Noise", "Combat & Scoring" and "Weapons".

signal ammo_changed(loaded: int, reserve: int)
signal health_changed(hp: int, max_hp: int)
signal state_changed(state_name: String)
signal suppressor_changed(has_suppressor: bool)
signal weapon_changed(display_name: String, fire_mode: String)
signal message(text: String)
signal ifak_changed(count: int, max_count: int)
signal ifak_progress(active: bool, progress: float)
signal grenade_changed(count: int, max_count: int)
signal claymore_changed(count: int, max_count: int)
signal claymore_equipped_changed(equipped: bool)
## Contextual interaction prompt. Emitted rather than the player holding a HUD
## reference, matching how every other Player->HUD channel already works.
## `source` is passed through to HUD.show_prompt/hide_prompt's owner argument
## so this prompt can't be stolen or stranded by another prompt owner.
signal prompt(text: String, source)
signal prompt_cleared(source)
## Equip state changed. The trajectory preview and the HUD both key off this
## rather than polling.
signal grenade_equipped_changed(equipped: bool)
## Emitted on death so any open modal UI (the store) can close itself cleanly.
signal died_while_busy
## Player took a hit. `dir_angle` is radians relative to facing (0 = ahead,
## positive = to the right) so the HUD can show where it came from.
signal damaged(dir_angle: float)
signal zombie_hit(headshot: bool, damage: int, remaining_hp: int)

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
# --- Jump & mantle ---------------------------------------------------------
@export var jump_height: float = 0.9
## Noise made on landing a jump and on completing a mantle (PROJECT_SPEC.md
## noise table). Neither may be silent or stealth breaks.
@export var jump_noise_radius: float = 12.0
@export var mantle_noise_radius: float = 10.0
## Ledges up to this high can be mantled. 2.0 is deliberate: it's exactly the
## depth of the zombie ditch, so climbing out is possible but effortful.
@export var mantle_max_height: float = 2.0
@export var mantle_reach: float = 0.9        # forward probe distance
const MANTLE_CHEST_Y := 1.0                  # forward probe height
const MANTLE_LEDGE_STEP := 0.45              # how far past the face to probe down
const MANTLE_MIN_HEIGHT := 0.35

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

const LASER_MAX_DRAW := 100.0

# --- Red laser detection ---------------------------------------------------
## REPLACES the old "zombie within 10m of the PLAYER" rule entirely.
##
## The zombie notices the DOT, not the operator. Any zombie within
## LASER_DETECT_RADIUS of the laser's impact point that has line of sight to
## that point becomes curious and investigates it. Distance from the player is
## irrelevant — a zombie 200m away is alerted if the dot lands beside it.
##
## Deliberately NOT routed through NoiseManager: this is a separate sensory
## channel and must never generate a noise event.
const LASER_DETECT_RADIUS := 15.0
## Evaluated on this cadence rather than per frame.
const LASER_DETECT_INTERVAL := 0.25
## Debounce: a zombie already alerted by the dot only re-arms once the dot has
## moved this far from where it alerted that zombie...
const LASER_REARM_DISTANCE := 5.0
## ...or once the laser has been off/IR for this long, which clears every mark.
const LASER_OFF_REARM_TIME := 3.0

# --- Laser appearance (tune these by eye in the Inspector) ----------------
# RED: visible with or without NVGs, dramatically brighter than IR — the
# obvious tradeoff against the 10m detection rule.
@export var laser_red_beam_radius: float = 0.012
@export var laser_red_beam_alpha: float = 0.35
@export var laser_red_emission: float = 7.0
@export var laser_red_dot_size: float = 0.075
# IR: rendered ONLY when NVGs are on. Dimmer than red at every range, so the
# visibility-vs-stealth tradeoff stays real.
@export var laser_ir_beam_radius: float = 0.006
@export var laser_ir_beam_alpha: float = 0.15
@export var laser_ir_emission: float = 2.2
@export var laser_ir_dot_size: float = 0.045

# --- Long-range visibility -------------------------------------------------
## Minimum apparent size as a fraction of viewport height. Below this the dot
## is grown in world space so it never shrinks to sub-pixel at 60m+.
## 0.009 ~= 10px at 1080p.
@export var dot_min_screen_frac: float = 0.009
## Ceiling on apparent dot size so it can never grow big enough to obscure
## what's being aimed at (~4.5% of viewport height).
@export var dot_max_screen_frac: float = 0.045
@export var beam_min_screen_frac: float = 0.0016
## Beam length below which nothing is drawn — cheap guard against degenerate
## geometry (a very short, very wide tube reads as a bright disc/hexagon).
@export var beam_min_length: float = 0.1
## Flip the no-hit fade gradient if it fades from the wrong end (CylinderMesh
## V-axis direction is not worth hardcoding an assumption about).
@export var beam_fade_flip: bool = false
## Soft halo drawn behind the core: radius multiple, and how quickly it fades.
@export var dot_halo_scale: float = 3.2
@export var dot_halo_falloff: float = 2.2   # higher = tighter core, softer edge
@export var dot_halo_alpha: float = 0.55

# --- Weapon tuning (per-weapon stats live in WeaponData / Arsenal) --------
## Weapon rays hit the world (layer 1) and zombie head hitboxes (layer 3).
## Other Area3Ds (e.g. the supply crate trigger) live on layer 2 and are ignored.
const HIT_MASK := 1 | 4
const STARTING_WEAPON := "m17"
const MAX_HP := 100

# --- Hand grenade ----------------------------------------------------------
## Input-map action name, not a keycode — see project.godot `[input]`.
const ACTION_EQUIP_GRENADE := "equip_grenade"
## Total fuse, in seconds, from the moment the throw button goes DOWN. Cooking
## and flight share one clock: a grenade cooked for 2s detonates 3s after it
## leaves the hand. Let it run out in your hand and it kills you.
const GRENADE_FUSE := 5.0
const GRENADE_SCRIPT := preload("res://scripts/Grenade.gd")
const GRENADE_PROFILE := preload("res://resources/frag_grenade.tres")

## Overhand: fast, lofted a little above the aim vector — an arm coming over
## the top releases upward, and on this map that buys ~28m of range.
## Underhand: much slower and lofted hard, landing ~10m out over a higher
## peak. The lob is for dropping one into the ditch or over near cover
## without stepping out.
##
## Both are read by the trajectory preview through grenade_launch_velocity(),
## so the drawn arc can never disagree with the throw.
##
## DERIVED, not guessed. At the grenade's effective gravity (12 m/s^2 — see
## Grenade.GRAVITY_SCALE) and a 1.6m release height, these give:
##   overhand   24 m/s @ 14deg -> 27.6m range, 3.0m peak, 1.18s flight
##   underhand  10 m/s @ 45deg ->  9.7m range, 3.6m peak, 1.37s flight
## which satisfies "the lob lands visibly shorter AND higher" on both counts,
## and leaves both well inside the 5s fuse so an uncooked throw lands and
## rolls before it goes off.
const GRENADE_SPEED_OVERHAND := 24.0
const GRENADE_SPEED_UNDERHAND := 10.0
const GRENADE_PITCH_OVERHAND_DEG := 14.0
const GRENADE_PITCH_UNDERHAND_DEG := 45.0
## Spawn offset from the camera, along the look direction — clear of the
## player's own capsule so the throw doesn't start inside it.
const GRENADE_SPAWN_FORWARD := 0.45

@export var grenade_max_carry: int = 4
## Master switch for the throw-trajectory preview, so the arc can be turned
## off and the throw playtested on instinct alone. Read every frame by
## GrenadeArc, so toggling it at runtime takes effect immediately.
@export var grenade_arc_enabled: bool = true
## Grenades are bought (EQUIPMENT tab) or found in resupply drops, never
## granted at spawn. Exposed so the arc/throw/detonation work can be
## playtested before the store tab exists — set it in the inspector.
@export var starting_grenades: int = 0

# --- Claymore --------------------------------------------------------------
## Input-map action name, not a keycode — see project.godot `[input]`.
## V, because C is crouch and G is the grenade.
const ACTION_EQUIP_CLAYMORE := "equip_claymore"
## Every claymore tunable lives in this resource — placement range, arming,
## detection geometry, recovery range, and the damage profile it detonates
## through. Edit resources/claymore.tres, not this script.
const CLAYMORE_CONFIG := preload("res://resources/claymore.tres")

## Carry cap is deliberately separate from the grenade's: they are independent
## inventories with independent caps, so nothing is shared but the pattern.
## 2 -> 4 (playtest fix pass), matching the grenade's cap. This is CARRIED
## only — placing one removes it from this count entirely (see
## _try_emplace_claymore()), and there is no cap on how many are emplaced in
## the world at once.
@export var claymore_max_carry: int = 4
## Bought at the crate (EQUIPMENT tab), never issued and never in a resupply
## drop. Exposed for the same reason as starting_grenades — so emplacement and
## detonation can be playtested without shopping first.
@export var starting_claymores: int = 0

# --- IFAK ------------------------------------------------------------------
## A 4-second commitment, not an instant heal: it forces the player to break
## contact before patching up, rather than button-mashing through a fight.
@export var ifak_heal: int = 40
@export var ifak_max_carry: int = 3
@export var ifak_apply_time: float = 4.0

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

# Stance multipliers for STANCE-penalty weapons (M249). Applied in real time,
# so starting to move mid-burst degrades control immediately.
@export var stance_mult_moving: float = 3.0
@export var stance_mult_standing: float = 1.5
@export var stance_mult_crouched: float = 1.1

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
## True only for the remainder of the frame in which the player died. The
## player respawns instantly, so this is the only window in which a death is
## observable at all — see is_alive().
var _died_this_frame := false

# Weapon state. `ammo`/`reserve` mirror the CURRENT weapon. Loaded magazines
# live here per weapon; RESERVE ammo is owned by the AmmoManager autoload.
var weapon: WeaponData
var current_weapon_id := STARTING_WEAPON
var owned: Array[String] = [STARTING_WEAPON]
var owned_items: Array[String] = []   # non-weapon purchases (radio, etc.)
var ifaks := 0
var _ifak_applying := false
var _ifak_timer := 0.0

# --- Equipment slot --------------------------------------------------------
## What is in the player's hands INSTEAD of the weapon. One slot, one item.
##
## The equipped WEAPON is deliberately never swapped out — nothing is stowed
## and restored — so "put the equipment away and go back to your weapon" is
## just returning this to NONE. Firing is gated on the slot instead.
##
## Generalised from a single `grenade_equipped` bool when the claymore
## arrived: two independent bools would have made "both equipped at once" a
## representable state, and every gate would have had to test both.
enum Equipment { NONE, GRENADE, CLAYMORE }
var equipped_item: int = Equipment.NONE

## Read-only views. Kept as properties rather than replaced with
## `equipped_item ==` at every call site so HUD.gd and GrenadeArc.gd — which
## both read `player.grenade_equipped` — needed no changes at all.
var grenade_equipped: bool:
	get:
		return equipped_item == Equipment.GRENADE
var claymore_equipped: bool:
	get:
		return equipped_item == Equipment.CLAYMORE
## The single gate the weapon respects: ANY equipment in hand blocks firing.
var equipment_equipped: bool:
	get:
		return equipped_item != Equipment.NONE

# --- Grenade state ---------------------------------------------------------
## Carried count. Persists across nights and is never restocked at dawn.
var grenades := 0
## Cooking = a throw button is held. Counts DOWN from GRENADE_FUSE.
var _cooking := false
var _cook_remaining := 0.0
## Which button started the cook. Only that button's RELEASE throws — the
## other one is ignored, because the throw type is committed at press.
var _cook_button := -1
var _cook_underhand := false

# --- Claymore state --------------------------------------------------------
## Carried count — what's in the pack, NOT what's emplaced in the world.
## There is no cap on how many are emplaced; the cap is on carry only.
## Persists across nights and is never restocked at dawn.
var claymores := 0
var _claymore_placer: ClaymorePlacer
## What the player is currently looking at, within recovery range, or null.
## Recomputed every physics frame via a raycast — see _find_recovery_target().
## Available at any time (Day or Night), not gated by phase.
var _recovery_target: Claymore
var _recovery_holding := false
var _recovery_hold_time := 0.0
var _prompt_showing := false
var _prompt_text := ""

# --- Radio menu coordination -----------------------------------------------
## True while the radio menu (T) is open. Movement stays enabled — the radio
## deliberately does not pause the game — but mouse-look is suppressed here
## so the camera doesn't spin while the player reads/keys through the list.
## RMB and Escape are deliberately NOT gated on this: both function normally
## (ADS, mouse-capture toggle) whether or not the menu is open — only T opens
## or closes it. Owned/set by RadioMenu via set_radio_menu_open(), not
## written directly.
var radio_menu_open := false
## True while TargetPainter owns the aim. Unlike radio_menu_open this leaves
## mouse-look and movement ALONE — painting is aiming — and only gates
## firing, ADS and the equipment toggles. Owned/set by TargetPainter via
## set_painting(), not written directly.
var painting := false
## Release-gated suppression of the NEXT trigger pull, so the LMB press that
## confirmed a paint can't also fire the weapon on the frame paint mode ends.
## Distinct from _ads_suppressed_until_release because they clear on
## different buttons.
var _fire_suppressed_until_release := false
## Sticky until an actual button-RELEASE event arrives. Guards the one frame
## a paint mode ends (see set_painting()) so the LMB press that CONFIRMED it
## can't also register as a fresh ADS press if RMB happened to be down at the
## same instant — a state check, not a reliance on which node's
## _unhandled_input happens to run first for a given event (that ordering
## isn't something to build correctness on). Also set on every radio menu
## close as the same conservative guard, though the menu closes on T now, a
## different key from RMB, so it rarely has anything to actually catch.
var _ads_suppressed_until_release := false

var ammo := 0                         # rounds in the current weapon's magazine
var reserve := 0                      # mirror of AmmoManager reserve for the current weapon
var reloading := false
var fire_cooldown := 0.0
var _auto_selected := false           # for BOTH-mode weapons: is auto selected?
var _mag: Dictionary = {}             # weapon id -> loaded rounds
var _suppressed: Dictionary = {}      # weapon id -> bool
# Weapon-specific attachments, one dict per slot, all weapon id -> bool. Kept
# in the same shape as `_suppressed` (rather than one dict of arrays) since
# each attachment id is only ever offered for a single weapon.
var _has_foregrip: Dictionary = {}        # HK 416 — moving-fire cone
var _has_choke: Dictionary = {}           # SPAS-12 — hip-fire spread
var _has_drum: Dictionary = {}            # M249 — 200-round belt
var _has_variable_zoom: Dictionary = {}   # M110 — adjustable 2x-8x
var _has_ir_laser: Dictionary = {}        # every laser-equipped weapon except M110

# M110 variable zoom optic state. Binary, not continuous: exactly two scope
# positions, no interpolated in-between value is ever stored or read.
const DEFAULT_ADS_FOV := 55.0
const HIP_FOV := 75.0
const SCOPE_FOV_NEAR := 41.98   # 2x, 2*atan(tan(37.5deg)/2)
const SCOPE_FOV_FAR := 10.96    # 8x, 2*atan(tan(37.5deg)/8)
const SCOPE_TWEEN_TIME := 0.08
var _scope_far := false     # false = 2x, true = 8x. Persists across ADS toggles.
var _scope_tween: Tween

var _footstep_timer := 0.0
var _branch_timer := 1.0
var _spawn_point := Vector3.ZERO

# Jump / mantle state.
var _jumping := false          # airborne because we jumped (drives landing noise)
var _mantling := false
var _mantle_t := 0.0
var _mantle_dur := 0.5
var _mantle_from := Vector3.ZERO
var _mantle_to := Vector3.ZERO

# Feedback runtime state.
var _shake_trauma := 0.0
var _recoil := 0.0
var _recoil_h := 0.0        # horizontal muzzle walk (auto weapons)
var _auto_shots := 0        # consecutive auto shots (drives RAMP + bloom)
var _auto_idle := 0.0       # time since the last shot
var _reload_cancel := false # set when a shell reload is interrupted by firing
var _muzzle_timer := 0.0
var _vm_recoil := 0.0
var _muzzle_flash: Node3D
var _muzzle_marker: Marker3D
var _viewmodel: Node3D
var _laser_beam: MeshInstance3D
var _laser_beam_mesh: CylinderMesh
var _laser_beam_mat: StandardMaterial3D
var _laser_fade_mat: StandardMaterial3D
# Laser debug telemetry (shown in the F3 overlay).
var _laser_dbg := "laser: idle"
# Laser-dot detection state.
var _laser_detect_timer := 0.0
var _laser_off_time := 0.0
var _laser_marks: Dictionary = {}   # zombie instance id -> dot pos when alerted
var _laser_dot: Node3D
var _laser_core: MeshInstance3D
var _laser_halo: MeshInstance3D
var _laser_dot_mat: StandardMaterial3D
var _laser_halo_mat: StandardMaterial3D
## Set by Main when NVGs toggle — the IR laser is only rendered under NVGs.
var nvg_active := false
var _sfx_fire: AudioStreamPlayer
var _sfx_fire_supp: AudioStreamPlayer
var _sfx_action: AudioStreamPlayer
var _sfx_hurt: AudioStreamPlayer
var _sfx_impact: AudioStreamPlayer

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var laser_ray: RayCast3D = $Head/Camera3D/LaserRay

func _ready() -> void:
	add_to_group("player")
	# Faction-blind: the area-damage system hits everything in this group,
	# including whoever threw the grenade.
	add_to_group(AreaDamageSystem.GROUP_DAMAGEABLE)
	# What zombies chase, attack and leap at. The sole member today.
	#
	# NOT joined to Damageable.GROUP_BULLET, and that omission is load-bearing:
	# that group is what a PLAYER ROUND can damage, and the player is kept out
	# of it so a round can never resolve its own shooter as a target. The two
	# groups are different axes — see Damageable.gd.
	add_to_group(Zombie.GROUP_HOSTILE_TARGET)
	# Collide with the world (layer 1) AND player-only barriers (layer 5, used
	# by C-wire). Zombies mask layer 1 only, so wire stops us and not them.
	collision_mask = 1 | Obstacle.PLAYER_BARRIER_LAYER | Obstacle.SOLID_NO_NAV_LAYER
	_spawn_point = global_position
	camera.current = true
	_build_laser()
	_set_mouse_captured(true)
	laser_ray.target_position = Vector3(0, 0, -LASER_MAX_DRAW)
	# Same mask as gunfire so the dot lands on zombies (bodies + head hitboxes)
	# and not just world geometry.
	laser_ray.collision_mask = HIT_MASK
	laser_ray.collide_with_areas = true
	_build_listener()
	_build_viewmodel()
	_build_audio()
	_build_grenade_arc()
	_build_claymore_placer()

	# Starting loadout: M17 only, 2 mags total (one loaded, one spare).
	_grant_starting_ammo(STARTING_WEAPON)
	_equip(STARTING_WEAPON)
	# Normally 0 — grenades are bought or found, never issued. Routed through
	# the same grant path as everything else so the cap holds even here.
	grenades = 0
	grant_grenades(starting_grenades)
	claymores = 0
	grant_claymores(starting_claymores)
	# Reserve changes (crate purchases, supply drops) keep the HUD honest.
	AmmoManager.reserve_changed.connect(_on_reserve_changed)

	# Prime the HUD.
	health_changed.emit(hp, MAX_HP)
	state_changed.emit("WALK")

func _physics_process(delta: float) -> void:
	fire_cooldown = maxf(0.0, fire_cooldown - delta)

	# A mantle is a locked interpolation: no gravity, no steering, no shooting.
	if _mantling:
		_update_mantle(delta)
		var mantle_head_y := CROUCH_HEAD_Y if is_crouching else STAND_HEAD_Y
		head.position.y = lerpf(head.position.y, mantle_head_y, delta * HEAD_LERP)
		_update_feedback(delta)
		_update_laser()
		return

	# Outside the control_enabled block on purpose: when control is taken away
	# (crate, build mode) this still runs and CLEARS a showing prompt/hold,
	# rather than stranding "Hold E — recover claymore" on screen (or a
	# half-finished hold) behind a menu.
	_update_claymore_recovery(delta)

	# Gravity always applies.
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0
		# Landing from a jump is loud.
		if _jumping:
			_jumping = false
			NoiseManager.emit_noise(global_position, jump_noise_radius)

	if control_enabled:
		_handle_movement(delta)
		_handle_noise(delta)
		_update_ifak(delta)
		_update_cook(delta)
		_update_laser_detection(delta)
		# Full-auto: keep firing while the trigger is held (rate-limited in
		# _fire). Gated on the equipment slot too, or holding LMB to cook a
		# throw — or to confirm a claymore — would empty a magazine as well.
		# `painting` is checked inside _fire() too, but is repeated here
		# because this is a POLLED path: holding LMB to confirm a paint would
		# otherwise keep calling _fire() every frame, and relying on the
		# painter marking its events handled does nothing for a poll.
		if not equipment_equipped and not painting and _wants_auto_fire() \
				and mouse_captured and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_fire()
	else:
		velocity.x = 0.0
		velocity.z = 0.0

	move_and_slide()

	# Smooth crouch camera.
	var target_y := CROUCH_HEAD_Y if is_crouching else STAND_HEAD_Y
	head.position.y = lerpf(head.position.y, target_y, delta * HEAD_LERP)

	_update_feedback(delta)
	_update_laser()

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
	elif sprint_held and is_moving and not _cooking:
		# No sprinting with a live fuse in your hand. Note this gates only
		# COOKING, not merely having a grenade equipped — walking around with
		# one in hand is free, and normal movement speed is untouched while
		# cooking. Only the sprint option is taken away.
		new_state = MoveState.SPRINT
	else:
		new_state = MoveState.WALK
	# Applying an IFAK caps you at a walk. Note the SPRINT state is still set
	# above when shift is held — _update_ifak reads that to cancel.

	if new_state != move_state:
		move_state = new_state
		state_changed.emit(_state_label())

	var speed: float = SPEED[move_state]
	# Extended Drum weight penalty: applies whenever it's fitted, not just
	# while the SAW is the equipped weapon or actively firing — it's carried
	# gear, not a firing-state effect.
	if move_state == MoveState.SPRINT and has_drum("m249"):
		speed *= 0.9
	if _ifak_applying:
		speed = minf(speed, SPEED[MoveState.WALK])   # walking speed maximum
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

## Zombies notice the DOT. Runs on LASER_DETECT_INTERVAL, not per frame.
func _update_laser_detection(delta: float) -> void:
	# The M110 has no laser at all — optic reticle only — so this entire
	# system is skipped for it, not merely inert. No zombie can ever be
	# alerted by aiming an M110, at any distance or angle.
	if current_weapon_id == "m110":
		return
	# Only the red laser does this. IR never gives you away — that's its point.
	var armed: bool = ads_active and not has_ir_laser() and _laser_dot.visible
	if not armed:
		_laser_off_time += delta
		if _laser_off_time >= LASER_OFF_REARM_TIME:
			_laser_marks.clear()      # everything re-arms after a long break
		return

	_laser_off_time = 0.0
	_laser_detect_timer -= delta
	if _laser_detect_timer > 0.0:
		return
	_laser_detect_timer = LASER_DETECT_INTERVAL

	var dot_pos := _laser_dot.global_position
	var space := get_world_3d().direct_space_state
	for node in get_tree().get_nodes_in_group("zombies"):
		var z = node
		if not is_instance_valid(z) or not z.is_alive():
			continue
		# Distance to the DOT, not to the player.
		if z.global_position.distance_to(dot_pos) > LASER_DETECT_RADIUS:
			continue

		# Debounce: one alert per zombie per continuous dwell. Holding the dot
		# still must not re-alert the same zombie every tick.
		var id := z.get_instance_id()
		if _laser_marks.has(id):
			var prev: Vector3 = _laser_marks[id]
			if prev.distance_to(dot_pos) < LASER_REARM_DISTANCE:
				continue

		# Line of sight from the ZOMBIE to the dot. The dot sits on a surface,
		# so the ray is expected to hit at the dot — anything closer is an
		# occluder in between.
		var from: Vector3 = z.global_position + Vector3(0, 1.4, 0)
		var q := PhysicsRayQueryParameters3D.create(from, dot_pos)
		q.collision_mask = 1
		q.exclude = [z.get_rid()]
		var hit := space.intersect_ray(q)
		var visible_dot := true
		if hit:
			var hp: Vector3 = hit.position
			visible_dot = hp.distance_to(dot_pos) < 0.5
		if not visible_dot:
			continue

		_laser_marks[id] = dot_pos
		z.notice_laser_dot(dot_pos)

# --- Input ----------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mouse_captured and control_enabled and not radio_menu_open:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		head.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		head.rotation.x = clampf(head.rotation.x, -1.4, 1.4)
	elif event is InputEventMouseButton:
		if not (mouse_captured and control_enabled):
			return
		if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			# Trigger released — a paint-confirm click can stop suppressing
			# the next real shot.
			_fire_suppressed_until_release = false
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if not event.pressed:
				_ads_suppressed_until_release = false
				return
			if painting or _ads_suppressed_until_release:
				# RMB is claimed while painting (aiming a fire mission), or
				# for one press right after something else just released the
				# suppression window. The radio menu no longer claims RMB at
				# all — it closes on T only, so RMB functions as ADS
				# identically whether or not the menu is open.
				return
		# A grenade in hand takes both mouse buttons: LMB overhand, RMB
		# underhand. Handled before the `pressed` filter below because a
		# throw fires on RELEASE, which the weapon path never needs.
		if grenade_equipped:
			_handle_grenade_mouse(event)
			return
		if not event.pressed:
			return
		# A claymore takes LMB only, on PRESS: confirm the emplacement. RMB
		# falls through to nothing rather than to ADS — aiming down sights
		# with a mine in your hands is not a state that should exist.
		if claymore_equipped:
			if event.button_index == MOUSE_BUTTON_LEFT:
				_try_emplace_claymore()
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if not _wants_auto_fire():   # semi: one shot per click (auto is in _physics_process)
				_fire()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_toggle_ads()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_toggle_scope()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_toggle_scope()
	elif event is InputEventKey and event.pressed and not event.echo:
		# Input-map action, so it stays remappable — see project.godot.
		if event.is_action_pressed(ACTION_EQUIP_GRENADE):
			_toggle_grenade()
			return
		if event.is_action_pressed(ACTION_EQUIP_CLAYMORE):
			_toggle_claymore()
			return
		# Claymore recovery is now a HOLD, not a single press — see
		# _update_claymore_recovery(), polled every physics frame via
		# Input.is_action_pressed("interact") rather than intercepted here.
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
			KEY_H:
				if control_enabled:
					_start_ifak()
			KEY_SPACE:
				_try_jump_or_mantle()
			KEY_1:
				_try_equip_slot(0)
			KEY_2:
				_try_equip_slot(1)
			KEY_3:
				_try_equip_slot(2)
			KEY_4:
				_try_equip_slot(3)
			KEY_5:
				_try_equip_slot(4)
			KEY_ESCAPE:
				# When the crate shop owns the mouse, let it handle Esc instead.
				# The radio menu no longer claims Escape at all — it closes on
				# T only — so this fires identically whether or not the menu
				# is open, the same "normal" behaviour Escape always has.
				if control_enabled:
					_set_mouse_captured(not mouse_captured)

func _toggle_ads() -> void:
	if _ifak_applying or _mantling:
		return   # can't aim while patching up or climbing
	_kill_scope_tween()
	ads_active = not ads_active
	camera.fov = _current_ads_fov() if ads_active else HIP_FOV
	message.emit("ADS " + ("ON — red laser hot (10m tell)" if ads_active else "OFF"))

## The ADS FOV for the currently equipped weapon: the M110's adjustable optic
## (if bought) wins over its fixed-scope default, which in turn wins over the
## player's baseline ADS FOV. Nothing else in the roster sets `ads_fov`.
## Entering ADS always snaps straight to the current value — only the scope
## TOGGLE (below) tweens, and only between the two fixed positions.
func _current_ads_fov() -> float:
	if weapon == null:
		return DEFAULT_ADS_FOV
	if current_weapon_id == "m110" and has_variable_zoom("m110"):
		return SCOPE_FOV_FAR if _scope_far else SCOPE_FOV_NEAR
	if weapon.ads_fov > 0.0:
		return weapon.ads_fov
	return DEFAULT_ADS_FOV

## Scroll wheel while ADS with the variable zoom optic fitted. Inert
## otherwise — no other control claims the wheel in first-person. Either
## direction just flips to the other position — this is a two-position
## scope, not a dial. A short tween carries the FOV across so the switch
## doesn't jar the eye, but it always lands exactly on 2x or 8x, never
## between them.
func _toggle_scope() -> void:
	if not (ads_active and current_weapon_id == "m110" and has_variable_zoom("m110")):
		return
	_scope_far = not _scope_far
	_kill_scope_tween()
	_scope_tween = create_tween()
	_scope_tween.tween_property(camera, "fov", SCOPE_FOV_FAR if _scope_far else SCOPE_FOV_NEAR,
		SCOPE_TWEEN_TIME)
	message.emit("Scope: %s" % ("8x" if _scope_far else "2x"))

func _kill_scope_tween() -> void:
	if _scope_tween and _scope_tween.is_valid():
		_scope_tween.kill()

# --- Weapon ---------------------------------------------------------------
func _fire() -> void:
	if _mantling:
		return   # both hands on the ledge
	if equipment_equipped:
		return   # something else is in that hand — stow it (G / V, or a weapon slot)
	if painting or _fire_suppressed_until_release:
		# Painting a fire mission, or this is the trigger pull that just
		# confirmed one. Either way the weapon stays cold.
		return
	# Firing cancels an in-progress IFAK (nothing consumed) and does not shoot
	# on that input — the cancel IS the action.
	if _ifak_applying:
		_cancel_ifak("fired")
		return
	if reloading:
		# Tube-fed weapons abort the reload and fire immediately, as long as at
		# least one shell has made it in. Core to how a shotgun plays.
		if weapon.shell_reload and ammo > 0:
			_reload_cancel = true
			reloading = false
		else:
			return
	if fire_cooldown > 0.0:
		return
	if ammo <= 0:
		message.emit("*click* — empty. Press R to reload.")
		return

	ammo -= 1
	fire_cooldown = weapon.fire_interval
	ammo_changed.emit(ammo, reserve)

	# Full-auto penalty: vertical kick scaled, plus unpredictable horizontal
	# walk. Semi-auto is unaffected (multiplier stays 1.0).
	var penalty := _auto_penalty_mult()
	var bloom_deg := _current_bloom_deg()
	_auto_shots += 1
	_auto_idle = 0.0

	# Fire feedback: muzzle flash, recoil kick, a touch of shake, and the report.
	_muzzle_flash.visible = true
	_muzzle_timer = MUZZLE_FLASH_TIME
	_recoil = minf(MAX_RECOIL, _recoil + weapon.recoil_per_shot * penalty)
	_recoil_h += randf_range(-1.0, 1.0) * weapon.horizontal_recoil * penalty
	_recoil_h = clampf(_recoil_h, -MAX_RECOIL, MAX_RECOIL)
	_vm_recoil = VM_RECOIL_KICK
	add_shake(FIRE_SHAKE)

	var suppressed: bool = _suppressed.get(current_weapon_id, false)

	# AUDIO state — keyed off the attachment only.
	if suppressed:
		if _sfx_fire_supp.stream:
			_sfx_fire_supp.play()
		if _sfx_action.stream:
			_sfx_action.play()   # action noise dominates the suppressed mix
	elif _sfx_fire.stream:
		_sfx_fire.play()

	# NOISE RADIUS — a separate system that happens to read the same attachment.
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
	# Baseline mechanical accuracy, then auto bloom on top (bloom applies in
	# ADS too — that IS the auto penalty), then the moving-fire penalty (if
	# this weapon has one — currently only the 416), tightened by the
	# Foregrip. Applies hip or ADS: moving is moving either way.
	var cone := weapon.ads_cone_deg + bloom_deg
	if is_moving and weapon.moving_cone_extra_deg > 0.0:
		var extra := weapon.moving_cone_extra_deg
		if has_foregrip(current_weapon_id):
			extra *= 0.6   # Foregrip: -40% of the moving-only penalty, not the baseline
		cone += extra
	if cone > 0.0:
		base_dir = _jitter_dir(base_dir, cone)

	# Shotguns fire multiple pellets, each jittered inside a cone. The
	# Breacher Choke widens this specifically for hip-fire — ADS is untouched.
	var pellet_spread := weapon.pellet_spread_deg
	if not ads_active and has_choke(current_weapon_id):
		pellet_spread *= 1.25
	for i in weapon.pellets:
		var dir := base_dir
		if pellet_spread > 0.0:
			dir = _jitter_dir(base_dir, pellet_spread)
		_fire_ray(from, dir)

# Traces one round/pellet, applies damage, and draws a tracer.
#
# For weapons with max_penetration_targets > 0 (currently only the 416) the
# round keeps travelling after damaging a zombie and can hit up to that many
# ADDITIONAL zombies behind it, each at penetration_damage_multiplier. It
# stops dead on the first NON-zombie collider — world geometry, obstacles,
# sandbag panels, the player — so penetration is strictly a flesh mechanic
# and can never punch through cover. Every other weapon has
# max_penetration_targets == 0, so the loop runs once and behaves exactly
# like the single-hit ray this replaced.
#
# Headshot is resolved independently per target: the ray can body the first
# zombie and head the second, and each gets its own multiplier.
func _fire_ray(from: Vector3, dir: Vector3) -> void:
	var to := from + dir * weapon.max_range
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = [get_rid()]
	var segment_from := from
	var impact := to
	# Counts ENTITIES DAMAGED so far, not ray segments traced — an entity's
	# head Area3D and body sit on separate colliders, so one entity can be
	# struck twice by consecutive segments. Only the first strike deals
	# damage (see `damaged` below) and only that one spends penetration
	# budget; the second is skipped without costing a target.
	var targets_damaged := 0
	var damaged: Array = []

	while true:
		var q := PhysicsRayQueryParameters3D.create(segment_from, to)
		q.exclude = exclude
		# World/bodies (layer 1) + head hitboxes (layer 3). Areas are opted
		# into so a head Area3D can be hit; other areas sit on other layers.
		q.collision_mask = HIT_MASK
		q.collide_with_areas = true
		var hit := space.intersect_ray(q)
		if not hit:
			break
		impact = hit.position

		# Head vs body comes from WHICH collider was hit — the head hitbox is a
		# distinct Area3D — not from inferring a hit height. Resolution is
		# GENERIC: nothing here names zombies, so a fighter joining
		# Damageable.GROUP_BULLET later becomes shootable with no change to
		# this function.
		var col = hit.collider
		var resolved: Dictionary = Damageable.resolve_hit(col)

		# COVER IS NOW A GENUINE FALLTHROUGH, not the default. It used to mean
		# "not a zombie"; it now means "not damageable". The distinction
		# matters because HIT_MASK admits all of layer 1 — including the
		# player, who is kept OUT of GROUP_BULLET precisely so a round can
		# never resolve its own shooter (the muzzle-RID exclude is not the
		# only thing standing between them).
		if not bool(resolved["is_damageable"]):
			# Cover, not flesh: the round stops here for every weapon.
			break

		# `entity` may be null for a damageable collider with no resolvable
		# owner (a head hitbox missing its meta). That is deliberately NOT
		# cover — it falls through to the is_new_target check below and stops
		# a non-penetrating round, exactly as it did before this refactor.
		var target = resolved["entity"]
		var headshot: bool = bool(resolved["is_head"])

		# INVARIANT: hit-zone resolution never returns "head" for an entity
		# with no registered head hitbox.
		#
		# It holds by construction today — a head result can only come from
		# striking a GROUP_BULLET_HEAD collider, whose HEAD_META names its own
		# owner. The assertion guards the future case: a damageable that
		# registers no head (an allied fighter is specified without one) must
		# resolve as a body hit, and anyone reintroducing height-inferred
		# headshots would trip this immediately. assert() only — per-shot
		# path, stripped from release builds.
		assert(not headshot or target == null
				or Damageable.has_head_hitbox(get_tree(), target),
			"[HIT] resolved a HEADSHOT on an entity with no registered head hitbox. Head vs body must come from which collider was struck, never from inferring a hit height.")

		var is_new_target: bool = target != null and is_instance_valid(target) \
				and not damaged.has(target)
		if not is_new_target and weapon.max_penetration_targets <= 0:
			# Non-penetrating weapon that struck a damageable collider it
			# can't damage (already-hit, or a head hitbox with no owner meta):
			# the round still stops, exactly as it did before penetration
			# existed.
			break
		if is_new_target:
			damaged.append(target)
			# Damage falls off with distance from the muzzle; a penetrating
			# round loses a further flat fraction on every entity behind the
			# first (flat, not compounded — flesh resistance, not falloff).
			var dist := from.distance_to(hit.position)
			var mult := weapon.damage_mult_at(dist)
			if targets_damaged > 0:
				mult *= weapon.penetration_damage_multiplier
			# Raw body_damage + the multiplier, NOT a pre-multiplied value:
			# take_damage() applies headshot first, then falloff, and rounds
			# exactly once — see Zombie.take_damage()'s docstring. This is the
			# damageable contract, documented on Damageable.gd.
			var dealt: int = target.take_damage(weapon.body_damage, headshot, mult)
			var remaining: int = maxi(0, target.hp)
			print("[HIT] %s — %d dmg @ %.1fm (x%.2f mult, target %d), %d HP remaining" % [
				"HEAD" if headshot else "BODY", dealt, dist, mult, targets_damaged + 1, remaining])
			zombie_hit.emit(headshot, dealt, remaining)
			if _sfx_impact.stream:
				_sfx_impact.play()
			targets_damaged += 1
			if targets_damaged > weapon.max_penetration_targets:
				break

		# Continue past this collider. Nudged forward so the next segment
		# can't re-register the surface it just left.
		exclude.append(col.get_rid())
		segment_from = hit.position + dir * 0.05

	_spawn_tracer(_muzzle_position(), impact)

# --- Full-auto penalty ----------------------------------------------------
## Recoil multiplier for this shot. 1.0 for semi-auto and NONE-penalty weapons.
func _auto_penalty_mult() -> float:
	if weapon == null or not _wants_auto_fire():
		return 1.0
	match weapon.auto_penalty:
		WeaponData.AutoPenalty.RAMP:
			# 1.4x on the first auto shot, +12% per consecutive shot, cap 3.5x.
			var m: float = weapon.auto_recoil_start_mult * pow(
				1.0 + weapon.auto_recoil_growth, float(_auto_shots))
			return minf(m, weapon.auto_recoil_max_mult)
		WeaponData.AutoPenalty.STANCE:
			return _stance_mult()
		_:
			return 1.0

## Real-time stance multiplier — re-evaluated per shot, so moving mid-burst
## degrades control immediately and settles back when you stop.
func _stance_mult() -> float:
	if is_crouching:
		return stance_mult_crouched
	if is_moving:
		return stance_mult_moving
	return stance_mult_standing

## Cone bloom in degrees for the shot about to be fired.
func _current_bloom_deg() -> float:
	if weapon == null or not _wants_auto_fire():
		return 0.0
	if weapon.auto_penalty == WeaponData.AutoPenalty.NONE:
		return 0.0
	var t: float = clampf(float(_auto_shots) / float(maxi(1, weapon.bloom_shots_to_max)), 0.0, 1.0)
	var deg: float = lerpf(weapon.bloom_min_deg, weapon.bloom_max_deg, t)
	# Stance weapons scale bloom by stance as well as recoil.
	if weapon.auto_penalty == WeaponData.AutoPenalty.STANCE:
		deg *= _stance_mult()
	return deg

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
	var cap := effective_mag_size(current_weapon_id)
	if reloading or ammo >= cap or reserve <= 0:
		return
	if weapon.shell_reload:
		_reload_shells()
		return

	reloading = true
	var id := current_weapon_id
	message.emit("Reloading…")
	await get_tree().create_timer(weapon.reload_time).timeout
	if not reloading or current_weapon_id != id:
		return   # cancelled by a weapon switch mid-reload
	# Reserve is owned by AmmoManager — pull the rounds from it.
	var needed := effective_mag_size(id) - ammo
	ammo += AmmoManager.take(id, needed)
	reserve = AmmoManager.get_reserve(id)
	reloading = false
	ammo_changed.emit(ammo, reserve)

## Tube-fed reload: one shell at a time, so topping up 2 shells is far quicker
## than filling all 8. Interruptible — firing after any completed shell aborts
## the rest (see _fire).
func _reload_shells() -> void:
	reloading = true
	_reload_cancel = false
	var id := current_weapon_id
	message.emit("Loading shells…")

	await get_tree().create_timer(weapon.reload_start).timeout
	while reloading and not _reload_cancel and current_weapon_id == id:
		if ammo >= weapon.mag_size or AmmoManager.get_reserve(id) <= 0:
			break
		await get_tree().create_timer(weapon.shell_time).timeout
		if _reload_cancel or current_weapon_id != id:
			break
		ammo += AmmoManager.take(id, 1)
		reserve = AmmoManager.get_reserve(id)
		ammo_changed.emit(ammo, reserve)

	if not _reload_cancel and current_weapon_id == id:
		await get_tree().create_timer(weapon.reload_end).timeout
	if current_weapon_id == id:
		reloading = false

# --- Weapon inventory -----------------------------------------------------
## Drops ADS unconditionally. FOV, zoom level and laser/reticle state are all
## specific to whichever weapon was equipped when ADS turned on, so carrying
## any of it across a change of what's in your hands is wrong in general.
##
## Extracted from _equip() so that bringing a GRENADE to hand goes through
## exactly the same rule as a weapon switch, rather than a parallel copy that
## could drift from it.
func _force_unads() -> void:
	if not ads_active:
		return
	ads_active = false
	_kill_scope_tween()
	camera.fov = HIP_FOV

func _equip(id: String) -> void:
	# Switching to ANY weapon empties the equipment slot — including
	# re-pressing the slot that's already equipped, which is why this runs
	# before the same-weapon early-out below. Silent: the weapon swap is its
	# own feedback, and "stowed" on every 1-5 press would be noise. For a
	# claymore this also cancels placement, because the placer draws nothing
	# unless claymore_equipped.
	if equipment_equipped:
		_set_equipped(Equipment.NONE)
	if weapon and id == current_weapon_id:
		return
	# This is the single choke point every weapon switch passes through.
	_force_unads()
	# Stash the outgoing weapon's loaded magazine before swapping.
	if weapon:
		_mag[current_weapon_id] = ammo
	current_weapon_id = id
	weapon = Arsenal.get_weapon(id)
	ammo = _mag.get(id, effective_mag_size(id))
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
	# radio_menu_open: keys 1-9 are claimed by the radio menu while it's
	# open (it selects a transmission), so the SAME press must not also
	# switch weapons underneath it — a single choke point here covers all
	# five slot keys rather than gating each match-branch individually.
	# painting: swapping weapons mid-paint would leave the painter aiming
	# with a mission whose radius belongs to a call already in progress.
	if painting:
		return
	if not control_enabled or radio_menu_open or index >= Arsenal.order.size():
		return
	if _cooking:
		# Same reason as _toggle_grenade(): you cannot put a burning fuse away
		# by reaching for a rifle.
		message.emit("Fuse is burning — throw it.")
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

# --- Hand grenade ---------------------------------------------------------
## The preview arc is a sibling in world space, not a child transform of the
## player — it draws absolute coordinates and sets top_level itself.
func _build_grenade_arc() -> void:
	var arc := GrenadeArc.new()
	arc.name = "GrenadeArc"
	add_child(arc)
	arc.setup(self, camera)

## G. A slot toggle, not a throw — the throw is LMB/RMB once it's in hand.
func _toggle_grenade() -> void:
	if not control_enabled or _mantling or painting:
		return
	if _cooking:
		# The fuse is burning. Stowing can't defuse it, and silently accepting
		# the input would leave the player holding a live grenade with no way
		# to throw it (the throw lives behind grenade_equipped) — a guaranteed
		# death they never chose. Refusing is the honest answer.
		message.emit("Fuse is burning — throw it.")
		return
	if grenade_equipped:
		_set_equipped(Equipment.NONE)
		return
	# G while a claymore is out puts the claymore away FIRST, so the input is
	# never a no-op: with grenades you switch to them, without you at least
	# cancel the placement. Either way the claymore comes off the slot.
	if grenades <= 0:
		if claymore_equipped:
			_set_equipped(Equipment.NONE)
		message.emit("No grenades.")
		return
	if _ifak_applying:
		_cancel_ifak("switched to grenade")
	_set_equipped(Equipment.GRENADE)

## V. Same slot toggle as G — see _set_equipped().
func _toggle_claymore() -> void:
	if not control_enabled or _mantling or painting:
		return
	if _cooking:
		# Identical reasoning to _toggle_grenade(): a burning fuse cannot be
		# put away, and the throw is only reachable while the grenade is in
		# hand, so accepting this would be a death the player never chose.
		message.emit("Fuse is burning — throw it.")
		return
	if claymore_equipped:
		_set_equipped(Equipment.NONE)
		return
	if claymores <= 0:
		message.emit("No claymores.")
		return
	if _ifak_applying:
		_cancel_ifak("switched to claymore")
	_set_equipped(Equipment.CLAYMORE)

## Thin compatibility wrapper. Every grenade path still calls this; it now
## routes through the shared slot rather than owning a bool of its own.
func _set_grenade_equipped(on: bool) -> void:
	_set_equipped(Equipment.GRENADE if on else Equipment.NONE)

## THE one place the equipment slot changes. Every rule that used to be
## grenade-specific lives here now and applies to anything in the slot.
func _set_equipped(item: int) -> void:
	if equipped_item == item:
		return
	# Backstop for the trap _toggle_grenade(), _toggle_claymore() and
	# _try_equip_slot() each guard at their own entry points: nothing may put a
	# COOKING grenade away, because the throw is only reachable while it is in
	# hand. The three paths that legitimately end a cook (throw / cook-off /
	# death) all clear `_cooking` before calling here, so none are blocked.
	if equipped_item == Equipment.GRENADE and _cooking:
		return
	var was := equipped_item
	equipped_item = item
	if item != Equipment.NONE:
		# Same rule as a weapon switch, through the same function.
		_force_unads()
	if was == Equipment.GRENADE:
		_cook_button = -1
	# Both signals fire on every transition, so a listener watching one of
	# them sees the edge when the OTHER item takes the slot too — switching
	# G -> V has to read as "grenade no longer equipped".
	grenade_equipped_changed.emit(grenade_equipped)
	claymore_equipped_changed.emit(claymore_equipped)

## Routes LMB/RMB while a grenade is in hand. Press starts the cook and
## commits the throw type; only the SAME button's release throws.
func _handle_grenade_mouse(event: InputEventMouseButton) -> void:
	var b: int = event.button_index
	if b != MOUSE_BUTTON_LEFT and b != MOUSE_BUTTON_RIGHT:
		return
	if event.pressed:
		if _cooking:
			return   # throw type is committed at press; the other button is inert
		_cooking = true
		_cook_button = b
		_cook_underhand = (b == MOUSE_BUTTON_RIGHT)
		_cook_remaining = GRENADE_FUSE
	elif _cooking and b == _cook_button:
		_throw_grenade()

## Initial velocity for a throw. THE PREVIEW ARC READS THIS TOO — the arc and
## the projectile cannot disagree about where a grenade goes, because there is
## only one function that decides.
func grenade_launch_velocity(underhand: bool) -> Vector3:
	var speed: float = GRENADE_SPEED_UNDERHAND if underhand else GRENADE_SPEED_OVERHAND
	var pitch: float = GRENADE_PITCH_UNDERHAND_DEG if underhand else GRENADE_PITCH_OVERHAND_DEG
	var dir := -camera.global_transform.basis.z.normalized()
	# Loft the aim vector upward around the camera's own right axis, so the
	# lob arcs above where you're looking rather than in world-space terms.
	var right := camera.global_transform.basis.x.normalized()
	dir = dir.rotated(right, deg_to_rad(pitch)).normalized()
	return dir * speed

## Where a thrown grenade starts. Shared with the preview arc for the same
## reason as the velocity.
func grenade_launch_origin() -> Vector3:
	var fwd := -camera.global_transform.basis.z.normalized()
	return camera.global_position + fwd * GRENADE_SPAWN_FORWARD

## Which trajectory the preview should draw right now: whichever button is
## cooking, or the overhand default when neither is held.
func grenade_preview_underhand() -> bool:
	return _cook_underhand if _cooking else false

func _throw_grenade() -> void:
	# Fuse carries over: flight time is whatever is LEFT after cooking, not a
	# fresh 5s. Cooking is only useful because of this.
	var remaining: float = _cook_remaining
	_cooking = false
	_cook_button = -1
	_cook_remaining = 0.0
	if grenades <= 0:
		return
	grenades -= 1
	grenade_changed.emit(grenades, grenade_max_carry)
	_spawn_grenade(grenade_launch_origin(), grenade_launch_velocity(_cook_underhand), remaining)
	# Out of grenades means empty hands — stow rather than leave the player
	# holding a grenade they don't have.
	if grenades <= 0:
		_set_grenade_equipped(false)

func _spawn_grenade(origin: Vector3, vel: Vector3, fuse: float) -> void:
	var g = GRENADE_SCRIPT.new()
	get_tree().current_scene.add_child(g)
	g.launch(origin, vel, fuse, GRENADE_PROFILE, self)

## Fuse burn while the button is held. Reaching zero in the hand is a real
## detonation at the player's own position — see _cook_off().
func _update_cook(delta: float) -> void:
	if not _cooking:
		return
	_cook_remaining -= delta
	if _cook_remaining <= 0.0:
		_cook_off()

## Cooked too long. Detonates in hand, at the hand — not at the feet — and is
## expected to kill: the frag profile's 110 max damage exceeds the player's
## 100 HP, and the player's own body is excluded from the blast's line-of-
## sight trace, so exposure is 1.0 and nothing softens it.
func _cook_off() -> void:
	_cooking = false
	_cook_button = -1
	_cook_remaining = 0.0
	if grenades > 0:
		grenades -= 1
		grenade_changed.emit(grenades, grenade_max_carry)
	_set_grenade_equipped(false)
	message.emit("Cooked off.")
	AreaDamageSystem.detonate(grenade_launch_origin(), GRENADE_PROFILE, Vector3.ZERO, "cook-off")

## Died mid-cook: the grenade goes off where the body dropped. Deferred and
## position-captured because this is called from _respawn(), which can itself
## be running inside AreaDamageSystem's actor loop — detonating inline would
## re-enter that loop mid-iteration. `_cooking` is cleared first so a chain of
## deaths can't recurse.
func _drop_cooking_grenade() -> void:
	if not _cooking:
		return
	var where := global_position + Vector3(0.0, 0.4, 0.0)
	_cooking = false
	_cook_button = -1
	_cook_remaining = 0.0
	if grenades > 0:
		grenades -= 1
		grenade_changed.emit(grenades, grenade_max_carry)
	_set_grenade_equipped(false)
	_detonate_at.call_deferred(where)

func _detonate_at(where: Vector3) -> void:
	AreaDamageSystem.detonate(where, GRENADE_PROFILE, Vector3.ZERO, "dropped")

# --- Grenade inventory ----------------------------------------------------
## Single grant path for every source — store purchase and resupply drop both
## come through here, so the carry cap can only be enforced in one place.
## Returns how many were ACTUALLY taken; a drop's grenade is lost at the cap
## rather than overflowing it.
func grant_grenades(count: int = 1) -> int:
	var before := grenades
	grenades = mini(grenade_max_carry, grenades + maxi(0, count))
	var taken := grenades - before
	if taken > 0:
		grenade_changed.emit(grenades, grenade_max_carry)
	return taken

func grenades_full() -> bool:
	return grenades >= grenade_max_carry

# --- Claymore inventory ---------------------------------------------------
## Single capped grant path, same shape as grant_grenades(): a store purchase
## and a recovered-from-the-ground claymore both come through here, so the
## carry cap has exactly one enforcement point. Returns how many were ACTUALLY
## taken, so a caller at the cap can react rather than silently losing one.
##
## Deliberately NOT merged with grant_grenades() into a generic
## grant_equipment(kind, n): the two are independent inventories with
## independent caps, and a shared function would need the counter and the max
## passed in anyway — all the sharing would buy is one more indirection
## between a purchase and the field it changes.
func grant_claymores(count: int = 1) -> int:
	var before := claymores
	claymores = mini(claymore_max_carry, claymores + maxi(0, count))
	var taken := claymores - before
	if taken > 0:
		claymore_changed.emit(claymores, claymore_max_carry)
	return taken

func claymores_full() -> bool:
	return claymores >= claymore_max_carry

# --- Claymore emplacement -------------------------------------------------
## The ghost lives in world space (top_level) because it previews a fixture
## that will NOT be parented to the player once committed.
func _build_claymore_placer() -> void:
	_claymore_placer = ClaymorePlacer.new()
	_claymore_placer.name = "ClaymorePlacer"
	_claymore_placer.setup(self, camera, CLAYMORE_CONFIG)
	add_child(_claymore_placer)

## LMB with a claymore in hand. Emplaces at the ghost, if the ghost is legal.
func _try_emplace_claymore() -> void:
	if _claymore_placer == null or claymores <= 0:
		return
	if not _claymore_placer.is_valid():
		message.emit("Can't emplace — %s." % _claymore_placer.reason())
		return

	var c := Claymore.new()
	# Parented to the CURRENT SCENE, not to the player: an emplaced claymore
	# is a fixture, and it must not move, rotate or free with whoever put it
	# there. This is also what makes it survive dawn for free — nothing frees
	# the scene between nights.
	get_tree().current_scene.add_child(c)
	c.global_position = _claymore_placer.ghost_position()
	c.rotation.y = _claymore_placer.ghost_yaw()
	c.setup(CLAYMORE_CONFIG)

	claymores -= 1
	claymore_changed.emit(claymores, claymore_max_carry)
	message.emit("Claymore emplaced (%d left)." % claymores)
	# Stay in placement mode while there is another one to place — emplacing a
	# pair to cover a lane shouldn't need re-equipping between them. Out of
	# stock means empty hands, so drop the slot.
	if claymores <= 0:
		_set_equipped(Equipment.NONE)

# --- Claymore recovery (any time — Day or Night) --------------------------
## Resolves what the player is LOOKING AT and owns the prompt for it.
##
## Centralised here rather than each claymore prompting for itself, because
## HUD.show_prompt() has a single owner: two claymores near each other would
## fight over it and one would strand the other's hide_prompt(). One chooser,
## one owner, no contention.
##
## LOOK-AT-AND-HOLD (playtest fix pass), available at any time — Day or
## Night, no more proximity-only auto-pickup. Polled every physics frame
## rather than event-driven, because "hold for 0.5s" needs a running
## accumulator, not a single press.
func _update_claymore_recovery(delta: float) -> void:
	if not control_enabled:
		_cancel_recovery_hold()
		_clear_recovery_prompt()
		_recovery_target = null
		return

	var target := _find_recovery_target()
	if target != _recovery_target:
		# Aim moved to a different claymore (or off it entirely) — the hold
		# does not carry over to a new target.
		_cancel_recovery_hold()
	_recovery_target = target

	if target == null:
		_clear_recovery_prompt()
		return

	if claymores_full():
		# Blocked BEFORE the hold can start, not discovered after 0.5s of
		# holding — the cap is checked every frame regardless, so this also
		# safely aborts a hold that was already in progress.
		_cancel_recovery_hold()
		_show_recovery_prompt("Claymore — inventory full (%d/%d)" % [claymores, claymore_max_carry])
		return

	if Input.is_action_pressed("interact"):
		if not _recovery_holding:
			_recovery_holding = true
			_recovery_hold_time = 0.0
		_recovery_hold_time += delta
		if _recovery_hold_time >= CLAYMORE_CONFIG.recovery_hold_time:
			_complete_recovery(target)
			return
		var pct: int = int(round(100.0 * _recovery_hold_time / CLAYMORE_CONFIG.recovery_hold_time))
		_show_recovery_prompt("Recovering claymore… %d%%" % pct)
	else:
		# Released early (or never pressed this frame) — cancels with no
		# penalty. Nothing was ever spent, so there is nothing to refund.
		_cancel_recovery_hold()
		_show_recovery_prompt("Hold [E] — Recover Claymore")

func _cancel_recovery_hold() -> void:
	_recovery_holding = false
	_recovery_hold_time = 0.0

## Emitted only on CHANGE. HUD.show_prompt() takes ownership of the single
## prompt slot, and the crate/tent zones re-assert theirs every frame from
## their own _process — pushing ours every frame too would make two
## overlapping interactables flicker against each other instead of the last
## state change simply winning. The hold's own percentage text changes every
## frame while active, so this still updates every frame during a hold —
## the dedupe only ever skips a truly UNCHANGED frame.
func _show_recovery_prompt(text: String) -> void:
	if _prompt_showing and text == _prompt_text:
		return
	_prompt_text = text
	_prompt_showing = true
	prompt.emit(text, self)

func _clear_recovery_prompt() -> void:
	if _prompt_showing:
		_prompt_showing = false
		_prompt_text = ""
		prompt_cleared.emit(self)

## What claymore (if any) the player is currently looking at within
## recovery_range. A short raycast, NOT a scan of every placed claymore —
## this is the fix for the earlier implementation's per-frame linear scan of
## the whole "claymores" group, which would have degraded with the unbounded
## placed count Phase 2b explicitly allows. A raycast query is O(1) with
## respect to how many claymores exist in the world; only the ONE the player
## is actually looking at is ever touched.
##
## World geometry (layer 1) shares the query mask with the claymore's own
## interaction layer, so a wall between the player and the mine correctly
## blocks recovery — the ray hits the wall first and "claymore" meta lookup
## on a wall collider is simply absent.
func _find_recovery_target() -> Claymore:
	var space := get_world_3d().direct_space_state
	var from := camera.global_position
	var dir := -camera.global_transform.basis.z.normalized()
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * CLAYMORE_CONFIG.recovery_range)
	q.collision_mask = 1 | Obstacle.INTERACT_LAYER
	q.collide_with_areas = true
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return null
	var col = hit.collider
	if col == null:
		return null
	var c = col.get_meta("claymore", null)
	if c == null or not is_instance_valid(c) or not c.can_recover():
		return null
	return c

## No partial refund, no points — you get the claymore back. Emits a 3m
## noise event AT COMPLETION (not at hold-start): browsing/holding is silent,
## committing is what costs you, same convention the radio's transmission
## noise will use.
func _complete_recovery(target: Claymore) -> void:
	# Same capped grant path a store purchase uses.
	grant_claymores(1)
	target.queue_free()
	_recovery_target = null
	_cancel_recovery_hold()
	_clear_recovery_prompt()
	NoiseManager.emit_noise(global_position, CLAYMORE_CONFIG.recovery_noise_radius)
	message.emit("Claymore recovered (%d/%d)." % [claymores, claymore_max_carry])

# --- Laser (beam + terminal dot) -----------------------------------------
func _build_laser() -> void:
	# Beam: a unit-height cylinder scaled to the hit distance each frame.
	_laser_beam = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.radial_segments = 12
	cyl.rings = 0
	# No end caps: a low-segment cap viewed face-on is exactly the bright
	# polygon artefact this beam must never produce.
	cyl.cap_top = false
	cyl.cap_bottom = false
	_laser_beam_mesh = cyl
	_laser_beam.mesh = cyl
	_laser_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_laser_beam.top_level = true
	_laser_beam_mat = _laser_material()
	_laser_beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_laser_beam.material_override = _laser_beam_mat
	_laser_beam.visible = false
	add_child(_laser_beam)

	# Separate material for the no-hit case: same colour, but alpha ramps out
	# along the beam so it reads as fading into the dark.
	_laser_fade_mat = _laser_material()
	_laser_fade_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_laser_fade_mat.albedo_texture = _length_fade_texture()

	# Dot: a bright core plus a soft falloff halo. Both are BILLBOARDED and
	# additively blended so they read as scattered glow rather than a flat
	# disc — and, critically, a billboard can't be back-face culled or vanish
	# at grazing angles the way a surface-aligned quad does.
	_laser_dot = Node3D.new()
	_laser_dot.top_level = true
	_laser_dot.visible = false
	add_child(_laser_dot)

	_laser_halo = MeshInstance3D.new()
	var hquad := QuadMesh.new()
	hquad.size = Vector2.ONE
	_laser_halo.mesh = hquad
	_laser_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_laser_halo_mat = _glow_material(_radial_falloff_texture(dot_halo_falloff))
	_laser_halo.material_override = _laser_halo_mat
	_laser_dot.add_child(_laser_halo)

	_laser_core = MeshInstance3D.new()
	var cquad := QuadMesh.new()
	cquad.size = Vector2.ONE
	_laser_core.mesh = cquad
	_laser_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_laser_dot_mat = _glow_material(_radial_falloff_texture(0.9))
	_laser_core.material_override = _laser_dot_mat
	_laser_dot.add_child(_laser_core)

## Vertical white->transparent ramp used to fade the far end of a no-hit beam.
func _length_fade_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_offset(0, 0.0)
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_offset(1, 1.0)
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.45, Color(1, 1, 1, 0.55))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_LINEAR
	t.fill_from = Vector2(0.5, 0.0)
	t.fill_to = Vector2(0.5, 1.0)
	t.width = 8
	t.height = 64
	return t

## Radial white->transparent texture. `falloff` shapes the edge: higher values
## keep the centre solid longer and fade out more gradually.
func _radial_falloff_texture(falloff: float) -> GradientTexture2D:
	var g := Gradient.new()
	g.set_offset(0, 0.0)
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_offset(1, 1.0)
	g.set_color(1, Color(1, 1, 1, 0))
	# Extra midpoint so the falloff curves instead of ramping linearly.
	var mid: float = clampf(1.0 / maxf(1.0, falloff), 0.05, 0.95)
	g.add_point(mid, Color(1, 1, 1, 0.45))

	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	return t

## Additive, unshaded, billboarded — blooms naturally under the NVG glow pass.
func _glow_material(tex: Texture2D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_receive_shadows = true
	m.no_depth_test = false
	m.albedo_texture = tex
	m.emission_enabled = true
	return m

func _laser_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.emission_enabled = true
	m.disable_receive_shadows = true
	return m

## IR Laser is a per-weapon attachment (same shape as _suppressed), bought
## individually for each weapon — the M17, HK416, SPAS-12 and SAW each need
## their own purchase. Defaults to the currently equipped weapon so the
## laser-rendering call sites below don't need to change.
func attach_ir_laser(weapon_id: String) -> void:
	_has_ir_laser[weapon_id] = true
	message.emit("IR Laser fitted.")

func has_ir_laser(weapon_id: String = "") -> bool:
	var id := weapon_id if weapon_id != "" else current_weapon_id
	return _has_ir_laser.get(id, false)

## One-line laser telemetry for the debug overlay: hit true/false, hit
## distance, beam length and the computed radii.
func laser_debug_line() -> String:
	return _laser_dbg

## Red is always visible; IR renders only under NVGs (invisible to the naked
## eye, and invisible to zombies — see _update_laser_detection). The M110
## never draws either — see _update_laser().
func _laser_should_draw() -> bool:
	if current_weapon_id == "m110":
		return false
	if not ads_active:
		return false
	return nvg_active if has_ir_laser() else true

## The M110 has no laser, full stop — ADS brings up a scope reticle (HUD-only,
## no gameplay effect) instead. Returning before the raycast/build work below
## means it's fully skipped for this weapon, not just hidden.
func _update_laser() -> void:
	if current_weapon_id == "m110":
		_laser_beam.visible = false
		_laser_dot.visible = false
		_laser_dbg = "laser: n/a (M110 — optic reticle only)"
		return
	if not _laser_should_draw():
		_laser_beam.visible = false
		_laser_dot.visible = false
		_laser_dbg = "laser: off (not aiming)" if not ads_active else "laser: IR hidden (no NVG)"
		return

	var ir := has_ir_laser()
	var color := Color(0.6, 1.0, 0.6) if ir else Color(1.0, 0.05, 0.05)
	var beam_r: float = laser_ir_beam_radius if ir else laser_red_beam_radius
	var beam_a: float = laser_ir_beam_alpha if ir else laser_red_beam_alpha
	var emission: float = laser_ir_emission if ir else laser_red_emission
	var dot_size: float = laser_ir_dot_size if ir else laser_red_dot_size

	_laser_beam_mat.albedo_color = Color(color.r, color.g, color.b, beam_a)
	_laser_beam_mat.emission = color
	_laser_beam_mat.emission_energy_multiplier = emission
	_laser_dot_mat.albedo_color = Color(color.r, color.g, color.b, 1.0)
	_laser_dot_mat.emission = color
	_laser_dot_mat.emission_energy_multiplier = emission
	_laser_halo_mat.albedo_color = Color(color.r, color.g, color.b, dot_halo_alpha)
	_laser_halo_mat.emission = color
	_laser_halo_mat.emission_energy_multiplier = emission * 0.6

	# The RAY comes from the camera (so it matches point of aim); the BEAM is
	# drawn from the muzzle to that hit point. The resulting offset — large up
	# close, converging at distance — is correct for a weapon-mounted laser.
	var from := _muzzle_position()
	laser_ray.force_raycast_update()
	var hit_point: Vector3
	var normal := Vector3.UP
	var hit_something := laser_ray.is_colliding()
	if hit_something:
		hit_point = laser_ray.get_collision_point()
		normal = laser_ray.get_collision_normal()
	else:
		# Nothing in range: draw to the max-range point along the ray.
		hit_point = laser_ray.global_position + \
			(-laser_ray.global_transform.basis.z) * LASER_MAX_DRAW

	var seg := hit_point - from
	var length := seg.length()
	# Guard rail: nothing legitimate produces a beam this short, and a very
	# short beam with a scaled radius is exactly the disc/hexagon failure.
	if length < beam_min_length:
		_laser_beam.visible = false
		_laser_dot.visible = false
		_laser_dbg = "laser: hit=%s len=%.2f (SUPPRESSED: below min length)" % [
			hit_something, length]
		return

	var eye := camera.global_position
	var screen_k := 2.0 * tan(deg_to_rad(camera.fov) * 0.5)

	# TAPERED radius: each end is sized for its own distance from the camera,
	# so apparent thickness stays roughly constant along the beam instead of
	# one uniform radius that's fat at the muzzle and thin at the far end.
	var near_r := beam_r
	var far_r := beam_r
	if hit_something:
		near_r = maxf(beam_r, beam_min_screen_frac * eye.distance_to(from) * screen_k)
		far_r = maxf(beam_r, beam_min_screen_frac * eye.distance_to(hit_point) * screen_k)
	# No hit: base radius at both ends (there's no surface to scale against),
	# and the fade material ramps alpha out toward the far end.
	_laser_beam.material_override = _laser_beam_mat if hit_something else _laser_fade_mat
	if not hit_something:
		_laser_fade_mat.albedo_color = Color(color.r, color.g, color.b, beam_a)
		_laser_fade_mat.emission = color
		_laser_fade_mat.emission_energy_multiplier = emission
		var fade_dir: float = -1.0 if beam_fade_flip else 1.0
		_laser_fade_mat.uv1_scale = Vector3(1.0, fade_dir, 1.0)

	_laser_beam_mesh.bottom_radius = near_r   # -Y end = muzzle
	_laser_beam_mesh.top_radius = far_r       # +Y end = hit point

	# Orient the cylinder so its local +Y runs muzzle -> hit point.
	_laser_beam.global_position = from + seg * 0.5
	var up_ref := Vector3.UP
	if absf(seg.normalized().dot(Vector3.UP)) > 0.99:
		up_ref = Vector3.RIGHT
	_laser_beam.look_at(hit_point, up_ref)
	_laser_beam.rotate_object_local(Vector3.RIGHT, -PI * 0.5)
	# Radii live on the mesh, so only length is scaled here.
	_laser_beam.scale = Vector3(1.0, length, 1.0)
	_laser_beam.visible = true

	# Dot: only where the beam actually terminates on a surface. No hit = no
	# dot at all, rather than one drawn at some arbitrary far point.
	if hit_something:
		var dot_dist := eye.distance_to(hit_point)
		# Floor keeps it visible at 85m; ceiling stops it obscuring the target.
		var min_world := dot_min_screen_frac * dot_dist * screen_k
		var max_world := dot_max_screen_frac * dot_dist * screen_k
		var core_size: float = clampf(dot_size, min_world, max_world)
		_laser_dot.global_position = hit_point + normal * 0.02
		_laser_core.scale = Vector3(core_size, core_size, 1.0)
		_laser_halo.scale = Vector3(core_size * dot_halo_scale, core_size * dot_halo_scale, 1.0)
		_laser_dot.visible = true
		_laser_dbg = "laser: hit=true dist=%.1fm len=%.1fm r=%.3f/%.3f dot=%.3f" % [
			dot_dist, length, near_r, far_r, core_size]
	else:
		_laser_dot.visible = false
		_laser_dbg = "laser: hit=false len=%.1fm r=%.3f (no dot)" % [length, beam_r]

# --- Tracer ---------------------------------------------------------------
## The true muzzle, taken from the Muzzle marker on the viewmodel. Because the
## marker is a child of the viewmodel it inherits the ADS pose, the recoil kick
## and any bob for free — the origin stays welded to the weapon.
func _muzzle_position() -> Vector3:
	if _muzzle_marker:
		return _muzzle_marker.global_position
	return camera.global_position   # pre-_ready fallback

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
	_recoil_h = lerpf(_recoil_h, 0.0, delta * RECOIL_RECOVER)
	_shake_trauma = maxf(0.0, _shake_trauma - SHAKE_DECAY * delta)

	# The auto ramp clears after a short pause in fire.
	_auto_idle += delta
	if weapon and _auto_idle > weapon.auto_reset_time:
		_auto_shots = 0

	# Camera-local shake + recoil (independent of head mouse-look and ADS fov).
	var shake := _shake_trauma * _shake_trauma
	camera.rotation = Vector3(
		-_recoil + randf_range(-1.0, 1.0) * shake * MAX_SHAKE_ROT,
		_recoil_h + randf_range(-1.0, 1.0) * shake * MAX_SHAKE_ROT,
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

	# Muzzle marker: the authoritative origin for the laser beam and tracers.
	# As a child of the viewmodel it inherits the ADS pose, recoil and bob, so
	# the beam stays welded to the weapon in every state.
	_muzzle_marker = Marker3D.new()
	_muzzle_marker.name = "Muzzle"
	_muzzle_marker.position = Vector3(0, 0.005, -0.17)
	_viewmodel.add_child(_muzzle_marker)

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

## Two audio states per weapon, driven by the suppressor attachment but kept
## COMPLETELY SEPARATE from the noise-radius logic (40m -> 8m). One attachment
## drives two independent systems.
##
## The suppressed report is the same sample routed through a dedicated bus with
## a low-pass + shortened tail, and the mechanical action (slide/bolt) mixed up
## so it reads as "mostly action noise" — placeholder until real recordings.
const BUS_SUPPRESSED := "Suppressed"

func _build_audio() -> void:
	_ensure_suppressed_bus()
	_sfx_fire = _make_sfx(SFX_GUNSHOT, -6.0)
	_sfx_fire_supp = _make_sfx(SFX_GUNSHOT, -19.0)
	_sfx_fire_supp.bus = BUS_SUPPRESSED
	_sfx_fire_supp.pitch_scale = 1.25   # shorter, snappier tail
	# Mechanical action, more prominent in the suppressed mix.
	_sfx_action = _make_sfx(SFX_IMPACT, -8.0)
	_sfx_action.pitch_scale = 1.9
	_sfx_hurt = _make_sfx(SFX_HURT, 0.0)
	_sfx_impact = _make_sfx(SFX_IMPACT, -3.0)

## Creates the "Suppressed" bus (low-pass + damped) at runtime if the project
## doesn't already define one, so no .tscn/bus-layout authoring is required.
func _ensure_suppressed_bus() -> void:
	if AudioServer.get_bus_index(BUS_SUPPRESSED) != -1:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, BUS_SUPPRESSED)
	AudioServer.set_bus_send(idx, "Master")

	var lp := AudioEffectLowPassFilter.new()
	lp.cutoff_hz = 900.0        # muffled
	lp.resonance = 0.2
	AudioServer.add_bus_effect(idx, lp)

	# Tighten the tail so it stops abruptly instead of ringing out.
	var comp := AudioEffectCompressor.new()
	comp.threshold = -22.0
	comp.ratio = 8.0
	comp.attack_us = 20.0
	comp.release_ms = 60.0
	AudioServer.add_bus_effect(idx, comp)

func _make_sfx(path: String, volume_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	if ResourceLoader.exists(path):
		var res = load(path)  # untyped: avoids a Resource->AudioStream downcast error
		p.stream = res
	p.volume_db = volume_db
	add_child(p)
	return p

# --- Damage / life --------------------------------------------------------
## Uniform blast entry point (AreaDamageSystem convention). The player is in
## the `damageable` group like everything else — a blast has no idea who threw
## it, so your own grenade at your own feet will kill you.
func take_area_damage(amount: int, origin: Vector3) -> void:
	take_damage(amount, origin)

## AreaDamageSystem's optional liveness convention, same as Zombie.is_alive().
##
## Without this the player was silently absent from every blast's `killed`
## tally: _apply_once() guards on has_method("is_alive"), so killing yourself
## with your own grenade reported 0 kills.
##
## `hp > 0` would NOT have worked. The player has no persistent dead state —
## take_damage() calls _respawn() synchronously at 0 HP, which restores full
## HP before take_area_damage() even returns — so a naive HP test reads true
## both before and after the killing blow and still never counts. Hence the
## latch below: _respawn() sets it, and it clears deferred, i.e. after every
## same-frame consumer (the blast loop is synchronous) has sampled it.
func is_alive() -> bool:
	return not _died_this_frame

## Line-of-sight sample points for a blast: feet / chest / head. Uses the live
## head height so crouching behind sandbags genuinely reduces exposure.
func area_damage_points() -> Array:
	var head_y: float = head.position.y
	return [
		global_position + Vector3(0.0, 0.2, 0.0),
		global_position + Vector3(0.0, head_y * 0.55, 0.0),
		global_position + Vector3(0.0, head_y, 0.0),
	]

func take_damage(amount: int, source_pos = null) -> void:
	hp = maxi(0, hp - amount)
	health_changed.emit(hp, MAX_HP)
	add_shake(HURT_SHAKE)
	# Direction the hit came from, in the player's own frame.
	var ang := 0.0
	if source_pos != null:
		var local: Vector3 = global_transform.basis.inverse() * ((source_pos as Vector3) - global_position)
		ang = atan2(local.x, -local.z)
	damaged.emit(ang)
	if _sfx_hurt.stream:
		_sfx_hurt.play()
	if hp <= 0:
		_respawn()

func _respawn() -> void:
	# One-frame death latch for is_alive() — see its docstring. Set before
	# anything else so a same-frame observer (AreaDamageSystem's kill tally)
	# sees the death that the immediate HP restore below would otherwise hide.
	_died_this_frame = true
	_clear_death_latch.call_deferred()
	# A grenade cooking in a dead hand goes off where the body dropped —
	# before the respawn teleport below moves the player away from it.
	_drop_cooking_grenade()
	# Dying with the store open must not soft-lock: force it shut (which
	# restores control and mouse capture) before the normal death flow.
	died_while_busy.emit()
	_cancel_ifak("died")
	message.emit("You died — respawning at base. Ammo is NOT replenished.")
	hp = MAX_HP
	# Ammo deliberately does NOT regenerate — not on death, not at dawn.
	global_position = _spawn_point
	velocity = Vector3.ZERO
	health_changed.emit(hp, MAX_HP)

func _clear_death_latch() -> void:
	_died_this_frame = false

# --- Attachment pipeline --------------------------------------------------
## Fit a suppressor to a specific weapon (defaults to the equipped one).
func attach_suppressor(weapon_id: String = "") -> void:
	var id := weapon_id if weapon_id != "" else current_weapon_id
	_suppressed[id] = true
	var w := Arsenal.get_weapon(id)
	if id == current_weapon_id:
		suppressor_changed.emit(true)
	message.emit("Suppressor fitted to %s — now %dm." % [
		w.display_name, int(w.noise_suppressed)])

func has_suppressor() -> bool:
	return _suppressed.get(current_weapon_id, false)

func weapon_suppressed(weapon_id: String) -> bool:
	return _suppressed.get(weapon_id, false)

## HK 416 Foregrip — tightens the moving-fire cone (see _fire()).
func attach_foregrip(weapon_id: String) -> void:
	_has_foregrip[weapon_id] = true
	message.emit("Foregrip fitted.")

func has_foregrip(weapon_id: String) -> bool:
	return _has_foregrip.get(weapon_id, false)

## SPAS-12 Breacher Choke — widens the hip-fire pellet spread (see _fire()).
func attach_choke(weapon_id: String) -> void:
	_has_choke[weapon_id] = true
	message.emit("Breacher Choke fitted.")

func has_choke(weapon_id: String) -> bool:
	return _has_choke.get(weapon_id, false)

## M249 Extended Drum — 200-round belt, -10% sprint while fitted.
func attach_drum(weapon_id: String) -> void:
	_has_drum[weapon_id] = true
	message.emit("Extended Drum fitted — 200-round belt.")

func has_drum(weapon_id: String) -> bool:
	return _has_drum.get(weapon_id, false)

## Effective magazine/belt capacity for a weapon, accounting for the Drum.
func effective_mag_size(weapon_id: String) -> int:
	var w := Arsenal.get_weapon(weapon_id)
	if w == null:
		return 0
	if has_drum(weapon_id):
		return w.mag_size * 2
	return w.mag_size

## Ammo purchases scale with the equipped belt/mag capacity, so a drum-fitted
## SAW resupplies to a full 200-round drum rather than a bare 100-round belt.
## Same per-round price either way. Still routes through AmmoManager.grant_ammo
## — this only decides HOW MANY magazines that call passes.
func ammo_purchase_magazines(weapon_id: String) -> int:
	return 2 if has_drum(weapon_id) else 1

func ammo_purchase_cost(weapon_id: String) -> int:
	var w := Arsenal.get_weapon(weapon_id)
	if w == null:
		return 0
	return w.ammo_cost * ammo_purchase_magazines(weapon_id)

## M110 Variable Zoom Optic — replaces the fixed 3x with adjustable 2x-8x.
func attach_variable_zoom(weapon_id: String) -> void:
	_has_variable_zoom[weapon_id] = true
	message.emit("Variable Zoom Optic fitted — scroll while ADS to adjust.")

func has_variable_zoom(weapon_id: String) -> bool:
	return _has_variable_zoom.get(weapon_id, false)

# --- Jump & mantle --------------------------------------------------------
## Space is a single contextual button: if a mantleable ledge is in front of
## you it mantles, otherwise it jumps. Chosen over a separate bind because a
## dedicated mantle key is one more thing to remember mid-fight, and over
## "auto-mantle on jump collision" because that fires accidentally every time
## you jump beside cover.
func _try_jump_or_mantle() -> void:
	if _mantling or not control_enabled:
		return
	# A ledge in front wins over a plain jump, but only while holding forward
	# into it — otherwise standing beside a wall would never let you jump.
	if Input.is_physical_key_pressed(KEY_W):
		var target := _find_mantle_target()
		if not target.is_empty():
			_begin_mantle(target)
			return
	if is_crouching:
		message.emit("Can't jump while crouched.")
		return
	if not is_on_floor():
		return
	velocity.y = sqrt(2.0 * gravity * jump_height)   # v = sqrt(2gh)
	_jumping = true

## Three-stage probe: forward at chest height to find a face, down past its top
## edge to find the ledge surface, then a capsule sweep to confirm we'd fit.
func _find_mantle_target() -> Dictionary:
	var space := get_world_3d().direct_space_state
	var fwd := -global_transform.basis.z
	var chest := global_position + Vector3(0, MANTLE_CHEST_Y, 0)

	# World + the ditch revetment (so it can be climbed out of), but NOT the
	# player-barrier layer — wire must never be a mantle target.
	var q1 := PhysicsRayQueryParameters3D.create(chest, chest + fwd * mantle_reach)
	q1.collision_mask = 1 | Obstacle.SOLID_NO_NAV_LAYER
	q1.exclude = [get_rid()]
	var face := space.intersect_ray(q1)
	if not face:
		return {}
	# Must be a roughly vertical face, not a floor or ceiling.
	var face_normal: Vector3 = face.normal
	if absf(face_normal.dot(Vector3.UP)) > 0.4:
		return {}

	# Probe straight down from above, just past the face.
	var face_pos: Vector3 = face.position
	var probe: Vector3 = face_pos + fwd * MANTLE_LEDGE_STEP
	probe.y = global_position.y + mantle_max_height + 0.35
	var q2 := PhysicsRayQueryParameters3D.create(
		probe, probe + Vector3(0, -(mantle_max_height + 0.7), 0))
	q2.collision_mask = 1 | Obstacle.SOLID_NO_NAV_LAYER
	q2.exclude = [get_rid()]
	var ledge := space.intersect_ray(q2)
	if not ledge:
		return {}
	# The top must be standable, not a slope.
	var ledge_normal: Vector3 = ledge.normal
	if ledge_normal.dot(Vector3.UP) < 0.7:
		return {}

	var ledge_pos: Vector3 = ledge.position
	var dest: Vector3 = ledge_pos + Vector3(0, 0.05, 0)
	var height: float = dest.y - global_position.y
	if height < MANTLE_MIN_HEIGHT or height > mantle_max_height:
		return {}
	if _capsule_blocked(space, dest):
		return {}
	return {"dest": dest, "height": height}

## Would the player capsule fit standing at `foot_pos`?
func _capsule_blocked(space: PhysicsDirectSpaceState3D, foot_pos: Vector3) -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35          # slightly under the real 0.4 for tolerance
	shape.height = 1.7
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, foot_pos + Vector3(0, 0.9, 0))
	# The surface probes deliberately mask layer 1 only, so wire can never be
	# a mantle TARGET. The destination check adds the barrier layer so a
	# mantle over something else can never drop us INSIDE wire either.
	params.collision_mask = 1 | Obstacle.PLAYER_BARRIER_LAYER | Obstacle.SOLID_NO_NAV_LAYER
	params.exclude = [get_rid()]
	return space.intersect_shape(params, 1).size() > 0

func _begin_mantle(target: Dictionary) -> void:
	_mantling = true
	_jumping = false
	_mantle_t = 0.0
	_mantle_from = global_position
	_mantle_to = target["dest"]
	# Taller ledges take longer: ~0.4s at 1m, ~0.9s at 2m. A full-height
	# mantle is meant to feel like a commitment.
	var h: float = target["height"]
	_mantle_dur = clampf(0.4 + (h - 1.0) * 0.5, 0.25, 1.2)
	# Aiming is dropped for the duration; firing/ADS are blocked while mantling.
	ads_active = false
	camera.fov = 75.0
	velocity = Vector3.ZERO

## Locked interpolation — no steering, no gravity, no shooting.
func _update_mantle(delta: float) -> void:
	_mantle_t += delta
	var t: float = clampf(_mantle_t / _mantle_dur, 0.0, 1.0)
	var eased: float = t * t * (3.0 - 2.0 * t)      # smoothstep
	var pos: Vector3 = _mantle_from.lerp(_mantle_to, eased)
	# Rise faster than we move forward so we clear the lip rather than
	# clipping through the face.
	pos.y = lerpf(_mantle_from.y, _mantle_to.y, clampf(t * 1.5, 0.0, 1.0))
	global_position = pos
	velocity = Vector3.ZERO
	if t >= 1.0:
		_mantling = false
		global_position = _mantle_to
		NoiseManager.emit_noise(global_position, mantle_noise_radius)

func is_mantling() -> bool:
	return _mantling

# --- IFAK -----------------------------------------------------------------
func add_ifak(count: int = 1) -> bool:
	if ifaks >= ifak_max_carry:
		return false
	ifaks = mini(ifak_max_carry, ifaks + count)
	ifak_changed.emit(ifaks, ifak_max_carry)
	return true

func ifak_full() -> bool:
	return ifaks >= ifak_max_carry

func _start_ifak() -> void:
	if _ifak_applying or ifaks <= 0:
		return
	# Blocked at full health rather than silently wasting the IFAK — a
	# consumable this scarce should never be spent for nothing.
	if hp >= MAX_HP:
		message.emit("Already at full health.")
		return
	_ifak_applying = true
	_ifak_timer = 0.0
	# Aiming is dropped for the duration; firing/ADS are blocked while applying.
	ads_active = false
	camera.fov = 75.0
	message.emit("Applying IFAK…")
	ifak_progress.emit(true, 0.0)

## Cancels without consuming — the IFAK is only spent on a completed application.
func _cancel_ifak(reason: String) -> void:
	if not _ifak_applying:
		return
	_ifak_applying = false
	_ifak_timer = 0.0
	ifak_progress.emit(false, 0.0)
	message.emit("IFAK cancelled (%s)." % reason)

func _update_ifak(delta: float) -> void:
	if not _ifak_applying:
		return
	# Sprinting cancels the application.
	if move_state == MoveState.SPRINT:
		_cancel_ifak("sprinting")
		return
	_ifak_timer += delta
	ifak_progress.emit(true, clampf(_ifak_timer / ifak_apply_time, 0.0, 1.0))
	if _ifak_timer >= ifak_apply_time:
		_ifak_applying = false
		ifaks -= 1
		hp = mini(MAX_HP, hp + ifak_heal)   # no overheal
		ifaks = maxi(0, ifaks)
		ifak_changed.emit(ifaks, ifak_max_carry)
		health_changed.emit(hp, MAX_HP)
		ifak_progress.emit(false, 0.0)
		message.emit("IFAK applied — %d HP." % hp)

# --- Store purchase API ---------------------------------------------------
## Owned check for any catalog item. Ammo is always repurchasable.
func owns_store_item(item) -> bool:
	match item.kind:
		"weapon":
			return item.weapon_id in owned
		"attachment":
			if item.weapon_id != "":
				match item.attachment_type:
					"foregrip": return has_foregrip(item.weapon_id)
					"choke": return has_choke(item.weapon_id)
					"drum": return has_drum(item.weapon_id)
					"zoom": return has_variable_zoom(item.weapon_id)
					"ir_laser": return has_ir_laser(item.weapon_id)
					_: return weapon_suppressed(item.weapon_id)   # "suppressor" (and legacy "")
			return item.id in owned_items
		_:
			return false

## Applies a purchased item's effect. Returns a short status line for the UI.
func apply_store_purchase(item) -> String:
	match item.kind:
		"weapon":
			acquire_weapon(item.weapon_id)
			return "%s acquired & equipped." % item.display_name
		"ammo":
			# All ammo grants route through AmmoManager; the drum is the only
			# thing that changes how many magazines a purchase is worth.
			var mags := ammo_purchase_magazines(item.weapon_id)
			var rounds: int = AmmoManager.grant_ammo(item.weapon_id, mags)
			return "+%d rounds of %s." % [rounds, item.display_name]
		"attachment":
			if item.weapon_id != "":
				match item.attachment_type:
					"foregrip":
						attach_foregrip(item.weapon_id)
						return "Foregrip fitted to %s." % item.display_name
					"choke":
						attach_choke(item.weapon_id)
						return "Breacher Choke fitted to %s." % Arsenal.get_weapon(item.weapon_id).display_name
					"drum":
						attach_drum(item.weapon_id)
						return "Extended Drum fitted — 200-round belt."
					"zoom":
						attach_variable_zoom(item.weapon_id)
						return "Variable Zoom Optic fitted — 2x-8x, scroll while ADS."
					"ir_laser":
						attach_ir_laser(item.weapon_id)
						return "IR Laser fitted to %s." % Arsenal.get_weapon(item.weapon_id).display_name
					_:
						attach_suppressor(item.weapon_id)
						return "Suppressor fitted to %s." % Arsenal.get_weapon(item.weapon_id).display_name
			owned_items.append(item.id)
			return "%s acquired." % item.display_name
		"consumable":
			if item.id == "ifak":
				add_ifak(1)
				return "IFAK stowed (%d/%d)." % [ifaks, ifak_max_carry]
		"equipment":
			if item.id == "grenade":
				# Same capped grant path a resupply drop uses — the cap can
				# only ever be enforced in one place.
				grant_grenades(1)
				return "Grenade stowed (%d/%d)." % [grenades, grenade_max_carry]
			if item.id == "claymore":
				# Same capped grant path Day-phase recovery uses.
				grant_claymores(1)
				return "Claymore stowed (%d/%d)." % [claymores, claymore_max_carry]
	return ""

## Repeatable items are never "owned", but a full pouch blocks further
## purchase. Carry caps deliberately stay per-item rather than generic: each
## one reads a different counter against a different maximum, and collapsing
## them behind a shared interface would hide which field a cap belongs to.
func store_item_blocked(item) -> String:
	# Generic and data-driven: any catalog entry can set day_only and this
	# needs no new branch. The crate itself is open at night on purpose (see
	# SupplyCrateZone) — the restriction belongs to the item, not the store.
	if item.day_only and not GameManager.is_day():
		return "DAY ONLY"
	# Carry caps, by contrast, are NOT generic — each is a different counter
	# on a different field. See the note on apply_store_purchase().
	if item.kind == "consumable" and item.id == "ifak" and ifak_full():
		return "CARRYING %d/%d" % [ifaks, ifak_max_carry]
	if item.kind == "equipment" and item.id == "grenade" and grenades_full():
		return "CARRYING %d/%d" % [grenades, grenade_max_carry]
	if item.kind == "equipment" and item.id == "claymore" and claymores_full():
		return "CARRYING %d/%d" % [claymores, claymore_max_carry]
	return ""

## Prerequisite satisfied? Prereqs may name a weapon id or a non-weapon item id.
func owns_item_id(id: String) -> bool:
	return id in owned or id in owned_items

# --- Helpers --------------------------------------------------------------
func set_control_enabled(enabled: bool) -> void:
	control_enabled = enabled
	if not enabled:
		velocity.x = 0.0
		velocity.z = 0.0

## Called by RadioMenu on open/close. Deliberately distinct from
## set_control_enabled() above — the crate/build-mode path stops movement
## entirely, but the radio menu must not (the game keeps running while it's
## open). This only touches mouse-look and the RMB debounce.
func set_radio_menu_open(open: bool) -> void:
	radio_menu_open = open
	if not open:
		# The menu closes on T, a different key from RMB, so this rarely has
		# anything to catch — kept as the same conservative guard set_painting()
		# uses below, in case RMB happens to be down at the instant T closes
		# the menu. Release-gated, not a fixed delay, so it can never leave a
		# stale window where a LATER unrelated click gets eaten.
		_ads_suppressed_until_release = true

## Called by TargetPainter on entering/leaving paint mode.
##
## Deliberately does NOT suppress mouse-look, unlike set_radio_menu_open()
## above: painting IS aiming, so the camera has to keep working. Movement is
## untouched too — the game doesn't pause and the player stays vulnerable.
##
## What it does suppress is everything that would otherwise fire on the same
## clicks the painter is claiming: weapon fire, ADS, and the equipment
## toggles. The painter marks its own events handled as well, but that alone
## only protects against events, not against the polled full-auto path in
## _physics_process — hence a state flag rather than relying on input
## consumption.
func set_painting(on: bool) -> void:
	painting = on
	if on:
		# Same rule as a weapon switch or bringing a grenade to hand: you
		# cannot be looking down a scope while calling in a fire mission.
		_force_unads()
	else:
		# Release-gated, matching the radio menu's own debounce: the LMB
		# press that CONFIRMED a paint must not also register as a shot the
		# instant paint mode ends.
		_ads_suppressed_until_release = true
		_fire_suppressed_until_release = true

func _set_mouse_captured(captured: bool) -> void:
	mouse_captured = captured
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE

func _state_label() -> String:
	match move_state:
		MoveState.CROUCH: return "CROUCH (silent)"
		MoveState.SPRINT: return "SPRINT (15m)"
		_: return "WALK (5m)"
