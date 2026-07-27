extends Node
## Single source of truth for RESERVE (un-loaded) ammunition, per weapon.
##
## Everything that grants ammo — starting loadout, crate purchases, and future
## supply drops / enablers — must go through `grant_ammo()`. Nothing else may
## write to the reserve pools. The currently-loaded magazine lives on the
## Player; this manager owns everything behind it.

signal reserve_changed(weapon_id: String, rounds: int)

var _reserve: Dictionary = {}   # weapon id -> rounds in reserve

## Grant whole magazines of a weapon's ammo. Returns the rounds actually added.
## THE single entry point for handing out ammo.
func grant_ammo(weapon_id: String, magazines: int) -> int:
	var w = Arsenal.get_weapon(weapon_id)
	if w == null or magazines <= 0:
		return 0
	var rounds: int = w.mag_size * magazines
	_reserve[weapon_id] = get_reserve(weapon_id) + rounds
	reserve_changed.emit(weapon_id, _reserve[weapon_id])
	return rounds

func get_reserve(weapon_id: String) -> int:
	return _reserve.get(weapon_id, 0)

## Pull up to `rounds` out of reserve (used by reloads). Returns what was taken.
func take(weapon_id: String, rounds: int) -> int:
	var have: int = get_reserve(weapon_id)
	var taken: int = mini(have, maxi(0, rounds))
	_reserve[weapon_id] = have - taken
	reserve_changed.emit(weapon_id, _reserve[weapon_id])
	return taken

## Wipe all reserves (new game / full reset). Not called between nights —
## ammo deliberately does NOT regenerate at dawn.
func reset() -> void:
	_reserve.clear()
