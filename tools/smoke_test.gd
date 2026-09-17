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
## RUN AS A SCENE, NOT VIA --script. A custom MainLoop (extends SceneTree,
## --script) does not register autoload globals at compile time, which fails
## to compile the project's OWN scripts — Fighter.gd's GameManager reference
## and Zombie.gd's NoiseManager one both die, and custom resources load as
## plain Resource with their class_name stripped. Running as an ordinary scene
## keeps autoloads and script classes intact, which is the whole point: this
## has to exercise the real game, not a degraded copy of it.

var _main: Node
var _fighter: Fighter
var _zombie: Node3D
var _frames := 0
var _failures: Array[String] = []

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
	_frames += 1

	if _frames == 5:
		GameManager.force_phase(GameManager.Phase.NIGHT)
		print("[SMOKE] phase forced to %s" % GameManager.phase_name())

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

	# ~15s of engagement at 60fps.
	if _frames == 900:
		print("[SMOKE] --- results ---")
		_check(GameManager.phase_name() == "NIGHT", "engagement ran during NIGHT")
		_check(_fighter.shots_fired > 0, "fighter fired at least one round")
		_check(_fighter.hits_landed > 0, "fighter landed at least one hit")
		_check(_fighter.hits_landed <= _fighter.shots_fired, "hits never exceed shots")
		_check(_fighter.hit_chance < 1.0, "hit_chance below 1.0 (a maxed fighter can still miss)")
		_check(_fighter.is_in_group(Damageable.GROUP_BULLET), "joined GROUP_BULLET")
		_check(_fighter.is_in_group(Zombie.GROUP_HOSTILE_TARGET), "joined GROUP_HOSTILE_TARGET")
		_check(_fighter.is_in_group(AreaDamageSystem.GROUP_DAMAGEABLE), "joined GROUP_DAMAGEABLE")
		_check(_fighter.has_method("take_melee_damage"), "melee axis has its own verb")
		print("[SMOKE] shots=%d hits=%d kills=%d zombie_alive=%s" % [
			_fighter.shots_fired, _fighter.hits_landed, _fighter.kills,
			is_instance_valid(_zombie) and _zombie.is_alive()])
		print("[SMOKE] %s (%d failure(s))" % [
			"ALL PASS" if _failures.is_empty() else "FAILURES: " + ", ".join(_failures),
			_failures.size()])
		get_tree().quit(0 if _failures.is_empty() else 1)
