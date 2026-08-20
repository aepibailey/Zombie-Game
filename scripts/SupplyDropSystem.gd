extends Node
class_name SupplyDropSystem
## Runs the radio-called Supply Drop: pay, wait out the delivery delay, then
## spawn a crate on the existing fixed LZ — the resupply crate's own
## position/radius (see Main._crate_position / drop_radius), passed in via
## setup() rather than looked up, so this stays decoupled from Main.
##
## OWNS NO PICKUP CODE. SupplyDrop.gd is the exact same scene the guaranteed
## dawn drop already uses (Main._spawn_supply_drop()) — this system only
## decides WHEN one is called and WHAT it's stocked with; collection,
## partial-pickup persistence, and the LZ placement solve all live there.

const SUPPLY_DROP_ID := "supply_drop"

@export var config: SupplyDropConfig

var _player: Player
var _hud: HUD
var _radio: RadioMenu
var _lz_anchor: Vector3
var _lz_radius: float

## The SAME dictionary handed to EnablerManager.callable_enablers — Dictionary
## is a reference type in GDScript, so rewriting this entry's "cost" in
## _process() (SCALED mode only) is what the radio menu reads, with no
## menu-side change needed to keep it current.
var _entry: Dictionary

func setup(player: Player, hud: HUD, radio: RadioMenu, lz_anchor: Vector3, lz_radius: float) -> void:
	_player = player
	_hud = hud
	_radio = radio
	_lz_anchor = lz_anchor
	_lz_radius = lz_radius
	_entry = {
		"id": SUPPLY_DROP_ID,
		"display_name": "Supply Drop",
		"cost": _current_cost(),
		"call_fn": _call,
		"available_fn": _available_reason,
	}
	EnablerManager.callable_enablers.append(_entry)

func _process(_delta: float) -> void:
	if config.pricing_mode == SupplyDropConfig.PricingMode.SCALED:
		_entry["cost"] = _current_cost()

## Cooldown and the global lockout are already checked by
## EnablerManager.unavailable_reason() ahead of this — this only adds the one
## reason it doesn't know about. Multiple drops per night ARE allowed, so
## there's no "already used"/"in flight" state to report here at all.
func _available_reason() -> String:
	if GameManager.is_day():
		return "NIGHT ONLY"
	return ""

func _current_cost() -> int:
	if config.pricing_mode == SupplyDropConfig.PricingMode.FLAT:
		return config.cost
	return floori(float(_contents_value()) * config.discount_pct)

## Sum of buying the actual contents individually, at CURRENT store prices,
## for the CURRENT loadout. What both the SCALED price and the runtime
## pricing assertion are measured against.
func _contents_value() -> int:
	var total := 0
	for id in _player.owned_weapons():
		var w = Arsenal.get_weapon(id)
		if w:
			total += w.ammo_cost * config.mags_per_weapon
	total += StoreCatalog.GRENADE_COST * config.grenades_per_crate
	total += StoreCatalog.IFAK_COST * config.ifaks_per_crate
	return total

func _call() -> void:
	# Re-checked rather than trusted from selection time — the menu closed
	# several seconds ago and the phase or cooldown may have changed since.
	if _available_reason() != "" or EnablerManager.cooldown_left(SUPPLY_DROP_ID) > 0.0 \
			or EnablerManager.global_lockout_left() > 0.0:
		return

	var cost := _current_cost()
	var value := _contents_value()
	# RUNTIME ASSERTION, same spirit as Arsenal's HK416 > M17 damage
	# invariant: a crate must always be a strictly better deal than buying
	# its contents piece by piece, under EITHER pricing mode, checked on
	# every call — not trusted to stay true as prices get retuned later.
	assert(cost < value,
		"SUPPLY DROP PRICING INVARIANT VIOLATED: charged %d pts but the contents are worth %d pts individually — a crate must always cost strictly less than buying its contents piece by piece." % [cost, value])
	if cost >= value:
		push_error("SUPPLY DROP PRICING INVARIANT VIOLATED: charged %d pts but contents are worth %d pts (mode=%s)." % [
			cost, value,
			"FLAT" if config.pricing_mode == SupplyDropConfig.PricingMode.FLAT else "SCALED"])

	if not PointsManager.spend_points(cost):
		_hud.show_message("Not enough points for Supply Drop.")
		return

	# Independent cooldown AND the shared 10s global lockout, from the one
	# call every other enabler uses.
	EnablerManager.start_cooldown(SUPPLY_DROP_ID, config.cooldown)
	_radio.commit_transmission()

	# Snapshotted HERE, at call time — not at delivery or at pickup — because
	# "computed at call time from current loadout" is the whole point of
	# tying a drop to what you were carrying when you called it in, not to
	# whatever you happen to own by the time it lands or gets looted.
	var mags_by_weapon := {}
	for id in _player.owned_weapons():
		mags_by_weapon[id] = config.mags_per_weapon
	var contents := {
		"magazines_by_weapon": mags_by_weapon,
		"grenades": config.grenades_per_crate,
		"ifaks": config.ifaks_per_crate,
	}

	_hud.show_message("SUPPLY DROP — SHOT, OVER. Wheels down in %ds." % int(round(config.delay)))
	print("[SUPPLYDROP] called — cost %d pts (contents worth %d), %s" % [cost, value, contents])
	_run_delivery(contents)

## Fire-and-forget from _call() — the coroutine runs independently, same
## pattern as FireMissionSystem._run_mission(). Guarded on
## is_instance_valid(self) after the await so a scene teardown mid-delay
## can't resume into a freed node.
func _run_delivery(contents: Dictionary) -> void:
	await get_tree().create_timer(config.delay).timeout
	if not is_instance_valid(self):
		return
	var drop := SupplyDrop.new()
	drop.setup(_hud, contents)
	# Parented to the CURRENT SCENE, not to this system — same reasoning as
	# WhitePhosphorusZone: the crate is a fixture that outlives nothing in
	# particular and must not move or free with anything else. It persists
	# until looted, not until sunrise.
	get_tree().current_scene.add_child(drop)
	drop.global_position = SupplyDrop.find_spawn_point(
		get_tree().root.world_3d, _lz_anchor, _lz_radius, _player.global_position)
	_hud.show_message("SUPPLY DROP — ON THE LZ.")
	print("[SUPPLYDROP] landed at %s" % drop.global_position)
