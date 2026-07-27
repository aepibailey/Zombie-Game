extends Area3D
class_name EngineersTentZone
## Trigger volume for the Engineers' Tent. Press the "interact" action (E)
## while inside to open build mode.
##
## The engineers are civilian construction workers sheltering at the base. They
## won't work after dark, so the tent is DAY ONLY — unlike the supply crate,
## which is now usable in both phases.

var build_mode: BuildMode = null
var hud: HUD = null

var _player_inside := false
var _player: Player = null

func _ready() -> void:
	# Layer 2 like the other triggers, so weapon rays don't hit it.
	collision_layer = 2
	collision_mask = 1
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _process(_delta: float) -> void:
	_update_prompt()

func _unhandled_input(event: InputEvent) -> void:
	if not _player_inside or _player == null or build_mode == null:
		return
	if build_mode.is_open():
		return   # build mode handles its own Esc
	if event.is_action_pressed("interact"):
		if GameManager.is_day():
			build_mode.open()
		elif hud:
			hud.show_message("The engineers won't leave the tent after dark.")
		get_viewport().set_input_as_handled()

func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	_player_inside = true
	_player = body as Player

func _on_body_exited(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	_player_inside = false
	_player = null
	if hud:
		hud.hide_prompt(self)

func _update_prompt() -> void:
	if hud == null:
		return
	var open: bool = build_mode != null and build_mode.is_open()
	if not _player_inside or open:
		hud.hide_prompt(self)
		return
	if GameManager.is_day():
		hud.show_prompt("Press E — Engineers' Tent (build)", self)
	else:
		hud.show_prompt("Engineers' Tent — closed until morning", self)
