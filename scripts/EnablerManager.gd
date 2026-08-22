extends Node
## Radio enabler call-flow support (autoload).
##
## RESPONSIBLE FOR: per-enabler cooldowns, the shared global radio lockout,
## and `callable_enablers` — the registry RadioMenu renders. NOT responsible
## for ownership: whether the player HAS an item (the radio, a weapon, an
## enabler) is answered exclusively by Player.owns_item_id(). If a future
## enabler needs individual ownership rather than just radio-gated access, it
## goes through that with its own item id — do not rebuild a second registry
## here.

## Radio-callable transmissions, in menu display order. Six real entries
## register here today: the 120mm mortar and shake-and-bake (FireMissionSystem),
## UAV Overwatch (UAVSystem), Supply Drop (SupplyDropSystem), and the Apache
## patrol box (ApacheSystem). RadioMenu iterates this directly and renders
## "No transmissions available" when it's empty, rather than the menu being
## hardcoded to show nothing.
##
## Deliberately a plain Dictionary, not an EnablerType resource — see
## RadioMenu._build_row() for the duck-typed read. Shape:
##   {
##     "id": String,             # cooldown key, must be unique
##     "display_name": String,
##     "cost": int,
##     "call_fn": Callable,      # invoked on selection; owns its own flow
##     "available_fn": Callable, # -> String; "" = selectable, else the
##                               #    greyed-out reason shown in the row
##   }
## `call_fn` and `available_fn` are optional — an entry without them is
## treated as always-available and a no-op on select.
var callable_enablers: Array = []

# --- Cooldowns -------------------------------------------------------------
## INDEPENDENT per-enabler cooldowns, keyed by enabler id. Deliberately NOT a
## shared pool: a shared pool means calling a UAV locks out fire support,
## which pushes the player to hoard the radio rather than use it.
var _cooldowns: Dictionary = {}   # enabler id -> seconds remaining

## The one thing that IS global: a short lockout after any transmission, so
## three calls can't be chained back to back. "You are still on the handset",
## distinct from and much shorter than any per-enabler cooldown.
@export var global_radio_lockout: float = 10.0
var _global_lockout_remaining := 0.0

func _process(delta: float) -> void:
	if _global_lockout_remaining > 0.0:
		_global_lockout_remaining = maxf(0.0, _global_lockout_remaining - delta)
	if _cooldowns.is_empty():
		return
	for id in _cooldowns.keys():
		var left: float = _cooldowns[id] - delta
		if left <= 0.0:
			_cooldowns.erase(id)
		else:
			_cooldowns[id] = left

## Seconds left on this enabler's own cooldown. 0 = ready.
func cooldown_left(id: String) -> float:
	return _cooldowns.get(id, 0.0)

## Start an enabler's cooldown AND the global lockout. Called once a call has
## actually committed — not on menu selection, since a cancelled paint must
## consume neither.
func start_cooldown(id: String, seconds: float) -> void:
	if seconds > 0.0:
		_cooldowns[id] = seconds
	_global_lockout_remaining = global_radio_lockout

## Seconds left on the global handset lockout. 0 = clear.
func global_lockout_left() -> float:
	return _global_lockout_remaining

## Why this enabler can't be called right now, or "" if it can. Cooldowns are
## checked here so every caller (menu rendering AND selection) gets the same
## answer from one place; per-enabler `available_fn` reasons stack on top.
func unavailable_reason(entry: Dictionary) -> String:
	var id: String = entry.get("id", "")
	var cd := cooldown_left(id)
	if cd > 0.0:
		return "%ds" % int(ceil(cd))
	if _global_lockout_remaining > 0.0:
		return "RADIO %ds" % int(ceil(_global_lockout_remaining))
	var fn = entry.get("available_fn")
	if fn is Callable and (fn as Callable).is_valid():
		return str((fn as Callable).call())
	return ""
