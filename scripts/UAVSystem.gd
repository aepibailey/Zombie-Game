extends Node
## Autoload. UAV call-in, night/active state gating, and the wall-hack reveal
## broadcast every Zombie listens for.
##
## OWNS NO DRAWING. The through-wall silhouette lives on each Zombie (see
## Zombie._build_uav_silhouette()); the offscreen edge indicators live on
## UAVOverlay. This script only decides WHEN the UAV is up and broadcasts
## that — a global autoload rather than a Main-instantiated node (like
## FireMissionSystem) because every Zombie needs to query/subscribe to it
## without a reference threaded through the spawner, the same reason
## NoiseManager is an autoload.
##
## Tunables live on UAVConfig (see CONFIG below), not as @export vars here —
## an autoload script has no .tscn for its own exports to be edited FROM, so
## they would never actually reach an inspector. Same reason FireMissionConfig
## is a Resource rather than exports directly on FireMissionSystem.

const UAV_ID := "uav"
const CONFIG: UAVConfig = preload("res://resources/uav.tres")

## Broadcast on activate/deactivate. Every Zombie connects in its own
## _ready() (same pattern as NoiseManager.noise_emitted), so the reveal
## needs no reference threaded through the spawner.
signal uav_state_changed(is_active: bool)

var active := false
## Night number the UAV was last called on. -1 = never called. Compared
## against GameManager.night_number rather than reset by a "new night"
## listener, so there's nothing to keep in sync — the same pattern
## EnablerManager.is_guaranteed_drop_night() uses.
var _used_night := -1

var _hud: HUD
var _radio: RadioMenu

func setup(hud: HUD, radio: RadioMenu) -> void:
	_hud = hud
	_radio = radio
	GameManager.phase_changed.connect(_on_phase_changed)
	EnablerManager.callable_enablers.append({
		"id": UAV_ID,
		"display_name": "UAV Overwatch",
		"cost": CONFIG.uav_cost,
		"call_fn": _call_uav,
		"available_fn": _available_reason,
	})

## Reasons EnablerManager.unavailable_reason() doesn't already know about —
## cooldown and the global lockout are checked there first, ahead of this.
func _available_reason() -> String:
	if GameManager.is_day():
		return "NIGHT ONLY"
	if active:
		return "ACTIVE"
	if _used_night == GameManager.night_number:
		return "USED"
	return ""

func _call_uav() -> void:
	if _available_reason() != "":
		return
	if not PointsManager.spend_points(CONFIG.uav_cost):
		if _hud:
			_hud.show_message("Not enough points for UAV Overwatch.")
		return
	active = true
	_used_night = GameManager.night_number
	# No per-enabler cooldown — availability is night-based (_available_reason
	# above), not a timer. seconds=0.0 still triggers the global lockout,
	# which is the only thing EnablerManager needs to do for this call.
	EnablerManager.start_cooldown(UAV_ID, 0.0)
	if _radio:
		_radio.commit_transmission()
	if _hud:
		_hud.show_message("UAV OVERWATCH — ON STATION.")
	uav_state_changed.emit(true)

## ALWAYS terminates here, never on its own timer — see the class docstring.
## Checked against the phase actually becoming DAY (not merely "not NIGHT")
## because that IS what "sunrise" means on the two-value Phase enum.
func _on_phase_changed(phase: int) -> void:
	if phase == GameManager.Phase.DAY and active:
		active = false
		if _hud:
			_hud.show_message("UAV OVERWATCH — OFF STATION.")
		uav_state_changed.emit(false)
