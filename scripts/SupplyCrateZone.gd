extends Area3D
class_name SupplyCrateZone
## Trigger volume for the air-dropped supply crate. Entering only flags the
## player as "in range" and shows a prompt; the crate opens when they press the
## "interact" action (E), and the same key (or the UI's close/Esc) shuts it.
## Walking out closes it too. Only usable during Day.

var crate_ui: SupplyCrateUI = null
var hud: HUD = null

var _player_inside := false
var _player = null  # untyped: player exposes a custom API off CharacterBody3D

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	GameManager.phase_changed.connect(_on_phase_changed)

func _process(_delta: float) -> void:
	# Keep the prompt in sync regardless of how the crate was opened/closed
	# (interact key, close button, Esc, walking away, or nightfall).
	_update_prompt()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		_toggle_crate()

func _toggle_crate() -> void:
	if crate_ui == null:
		return
	if crate_ui.is_open():
		crate_ui.close_crate()
	elif _player_inside and _player != null:
		# Usable in BOTH phases now — shopping at night is allowed, and the
		# game keeps running while you do it.
		crate_ui.open_crate(_player)

func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	_player_inside = true
	_player = body

func _on_body_exited(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	_player_inside = false
	_player = null
	if crate_ui:
		crate_ui.close_crate()

func _on_phase_changed(_phase: int) -> void:
	# The crate no longer closes at dusk — it's usable in both phases.
	pass

func _update_prompt() -> void:
	if hud == null:
		return
	var crate_open: bool = crate_ui != null and crate_ui.is_open()
	if _player_inside and not crate_open:
		var suffix := "" if GameManager.is_day() else " (you are exposed)"
		hud.show_prompt("Press E to open the supply crate" + suffix, self)
	else:
		hud.hide_prompt(self)
