extends Node
## Headless smoke test: drives a fighter through a real engagement and asserts
## the loop actually resolved rounds. Run with:
##   godot --headless res://tools/smoke_test.tscn
## Exit code is 0 on all-pass, 1 on any failure, so CI can gate on it.
##
## Not a unit-test framework and not a substitute for playtesting — it is the
## cheapest possible answer to "did that commit break the firing loop", which
## is a question no amount of re-reading the diff can settle.
##
## RUN AS A SCENE, NEVER VIA --script. A custom MainLoop does not register
## autoload globals at compile time, which fails to compile this project's OWN
## scripts — Fighter.gd's GameManager reference and Zombie.gd's NoiseManager
## one both die, and fighter_irregular.tres loads as a bare Resource with its
## class_name stripped, so recruit() rejects it. The harness would then "fail"
## for reasons that have nothing to do with the game.
##
## THE NIGHT WAVE IS SUPPRESSED, AND THAT IS THE WHOLE REASON THIS IS STABLE.
## The first version of this test left Main's own 6-zombie wave running. Those
## zombies hunt fighters now (GROUP_HOSTILE_TARGET, added the same commit this
## test exists to cover), so roughly half of all runs ended with the test
## fighter KIA — and reading shots_fired off a freed object threw inside
## _process every frame, so quit() was never reached and the run hung forever
## instead of failing. Two separate mistakes, one symptom. Both are fixed:
## the wave is stopped so the fighter's only contact is the one placed for it,
## AND the stats below are snapshotted every frame so a dead fighter can still
## be reported on rather than crashing the harness.

var _main: Node
var _fighter: Fighter
var _zombie: Node3D
var _frames := 0
var _failures: Array[String] = []
var _done := false

# Snapshot of the fighter's counters, refreshed while it lives. Read these, not
# the fighter — it can die mid-run and a freed object cannot be queried.
var _shots := 0
var _hits := 0
var _kills := 0
var _hit_chance := 0.0
var _in_bullet_group := false
var _in_hostile_group := false
var _in_damageable_group := false
var _has_melee_verb := false
var _fighter_kia := false

# 5s of setup slack past the 900-frame engagement window. A smoke test that can
# hang is worse than one that fails: CI reports the failure and moves on, but
# it waits on the hang until someone notices.
const HARD_FRAME_CAP := 1800

func _ready() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	add_child(_main)

func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  %s" % label)
	else:
		_failures.append(label)
		print("  FAIL  %s" % label)

func _process(_delta: float) -> void:
	if _done:
		return
	_frames += 1

	if _frames == 5:
		GameManager.force_phase(GameManager.Phase.NIGHT)
		print("[SMOKE] phase forced to %s" % GameManager.phase_name())
		_suppress_night_wave()

		_fighter = Fighter.new()
		_fighter.recruit(load("res://resources/fighter_irregular.tres"))
		_main.add_child(_fighter)
		_fighter.global_position = Vector3.ZERO
		_fighter.global_rotation.y = 0.0

		# Directly downrange of the fighter's facing, well inside its band.
		_zombie = load("res://scenes/Zombie.tscn").instantiate()
		_zombie.zombie_type = _main._pick_zombie_type()
		_zombie.max_hp = 100
		_main.add_child(_zombie)
		_zombie.global_position = Vector3(0.0, 0.3, -8.0)
		_zombie.set_active(true)
		print("[SMOKE] fighter hit_chance=%.2f damage=%d reaction=%.2fs" % [
			_fighter.hit_chance, _fighter.damage, _fighter.reaction_delay])
		return

	_snapshot()

	# ~15s of engagement at 60fps, or the hard cap if anything above stalls.
	if _frames >= 900 or _frames >= HARD_FRAME_CAP:
		_report()

## Stops Main's own night wave. `_spawn_zombie()` is gated on
## `_wave_spawned < _wave_total`, so levelling the two ends the trickle, and
## anything already on the field is cleared. Without this the fighter's real
## contact is whatever wandered in, which is a fine game and a useless test.
func _suppress_night_wave() -> void:
	_main._wave_spawned = _main._wave_total
	for z in _main._zombies:
		if is_instance_valid(z):
			z.queue_free()
	_main._zombies.clear()

func _snapshot() -> void:
	if _fighter == null:
		return
	if not is_instance_valid(_fighter):
		_fighter_kia = true
		return
	_shots = _fighter.shots_fired
	_hits = _fighter.hits_landed
	_kills = _fighter.kills
	_hit_chance = _fighter.hit_chance
	_in_bullet_group = _fighter.is_in_group(Damageable.GROUP_BULLET)
	_in_hostile_group = _fighter.is_in_group(Zombie.GROUP_HOSTILE_TARGET)
	_in_damageable_group = _fighter.is_in_group(AreaDamageSystem.GROUP_DAMAGEABLE)
	_has_melee_verb = _fighter.has_method("take_melee_damage")
	if not _fighter.is_alive():
		_fighter_kia = true

func _report() -> void:
	_done = true
	print("[SMOKE] --- results ---")
	_check(GameManager.phase_name() == "NIGHT", "engagement ran during NIGHT")
	_check(not _fighter_kia, "test fighter survived (night wave stayed suppressed)")
	_check(_shots > 0, "fighter fired at least one round")
	_check(_hits > 0, "fighter landed at least one hit")
	_check(_hits <= _shots, "hits never exceed shots")
	_check(_hit_chance < 1.0, "hit_chance below 1.0 (a maxed fighter can still miss)")
	_check(_in_bullet_group, "joined GROUP_BULLET")
	_check(_in_hostile_group, "joined GROUP_HOSTILE_TARGET")
	_check(_in_damageable_group, "joined GROUP_DAMAGEABLE")
	_check(_has_melee_verb, "melee axis has its own verb")
	print("[SMOKE] shots=%d hits=%d kills=%d fighter_kia=%s zombie_alive=%s" % [
		_shots, _hits, _kills, _fighter_kia,
		is_instance_valid(_zombie) and _zombie.is_alive()])
	print("[SMOKE] %s (%d failure(s))" % [
		"ALL PASS" if _failures.is_empty() else "FAILURES: " + ", ".join(_failures),
		_failures.size()])
	get_tree().quit(0 if _failures.is_empty() else 1)
