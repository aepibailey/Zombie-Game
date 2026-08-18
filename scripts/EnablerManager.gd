extends Node
## Ownership registry for purchasable support enablers (autoload).
##
## STUB — no gameplay logic. It exists so the enabler tree (Radio → UAV /
## Apache / Supply Drop) has a home that other systems can already query, and
## so the guaranteed-drop schedule has somewhere to live that can be switched
## off wholesale once drops become purchasable. See docs/ROADMAP.md.

signal enabler_acquired(id: String)

## Which nights grant a free resupply drop at dawn. Owned here (not inside the
## SupplyDrop scene) so the whole stopgap can be disabled with one edit when
## the purchasable supply-drop enabler ships.
@export var guaranteed_drop_nights: Array[int] = [3, 5, 10]

var owned: Dictionary = {}   # enabler id -> true

## Radio-callable transmissions, in menu display order. Genuinely empty right
## now — UAV, Supply Drop (as a CALLED drop, distinct from the automatic
## Night 3+ crate above), Apache and the mortar/WP enablers all register here
## once each is actually built. RadioMenu iterates this directly and renders
## "No transmissions available" when it's empty, rather than the menu being
## hardcoded to show nothing — the difference matters the moment the first
## entry is added: zero menu-side changes needed.
##
## Deliberately a plain Dictionary, not an EnablerType resource, until a real
## enabler defines what fields it actually needs (travel time, duration,
## cooldown, call flow, ...). Minimum shape RadioMenu currently reads:
##   {"id": String, "display_name": String, "cost": int}
## Extend as needed when the first real entry is built; RadioMenu's row
## rendering is written to duck-type optional fields rather than assume this
## final shape is already right.
var callable_enablers: Array = []

func has(id: String) -> bool:
	return owned.get(id, false)

func acquire(id: String) -> void:
	if has(id):
		return
	owned[id] = true
	enabler_acquired.emit(id)

func reset() -> void:
	owned.clear()

## True when night `n` should drop a free resupply at the following dawn.
func is_guaranteed_drop_night(n: int) -> bool:
	return n in guaranteed_drop_nights
