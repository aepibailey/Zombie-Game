extends Node
## Points economy (autoload).
##
## Points are the only currency (PROJECT_SPEC.md "Economy"). Kills add points;
## the crate spends them. `points_changed` keeps the HUD and crate UI in sync.

signal points_changed(points: int)

var points: int = 0
## Everything earned since the run began, spending ignored — what the
## game-over panel reports. `points` is only the balance left to spend.
var earned_this_run: int = 0
## Everything spent since the run began. With earned_this_run, the only
## totals kept here: RunLogger takes per-night windows as deltas of the two.
var spent_this_run: int = 0

func add_points(amount: int) -> void:
	points += amount
	earned_this_run += amount
	points_changed.emit(points)

## Back to a cold boot's values. Part of GameManager.start_new_run().
func reset() -> void:
	points = 0
	earned_this_run = 0
	spent_this_run = 0
	_defense_credit_depth = 0
	points_changed.emit(points)

# --- Placed-defense credit --------------------------------------------------
## Kills by a PLACED DEFENSE score even by day: a dawn retreat that walks into
## your claymore or minefield still pays, the way it would for real. What the
## player does directly — gunfire, grenades, enablers — scores nothing by day
## (Zombie._die() is the one gate).
##
## The defense wraps its own damage in credit_defense_kills(), and _die()
## reads defense_credit_active(). Exact rather than a heuristic because both
## defenses deal their damage synchronously inside the call (the claymore
## profile has duration 0, so AreaDamageSystem applies it in one pass). A
## depth counter, not a bool, so a nested call can never clear an outer one.
var _defense_credit_depth := 0

func credit_defense_kills(apply_damage: Callable) -> void:
	_defense_credit_depth += 1
	apply_damage.call()
	_defense_credit_depth -= 1

func defense_credit_active() -> bool:
	return _defense_credit_depth > 0

## Returns true if the purchase succeeded (enough points and they were spent).
func spend_points(amount: int) -> bool:
	if points >= amount:
		points -= amount
		spent_this_run += amount
		points_changed.emit(points)
		return true
	return false
