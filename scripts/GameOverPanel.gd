extends CanvasLayer
class_name GameOverPanel
## The run is over. Shown once, on Player.died_permanently, and never closed —
## the only ways out are Restart (a fresh run) and Quit.
##
## Same shape as RosterMenu: built in code, holds the clock with its own
## source id, takes the mouse off the player. Mouse-driven only — no keys of
## its own, so it adds no hardcoded keycodes.
##
## Reports the night the run ended on, a rank for the nights survived (from
## Main.rank_thresholds), and points earned this run. Kills are not tracked
## run-wide anywhere, so they are not shown. There is no win condition: the
## rank is a description of how far the run got, not an ending.
##
## WHILE SHOWN, THE GAME BEHIND IT IS INERT — enforced here, in one place,
## rather than by gating each of the nine _unhandled_input handlers that act
## for the player (Main's all-clear/radio/debug keys, BuildMode, RadioMenu,
## RosterMenu, TargetPainter, the crate, the supply drop, the trigger zones).
## Godot delivers input as _input -> GUI -> _unhandled_input, so: every key
## is swallowed in _input below, and a full-screen backdrop with
## MOUSE_FILTER_STOP eats every click that does not land on a button. Nothing
## downstream ever sees an event, whoever it belongs to.

const HALT_ID := "game_over"

var _player: Player
var _shown := false
var _summary: Label
var _rank_label: Label
## nights survived -> rank name. See Main.rank_thresholds.
var _rank_thresholds: Dictionary = {}

func setup(player: Player, rank_thresholds: Dictionary) -> void:
	_player = player
	assert(rank_thresholds.has(0),
		"[GAMEOVER] rank_thresholds must have a 0 entry, or a run that survives no nights has no rank.")
	_rank_thresholds = rank_thresholds
	player.died_permanently.connect(_show)

func _ready() -> void:
	layer = 25   # above everything, including the crate store (20)
	visible = false

	# Full-screen, under the panel: dims the dead world and STOPs every click
	# that misses a button — see the class note.
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(360, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.03, 0.03, 0.94)
	sb.border_color = Color(0.75, 0.25, 0.2, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)

	var title := Label.new()
	title.text = "— YOU DIED —"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.75, 0.7))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)

	_rank_label = Label.new()
	_rank_label.add_theme_font_size_override("font_size", 26)
	_rank_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.55))
	_rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_rank_label)

	_summary = Label.new()
	_summary.add_theme_font_size_override("font_size", 15)
	_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_summary)
	root.add_child(HSeparator.new())

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	root.add_child(buttons)

	var restart := Button.new()
	restart.text = "Restart"
	restart.custom_minimum_size = Vector2(120, 36)
	restart.pressed.connect(_on_restart)
	buttons.add_child(restart)

	var quit := Button.new()
	quit.text = "Quit"
	quit.custom_minimum_size = Vector2(120, 36)
	quit.pressed.connect(_on_quit)
	buttons.add_child(quit)

## Dying during Night N means N-1 nights were survived; dying by day (your
## own grenade, say) means the night just finished counts.
static func nights_survived(night_number: int, is_day: bool) -> int:
	return maxi(0, night_number if is_day else night_number - 1)

## The rank for `survived` nights: the name at the highest threshold at or
## below it. 0 -> Overrun, 14 -> Overrun, 15 -> Held the Line, 50+ -> Legend.
static func rank_for(survived: int, thresholds: Dictionary) -> String:
	var best := -1
	for t in thresholds:
		if int(t) <= survived and int(t) > best:
			best = int(t)
	return thresholds[best] if best >= 0 else ""

func _show() -> void:
	if _shown:
		return
	_shown = true
	GameManager.request_clock_halt(HALT_ID)
	if _player:
		_player._set_mouse_captured(false)
	var survived := nights_survived(GameManager.night_number, GameManager.is_day())
	_rank_label.text = rank_for(survived, _rank_thresholds)
	# "Night N" is the night the run ended on: the night being fought, or by
	# day the one just survived.
	_summary.text = "Night %d\nNights survived: %d\nPoints earned this run: %d" % [
		maxi(GameManager.night_number, 1), survived, PointsManager.earned_this_run]
	visible = true

## Keys only. Mouse buttons must reach the GUI stage for the buttons to work;
## the backdrop handles stray clicks there instead.
func _input(event: InputEvent) -> void:
	if _shown and event is InputEventKey:
		get_viewport().set_input_as_handled()

func _on_restart() -> void:
	# start_new_run() clears every clock halt, this one included, before the
	# reload frees this node — _exit_tree()'s release is then a no-op.
	GameManager.start_new_run()

func _on_quit() -> void:
	get_tree().quit()

## Same belt-and-braces as RosterMenu: a halt must never outlive its holder.
func _exit_tree() -> void:
	if _shown:
		GameManager.release_clock_halt(HALT_ID)
