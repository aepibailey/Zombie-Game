extends Node
## Headless damage tests: what every damage path does to every actor, pinned
## as it behaves today. Run with:
##   godot --headless res://tools/damage_tests.tscn
## Exit code is 0 on all-pass, 1 on any failure, so CI can gate on it.
##
## RUN AS A SCENE, NEVER VIA --script — same reason as smoke_test.gd.
##
## CHARACTERIZATION, NOT SPECIFICATION. These numbers were recorded from the
## code as it stood before the Health/DamageInfo refactor, and that refactor
## must leave every one of them unchanged. Where a value looks odd (a zombie
## still taking damage after it died, a fighter returning 0), that is the
## current behaviour being held still, not an endorsement of it.
##
## Real call paths wherever one exists: rounds go through Player._fire_ray(),
## fighter fire through Fighter._shoot(), blasts through
## AreaDamageSystem.detonate(), mines through Minefield._apply(), zombie
## melee through Zombie._do_attack()/_do_entangled(). Only the bare verb
## checks call the damage functions directly, and they do it through the
## four adapters below — so a change of damage API touches those adapters,
## never an expected value.
##
## No Main: a floor, the actors under test, nothing else. Zombies are left
## inactive (dormant, so they never move or hunt); fighters are only ever
## present by Day, so their own night engagement loop never fires on its own.

const WATCHDOG_SEC := 30.0
const EPS := 0.001

var _failures: Array[String] = []
var _frag: AreaDamageProfile

func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SEC).timeout.connect(_on_watchdog)
	_frag = load("res://resources/frag_grenade.tres")
	_build_floor()
	await _frames(2)
	for section in [
		_test_zombie_verbs,
		_test_zombie_scoring,
		_test_player_rounds,
		_test_fighter_verbs,
		_test_fighter_rounds,
		_test_minefield,
		_test_zombie_melee,
		_test_blasts,
		_test_player_damage,
		_test_player_respawn,
		_test_player_game_over,
		_test_ifak,
	]:
		await _run_section(section)
	_report()

# --- Adapters: the ONLY places that name the damage API ----------------------
func _bullet(target: Node, amount: int, headshot: bool, falloff: float = 1.0) -> int:
	return target.take_damage(amount, headshot, falloff)

func _blast(target: Node, amount: int, origin: Vector3) -> void:
	target.take_area_damage(amount, origin)

func _melee(target: Node, amount: int, source: Vector3) -> void:
	target.take_melee_damage(amount, source)

func _player_hp(p: Player) -> int:
	return p.hp

# --- Harness -----------------------------------------------------------------
## A section that throws stops at the error and returns null; see table_tests.gd.
func _run_section(section: Callable) -> void:
	if await section.call() != true:
		_check(false, "%s aborted before finishing (see SCRIPT ERROR above)" % section.get_method())

func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  %s" % label)
	else:
		_failures.append(label)
		print("  FAIL  %s" % label)

func _eq(a, b, label: String) -> void:
	_check(a == b, "%s (got %s, want %s)" % [label, a, b])

func _near(a: float, b: float, label: String) -> void:
	_check(absf(a - b) < EPS, "%s (got %.4f, want %.4f)" % [label, a, b])

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _build_floor() -> void:
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	shape.shape = box
	floor_body.add_child(shape)
	add_child(floor_body)
	floor_body.global_position = Vector3(0.0, -0.5, 0.0)

func _zombie(at: Vector3, max_hp: int, type_path := "res://resources/zombie_walker.tres") -> Zombie:
	var z: Zombie = load("res://scenes/Zombie.tscn").instantiate()
	z.zombie_type = load(type_path)
	z.max_hp = max_hp
	add_child(z)
	z.global_position = at
	return z

func _fighter(at: Vector3) -> Fighter:
	var f := Fighter.new()
	f.recruit(load("res://resources/fighter_irregular.tres"))
	add_child(f)
	f.global_position = at
	f.global_rotation.y = 0.0
	return f

func _player(at: Vector3, respawn: bool) -> Player:
	var p: Player = load("res://scenes/Player.tscn").instantiate()
	p.respawn_on_death = respawn
	add_child(p)
	p.global_position = at
	p.global_rotation = Vector3.ZERO
	return p

func _free(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	await _frames(2)

## Counts emissions of `sig` on `obj` into a fresh one-element array.
func _counter(obj: Object, sig: String) -> Array:
	var box := [0]
	obj.connect(sig, func(_a = null, _b = null): box[0] += 1)
	return box

# --- Zombie: the bare verbs --------------------------------------------------
func _test_zombie_verbs() -> bool:
	print("[DMG] zombie verbs")
	GameManager.force_phase(GameManager.Phase.DAY)
	var z := _zombie(Vector3(0, 0, -40), 1000)
	_eq(_bullet(z, 34, false), 34, "body hit deals raw damage")
	_eq(_bullet(z, 34, true), 68, "headshot doubles")
	_eq(_bullet(z, 34, true, 0.4), 27, "headshot then falloff, rounded once (34x2x0.4)")
	_eq(_bullet(z, 34, false, 0.4), 14, "body x0.4 rounds 13.6 up")
	_eq(_bullet(z, 1, false, 0.1), 1, "never below 1")
	_eq(z.remaining_hp(), 1000 - 34 - 68 - 27 - 14 - 1, "HP after five hits")
	_eq(z.last_hit_headshot, false, "last hit was a body hit")
	_blast(z, 50, Vector3(0, 0, -45))
	_eq(z.remaining_hp(), 1000 - 144 - 50, "blast takes its amount exactly")
	_eq(z.last_hit_headshot, false, "a blast is never a headshot")
	await _free([z])

	# Death, once — and a corpse still takes (and reports) damage until freed.
	var k := _zombie(Vector3(0, 0, -40), 100)
	var died := _counter(k, "died")
	_eq(_bullet(k, 99, false), 99, "99 to a 100 HP zombie")
	_check(k.is_alive(), "alive at 1 HP")
	_eq(_bullet(k, 34, false), 34, "killing hit")
	_check(not k.is_alive(), "dead after the killing hit")
	_eq(k.remaining_hp(), 0, "remaining HP floors at 0")
	_eq(_bullet(k, 34, true), 68, "a same-frame hit on the corpse still reports damage")
	_eq(died[0], 1, "died emitted exactly once")
	await _free([k])
	return true

# --- Zombie: what a kill scores ----------------------------------------------
func _test_zombie_scoring() -> bool:
	print("[DMG] zombie kill scoring")
	GameManager.force_phase(GameManager.Phase.NIGHT)
	var before := PointsManager.points
	var a := _zombie(Vector3(0, 0, -40), 50)
	_bullet(a, 34, true)
	_eq(PointsManager.points - before, 3, "night headshot kill scores 3")
	before = PointsManager.points
	var b := _zombie(Vector3(3, 0, -40), 70)
	_bullet(b, 30, true)
	_bullet(b, 30, false)
	_eq(PointsManager.points - before, 1, "night kill scores off the KILLING hit (body after head)")
	before = PointsManager.points
	var leaper := _zombie(Vector3(6, 0, -40), 10, "res://resources/zombie_leaper.tres")
	_bullet(leaper, 34, true)
	_eq(PointsManager.points - before, 5, "leaper headshot kill scores 5")
	GameManager.force_phase(GameManager.Phase.DAY)
	before = PointsManager.points
	var c := _zombie(Vector3(9, 0, -40), 10)
	_bullet(c, 34, true)
	_eq(PointsManager.points - before, 0, "day kill scores nothing")
	var d := _zombie(Vector3(12, 0, -40), 10)
	PointsManager.credit_defense_kills(func(): _blast(d, 50, Vector3(12, 0, -42)))
	_eq(PointsManager.points - before, 1, "day kill inside defense credit scores")
	await _free([a, b, leaper, c, d])
	return true

# --- Player rounds, through the real hit-resolution path ----------------------
func _test_player_rounds() -> bool:
	print("[DMG] player rounds via Player._fire_ray()")
	GameManager.force_phase(GameManager.Phase.DAY)
	var p := _player(Vector3(0, 0, 60), false)
	var z := _zombie(Vector3(0, 0, 0), 1000)
	var f := _fighter(Vector3(20, 0, 0))
	await _frames(3)
	var m17: WeaponData = Arsenal.get_weapon("m17")
	p.weapon = m17
	var shots: Array = []
	p.zombie_hit.connect(func(head, dealt, remaining): shots.append([head, dealt, remaining]))
	var zt: ZombieType = z.zombie_type
	# 5m out: inside the M17's 15m full-damage band.
	p._fire_ray(z.global_position + Vector3(0, zt.body_center_y(), 5), Vector3(0, 0, -1))
	p._fire_ray(z.global_position + Vector3(0, zt.head_center_y(), 5), Vector3(0, 0, -1))
	# 27.5m out: M17 falloff x0.70.
	p._fire_ray(z.global_position + Vector3(0, zt.body_center_y(), 27.5), Vector3(0, 0, -1))
	var ft: FighterType = f.fighter_type
	p._fire_ray(f.global_position + Vector3(0, ft.total_height() * 0.5, 5), Vector3(0, 0, -1))
	_eq(shots.size(), 4, "four rounds connected")
	if shots.size() == 4:
		_eq(shots[0], [false, 34, 966], "zombie body at 5m")
		_eq(shots[1], [true, 68, 898], "zombie head at 5m")
		_eq(shots[2], [false, 24, 874], "zombie body at 27.5m (34 x 0.70 = 23.8)")
		_eq(shots[3], [false, 34, 66], "fighter body at 5m")
	await _free([p, z, f])
	return true

# --- Fighter: the bare verbs --------------------------------------------------
func _test_fighter_verbs() -> bool:
	print("[DMG] fighter verbs")
	GameManager.force_phase(GameManager.Phase.DAY)
	var f := _fighter(Vector3(0, 0, -40))
	_eq(_bullet(f, 30, false, 0.5), 15, "body x0.5")
	_eq(_bullet(f, 30, true), 30, "headshot flag ignored: a fighter has no head")
	_eq(_bullet(f, 1, false, 0.1), 1, "never below 1")
	_eq(f.remaining_hp(), 100 - 15 - 30 - 1, "HP after three rounds")
	_blast(f, 20, Vector3(0, 0, -42))
	_eq(f.remaining_hp(), 34, "blast takes its amount exactly")
	_melee(f, 20, Vector3(0, 0, -41))
	_eq(f.remaining_hp(), 14, "melee takes its amount exactly, never doubled")
	var died := _counter(f, "died")
	_melee(f, 20, Vector3(0, 0, -41))
	_check(not f.is_alive(), "dead at 0")
	_eq(f.remaining_hp(), 0, "remaining HP floors at 0")
	_eq(died[0], 1, "died emitted once")
	_eq(_bullet(f, 30, false), 0, "a dead fighter takes nothing and reports 0")
	_blast(f, 20, Vector3(0, 0, -42))
	_melee(f, 20, Vector3(0, 0, -41))
	_eq(died[0], 1, "still emitted once after more hits")
	await _free([f])
	return true

# --- Fighter rounds and kill credit, through Fighter._shoot() -----------------
func _test_fighter_rounds() -> bool:
	print("[DMG] fighter rounds via Fighter._shoot()")
	GameManager.force_phase(GameManager.Phase.DAY)
	var f := _fighter(Vector3(0, 0, -40))
	# hit_chance is a sanctioned post-roll write (upgrade() does it). Above 1.0
	# so randf()'s inclusive 1.0 can never turn this into a miss.
	f.hit_chance = 2.0
	f.damage = 25
	var z := _zombie(Vector3(0, 0, -50), 60)
	f._shoot(z)
	_eq(z.remaining_hp(), 35, "a fighter round deals its damage as a body hit")
	_eq(f.kills, 0, "no kill credit for a round that did not kill")
	f._shoot(z)
	_eq(f.kills, 0, "still no kill at 10 HP")
	f._shoot(z)
	_check(not z.is_alive(), "third round kills")
	_eq(f.kills, 1, "kill credited to the round that put it down")
	_eq([f.shots_fired, f.hits_landed], [3, 3], "shots and hits counted")
	await _free([f, z])
	return true

# --- Minefield, through Minefield._apply() ------------------------------------
func _test_minefield() -> bool:
	print("[DMG] minefield via Minefield._apply()")
	GameManager.force_phase(GameManager.Phase.DAY)
	var mf := Minefield.new()
	var z := _zombie(Vector3(0, 0, -40), 200)
	mf._apply(z, 125)
	_eq(z.remaining_hp(), 75, "mine charge takes its amount exactly")
	_check(z.is_alive(), "a 200 HP zombie survives a 125 charge")
	_eq(z.last_hit_headshot, false, "a mine is never a headshot")
	mf._apply(z, 125)
	_check(not z.is_alive(), "second charge kills")
	mf.free()
	await _free([z])
	return true

# --- Zombie melee, through _do_attack() and _do_entangled() -------------------
func _test_zombie_melee() -> bool:
	print("[DMG] zombie melee via _do_attack() / _do_entangled()")
	GameManager.force_phase(GameManager.Phase.DAY)
	var f := _fighter(Vector3(0, 0, -40))
	var z := _zombie(Vector3(0, 0, -41), 1000)
	await _frames(2)
	z._attack_timer = 0.0
	z._do_attack(0.0)
	_eq(f.remaining_hp(), 80, "attack swing on a fighter: walker melee 20")
	z._attack_timer = 0.0
	z._target_timer = 0.0
	z._do_entangled(0.0)
	_eq(f.remaining_hp(), 60, "entangled swing on a fighter: 20 more")
	await _free([f, z])

	var p := _player(Vector3(0, 0, -40), false)
	var hz := _zombie(Vector3(0, 0, -41.5), 1000)
	await _frames(2)
	p.global_position = Vector3(0, 0, -40)
	p.global_rotation = Vector3.ZERO
	var hits: Array = []
	p.damaged.connect(func(ang): hits.append(ang))
	hz._attack_timer = 0.0
	hz._do_attack(0.0)
	_eq(_player_hp(p), 80, "attack swing on the player: 20")
	_eq(hits.size(), 1, "the player's damaged signal fired once")
	await _free([p, hz])
	return true

# --- Blasts, through AreaDamageSystem.detonate() ------------------------------
## Exact frag numbers are recorded, not derived: they depend on the profile's
## falloff and on the exposure rays, and this pins both paths as they are.
func _test_blasts() -> bool:
	print("[DMG] blasts via AreaDamageSystem.detonate()")
	GameManager.force_phase(GameManager.Phase.DAY)
	var z := _zombie(Vector3(0, 0, -40), 1000)
	var f := _fighter(Vector3(30, 0, -40))
	await _frames(3)
	var r1: Dictionary = AreaDamageSystem.detonate(z.global_position + Vector3(0, 0.2, 2.0), _frag, Vector3.ZERO, "test")
	_eq([r1["actors"], r1["killed"]], [1, 0], "frag beside a zombie: 1 hit, 0 killed")
	_eq(z.remaining_hp(), 1000 - r1["total_damage"], "zombie lost exactly the reported damage")
	_eq(r1["total_damage"], FRAG_ZOMBIE_2M, "frag at 2m from a zombie")
	var r2: Dictionary = AreaDamageSystem.detonate(f.global_position + Vector3(0, 0.2, 2.0), _frag, Vector3.ZERO, "test")
	_eq([r2["actors"], r2["killed"]], [1, 1], "frag beside a 100 HP fighter: 1 hit, 1 killed")
	_check(not f.is_alive(), "the fighter is dead")
	await _free([z, f])
	return true

## Recorded from the pre-refactor code. See _test_blasts().
const FRAG_ZOMBIE_2M := 180

# --- Player: blast and melee bookkeeping --------------------------------------
func _test_player_damage() -> bool:
	print("[DMG] player blast and melee")
	GameManager.force_phase(GameManager.Phase.DAY)
	var p := _player(Vector3(0, 0, -40), false)
	await _frames(2)
	p.global_position = Vector3(0, 0, -40)
	p.global_rotation = Vector3.ZERO
	var changed: Array = []
	p.health_changed.connect(func(hp, mx): changed.append([hp, mx]))
	var angles: Array = []
	p.damaged.connect(func(ang): angles.append(ang))
	_blast(p, 30, p.global_position + Vector3(0, 0, -3))
	_eq(_player_hp(p), 70, "blast takes its amount exactly")
	_eq(changed.back() if not changed.is_empty() else null, [70, 100], "health_changed(70, 100)")
	_near(angles.back() if not angles.is_empty() else 99.0, 0.0, "blast dead ahead reads as 0 rad")
	_melee(p, 20, p.global_position + Vector3(3, 0, 0))
	_eq(_player_hp(p), 50, "melee takes its amount exactly")
	_near(angles.back() if not angles.is_empty() else 99.0, PI / 2.0, "melee from the right reads as +pi/2")
	_eq([changed.size(), angles.size()], [2, 2], "one health_changed and one damaged per hit")
	await _free([p])
	return true

# --- Player: debug respawn and its one-frame death latch ----------------------
func _test_player_respawn() -> bool:
	print("[DMG] player respawn_on_death = true")
	GameManager.force_phase(GameManager.Phase.DAY)
	var p := _player(Vector3(0, 0, -40), true)
	await _frames(2)
	var perm := _counter(p, "died_permanently")
	_blast(p, 150, p.global_position + Vector3(0, 0, -1))
	_eq(_player_hp(p), 100, "respawn restores full HP inside the killing call")
	_check(not p.is_alive(), "is_alive() false for the frame of the death (latch)")
	_check(not p.is_dead(), "not dead: the run goes on")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(p.is_alive(), "latch clears after the frame")
	_eq(perm[0], 0, "no died_permanently on a respawn")

	# The latch is what lets a blast's kill tally see a respawn death.
	await _frames(2)
	p.global_position = Vector3(0, 0, -40)
	await _frames(2)
	_blast(p, 60, p.global_position + Vector3(0, 0, -1))
	_eq(_player_hp(p), 40, "60 off a fresh 100")
	await _frames(1)
	var r: Dictionary = AreaDamageSystem.detonate(p.global_position + Vector3(0, 0.2, 1.0), _frag, Vector3.ZERO, "test")
	_eq(r["killed"], 1, "a blast that kills a respawning player counts the kill")
	_eq(_player_hp(p), 100, "and the player is back at full HP")
	await _free([p])
	return true

# --- Player: game over ----------------------------------------------------------
func _test_player_game_over() -> bool:
	print("[DMG] player respawn_on_death = false (game over)")
	GameManager.force_phase(GameManager.Phase.DAY)
	var p := _player(Vector3(0, 0, -40), false)
	await _frames(2)
	var perm := _counter(p, "died_permanently")
	var changed := _counter(p, "health_changed")
	_blast(p, 150, p.global_position + Vector3(0, 0, -1))
	_eq(_player_hp(p), 0, "HP floors at 0")
	_check(p.is_dead() and not p.is_alive(), "dead, and stays dead")
	_eq(perm[0], 1, "died_permanently once")
	_check(not p.is_in_group(Zombie.GROUP_HOSTILE_TARGET), "left the hostile-target group")
	_check(not p.is_in_group(AreaDamageSystem.GROUP_DAMAGEABLE), "left the blast group")
	_check(p.is_in_group("player"), "still in the player group")
	var changes_at_death: int = changed[0]
	_blast(p, 20, p.global_position)
	_melee(p, 20, p.global_position)
	_eq(changed[0], changes_at_death, "a dead player ignores further damage")
	_eq(perm[0], 1, "died_permanently still once")
	await _free([p])
	return true

# --- Player: IFAK ---------------------------------------------------------------
func _test_ifak() -> bool:
	print("[DMG] IFAK heal")
	GameManager.force_phase(GameManager.Phase.DAY)
	var p := _player(Vector3(0, 0, -40), false)
	await _frames(2)
	_blast(p, 50, p.global_position + Vector3(0, 0, -3))
	p.ifaks = 2
	p._start_ifak()
	p._update_ifak(p.ifak_apply_time + 0.1)
	_eq(_player_hp(p), 90, "IFAK heals 40")
	p._start_ifak()
	p._update_ifak(p.ifak_apply_time + 0.1)
	_eq(_player_hp(p), 100, "no overheal")
	_eq(p.ifaks, 0, "both IFAKs spent")
	await _free([p])
	return true

func _report() -> void:
	print("[DMG] %s (%d failure(s))" % ["ALL PASS" if _failures.is_empty() else "FAILED", _failures.size()])
	for f in _failures:
		print("  - %s" % f)
	get_tree().quit(0 if _failures.is_empty() else 1)

func _on_watchdog() -> void:
	print("[DMG] FAILED — watchdog: the run never reached its report (a test threw?)")
	get_tree().quit(1)
