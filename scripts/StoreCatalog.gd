extends Node
## Data-driven catalog for the supply crate store (autoload).
##
## WHY A DICTIONARY-BACKED `StoreItem` OBJECT rather than .tres Resources:
## every item here is generated from data we already own (the Arsenal roster),
## so authoring 12+ .tres files by hand would duplicate that and drift from it.
## A plain script object keeps the catalog in one readable place, lets ammo and
## attachment entries be derived per weapon in a loop, and still gives the UI a
## uniform interface. If items later need designer-authored art/copy, each
## entry can become a Resource without changing the UI — the UI only ever reads
## the fields below.
##
## The store UI builds its tabs from `categories()`, so ADDING A CATEGORY IS A
## CONFIG CHANGE: append items with a new `category` and a tab appears.

class StoreItem:
	var id: String            # unique item id
	var category: String      # tab it appears under
	var display_name: String
	var description: String
	var cost: int
	var requires: String = ""     # prerequisite item id ("" = none)
	var weapon_id: String = ""    # parent weapon for ammo/attachment entries
	var kind: String = ""         # "weapon" | "ammo" | "attachment"
	var repeatable: bool = false  # ammo can be bought over and over

# Tab order. Categories not listed here are appended alphabetically, so a new
# category still produces a working tab without touching this list.
const CATEGORY_ORDER := ["WEAPONS", "ATTACHMENTS", "AMMO"]

const SUPPRESSOR_COST := 3

var items: Array = []

func _ready() -> void:
	rebuild()

func rebuild() -> void:
	items.clear()

	# --- WEAPONS ---
	for id in Arsenal.order:
		var w = Arsenal.get_weapon(id)
		if w == null or w.cost <= 0:
			continue   # starter weapon isn't for sale
		items.append(_mk({
			"id": "weapon_" + id, "category": "WEAPONS", "kind": "weapon",
			"display_name": w.display_name, "weapon_id": id, "cost": w.cost,
			"requires": w.requires,
			"description": "%d-round mag · %s · ships with %d mags" % [
				w.mag_size, _fire_mode_text(w), w.starting_mags],
		}))

	# The radio lives under WEAPONS as a stopgap; it moves to an ENABLERS tab
	# once the UAV/Apache/supply-drop enablers exist.
	items.append(_mk({
		"id": "radio", "category": "WEAPONS", "kind": "attachment",
		"display_name": "Radio", "cost": 10,
		"description": "Comms link. Prerequisite for future support enablers.",
	}))

	# --- ATTACHMENTS (per weapon; filtered to owned at display time) ---
	for id in Arsenal.order:
		var w = Arsenal.get_weapon(id)
		if w == null:
			continue
		items.append(_mk({
			"id": "supp_" + id, "category": "ATTACHMENTS", "kind": "attachment",
			"display_name": "%s Suppressor" % w.display_name,
			"weapon_id": id, "cost": SUPPRESSOR_COST,
			"description": "Drops gunshot noise %dm → %dm." % [
				int(w.noise_unsuppressed), int(w.noise_suppressed)],
		}))

	# --- AMMO (per weapon; filtered to owned at display time) ---
	for id in Arsenal.order:
		var w = Arsenal.get_weapon(id)
		if w == null:
			continue
		items.append(_mk({
			"id": "ammo_" + id, "category": "AMMO", "kind": "ammo",
			"display_name": "%s Ammo" % w.display_name,
			"weapon_id": id, "cost": w.ammo_cost, "repeatable": true,
			"description": "+1 magazine (%d rounds)." % w.mag_size,
		}))

func _mk(d: Dictionary) -> StoreItem:
	var it := StoreItem.new()
	for key in d:
		it.set(key, d[key])
	return it

func _fire_mode_text(w) -> String:
	match w.fire_mode:
		WeaponData.FireMode.AUTO: return "auto"
		WeaponData.FireMode.BOTH: return "semi/auto"
		_: return "semi"

## Every category present in the catalog, ordered. Tabs are built from this —
## a new category in the item list yields a new tab with no UI changes.
func categories() -> Array:
	var seen: Array = []
	for it in items:
		if not (it.category in seen):
			seen.append(it.category)
	var ordered: Array = []
	for c in CATEGORY_ORDER:
		if c in seen:
			ordered.append(c)
	var extras: Array = []
	for c in seen:
		if not (c in CATEGORY_ORDER):
			extras.append(c)
	extras.sort()
	return ordered + extras

func items_in(category: String) -> Array:
	return items.filter(func(it): return it.category == category)

func get_item(id: String) -> StoreItem:
	for it in items:
		if it.id == id:
			return it
	return null
