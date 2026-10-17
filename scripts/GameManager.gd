extends Node
## Day/Night cycle driver (autoload).
##
## Day = safe, crate open, zombies dormant. Night = zombies spawn and hunt.
## v1 uses one fixed night length for fast playtesting (PROJECT_SPEC.md
## "Core Loop"). Emits `phase_changed` on every transition; the world reacts
## (lighting, zombie waves, crate availability). Also owns the night counter.

signal phase_changed(phase: int)
signal time_updated(time_left: float, phase: int)
## Fired at dusk, right after phase_changed(NIGHT), once night_number has
## advanced. Carries the night's scheduled type so the HUD can name it.
signal night_started(night: int, type_name: String)
## Fired at the dawn after a transit night, once current_position has
## advanced. There is no map change yet; listeners react to the number
## (the roster's Position Two rescue grant).
signal position_changed(new_position: int)

enum Phase { DAY, NIGHT }

## The night schedule's vocabulary. TRANSIT is planned but not built: it
## resolves to transit_standin_profile until it is (see get_night_profile).
enum NightType { NORMAL, SWARM, SIEGE, HUNTERS, TRANSIT }

# --- Tuning ---------------------------------------------------------------
# Playtest cadence: 30s day / 120s night. (Spec default for a night is 360s /
# 6 min.) Night length is the value tuned most often, so it's a plain var
# rather than a const — edit here, or set it at runtime.
const DAY_LENGTH: float = 30.0
## The Ready action (Main) may end Day early. The 30s Day itself is
## unchanged; Ready only stops waiting it out.
@export var day_skip_enabled: bool = true
@export var NIGHT_LENGTH: float = 120.0

# --- Night schedule — docs/RUN_STRUCTURE.md "Escalation, night types and Day" --
## Fixed special nights. Every other night is NORMAL, except the cycle below.
@export var special_nights: Dictionary = {
	5: NightType.SWARM, 9: NightType.TRANSIT, 10: NightType.HUNTERS,
	15: NightType.SWARM, 20: NightType.SIEGE, 25: NightType.TRANSIT,
}
## From special_cycle_start, every special_cycle_every-th night takes the next
## entry of special_cycle, wrapping: 30 Hunters, 35 Swarm, 40 Siege, 45 Hunters.
@export var special_cycle_start: int = 30
@export var special_cycle_every: int = 5
@export var special_cycle: Array[NightType] = [NightType.HUNTERS, NightType.SWARM, NightType.SIEGE]
@export var normal_profile: NightTypeProfile = preload("res://resources/night_normal.tres")
@export var swarm_profile: NightTypeProfile = preload("res://resources/night_swarm.tres")
@export var siege_profile: NightTypeProfile = preload("res://resources/night_siege.tres")
@export var hunters_profile: NightTypeProfile = preload("res://resources/night_hunters.tres")
## What a TRANSIT night actually plays as until the transit night is built.
@export var transit_standin_profile: NightTypeProfile = preload("res://resources/night_siege.tres")

# --- Positions — docs/RUN_STRUCTURE.md "Decision" ---------------------------
## The run is split into positions that act as chapters. The dawn after each
## of these nights moves the operator to the next one.
@export var position_transit_nights: Array[int] = [9, 25]
## 1 = Position One, the lone-operator act. Only ever increases in a run.
var current_position: int = 1

var current_phase: int = Phase.DAY
var time_left: float = 0.0
var night_number: int = 0        # incremented at the start of each night

## Reference-counted clock halt. Any number of independent consumers (build
## mode, the roster menu, ...) can each hold the clock stopped at once; the
## clock advances again only once EVERY one of them has released. Keyed by a
## caller-chosen source_id rather than a plain counter so a caller can never
## accidentally double-halt itself (a second request from the same id is a
## no-op) and a mismatched release can never under-run into someone else's
## hold (a release from an id that never requested is a no-op, not an error).
##
## This replaces what used to be a single bool (`paused`) owned by BuildMode.
## A bool cannot express "two things are holding the clock, one just let go" —
## the roster menu opened from inside build mode is exactly that case, and a
## bool would have let either one's close prematurely resume the day.
var _clock_halt_sources: Dictionary = {}   # source_id -> true

func _ready() -> void:
	_ensure_input_actions()
	_start_phase(Phase.DAY)

## The "interact" action is defined in project.godot's Input Map (remappable in
## Project Settings). This is a safety net so the crate still opens even if that
## definition is missing for any reason.
func _ensure_input_actions() -> void:
	if not InputMap.has_action("interact"):
		InputMap.add_action("interact")
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_E
		InputMap.action_add_event("interact", ev)

## Hold the clock. Idempotent — a repeated request from the SAME source_id
## does not add a second hold that would need a second release.
func request_clock_halt(source_id: String) -> void:
	_clock_halt_sources[source_id] = true

## Release this source's hold. A source_id that never requested a halt is a
## no-op, not an error — an early-exit/error path in a caller that never got
## as far as requesting must still be safe to call this from.
func release_clock_halt(source_id: String) -> void:
	_clock_halt_sources.erase(source_id)

## True while at least one source is holding the clock.
func is_clock_halted() -> bool:
	return not _clock_halt_sources.is_empty()

func _process(delta: float) -> void:
	if is_clock_halted():
		return
	time_left -= delta
	time_updated.emit(time_left, current_phase)
	if time_left <= 0.0:
		_start_phase(Phase.NIGHT if current_phase == Phase.DAY else Phase.DAY)

func _start_phase(phase: int) -> void:
	current_phase = phase
	time_left = DAY_LENGTH if phase == Phase.DAY else NIGHT_LENGTH
	if phase == Phase.NIGHT:
		night_number += 1
		# LEAK GUARD. Day only ever ends by time_left reaching 0 in
		# _process(), which does not run at all while halted — so reaching
		# here with an active hold means force_phase() was called past a
		# halt, or (the real risk) something requested a halt and never
		# released it. Either way the day clock would appear to advance
		# during a supposedly-paused menu, or Night could start with a menu
		# still silently holding a stale halt into the next Day. Loud in
		# debug, not a silent stuck clock.
		assert(_clock_halt_sources.is_empty(),
			"[GAMEMANAGER] entering Night with the clock halt still held by: %s — every request_clock_halt() must be matched by a release_clock_halt()." % [_clock_halt_sources.keys()])
	phase_changed.emit(phase)
	if phase == Phase.NIGHT:
		night_started.emit(night_number, night_type_name(night_number))
	# After phase_changed, so the Day is fully set up (survivors retreating,
	# HUD in Day mode) before anything reacts to the move.
	elif night_number in position_transit_nights:
		current_position += 1
		print("[POSITION] dawn after night %d: now at Position %d (no map change yet)" % [
			night_number, current_position])
		position_changed.emit(current_position)

## The scheduled type of `night`: a fixed special night, else the cycle from
## special_cycle_start, else NORMAL.
func get_night_type(night: int) -> NightType:
	if special_nights.has(night):
		return special_nights[night]
	if night >= special_cycle_start and not special_cycle.is_empty() \
			and (night - special_cycle_start) % maxi(1, special_cycle_every) == 0:
		var i := ((night - special_cycle_start) / maxi(1, special_cycle_every)) % special_cycle.size()
		return special_cycle[i]
	return NightType.NORMAL

## The profile `night` actually PLAYS with. TRANSIT resolves to the stand-in.
func get_night_profile(night: int) -> NightTypeProfile:
	match get_night_type(night):
		NightType.SWARM: return swarm_profile
		NightType.SIEGE: return siege_profile
		NightType.HUNTERS: return hunters_profile
		NightType.TRANSIT: return transit_standin_profile
	return normal_profile

## Tonight's profile. Only meaningful at Night; by Day it is the profile of
## the night just survived.
func tonight_profile() -> NightTypeProfile:
	return get_night_profile(night_number)

## The SCHEDULED type's name, upper case: "TRANSIT" on night 9 even though it
## plays as Siege — the HUD and the run log say what the night is.
func night_type_name(night: int) -> String:
	return NightType.keys()[get_night_type(night)]

func is_day() -> bool:
	return current_phase == Phase.DAY

func phase_name() -> String:
	return "DAY" if current_phase == Phase.DAY else "NIGHT"

## Ready: end Day now. The caller (Main's Ready action) has already refused
## while any clock halt is held, so this never has a halt to release — and
## asserting it here, rather than releasing someone else's halt, keeps
## _start_phase()'s leak guard exactly as strict as it was. Returns false,
## and does nothing, if Day cannot end early right now.
func end_day_early() -> bool:
	if not day_skip_enabled or not is_day() or is_clock_halted():
		return false
	print("[GAMEMANAGER] Ready: Day %d ended early with %.1fs left" % [night_number, time_left])
	_start_phase(Phase.NIGHT)
	return true

## Convenience for external callers (crate, all-clear skip) to force dawn/dusk.
func force_phase(phase: int) -> void:
	_start_phase(phase)

# --- Run lifecycle ----------------------------------------------------------
## THE way a new run begins (the game-over panel's Restart). Resets every
## autoload that holds run state, explicitly, and only THEN reloads the scene,
## which rebuilds everything Main owns (player, base, fighters, zombies, the
## enabler systems) from scratch.
##
## The scene reload is NOT sufficient by itself and is not relied on alone —
## autoloads survive it, and three of them would actively corrupt the new run:
## GameState would hand Main the dead run's base to restore, EnablerManager
## would list every radio entry twice, and AmmoManager would stack the new
## loadout's starting ammo on the old reserves.
##
## A restarted run is a cold boot: opening Day, night counter 0.
func start_new_run() -> void:
	reset_run()
	PointsManager.reset()
	AmmoManager.reset()
	EnablerManager.reset()
	UAVSystem.reset()
	RunLogger.reset()
	# Last before the reload, after anything that might snapshot.
	GameState.clear()
	get_tree().reload_current_scene()

## This autoload's share of start_new_run(). SILENT: no phase_changed. The old
## scene is still alive until the deferred reload swaps it out, and its Main
## snapshots the base into GameState on every phase boundary — emitting here
## would re-capture the dead run right after it was cleared. A cold boot's
## own _ready() emit has no listeners either, so this matches it exactly.
##
## Clearing every clock halt is what keeps _start_phase()'s leak guard honest
## rather than weakened: the game-over panel holds one, and the run it was
## holding for no longer exists.
func reset_run() -> void:
	_clock_halt_sources.clear()
	current_phase = Phase.DAY
	time_left = DAY_LENGTH
	night_number = 0
	current_position = 1
