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
	## Purchasable during Day only. The crate itself is open in BOTH phases
	## (see SupplyCrateZone — night shopping is deliberate), so this is a
	## PER-ITEM restriction, not a property of the store. Declared here as
	## data so a future Day-only item is a catalog entry and not another
	## branch in Player.store_item_blocked().
	var day_only: bool = false
	## Which attachment slot this fills, for "attachment" kind items with a
	## weapon_id: "suppressor" | "foregrip" | "choke" | "drum" | "zoom".
	## Non-weapon attachments (radio, ir_laser) leave this "" and dispatch
	## through Player.owned_items instead — see Player.owns_store_item().
	var attachment_type: String = ""

# Tab order. Categories not listed here are appended alphabetically, so a new
# category still produces a working tab without touching this list.
const CATEGORY_ORDER := ["WEAPONS", "ATTACHMENTS", "SUPPLIES", "EQUIPMENT"]

## ~27% of a typical night's earnings (see PROJECT_SPEC.md "Economy").
const IFAK_COST := 15
## Cheap per unit, but capped at 4 carried and never restocked at dawn, so the
## real cost of leaning on grenades is 24 points per full load-out plus a trip
## to the crate in daylight.
const GRENADE_COST := 6
## Playtest fix pass: 15 -> 10. Still above a grenade's 6 — it's a placed,
## reusable defensive tool rather than a one-shot throw — but it's fully
## recoverable (any time, not just by day — see ClaymoreConfig) and the
## carried cap is 4, not 2, so the old 15 read as punishing for something you
## get back. Capped at 4 carried; unlimited placed in the world.
const CLAYMORE_COST := 10

## Weapon-specific attachment costs (flat, not derived from weapon cost).
const FOREGRIP_COST := 12          # HK 416
const BREACHER_CHOKE_COST := 12    # SPAS-12
const EXTENDED_DRUM_COST := 25     # M249 SAW
const VARIABLE_ZOOM_COST := 25     # M110
## Was already a flat 8 as a single global unlock; same price, now bought
## per weapon instead (every laser-equipped weapon except the M110, which
## has no laser of any kind — see PROJECT_SPEC.md "Weapons").
const IR_LASER_COST := 8

## Suppressor cost rule: 2x the weapon's own price, so future weapons price
## their suppressor automatically. The M17 is the one exception — it's the
## free starter weapon, so there's no price to derive 2x from; it gets a flat
## cost instead.
const M17_SUPPRESSOR_COST := 12

func _suppressor_cost(w) -> int:
	return M17_SUPPRESSOR_COST if w.id == "m17" else w.cost * 2

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

	# --- ATTACHMENTS ---
	# Per-weapon attachments (filtered to owned weapons at display time).
	for id in Arsenal.order:
		var w = Arsenal.get_weapon(id)
		if w == null:
			continue
		items.append(_mk({
			"id": "supp_" + id, "category": "ATTACHMENTS", "kind": "attachment",
			"display_name": "%s Suppressor" % w.display_name,
			"weapon_id": id, "cost": _suppressor_cost(w), "attachment_type": "suppressor",
			"description": "Drops gunshot noise %dm → %dm." % [
				int(w.noise_unsuppressed), int(w.noise_suppressed)],
		}))

	# IR Laser: bought per weapon, same pattern as the suppressor — NOT a
	# single global unlock. The M110 has no laser of any kind (see its
	# "Weapons" spec entry), so it's excluded entirely rather than just
	# hidden — it must never appear in a laser-purchase list.
	for id in Arsenal.order:
		if id == "m110":
			continue
		var w = Arsenal.get_weapon(id)
		if w == null:
			continue
		items.append(_mk({
			"id": "ir_laser_" + id, "category": "ATTACHMENTS", "kind": "attachment",
			"display_name": "%s IR Laser" % w.display_name,
			"weapon_id": id, "cost": IR_LASER_COST, "attachment_type": "ir_laser",
			"description": "Replaces the red laser. Invisible to zombies; needs NVGs to see.",
		}))

	items.append(_mk({
		"id": "foregrip_hk416", "category": "ATTACHMENTS", "kind": "attachment",
		"display_name": "HK 416 Foregrip", "weapon_id": "hk416",
		"cost": FOREGRIP_COST, "attachment_type": "foregrip",
		"description": "Tightens the moving-fire cone. No effect standing or crouched.",
	}))
	items.append(_mk({
		"id": "choke_spas12", "category": "ATTACHMENTS", "kind": "attachment",
		"display_name": "SPAS-12 Breacher Choke", "weapon_id": "spas12",
		"cost": BREACHER_CHOKE_COST, "attachment_type": "choke",
		"description": "Wider hip-fire pattern, more forgiving up close. ADS unaffected.",
	}))
	items.append(_mk({
		"id": "drum_m249", "category": "ATTACHMENTS", "kind": "attachment",
		"display_name": "M249 Extended Drum", "weapon_id": "m249",
		"cost": EXTENDED_DRUM_COST, "attachment_type": "drum",
		"description": "200-round belt (was 100). -10% sprint speed while carried.",
	}))
	items.append(_mk({
		"id": "zoom_m110", "category": "ATTACHMENTS", "kind": "attachment",
		"display_name": "M110 Variable Zoom Optic", "weapon_id": "m110",
		"cost": VARIABLE_ZOOM_COST, "attachment_type": "zoom",
		"description": "Replaces the fixed 3x with adjustable 2x-8x (scroll wheel while ADS).",
	}))

	# --- SUPPLIES: consumables rebought every few nights ---
	# The IFAK always shows; ammo entries keep their owned-weapon filtering.
	items.append(_mk({
		"id": "ifak", "category": "SUPPLIES", "kind": "consumable",
		"display_name": "IFAK", "cost": IFAK_COST, "repeatable": true,
		"description": "Heals 40 HP over 4s. Carry up to 3.",
	}))
	for id in Arsenal.order:
		var w = Arsenal.get_weapon(id)
		if w == null:
			continue
		items.append(_mk({
			"id": "ammo_" + id, "category": "SUPPLIES", "kind": "ammo",
			"display_name": "%s Ammo" % w.display_name,
			"weapon_id": id, "cost": w.ammo_cost, "repeatable": true,
			"description": "+1 magazine (%d rounds)." % w.mag_size,
		}))

	# --- EQUIPMENT: ordnance you carry and permanently consume ---
	# Purchasable at night as well as day (playtest fix pass) — the `day_only`
	# field already IS the generic per-item opt-in the codebase uses everywhere
	# else (see the field's own doc comment on StoreItem above); the crate
	# itself has been open in both phases all along, so this is the only
	# change needed. Not day_only means "always available", not "unrestricted
	# by anything else" — the crate's own physical location is still the
	# spatial gate: you still have to walk there, exposed, at night.
	items.append(_mk({
		"id": "grenade", "category": "EQUIPMENT", "kind": "equipment",
		"display_name": "Hand Grenade", "cost": GRENADE_COST, "repeatable": true,
		"description": "4m lethal / 9m blast. Carry up to 4. Never restocked at dawn.",
	}))
	items.append(_mk({
		"id": "claymore", "category": "EQUIPMENT", "kind": "equipment",
		"display_name": "M18A1 Claymore", "cost": CLAYMORE_COST, "repeatable": true,
		"description": "Emplaced directional mine. 60° front arc, 10m. Carry 4, recoverable any time.",
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
