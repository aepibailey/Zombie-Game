extends Node
## Points economy (autoload).
##
## Points are the only currency (PROJECT_SPEC.md "Economy"). Kills add points;
## the tent spends them. `points_changed` lets the HUD and tent UI stay in sync.

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
