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
# Playtest cadence: 30s day / 60s night. (Spec default for a night is 360s /
# 6 min; shortened here for faster iteration.)
const DAY_LENGTH: float = 30.0
const NIGHT_LENGTH: float = 60.0

# Size of each night's zombie wave. v1 uses the same pool every night (no
# escalation yet — that's a v2 feature). Read by the spawner in Main.gd.
const NIGHT_ZOMBIE_COUNT: int = 5

var current_phase: int = Phase.DAY
var time_left: float = 0.0
var night_number: int = 0        # incremented at the start of each night

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

func _process(delta: float) -> void:
	time_left -= delta
	time_updated.emit(time_left, current_phase)
	if time_left <= 0.0:
		_start_phase(Phase.NIGHT if current_phase == Phase.DAY else Phase.DAY)

func _start_phase(phase: int) -> void:
	current_phase = phase
	time_left = DAY_LENGTH if phase == Phase.DAY else NIGHT_LENGTH
	if phase == Phase.NIGHT:
		night_number += 1
	phase_changed.emit(phase)

## The wave size for a given night. Constant for v1; a hook for future scaling.
func zombies_for_night(_n: int) -> int:
	return NIGHT_ZOMBIE_COUNT

func is_day() -> bool:
	return current_phase == Phase.DAY

func phase_name() -> String:
	return "DAY" if current_phase == Phase.DAY else "NIGHT"

## Convenience for external callers (crate, all-clear skip) to force dawn/dusk.
func force_phase(phase: int) -> void:
	_start_phase(phase)
