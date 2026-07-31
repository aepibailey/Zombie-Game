extends Node
## Points economy (autoload).
##
## Points are the only currency (PROJECT_SPEC.md "Economy"). Kills add points;
## the crate spends them. `points_changed` keeps the HUD and crate UI in sync.

signal points_changed(points: int)

var points: int = 0
## Points earned since the current night began. Reset by Main at dusk and
## logged at dawn — the per-night earnings telemetry that pricing decisions
## need and that previously didn't exist.
var earned_this_night: int = 0
var spent_this_night: int = 0

func add_points(amount: int) -> void:
	points += amount
	earned_this_night += amount
	points_changed.emit(points)

func begin_night_tally() -> void:
	earned_this_night = 0
	spent_this_night = 0

## Returns true if the purchase succeeded (enough points and they were spent).
func spend_points(amount: int) -> bool:
	if points >= amount:
		points -= amount
		spent_this_night += amount
		points_changed.emit(points)
		return true
	return false
