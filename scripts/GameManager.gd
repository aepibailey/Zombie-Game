extends Node
## Day/Night cycle driver (autoload).
##
## Day = safe, crate open, zombies dormant. Night = zombies spawn and hunt.
## v1 uses one fixed night length for fast playtesting (PROJECT_SPEC.md
## "Core Loop"). Emits `phase_changed` on every transition; the world reacts
## (lighting, zombie waves, crate availability). Also owns the night counter.

signal phase_changed(phase: int)
signal time_updated(time_left: float, phase: int)

enum Phase { DAY, NIGHT }

# --- Tuning ---------------------------------------------------------------
# Playtest cadence: 30s day / 120s night. (Spec default for a night is 360s /
# 6 min.) Night length is the value tuned most often, so it's a plain var
# rather than a const — edit here, or set it at runtime.
const DAY_LENGTH: float = 30.0
@export var NIGHT_LENGTH: float = 120.0

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

func is_day() -> bool:
	return current_phase == Phase.DAY

func phase_name() -> String:
	return "DAY" if current_phase == Phase.DAY else "NIGHT"

## Convenience for external callers (crate, all-clear skip) to force dawn/dusk.
func force_phase(phase: int) -> void:
	_start_phase(phase)
