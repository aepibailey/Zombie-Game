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
## authority on that, asserted on spawn. (Phase 2.)
var _sortie = null

func setup(player: Player, hud: HUD, radio: RadioMenu, painter: TargetPainter) -> void:
	_player = player
	_hud = hud
	_radio = radio
	_painter = painter
	_validate()
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

# --- Availability -------------------------------------------------------------
## Cooldown and the global lockout are answered by EnablerManager BEFORE this
## is consulted; this adds only the reasons it alone knows.
func _available_reason() -> String:
	if GameManager.is_day():
		return "NIGHT ONLY"
	if _sortie != null:
		# Phase 5 turns this into a retask rather than a block. Until then a
		# sortie in progress simply occupies the slot — exactly one Apache
		# exists at a time.
		return "ON STATION"
	return ""

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
	_hud.show_message("APACHE — SEND YOUR PATROL BOX, OVER.")
	_painter.begin(config.patrol_radius, config.paint_max_range,
		_on_painted, _on_paint_cancelled)

## Cancelling costs nothing: no points, no cooldown, no transmission.
func _on_paint_cancelled() -> void:
	_hud.show_message("APACHE — CANCELLED.")

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
