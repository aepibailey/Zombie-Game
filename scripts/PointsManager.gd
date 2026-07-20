extends Node
## Points economy (autoload).
##
## Points are the only currency (PROJECT_SPEC.md "Economy"). Kills add points;
## the crate spends them. `points_changed` keeps the HUD and crate UI in sync.

signal points_changed(points: int)

var points: int = 0

func add_points(amount: int) -> void:
	points += amount
	points_changed.emit(points)

## Returns true if the purchase succeeded (enough points and they were spent).
func spend_points(amount: int) -> bool:
	if points >= amount:
		points -= amount
		points_changed.emit(points)
		return true
	return false
