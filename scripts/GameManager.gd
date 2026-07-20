extends Node
## Day/Night cycle driver (autoload).
##
## Day = safe, tent open, zombies dormant. Night = zombies spawn and hunt.
## v1 uses one fixed night length for fast playtesting (PROJECT_SPEC.md
## "Core Loop"). Emits `phase_changed` on every transition; the world reacts
## (lighting, zombie activation, tent availability).

signal phase_changed(phase: int)
signal time_updated(time_left: float, phase: int)

enum Phase { DAY, NIGHT }

# --- Tuning ---------------------------------------------------------------
# Playtest cadence: 60s day / 180s night. (Spec default for a night is 360s /
# 6 min; shortened here for faster iteration.)
const DAY_LENGTH: float = 60.0
const NIGHT_LENGTH: float = 180.0

var current_phase: int = Phase.DAY
var time_left: float = 0.0

func _ready() -> void:
	_start_phase(Phase.DAY)

func _process(delta: float) -> void:
	time_left -= delta
	time_updated.emit(time_left, current_phase)
	if time_left <= 0.0:
		_start_phase(Phase.NIGHT if current_phase == Phase.DAY else Phase.DAY)

func _start_phase(phase: int) -> void:
	current_phase = phase
	time_left = DAY_LENGTH if phase == Phase.DAY else NIGHT_LENGTH
	phase_changed.emit(phase)

func is_day() -> bool:
	return current_phase == Phase.DAY

func phase_name() -> String:
	return "DAY" if current_phase == Phase.DAY else "NIGHT"

## Convenience for external callers (tent) that want to force dawn/dusk.
func force_phase(phase: int) -> void:
	_start_phase(phase)
