extends Area3D
class_name TentZone
## Trigger volume for the tent. Opens the shop only while it's Day and the
## player is inside. Leaving the zone (or nightfall) closes it.

var tent_ui: TentUI = null
var _player_inside := false

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	GameManager.phase_changed.connect(_on_phase_changed)

func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	_player_inside = true
	if GameManager.is_day() and tent_ui:
		tent_ui.open_tent(body)

func _on_body_exited(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	_player_inside = false
	if tent_ui:
		tent_ui.close_tent()

func _on_phase_changed(phase: int) -> void:
	# Tent shuts at dusk; if you're standing in it at dawn it opens back up.
	if phase == GameManager.Phase.NIGHT and tent_ui:
		tent_ui.close_tent()
	elif phase == GameManager.Phase.DAY and _player_inside and tent_ui:
		var players := get_tree().get_nodes_in_group("player")
		if players.size() > 0:
			tent_ui.open_tent(players[0])
