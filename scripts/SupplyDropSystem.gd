extends Node
class_name SupplyDropSystem
## Runs the radio-called, player-designated Supply Drop: call → paint the LZ →
## pay → delay → visible descent → lootable crate.
##
## OWNS NO PICKUP, DESIGNATION, DESCENT OR DAMAGE CODE. It consumes four
## existing systems and adds none: TargetPainter for the LZ, SupplyDrop for
## the crate and its partial-pickup rules, SupplyCrateDescent for the fall,
## and AreaDamageSystem for the optional crush. This script decides only WHEN
## a drop happens, WHERE it ends up, and WHAT is in it.

const SUPPLY_DROP_ID := "supply_drop"

## How many scattered candidates to try before walking inward toward the
## painted point. See _resolve_landing().
const SCATTER_ATTEMPTS := 12
## Inward retry steps between the scatter ring and the painted point itself.
const INWARD_STEPS := 4

@export var config: SupplyDropConfig

var _player: Player
var _hud: HUD
var _radio: RadioMenu
var _painter: TargetPainter
## The fixed LZ pad — now a LAST-RESORT FALLBACK only, never the default
## destination. Supplied by Main (the resupply crate's own position/radius).
var _pad_anchor: Vector3
var _pad_radius: float

func setup(player: Player, hud: HUD, radio: RadioMenu, painter: TargetPainter,
		pad_anchor: Vector3, pad_radius: float) -> void:
	_player = player
	_hud = hud
	_radio = radio
	_painter = painter
	_pad_anchor = pad_anchor
	_pad_radius = pad_radius
	_validate_pricing()
	EnablerManager.callable_enablers.append({
		"id": SUPPLY_DROP_ID,
		"display_name": "Supply Drop",
		"cost": config.supply_drop_cost,
		"call_fn": _begin_paint,
		"available_fn": _available_reason,
	})

# --- Pricing -----------------------------------------------------------------
## Sum of buying `weapon_ids`' worth of crate contents individually, at
## current store prices. The measuring stick for the whole price curve.
func _bundle_value(weapon_ids: Array) -> int:
	var total := 0
	for id in weapon_ids:
		var w = Arsenal.get_weapon(id)
		if w:
			total += w.ammo_cost * config.mags_per_weapon
	total += StoreCatalog.GRENADE_COST * config.grenades_per_crate
	total += StoreCatalog.IFAK_COST * config.ifaks_per_crate
	return total

## TWO-SIDED PRICE-CURVE INVARIANT, in the spirit of Arsenal's HK416 > M17
## damage invariant. The crate must be a BAD buy at one weapon owned and a
## GOOD buy at four — that inversion IS the mechanic, so both ends are
## asserted, not just the late-game one.
##
## Checked against the WORST CASE on each side rather than one arbitrary
## loadout: the DEAREST single weapon must still be cheaper to resupply
## piecemeal, and the CHEAPEST four-weapon set must still be dearer. A
## loadout-specific check could pass on a lucky combination while the curve
## was already broken for another.
func _validate_pricing() -> void:
	var cost: int = config.supply_drop_cost
	var worst_single := _worst_case_bundle(1)
	var best_four := _worst_case_bundle(4)

	assert(cost > worst_single,
		"SUPPLY DROP PRICE CURVE VIOLATED (early game): cost %d is not ABOVE the dearest single-weapon bundle %d. The crate must be a bad buy at one weapon owned — if it is ever a good deal early, the mechanic is broken." % [cost, worst_single])
	assert(cost < best_four,
		"SUPPLY DROP PRICE CURVE VIOLATED (late game): cost %d is not BELOW the cheapest four-weapon bundle %d. The crate must be a strong buy at four weapons owned." % [cost, best_four])
	if cost <= worst_single or cost >= best_four:
		push_error("SUPPLY DROP PRICE CURVE VIOLATED: cost %d must satisfy %d < cost < %d (dearest bundle(1) < cost < cheapest bundle(4))." % [
			cost, worst_single, best_four])

## The bundle value that binds the invariant at `count` weapons owned: the
## MAXIMUM over all combinations for count 1 (the price must beat even the
## dearest single), the MINIMUM for larger counts (the price must lose to
## even the cheapest set).
func _worst_case_bundle(count: int) -> int:
	var combos := _combinations(Arsenal.order, count)
	if combos.is_empty():
		return _bundle_value([])
	var best: int = _bundle_value(combos[0])
	for c in combos:
		var v := _bundle_value(c)
		if count <= 1:
			best = maxi(best, v)
		else:
			best = mini(best, v)
	return best

## All `count`-sized combinations of `items`. Small and non-recursive-hot —
## the arsenal is 5 weapons, so this is at most 10 combinations.
func _combinations(items: Array, count: int) -> Array:
	var out: Array = []
	if count <= 0 or count > items.size():
		return out
	var idx: Array[int] = []
	for i in count:
		idx.append(i)
	while true:
		var combo: Array = []
		for i in idx:
			combo.append(items[i])
		out.append(combo)
		# Odometer step from the rightmost index that can still advance.
		var pos := count - 1
		while pos >= 0 and idx[pos] == items.size() - count + pos:
			pos -= 1
		if pos < 0:
			break
		idx[pos] += 1
		for j in range(pos + 1, count):
			idx[j] = idx[j - 1] + 1
	return out

# --- Availability -------------------------------------------------------------
## Cooldown and the global lockout are already answered by
## EnablerManager.unavailable_reason() before this is consulted. Multiple
## drops per night ARE allowed, so there is no per-night state here.
func _available_reason() -> String:
	if GameManager.is_day():
		return "NIGHT ONLY"
	return ""

# --- Call flow ----------------------------------------------------------------
## Selection opens LZ designation. NOTHING is charged here — see _on_painted.
##
## FIRST OF TWO TRANSMISSIONS. Keying the mic to request the drop is itself a
## broadcast, so entering designation emits the standard pulse even if the
## player then cancels. That is deliberate and is the one asymmetry with the
## mortar (which is silent until commit): you have already told someone you
## want a crate. The noise lives here, in the consumer, NOT in TargetPainter —
## which is why the mortar stays a one-pulse enabler with no branch anywhere.
func _begin_paint() -> void:
	if _available_reason() != "":
		return
	_radio.commit_transmission()
	_hud.show_message("SUPPLY DROP — SEND YOUR LZ, OVER.")
	_painter.begin(config.landing_scatter_radius, 0.0,
		_on_painted, _on_paint_cancelled)

## Cancelling costs nothing: no points, no cooldown. The entry pulse already
## went out and is NOT retroactively silenced — the mic was already keyed.
func _on_paint_cancelled() -> void:
	_hud.show_message("SUPPLY DROP — CANCELLED.")

## THE COMMIT POINT. Everything the player pays happens here.
func _on_painted(point: Vector3) -> void:
	# Re-checked rather than trusted from selection time: the player spent
	# several seconds aiming, and the phase or another call may have moved on.
	if _available_reason() != "" or EnablerManager.cooldown_left(SUPPLY_DROP_ID) > 0.0:
		_hud.show_message("Supply Drop unavailable.")
		return

	var cost: int = config.supply_drop_cost
	var value := _bundle_value(_player.owned_weapons())
	if not PointsManager.spend_points(cost):
		_hud.show_message("Not enough points for Supply Drop.")
		return

	EnablerManager.start_cooldown(SUPPLY_DROP_ID, config.supply_drop_cooldown)
	# SECOND TRANSMISSION: confirming the LZ is a separate broadcast from
	# requesting the drop. Two transmissions, two noise events.
	_radio.commit_transmission()

	# Contents snapshotted at CONFIRM, not at delivery or at pickup — the drop
	# is tied to what you were carrying when you called it in.
	var mags_by_weapon := {}
	for id in _player.owned_weapons():
		mags_by_weapon[id] = config.mags_per_weapon
	var contents := {
		"magazines_by_weapon": mags_by_weapon,
		"grenades": config.grenades_per_crate,
		"ifaks": config.ifaks_per_crate,
	}

	_hud.show_message("SUPPLY DROP — LZ COPIED. Wheels down in %ds." % int(round(config.supply_drop_delay)))
	print("[SUPPLYDROP] called at (%.1f, %.1f, %.1f) — cost %d, contents worth %d (%d weapons)" % [
		point.x, point.y, point.z, cost, value, _player.owned_weapons().size()])
	_run_delivery(point, contents)

# --- Delivery -----------------------------------------------------------------
## Guarded on is_instance_valid(self) after each await so a scene teardown
## mid-delivery can't resume into a freed node — same pattern as
## FireMissionSystem._run_mission().
func _run_delivery(painted: Vector3, contents: Dictionary) -> void:
	await get_tree().create_timer(config.supply_drop_delay).timeout
	if not is_instance_valid(self):
		return
	var landing := _resolve_landing(painted)
	_hud.show_message("SUPPLY DROP — INBOUND, CHUTE OUT.")
	SupplyCrateDescent.spawn(get_tree().current_scene, landing, config.descent_time,
		func(): _on_crate_landed(landing, contents))

func _on_crate_landed(landing: Vector3, contents: Dictionary) -> void:
	if not is_instance_valid(self):
		return
	# Optional, OFF by default. Routed through the shared system with an
	# authored profile — no damage code exists in this file.
	if config.crate_crush_damage_enabled and config.crush_profile:
		AreaDamageSystem.detonate(landing + Vector3(0.0, 0.3, 0.0),
			config.crush_profile, Vector3.ZERO, "supply crate")

	var drop := SupplyDrop.new()
	drop.setup(_hud, contents)
	# Parented to the CURRENT SCENE, not to this system: the crate persists
	# until looted — through sunrise, through further drops — and must not
	# free with anything else.
	get_tree().current_scene.add_child(drop)
	drop.global_position = landing
	_hud.show_message("SUPPLY DROP — ON THE DECK.")
	print("[SUPPLYDROP] landed at (%.1f, %.1f, %.1f)" % [landing.x, landing.y, landing.z])

## Where the crate actually ends up, in descending order of preference:
##   1. a scattered point within landing_scatter_radius of the painted point
##   2. progressively further INWARD toward the painted point
##   3. the painted point itself
##   4. the fixed LZ pad — FALLBACK ONLY, never the default
##
## Every candidate is snapped to the navmesh and then checked for clearance,
## so the crate can never end up inside a structure or inside the player.
func _resolve_landing(painted: Vector3) -> Vector3:
	var world := get_tree().root.world_3d
	for i in SCATTER_ATTEMPTS:
		var ang := randf() * TAU
		var r: float = sqrt(randf()) * config.landing_scatter_radius
		var c := painted + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		var resolved = _try_candidate(world, c)
		if resolved != null:
			return resolved as Vector3

	# Walk inward: same bearing family, shrinking radius, so a crate called
	# into a tight courtyard converges on the point the player actually meant
	# rather than giving up and flying home.
	for step in range(INWARD_STEPS, 0, -1):
		var frac: float = float(step) / float(INWARD_STEPS + 1)
		var ang := randf() * TAU
		var c := painted + Vector3(cos(ang), 0.0, sin(ang)) * config.landing_scatter_radius * frac
		var resolved = _try_candidate(world, c)
		if resolved != null:
			return resolved as Vector3

	var exact = _try_candidate(world, painted)
	if exact != null:
		return exact as Vector3

	# Last resort. The pad exists so a drop is never simply lost, not as a
	# destination the player is steered toward.
	push_warning("[SUPPLYDROP] no clear landing near the painted LZ — falling back to the pad")
	return SupplyDrop.find_spawn_point(world, _pad_anchor, _pad_radius,
		_player.global_position)

## A candidate is usable if it snaps onto the navmesh close by, has real
## ground under it, and its volume is clear of geometry and of the player.
## Returns the resolved ground position, or null.
func _try_candidate(world: World3D, candidate: Vector3) -> Variant:
	var snapped := TargetPainter.snap_to_navmesh(world, candidate)
	if not TargetPainter.point_on_navmesh(world, snapped, _painter.config.navmesh_tolerance):
		return null
	var space := world.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		snapped + Vector3(0.0, 6.0, 0.0), snapped - Vector3(0.0, 3.0, 0.0))
	q.collision_mask = Obstacle.SOLID_SURFACE_MASK
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return null
	var ground: Vector3 = hit.position
	if hit.normal.dot(Vector3.UP) < 0.85:
		return null   # too steep for a crate to sit on
	# Never inside the player. Reuses SupplyDrop's own minimum, so "too close
	# to stand" means one thing for both spawn paths.
	if ground.distance_to(_player.global_position) < SupplyDrop.MIN_PLAYER_DISTANCE:
		return null
	if SupplyDrop.volume_blocked(space, ground + Vector3(0.0, 0.45, 0.0)):
		return null
	return ground
