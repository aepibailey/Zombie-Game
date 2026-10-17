extends Node
## Headless table tests: the numbers the specs work out by hand, checked
## against the live functions that produce them. Run with:
##   godot --headless res://tools/table_tests.tscn
## Exit code is 0 on all-pass, 1 on any failure, so CI can gate on it.
##
## RUN AS A SCENE, NEVER VIA --script — same reason as smoke_test.gd: without
## autoloads the project's own scripts do not compile.
##
## Each section names the prose table it pins. The expected values are the
## table's, so a failure means the code and the doc disagree — decide which is
## right; do not just copy the new number in. Where the live code has already
## moved away from a spec table, the CODE's numbers are pinned and the section
## says so.
##
## No world is built. Main is constructed but never added to the tree, so its
## _ready() (map, navmesh, wave) never runs; only its pure functions are
## called. The one exception is a single inactive, effectively unkillable
## zombie, so per-hit damage comes from the real Zombie.take_damage() —
## rounding and headshot order included — instead of a copy of its formula.

const EPS := 0.001

## If anything below throws, _ready() aborts before quit() and the run would
## sit until CI's 60s timeout. This turns that into a fast, loud failure.
const WATCHDOG_SEC := 10.0

var _failures: Array[String] = []
var _main: Node
var _main_script: GDScript
var _dummy: Zombie

func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SEC).timeout.connect(_on_watchdog)
	_main_script = load("res://scripts/Main.gd")
	_main = _main_script.new()
	_dummy = load("res://scenes/Zombie.tscn").instantiate()
	_dummy.zombie_type = load("res://resources/zombie_walker.tres")
	_dummy.max_hp = 1_000_000_000
	add_child(_dummy)

	var saved_night: int = GameManager.night_number
	for section in [
		_test_zombie_hp,
		_test_hp_curve,
		_test_max_alive,
		_test_night_types,
		_test_fighter_gate,
		_test_rank,
		_test_night_pool,
		_test_spawn_interval,
		_test_leaper_fraction,
		_test_falloff,
		_test_spas_one_shot,
		_test_headshots_to_kill,
		_test_416_beats_m17_everywhere,
		_test_leap_ballistics,
		_test_supply_drop_pricing,
	]:
		_run_section(section)
	GameManager.night_number = saved_night

	_main.free()
	_report()

## A runtime error in GDScript aborts only the function it happens in; the
## caller carries on. Without this, a section that throws halfway would skip
## the rest of its checks and the run would still report ALL PASS. Every
## section returns true as its last statement, so anything else means it died.
func _run_section(section: Callable) -> void:
	if section.call() != true:
		_check(false, "%s aborted before finishing (see SCRIPT ERROR above)" % section.get_method())

func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  %s" % label)
	else:
		_failures.append(label)
		print("  FAIL  %s" % label)

func _near(a: float, b: float, label: String) -> void:
	_check(absf(a - b) < EPS, "%s (got %.4f, want %.4f)" % [label, a, b])

func _eq(a, b, label: String) -> void:
	_check(a == b, "%s (got %s, want %s)" % [label, a, b])

## Damage the real take_damage() deals for one hit. The dummy has a billion HP
## and is never activated, so it never dies and never enters chase.
func _hit(weapon: WeaponData, distance: float, headshot: bool) -> int:
	return _dummy.take_damage(DamageInfo.bullet(weapon.body_damage, headshot, weapon.damage_mult_at(distance)))

func _shots_to_kill(hp: int, per_hit: int) -> int:
	return ceili(float(hp) / float(per_hit))

func _hp_on_night(night: int, base: int = 100) -> int:
	GameManager.night_number = night
	return _main._zombie_hp_for_type(base)

# --- PROJECT_SPEC.md "Zombie health scaling" -----------------------------------
func _test_zombie_hp() -> bool:
	print("[TABLE] zombie HP per night (PROJECT_SPEC.md \"Zombie health scaling\")")
	for row in [[1, 100], [2, 100], [3, 108], [4, 108], [5, 116], [6, 116],
			[9, 132], [10, 132]]:
		_eq(_hp_on_night(row[0]), row[1], "night %d walker HP" % row[0])
	# The step is absolute, not proportional (Main.hp_for_night()).
	_eq(_hp_on_night(3, 60), 68, "night 3 leaper HP (60 base + 8)")
	return true

# --- docs/RUN_STRUCTURE.md "Escalation" + Prompt A phase 1 -----------------------
## Past hp_linear_until_night, HP compounds on the variant's own night-10
## value. Walker rows are Prompt A's table; leaper rows follow from the same
## rule on 92 (60 + 8 x 4), which is "leapers keep their current scaling
## through night 10".
func _test_hp_curve() -> bool:
	print("[TABLE] HP curve (docs/RUN_STRUCTURE.md \"Escalation\", Prompt A phase 1)")
	for row in [[1, 100], [10, 132], [11, 140], [15, 177], [20, 236], [30, 423], [50, 1358]]:
		_eq(_hp_on_night(row[0]), row[1], "night %d walker HP" % row[0])
	for row in [[10, 92], [11, 98], [15, 123], [20, 165], [30, 295]]:
		_eq(_hp_on_night(row[0], 60), row[1], "night %d leaper HP" % row[0])
	return true

## Max alive with no night type: the base before night 10, +2 every 5 nights
## from it, the 32 ceiling last.
func _test_max_alive() -> bool:
	print("[TABLE] max alive, no night type (Prompt A phase 1)")
	for row in [[1, 20], [9, 20], [10, 20], [14, 20], [15, 22], [20, 24], [40, 32], [60, 32]]:
		_eq(_main_script.max_alive_for_night(row[0], _main.max_alive_base, _main.max_alive_step,
			_main.max_alive_step_every, _main.max_alive_step_start_night, _main.max_alive_ceiling),
			row[1], "night %d max alive" % row[0])
	return true

# --- Prompt A phase 2: night types (docs/RUN_STRUCTURE.md "Night-by-night table") --
## The schedule, then each override through the SAME functions the spawner
## uses: the profile's apply_* helpers, Main.max_alive_for_night() with the
## profile's bonus/override, and Main._night_hp_for_type().
func _test_night_types() -> bool:
	print("[TABLE] night types (Prompt A phase 2)")
	var NT := GameManager.NightType
	for row in [[5, NT.SWARM], [9, NT.TRANSIT], [10, NT.HUNTERS], [12, NT.NORMAL],
			[15, NT.SWARM], [20, NT.SIEGE], [25, NT.TRANSIT],
			[30, NT.HUNTERS], [35, NT.SWARM], [40, NT.SIEGE], [45, NT.HUNTERS], [50, NT.SWARM]]:
		_eq(GameManager.night_type_name(row[0]), NT.keys()[row[1]], "night %d type" % row[0])
	_check(GameManager.get_night_profile(9) == GameManager.siege_profile, "night 9 TRANSIT plays as Siege")
	_check(GameManager.get_night_profile(25) == GameManager.siege_profile, "night 25 TRANSIT plays as Siege")
	_eq(GameManager.get_night_profile(12).id, "normal", "night 12 profile")
	_eq(GameManager.get_night_profile(31).id, "normal", "night 31 profile (between cycle nights)")

	for row in [[9, 45], [10, 17], [20, 95], [30, 47], [12, 39], [5, 18]]:
		var base: int = _main_script.pool_for_night(row[0], _main.base_spawn, _main.spawn_per_night)
		_eq(GameManager.get_night_profile(row[0]).apply_pool(base), row[1],
			"night %d pool before carryover" % row[0])

	for row in [[9, 28], [10, 8], [20, 32], [25, 32], [15, 22], [12, 20]]:
		var p: NightTypeProfile = GameManager.get_night_profile(row[0])
		_eq(_main_script.max_alive_for_night(row[0], _main.max_alive_base, _main.max_alive_step,
			_main.max_alive_step_every, _main.max_alive_step_start_night, _main.max_alive_ceiling,
			p.max_alive_bonus, p.max_alive_override), row[1], "night %d max alive" % row[0])

	for row in [[10, 264], [15, 142], [30, 846], [5, 93], [12, 148], [20, 236]]:
		GameManager.night_number = row[0]
		_eq(_main._night_hp_for_type(100), row[1], "night %d walker HP with type" % row[0])
	GameManager.night_number = 10
	_eq(_main._night_hp_for_type(60), 184, "night 10 Hunters leaper HP (92 x 2)")

	for row in [[5, 0.70], [15, 0.70], [9, 0.30], [12, 0.30], [4, 0.10]]:
		GameManager.night_number = row[0]
		_near(_main._night_leaper_fraction(), row[1], "night %d leaper share with type" % row[0])

	var hunters: NightTypeProfile = GameManager.hunters_profile
	_eq([hunters.apply_points(1), hunters.apply_points(3), hunters.apply_points(5)], [2, 6, 10],
		"Hunters doubles kill awards")
	_eq(GameManager.normal_profile.apply_points(3), 3, "Normal leaves kill awards alone")
	_check(GameManager.siege_profile.has_spawn_arc() and not GameManager.normal_profile.has_spawn_arc(),
		"Siege has a spawn arc, Normal the full ring")
	return true

# --- Prompt A phase 3: positions and the fighter gate ---------------------------
## Recruit prices by live count: 4 granted at Position Two, then 20/35/55/80
## for fighters 5-8, and a replacement below 4 costs 20 — nothing is free here.
func _test_fighter_gate() -> bool:
	print("[TABLE] fighter gate (Prompt A phase 3)")
	var econ: FighterEconomyConfig = load("res://resources/fighter_economy.tres")
	_eq(GameManager.position_transit_nights, [9, 25] as Array[int], "transit nights")
	_eq(econ.fighters_unlock_position, 2, "roster unlocks at Position Two")
	_eq(econ.free_fighter_count, 4, "Position Two grants 4")
	_eq(econ.free_fighter_count + econ.recruit_costs.size(), FighterEconomyConfig.FIGHTER_CAP,
		"grant + priced recruits fill the cap")
	var got := []
	for live in FighterEconomyConfig.FIGHTER_CAP:
		got.append(econ.recruit_cost(live))
	_eq(got, [20, 20, 20, 20, 20, 35, 55, 80], "recruit cost for 0..7 alive")
	return true

# --- Prompt A phase 4: the rank on game over -------------------------------------
## Keyed by nights SURVIVED (GameOverPanel.nights_survived): dying during night
## 15 is 14 survived, still Overrun; dying in the Day after it is Held the Line.
func _test_rank() -> bool:
	print("[TABLE] game-over rank (Prompt A phase 4)")
	var ranks: Dictionary = _main.rank_thresholds
	for row in [[0, "Overrun"], [14, "Overrun"], [15, "Held the Line"], [29, "Held the Line"],
			[30, "Veteran"], [49, "Veteran"], [50, "Legend"], [80, "Legend"]]:
		_eq(GameOverPanel.rank_for(row[0], ranks), row[1], "%d nights survived" % row[0])
	_eq(GameOverPanel.nights_survived(15, false), 14, "dying during night 15 survives 14")
	_eq(GameOverPanel.nights_survived(15, true), 15, "dying in the Day after night 15 survives 15")
	_eq(GameOverPanel.rank_for(GameOverPanel.nights_survived(15, false), ranks), "Overrun",
		"died on night 15: Overrun")
	return true

# --- PROJECT_SPEC.md "Night scaling" ------------------------------------------
## Pool before carryover, at Main's real exported defaults, over the same
## nights 1–21 the HP and headshot tables cover. Nights 1/3/5/10 are also the
## pools the spawn-interval rows below assume.
func _test_night_pool() -> bool:
	print("[TABLE] night pool (PROJECT_SPEC.md \"Night scaling\" / \"Economy\")")
	for row in [[1, 6], [2, 9], [3, 12], [4, 15], [5, 18], [8, 27], [10, 33], [21, 66]]:
		_eq(_main_script.pool_for_night(row[0], _main.base_spawn, _main.spawn_per_night), row[1],
			"night %d pool" % row[0])
	return true

## Intervals for the pools above (no carryover).
func _test_spawn_interval() -> bool:
	print("[TABLE] spawn interval (PROJECT_SPEC.md \"Night scaling\")")
	_near(GameManager.NIGHT_LENGTH, 120.0, "table assumes 120s nights")
	for row in [[1, 6, 15.0], [3, 12, 7.5], [5, 18, 5.0], [10, 33, 90.0 / 33.0]]:
		_near(_main._compute_spawn_interval(row[1]), row[2],
			"night %d interval (pool %d)" % [row[0], row[1]])
	_near(_main._compute_spawn_interval(1), _main.spawn_interval_max, "tiny pool clamps to max")
	_near(_main._compute_spawn_interval(1000), _main.spawn_interval_min, "huge pool clamps to min")
	_near(_main._compute_spawn_interval(0), _main.spawn_interval_max, "empty pool returns max")
	return true

# --- Main.leaper_fraction_for_night() doc comment ------------------------------
func _test_leaper_fraction() -> bool:
	print("[TABLE] leaper share per night (Main.leaper_fraction_for_night)")
	for row in [[1, 0.0], [3, 0.0], [4, 0.10], [5, 0.15], [7, 0.25], [8, 0.30],
			[9, 0.30], [30, 0.30]]:
		_near(_main.leaper_fraction_for_night(row[0]), row[1], "night %d" % row[0])
	return true

# --- PROJECT_SPEC.md "Damage falloff" ------------------------------------------
## SPAS-12, M249 and M110 match the spec table. The M17 and HK 416 do NOT:
## the table still says M17 25m → 0.70@60 → 0.50@100 and 416 30m → 0.85@85,
## but Arsenal.gd ships the M17 on the simple model (full to 15m, 0.40 at 40m)
## and the 416 with no falloff at all. These rows pin the code.
func _test_falloff() -> bool:
	print("[TABLE] damage falloff (PROJECT_SPEC.md \"Damage falloff\"; M17/416 pin Arsenal.gd)")
	var rows := {
		"m17": [[0.0, 1.0], [15.0, 1.0], [27.5, 0.70], [35.0, 0.52], [40.0, 0.40], [100.0, 0.40]],
		"hk416": [[0.0, 1.0], [85.0, 1.0], [200.0, 1.0]],
		"spas12": [[10.0, 1.0], [12.0, 0.88], [20.0, 0.40], [30.0, 0.15], [40.0, 0.15]],
		"m249": [[30.0, 1.0], [57.5, 0.90], [85.0, 0.80], [120.0, 0.80]],
		"m110": [[0.0, 1.0], [250.0, 1.0]],
	}
	for id in rows:
		var w: WeaponData = Arsenal.get_weapon(id)
		for row in rows[id]:
			_near(w.damage_mult_at(row[0]), row[1], "%s at %.1fm" % [id, row[0]])
	# Structural, every weapon: falloff never rises with distance.
	for id in Arsenal.order:
		var w: WeaponData = Arsenal.get_weapon(id)
		var prev := w.damage_mult_at(0.0)
		var ok := true
		var d := 0.25
		while d <= w.max_range:
			var m := w.damage_mult_at(d)
			if m > prev + EPS:
				ok = false
			prev = m
			d += 0.25
		_check(ok, "%s falloff never increases with range" % id)
	return true

# --- PROJECT_SPEC.md "SPAS-12 close-range lethality" ---------------------------
func _test_spas_one_shot() -> bool:
	print("[TABLE] SPAS-12 pellets (PROJECT_SPEC.md \"SPAS-12 close-range lethality\")")
	var spas: WeaponData = Arsenal.get_weapon("spas12")
	var pellet := _hit(spas, 7.0, false)
	_eq(pellet * 9, 198, "9 pellets at point blank")
	_check(pellet * 5 >= _hp_on_night(1), "5 body pellets one-shot a night-1 zombie")
	_check(pellet * 6 >= _hp_on_night(10), "6 body pellets one-shot a night-10 zombie")
	return true

# --- PATROL_BASE_ZERO_V2_SPEC.md §4.4 headshot shots-to-kill table ----------
## Nights 1-10 are §4.4's own rows. From night 11 the CODE's numbers are
## pinned: §4.4 was written for the linear HP formula, and HP now compounds
## after night 10 (docs/RUN_STRUCTURE.md). §4.4's derivation of the 416's 66
## is unaffected — its binding case is the 132 HP of nights 9-10.
func _test_headshots_to_kill() -> bool:
	print("[TABLE] headshots to kill (V2_SPEC §4.4)")
	var m17: WeaponData = Arsenal.get_weapon("m17")
	var hk: WeaponData = Arsenal.get_weapon("hk416")
	_eq(_hit(m17, 10.0, true), 68, "M17 headshot at 10m")
	_eq(_hit(m17, 35.0, true), 35, "M17 headshot at 35m")
	_eq(_hit(hk, 0.0, true), 132, "416 headshot at 0m")
	_eq(_hit(hk, 150.0, true), 132, "416 headshot at 150m")
	# night, HP, M17 @10m, M17 @35m, 416
	var table := [
		[1, 100, 2, 3, 1], [3, 108, 2, 4, 1], [5, 116, 2, 4, 1], [7, 124, 2, 4, 1],
		[9, 132, 2, 4, 1], [11, 140, 3, 4, 2], [13, 157, 3, 5, 2], [15, 177, 3, 6, 2],
		[17, 198, 3, 6, 2], [19, 223, 4, 7, 2], [21, 251, 4, 8, 2],
	]
	for row in table:
		var hp := _hp_on_night(row[0])
		_eq(hp, row[1], "night %d HP" % row[0])
		var got := [_shots_to_kill(hp, _hit(m17, 10.0, true)),
			_shots_to_kill(hp, _hit(m17, 35.0, true)),
			_shots_to_kill(hp, _hit(hk, 0.0, true))]
		_eq(got, [row[2], row[3], row[4]], "night %d shots [M17@10, M17@35, 416]" % row[0])
	return true

## The rule §4.4 derived 66 from: the 416 kills in STRICTLY fewer headshots
## than the M17 at every night and every range. Arsenal's boot assert checks a
## weaker proxy (body damage >= at every range); this is the rule itself, over
## the same sweep the spec quotes (nights 1–200, 0–150m, 0.25m steps).
func _test_416_beats_m17_everywhere() -> bool:
	print("[TABLE] 416 strictly fewer headshots than M17 (V2_SPEC §4.4 rule)")
	var m17: WeaponData = Arsenal.get_weapon("m17")
	var hk: WeaponData = Arsenal.get_weapon("hk416")
	var m17_hits: Array[int] = []
	var hk_hits: Array[int] = []
	for step in 601:
		var d := step * 0.25
		m17_hits.append(_hit(m17, d, true))
		hk_hits.append(_hit(hk, d, true))
	var first_fail := ""
	for night in range(1, 201):
		var hp := _hp_on_night(night)
		for step in 601:
			if _shots_to_kill(hp, hk_hits[step]) >= _shots_to_kill(hp, m17_hits[step]):
				first_fail = "night %d at %.2fm" % [night, step * 0.25]
				break
		if first_fail != "":
			break
	_check(first_fail == "", "holds everywhere%s" % ("" if first_fail == "" else " — first failure " + first_fail))
	return true

# --- PATROL_BASE_ZERO_V2_SPEC.md §2 "Leap mechanic — confirmed ballistics" ---
func _test_leap_ballistics() -> bool:
	print("[TABLE] leaper ballistics (V2_SPEC §2)")
	var leaper: ZombieType = load("res://resources/zombie_leaper.tres")
	var z: Zombie = load("res://scenes/Zombie.tscn").instantiate()
	z.zombie_type = leaper
	var run_speed := leaper.resolved_chase_speed()
	var arc := z._leap_arc_time()
	_near(run_speed, 6.375, "chase speed = 0.85 x sprint")
	_near(z._leap_vertical_speed(), 15.4919, "vertical launch speed")
	_near(arc, 1.2910, "arc time")
	_near(leaper.max_horizontal_distance / arc, 4.6476, "horizontal speed at the 6m cap")
	var leap_total := arc + leaper.landing_recovery
	_near(leap_total, 1.641, "arc + recovery")
	for d in [1.0, 3.0, 6.0]:
		_check(leap_total > d / run_speed, "leap slower than running %.0fm" % d)
	_near(leaper.max_horizontal_distance / leap_total, 3.656, "leap-chain speed")
	z.free()
	return true

# --- PATROL_BASE_ZERO_V2_SPEC.md §12 "Pricing — flat, and deliberately bad early"
func _test_supply_drop_pricing() -> bool:
	print("[TABLE] supply drop pricing (V2_SPEC §12)")
	var sds := SupplyDropSystem.new()
	sds.config = load("res://resources/supply_drop.tres")
	_eq(sds.config.supply_drop_cost, 31, "flat cost")
	var loadouts := [
		[["m17"], 23], [["m17", "hk416"], 27], [["m17", "hk416", "spas12"], 31],
		[["m17", "hk416", "spas12", "m249"], 39],
	]
	for row in loadouts:
		_eq(sds._bundle_value(row[0]), row[1], "contents worth with %d weapon(s)" % row[0].size())
	# The two-sided invariant _validate_pricing() asserts at runtime.
	_check(sds.config.supply_drop_cost > sds._worst_case_bundle(1),
		"bad buy with the dearest single weapon (%d > %d)" % [sds.config.supply_drop_cost, sds._worst_case_bundle(1)])
	_check(sds.config.supply_drop_cost < sds._worst_case_bundle(4),
		"good buy with the cheapest four (%d < %d)" % [sds.config.supply_drop_cost, sds._worst_case_bundle(4)])
	sds.free()
	return true

func _report() -> void:
	print("[TABLE] %s (%d failure(s))" % ["ALL PASS" if _failures.is_empty() else "FAILED", _failures.size()])
	for f in _failures:
		print("  - %s" % f)
	get_tree().quit(0 if _failures.is_empty() else 1)

func _on_watchdog() -> void:
	print("[TABLE] FAILED — watchdog: the run never reached its report (a test threw?)")
	get_tree().quit(1)
