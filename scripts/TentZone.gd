extends Area3D
class_name TentZone
## Trigger volume for the tent. Entering only flags the player as "in range" and
## shows a prompt; the shop opens when they press the "interact" action (E), and
## the same key (or the UI's close/Esc) shuts it. Walking out closes it too.
## Only usable during Day.

var tent_ui: TentUI = null
var hud: HUD = null

var _player_inside := false
var _player = null  # untyped: player exposes a custom API off CharacterBody3D

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	GameManager.phase_changed.connect(_on_phase_changed)

func _process(_delta: float) -> void:
	# Keep the prompt in sync regardless of how the shop was opened/closed
	# (interact key, close button, Esc, walking away, or nightfall).
	_update_prompt()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		_toggle_shop()

func _toggle_shop() -> void:
	if tent_ui == null:
		return
	if tent_ui.is_open():
		tent_ui.close_tent()
	elif _player_inside and GameManager.is_day() and _player != null:
		tent_ui.open_tent(_player)

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
	if tent_ui:
		tent_ui.close_tent()

func _on_phase_changed(phase: int) -> void:
	# Tent shuts at dusk.
	if phase == GameManager.Phase.NIGHT and tent_ui:
		tent_ui.close_tent()

func _update_prompt() -> void:
	if hud == null:
		return
	var shop_open: bool = tent_ui != null and tent_ui.is_open()
	if _player_inside and GameManager.is_day() and not shop_open:
		hud.show_prompt("Press E to open shop")
	else:
		hud.hide_prompt()
