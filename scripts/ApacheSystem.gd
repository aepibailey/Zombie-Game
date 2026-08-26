extends Node
class_name ApacheSystem
## AH-64 Apache patrol box: call flow, box designation, and the sortie's
## lifecycle. Registers itself into EnablerManager.callable_enablers like
## every other enabler.
##
## OWNS NO PAINTING, DAMAGE OR NOISE CODE. Designation is the shared
## TargetPainter; each burst is one AreaDamageSystem.detonate() with an
## authored profile. Nothing here writes damage numbers or emits noise.
##
## THE STANDOFF CONSTRAINT, ENFORCED STRUCTURALLY RATHER THAN BY DISCIPLINE.
## A real Apache services targets from kilometres out with an optical sensor
## and a stabilized gun; it does not overfly the target area. So the aircraft's
## POSITION MUST NEVER GATE A SHOT. That is not left to care and code review:
## the acquisition function below takes only (box centre, box radius, player
## position) and never receives the airframe or its transform, so a
## distance-to-aircraft check is not expressible inside it. The orbit is
## written by the Apache actor's own _process and is read by nothing.

const APACHE_ID := "apache"
## The mortar profile, loaded ONLY to assert the Apache stays weaker per
## event. Read rather than copied, so retuning the mortar can't silently
## invert the attrition/alpha relationship the two are built around.
const MORTAR_PROFILE: AreaDamageProfile = preload("res://resources/mortar_he.tres")
## The mortar MISSION, loaded only to assert the Apache is priced above it.
## Read rather than copied for the same reason as the profile above.
const MORTAR_MISSION: FireMissionConfig = preload("res://resources/mission_mortar.tres")

@export var config: ApacheConfig

var _player: Player
var _hud: HUD
var _radio: RadioMenu
var _painter: TargetPainter

## The registered menu Dictionary. Held as a reference so the entry can be
## rewritten in place for retasking — RadioMenu re-reads the same instance on
## every refresh, so swapping display_name/cost/call_fn needs no menu-side
## change. (Phase 5.)
var _entry: Dictionary

## The live sortie, or null. Exactly one Apache exists at a time; this is the
## first line of defence and Apache.spawn() asserts the scene tree agrees.
var _sortie: Apache = null
## The painted patrol box currently being serviced. Held HERE rather than on
## the aircraft, because it is what targeting reads and the aircraft must
## never be involved in targeting.
var _box_centre := Vector3.ZERO

# --- Gunnery state ------------------------------------------------------------
## The gun cycles ACQUIRING -> SLEWING -> FIRING -> ACQUIRING for as long as
## the aircraft is on station and has ammunition. None of these transitions
## consults the aircraft's position; the only thing the airframe is ever asked
## is whether it has finished transit (a state, not a place).
enum Gun { ACQUIRING, SLEWING, FIRING }

var _gun_state: int = Gun.ACQUIRING
var _gun_timer := 0.0
var _target: Zombie = null
var _rounds_left := 0
## Sensor reacquisition after a retask. While positive the gun is silent; it
## counts down in _process and is asserted never to exceed retask_slew_time.
var _retask_pause := 0.0

func setup(player: Player, hud: HUD, radio: RadioMenu, painter: TargetPainter) -> void:
	_player = player
	_hud = hud
	_radio = radio
	_painter = painter
	_validate()
	GameManager.phase_changed.connect(_on_phase_changed)
	_entry = {
		"id": APACHE_ID,
		"display_name": config.display_name,
		"cost": config.apache_cost,
		"call_fn": _begin_paint,
		"available_fn": _available_reason,
	}
	EnablerManager.callable_enablers.append(_entry)

## Startup invariants, in the spirit of Arsenal's HK416 > M17 damage check.
##
## Two of this enabler's stated invariants are STRUCTURAL, not values
## observable at a point in time, and are deliberately NOT faked as runtime
## asserts here:
##   - "no distance check between the airframe and a target" is guaranteed by
##     _acquire_target()'s signature, which never receives the aircraft.
##   - "emits zero noise events over its lifetime" is guaranteed by neither
##     this file nor Apache.gd referencing NoiseManager at all. The one hook
##     that could fire is AreaDamageSystem's own emit on a profile with a
##     nonzero noise_radius — which IS checkable, and is checked below.
func _validate() -> void:
	assert(config != null, "[APACHE] no ApacheConfig assigned")
	assert(config.burst_profile != null, "[APACHE] config has no burst_profile")

	# ZERO NOISE. AreaDamageSystem.detonate() only reaches its
	# NoiseManager.emit_noise() branch when noise_radius > 0, so this zero is
	# the whole mechanism by which the Apache stays silent to the AI.
	assert(config.burst_profile.noise_radius == 0.0,
		"[APACHE] burst_profile.noise_radius is %.1f, must be 0 — the Apache must emit no noise events of any kind and must never attract, alert or reorient a zombie." % config.burst_profile.noise_radius)
	if config.burst_profile.noise_radius != 0.0:
		push_error("[APACHE] burst_profile emits noise (radius %.1f). The Apache must be silent to the AI." % config.burst_profile.noise_radius)

	# ATTRITION, NOT ALPHA. A burst must stay weaker than one mortar round or
	# the mortar loses its role.
	assert(config.burst_profile.max_damage < MORTAR_PROFILE.max_damage,
		"[APACHE] burst damage %d is not below a single mortar round's %d. The Apache is sustained attrition; the mortar is alpha. If this inverts, the mortar has no role." % [
			config.burst_profile.max_damage, MORTAR_PROFILE.max_damage])
	if config.burst_profile.max_damage >= MORTAR_PROFILE.max_damage:
		push_error("[APACHE] burst damage %d >= mortar round %d — attrition/alpha relationship inverted." % [
			config.burst_profile.max_damage, MORTAR_PROFILE.max_damage])

	assert(config.retask_slew_time >= 0.0, "[APACHE] negative retask_slew_time")
	assert(config.no_fire_radius > 0.0,
		"[APACHE] no_fire_radius must be positive — the player must always have a bubble the gun refuses to fire into.")

	# THE PLAYER CANNOT BE DAMAGED BY THIS AIRCRAFT, GUARANTEED BY GEOMETRY.
	# The shared damage system is faction-blind by construction — it would
	# happily hurt the player — so the safety is that no legal impact point
	# can ever be close enough to reach them. The nearest a burst may land is
	# no_fire_radius; it reaches max_radius. The first must exceed the second,
	# or a legal shot could still splash the player.
	assert(config.no_fire_radius > config.burst_profile.max_radius,
		"[APACHE] no_fire_radius %.1f must EXCEED the burst's own max_radius %.1f. The nearest legal impact is no_fire_radius from the player; if the blast reaches further than that, a legal shot can still damage them." % [
			config.no_fire_radius, config.burst_profile.max_radius])
	if config.no_fire_radius <= config.burst_profile.max_radius:
		push_error("[APACHE] no_fire_radius %.1f <= burst max_radius %.1f — the player is reachable by a legal shot." % [
			config.no_fire_radius, config.burst_profile.max_radius])

	# PRICED ABOVE THE MORTAR. A 90-second gun that services a whole box is
	# worth more than one six-round sheaf; read from the mortar's own config
	# so retuning it can't silently leave the Apache cheaper.
	assert(config.apache_cost > MORTAR_MISSION.cost,
		"[APACHE] apache_cost %d must exceed the mortar's %d." % [
			config.apache_cost, MORTAR_MISSION.cost])
	if config.apache_cost <= MORTAR_MISSION.cost:
		push_error("[APACHE] apache_cost %d <= mortar %d." % [
			config.apache_cost, MORTAR_MISSION.cost])

# --- Availability -------------------------------------------------------------
## Cooldown and the global lockout are answered by EnablerManager BEFORE this
## is consulted; this adds only the reasons it alone knows.
##
## While a sortie is ON STATION this returns "" — the row is live, but by then
## it is the RETASK row, not the call-in row (see _refresh_entry()). The only
## state that blocks outright is the initial inbound transit: there is nothing
## on station to retask yet.
func _available_reason() -> String:
	if GameManager.is_day():
		return "NIGHT ONLY"
	if _sortie != null and is_instance_valid(_sortie) and not _sortie.is_on_station():
		return "INBOUND"
	return ""

## Swaps the registered menu entry between CALL-IN and RETASK.
##
## Mutates the SAME Dictionary instance appended to
## EnablerManager.callable_enablers — Dictionaries are reference types in
## GDScript and RadioMenu re-reads the entry on every refresh, so the right
## row appears with no menu-side change and no second registration.
func _refresh_entry() -> void:
	var on_station: bool = _sortie != null and is_instance_valid(_sortie) \
		and _sortie.is_on_station()
	if on_station:
		_entry["display_name"] = "Apache — Retask Box"
		# FREE. Retasking costs no points, and RadioMenu's own affordability
		# check passes trivially at zero.
		_entry["cost"] = 0
		_entry["call_fn"] = _begin_retask_paint
	else:
		_entry["display_name"] = config.display_name
		_entry["cost"] = config.apache_cost
		_entry["call_fn"] = _begin_paint

# --- Call flow ----------------------------------------------------------------
## Selection opens box designation. NOTHING is charged here — see _on_painted.
## The box is painted with the shared substrate at config.patrol_radius, so
## the circle the player aims with IS the area that will be serviced.
##
## requires_navmesh is left at the shared default (true): the box is an area
## the gun will service zombies inside, and a box painted where nothing can
## walk is a box nothing will ever be inside.
func _begin_paint() -> void:
	if _available_reason() != "":
		return
	# Defensive: while a sortie exists the registered call_fn is the retask
	# one, so this should be unreachable — but exactly one Apache may exist.
	if _sortie != null and is_instance_valid(_sortie):
		return
	_hud.show_message("APACHE — SEND YOUR PATROL BOX, OVER.")
	_painter.begin(config.patrol_radius, config.paint_max_range,
		_on_painted, _on_paint_cancelled)

## Cancelling costs nothing: no points, no cooldown, no transmission.
func _on_paint_cancelled() -> void:
	_hud.show_message("APACHE — CANCELLED.")

# --- Retasking ----------------------------------------------------------------
## Retask the aircraft already on station onto a new box. Same painting flow,
## same footprint — the substrate does not know or care that this is a retask.
##
## Unavailable during the initial inbound transit only; _available_reason()
## returns "INBOUND" then and the row is greyed.
func _begin_retask_paint() -> void:
	if _sortie == null or not is_instance_valid(_sortie) or not _sortie.is_on_station():
		return
	_hud.show_message("APACHE — SEND YOUR NEW BOX, OVER.")
	_painter.begin(config.patrol_radius, config.paint_max_range,
		_on_retasked, _on_paint_cancelled)

## The new box replaces the old one IMMEDIATELY. The aircraft does not
## reposition and its orbit is not interrupted — only the sensor has to catch
## up, which is what retask_slew_time represents.
##
## COSTS NOTHING: no points, no cooldown, no station time, and no cap on how
## often it may be done.
func _on_retasked(centre: Vector3) -> void:
	if _sortie == null or not is_instance_valid(_sortie) or not _sortie.is_on_station():
		return

	# Station time must be untouched by this. Captured before and asserted
	# after, so a future change that quietly charges station time for a
	# retask fails loudly instead of silently shortening the sortie.
	var station_left_before := _sortie.station_time_left()

	_box_centre = centre
	# Cosmetic orbit drift only. The gun is ALREADY servicing the new box —
	# nothing about engagement waits on the airframe going anywhere.
	_sortie.retask(centre)

	# Drop the current target and pause the gun for exactly retask_slew_time.
	_target = null
	_gun_state = Gun.ACQUIRING
	_retask_pause = config.retask_slew_time

	assert(is_equal_approx(_sortie.station_time_left(), station_left_before),
		"[APACHE] retask changed remaining station time from %.2fs to %.2fs. Retasking must never reduce station time beyond normal elapsed time." % [
			station_left_before, _sortie.station_time_left()])

	# A retask IS a transmission: it keys the mic like any other call, so it
	# emits the standard 10m pulse and arms the shared global radio lockout,
	# per the same rule every other enabler follows. That lockout rate-limits
	# how often the radio can be used at all; it does not pause the gun and
	# does not cap retasks.
	_radio.commit_transmission()
	EnablerManager.start_cooldown(APACHE_ID, 0.0)

	_hud.show_message("APACHE — NEW BOX COPIED.")
	print("[APACHE] retasked to (%.1f, %.1f, %.1f) — %.1fs sensor slew, %d rounds remaining, %.0fs station left" % [
		centre.x, centre.y, centre.z, config.retask_slew_time,
		_rounds_left, _sortie.station_time_left()])

## THE COMMIT POINT. Everything the player pays happens here and nowhere
## earlier, so a cancelled designation is genuinely free.
func _on_painted(centre: Vector3) -> void:
	# Re-checked rather than trusted from selection time: the player spent
	# several seconds aiming and the phase may have turned over since.
	if _available_reason() != "" or EnablerManager.cooldown_left(APACHE_ID) > 0.0:
		_hud.show_message("Apache unavailable.")
		return
	if not PointsManager.spend_points(config.apache_cost):
		_hud.show_message("Not enough points for the Apache.")
		return

	# The handset noise — the RADIO makes this, not the aircraft. The Apache
	# itself is silent for its entire lifetime; keying the mic to call it is a
	# separate event that happens at the player's own position.
	_radio.commit_transmission()

	# Per-enabler cooldown is NOT started here. It starts on DEPARTURE — see
	# _on_departed(). seconds=0.0 still arms the shared 10s global lockout,
	# which is the only thing EnablerManager needs to do at call-in.
	EnablerManager.start_cooldown(APACHE_ID, 0.0)

	_hud.show_message("APACHE — BOX COPIED. On station in %ds." % int(round(config.transit_time_in)))
	print("[APACHE] patrol box painted at (%.1f, %.1f, %.1f) radius %.1fm — cost %d, transit %.1fs, %d rounds, %.0fs on station" % [
		centre.x, centre.y, centre.z, config.patrol_radius, config.apache_cost,
		config.transit_time_in, config.total_rounds, config.time_on_station])

	_box_centre = centre
	# Ammunition is the sortie's, not the aircraft's — the actor is a visual
	# and holds no combat state at all.
	_rounds_left = config.total_rounds
	_target = null
	_gun_state = Gun.ACQUIRING
	_retask_pause = 0.0
	# Parented to the CURRENT SCENE, not to this system: the aircraft is a
	# world fixture for the length of its sortie and must not move or free
	# with anything else. Same reasoning as WhitePhosphorusZone and the
	# supply crate.
	_sortie = Apache.spawn(get_tree().current_scene, centre, config,
		_on_station, _on_departed)
	_refresh_entry()   # sortie now inbound: row greys to INBOUND

# --- Sortie lifecycle ---------------------------------------------------------
func _on_station() -> void:
	# The call-in row becomes the retask row for the rest of the sortie.
	_refresh_entry()
	_hud.show_message("APACHE — ON STATION, %d ROUNDS." % config.total_rounds)
	print("[APACHE] on station over (%.1f, %.1f, %.1f)" % [
		_box_centre.x, _box_centre.y, _box_centre.z])

## NIGHT PHASE ONLY, for the whole sortie and not merely the call button.
##
## This matters far more than it looks: a night is 120s and a full sortie is
## 115s (25 transit + 90 station), so almost any call spans sunrise. Zombies
## go dormant at dawn but stay alive and stay in the "zombies" group —
## Zombie.set_active(false) only changes their tint — so without this the
## aircraft would keep gunning down sleeping zombies in broad daylight.
##
## Departing (rather than merely holding fire) also keeps the cooldown rule
## honest: it still starts on the departure event, exactly as it would have.
func _on_phase_changed(phase: int) -> void:
	if phase != GameManager.Phase.DAY:
		return
	if _sortie != null and is_instance_valid(_sortie):
		_hud.show_message("APACHE — SUNRISE, RTB.")
		_sortie.depart_now("sunrise")

## THE COOLDOWN EVENT. Starts strictly here — on the aircraft going offmap —
## and not at call-in, not on winchester. Same rule the mortar and WP follow,
## so "cooldown" means the same thing across every fire support enabler.
func _on_departed() -> void:
	_sortie = null
	_target = null
	_gun_state = Gun.ACQUIRING
	_retask_pause = 0.0
	_refresh_entry()   # back to the call-in row
	# COOLDOWN STARTS STRICTLY AFTER DEPARTURE. Asserted by checking it had
	# NOT already started: anything nonzero here means something armed the
	# cooldown earlier in the sortie — at call-in or on winchester — which is
	# exactly the mistake this ordering exists to prevent.
	var already := EnablerManager.cooldown_left(APACHE_ID)
	assert(already <= 0.0,
		"[APACHE] cooldown was already running (%.1fs) before the departure event. It must start strictly on departure, not at call-in and not on winchester." % already)
	if already > 0.0:
		push_error("[APACHE] cooldown started before departure (%.1fs remaining)." % already)
	EnablerManager.start_cooldown(APACHE_ID, config.apache_cooldown)
	_hud.show_message("APACHE — OFF STATION.")
	print("[APACHE] offmap — cooldown %.0fs begins now" % config.apache_cooldown)

# --- Gunnery ------------------------------------------------------------------
## The engagement loop. Runs only while the aircraft is ON STATION — a state
## query, NOT a position query. The airframe's location is never consulted
## here or anywhere below it.
func _process(delta: float) -> void:
	if _sortie == null or not is_instance_valid(_sortie) or not _sortie.is_on_station():
		return
	# Winchester: leave immediately rather than orbiting out the station
	# clock with an empty gun.
	if _rounds_left <= 0:
		_hud.show_message("APACHE — WINCHESTER, RTB.")
		_sortie.depart_now("winchester")
		return

	# Sensor reacquisition after a retask. The gun is silent for EXACTLY
	# retask_slew_time and not a frame longer — asserted, because this is the
	# one place a retask could quietly become expensive.
	if _retask_pause > 0.0:
		assert(_retask_pause <= config.retask_slew_time + 0.001,
			"[APACHE] retask pause is %.3fs, longer than retask_slew_time %.3fs. A retask must never suppress firing for longer than that." % [
				_retask_pause, config.retask_slew_time])
		_retask_pause -= delta
		return

	match _gun_state:
		Gun.ACQUIRING:
			_tick_acquire()
		Gun.SLEWING:
			_tick_slew(delta)
		Gun.FIRING:
			_tick_firing(delta)

## Re-evaluated from scratch every cycle, so the gun always services the
## current highest-priority target rather than staying fixated on one.
func _tick_acquire() -> void:
	_target = _acquire_target(_box_centre, config.patrol_radius,
		_player.global_position)
	if _target == null:
		return   # nothing serviceable this frame; poll again next
	_gun_state = Gun.SLEWING
	_gun_timer = config.slew_time

func _tick_slew(delta: float) -> void:
	# A target that dies, leaves the box, or steps into the bubble mid-slew is
	# dropped and the cycle restarts rather than firing at where it was.
	if not _is_serviceable(_target, _player.global_position):
		_target = null
		_gun_state = Gun.ACQUIRING
		return
	_gun_timer -= delta
	if _gun_timer <= 0.0:
		# A refused shot consumes no ammunition and costs only the cycle:
		# straight back to acquisition.
		if not _fire_burst():
			_target = null
			_gun_state = Gun.ACQUIRING
			return
		_gun_state = Gun.FIRING
		_gun_timer = config.burst_duration

## The burst has already resolved; this is the cycle's tail before the gun
## reacquires. A target that dies or becomes unserviceable during it ends the
## tail early rather than idling out the clock on something that no longer
## needs servicing.
func _tick_firing(delta: float) -> void:
	if not _is_serviceable(_target, _player.global_position):
		_target = null
		_gun_state = Gun.ACQUIRING
		return
	_gun_timer -= delta
	if _gun_timer <= 0.0:
		_target = null
		_gun_state = Gun.ACQUIRING

## THE TARGETING FUNCTION. Its signature is the enforcement mechanism for the
## standoff constraint: it receives the box, its radius, and the player's live
## position — and NOT the aircraft or its transform. A distance check between
## the airframe and a candidate is not expressible here, so the aircraft can
## never be "too far" to shoot, and never has to fly anywhere to engage.
##
## Priority is CLOSEST TO THE PLAYER among valid targets: the gun services
## whatever is about to reach the player first.
func _acquire_target(box_centre: Vector3, box_radius: float,
		player_pos: Vector3) -> Zombie:
	var best: Zombie = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group("zombies"):
		if not (node is Zombie):
			continue
		var z: Zombie = node as Zombie
		if not _is_serviceable(z, player_pos):
			continue
		var d := _flat_distance(z.global_position, player_pos)
		if d < best_d:
			best_d = d
			best = z
	return best

## A zombie is serviceable when it is alive, inside the painted box, and
## OUTSIDE the player's no-fire bubble. Zombies inside the bubble are simply
## not engaged — no warning, no override.
##
## Deliberately re-checked mid-slew as well as at acquisition, so the same
## rule governs both and they can never disagree.
##
## `z` IS DELIBERATELY UNTYPED, AND MUST STAY THAT WAY. It was `z: Zombie`,
## which crashed the game the first time a target died mid-engagement:
## _target is a stored reference held across frames, and the moment its
## zombie is freed, passing it to a statically-typed parameter throws
## "the Object-derived class of argument 1 (previously freed) is not a
## subclass of the expected argument class" — GDScript rejects the argument
## at the CALL BOUNDARY, before the function body runs. That made the
## is_instance_valid() guard on the very next line unreachable for the exact
## case it was written to catch. Typing this parameter is not a safety
## improvement here; it is what disables the safety check.
func _is_serviceable(z, player_pos: Vector3) -> bool:
	if z == null or not is_instance_valid(z) or not z.is_alive():
		return false
	if _flat_distance(z.global_position, _box_centre) > config.patrol_radius:
		return false
	if _flat_distance(z.global_position, player_pos) <= config.no_fire_radius:
		return false
	return true

## Flat 2D distance. Height is deliberately ignored throughout: the box is a
## ground area, and a zombie in the ditch is as much inside it as one on the
## berm above.
func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

## One burst, resolved as a single area-damage event at the target's position
## through the SHARED system. No damage numbers live here — they are all on
## the authored profile, whose noise_radius of 0 is what keeps the burst
## silent to the AI (asserted in _validate()).
##
## Returns false if the shot was REFUSED, in which case nothing was fired and
## no ammunition was spent.
func _fire_burst() -> bool:
	var impact := _target.global_position

	# THE NO-FIRE GATE, APPLIED AT THE MOMENT OF FIRE against the player's
	# LIVE position — not the position they held at acquisition, and not a
	# static point. This is the last thing standing between the faction-blind
	# damage system and the player.
	#
	# Reaching this branch means the shot passed _is_serviceable() earlier in
	# the same frame and became illegal anyway, which should be impossible —
	# hence assert plus push_error rather than a quiet return. The aircraft
	# refuses the shot either way: it never fires and merely warns.
	var to_player := _flat_distance(impact, _player.global_position)
	assert(to_player > config.no_fire_radius,
		"[APACHE] burst impact was %.2fm from the player, inside the %.1fm no-fire bubble. The Apache must never fire a burst whose impact point falls inside the bubble." % [
			to_player, config.no_fire_radius])
	if to_player <= config.no_fire_radius:
		push_error("[APACHE] refused a burst %.2fm from the player (bubble %.1fm)." % [
			to_player, config.no_fire_radius])
		return false

	var fired: int = mini(config.rounds_per_burst, _rounds_left)
	_rounds_left -= fired
	AreaDamageSystem.detonate(impact, config.burst_profile, Vector3.ZERO,
		"apache 30mm")

	# TRACERS LAST, AFTER THE BURST HAS ALREADY RESOLVED. This is the only
	# place in the entire system that reads the airframe's position, and it
	# reads it purely to know where to draw a line FROM — the shot is already
	# decided and applied by the line above, so no cosmetic here can gate,
	# block or miss it. That ordering is the whole reason drawing from the
	# aircraft is safe; see _acquire_target()'s note on why the aircraft's
	# position must never reach a targeting decision.
	if is_instance_valid(_sortie):
		ApacheTracer.spawn(get_tree().current_scene, _sortie.gun_muzzle(),
			impact, config)

	print("[APACHE] burst — %d rounds at (%.1f, %.1f, %.1f), %d remaining" % [
		fired, impact.x, impact.y, impact.z, _rounds_left])
	return true
