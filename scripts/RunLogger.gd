extends Node
## Per-night run log (autoload). One CSV per run, one row per night, so
## economy and escalation can be tuned from data (docs/RUN_STRUCTURE.md,
## "Open questions"). Measurement only: nothing here changes gameplay.
##
## ROW WINDOW. Row N covers Night N plus the Day that follows it. It opens
## when Night N starts and is written when Night N+1 starts (ended_by =
## dusk). A run that ends mid-row writes it as a partial row instead: on
## player death (ended_by = death) or on closing the game window (ended_by =
## quit). Columns whose event never happened in that window are left blank —
## a row cut short at night has no bank_at_dawn — rather than written as 0.
##
## CRASH SAFETY. The file is opened, appended to and closed once per row, so
## a crash loses at most the row in progress. It is created lazily on the
## first row, so a session that never reaches Night 1 (the test suites, a
## quick boot) leaves no empty file behind.
##
## DRIVEN EXPLICITLY, not by phase_changed: Main calls begin_night() /
## mark_dawn() from its own phase handlers, after it has computed the pool
## and carryover, so this never depends on signal connection order.
##
## Stopping play from the editor kills the process without a close request,
## so no quit row is written that way. Close the game window instead.

const RUNS_DIR := "user://runs"
const COLUMNS := [
	"run_id", "night", "night_type", "position", "ended_by", "pool", "carryover_in", "carryover_out",
	"max_alive", "walker_hp",
	"walker_kills_head", "walker_kills_body", "leaper_kills_head", "leaper_kills_body",
	"day_kills", "points_earned", "bank_at_dawn", "bank_at_dusk",
	"spent_ammo", "spent_weapons", "spent_attachments", "spent_equipment",
	"spent_defences", "spent_enablers", "spent_fighters",
	"max_alive_reached", "player_hp_lost", "ifaks_used", "fighters_lost",
	"fps_min", "fps_avg",
]
## Column for each PointsManager.SpendCategory, in enum order.
const SPEND_COLUMNS := [
	"spent_ammo", "spent_weapons", "spent_attachments", "spent_equipment",
	"spent_defences", "spent_enablers", "spent_fighters",
]

## FPS is sampled at Night only, every FPS_SAMPLE_INTERVAL, skipping the first
## FPS_WARMUP of each night (the dusk spike: HUD messages, the first spawns).
const FPS_SAMPLE_INTERVAL := 0.5
const FPS_WARMUP := 1.0

var run_id := ""
var _path := ""
## The row in progress, or empty between rows. Keys are COLUMNS; a key that
## is absent is written as a blank cell.
var _row: Dictionary = {}
var _dawn_seen := false
# PointsManager's run-cumulative totals at the start of the row and at dawn.
# Window figures are deltas of these, so nothing here keeps its own tally of
# points that could drift from the authority.
var _earned_at_open := 0
var _spent_at_open := 0
var _by_category_at_open: Array[int] = []
# Player HP as last reported, so a loss is the real drop in HP (a killing
# blow larger than the HP left counts only what was left).
var _last_hp := 0
var _night_elapsed := 0.0
var _fps_timer := 0.0
var _fps_sum := 0.0
var _fps_count := 0
var _fps_min := 0.0
var _earned_at_dawn := 0
var _spent_at_dawn := 0

func _ready() -> void:
	_start_run()

## Part of GameManager.start_new_run(): a restarted run gets its own file.
func reset() -> void:
	_row = {}
	_start_run()

func _start_run() -> void:
	var t := Time.get_datetime_dict_from_system()
	run_id = "run_%04d%02d%02d_%02d%02d%02d" % [t.year, t.month, t.day, t.hour, t.minute, t.second]
	_path = "%s/%s.csv" % [RUNS_DIR, run_id]
	# Two runs started within the same second (a fast Restart) must not share
	# a file.
	var n := 2
	while FileAccess.file_exists(_path):
		_path = "%s/%s_%d.csv" % [RUNS_DIR, run_id, n]
		n += 1
	print("[RUNLOG] %s -> %s" % [run_id, ProjectSettings.globalize_path(_path)])

# --- Called by Main ----------------------------------------------------------
## Night N has started. Closes row N-1 (its Day just ended) and opens row N.
## `carryover_in` is also the closing row's carryover_out — the same survivors
## counted at the same moment, so the two can never disagree.
## `max_alive` and `walker_hp` are the night's escalation as Main computed
## it — the cap and a walker's max HP — so a run can be checked against
## docs/RUN_STRUCTURE.md's night-by-night table straight from the CSV.
## `night_type` is the SCHEDULED type (GameManager.night_type_name): TRANSIT
## on nights 9 and 25 even though they play as Siege for now.
func begin_night(night: int, night_type: String, pool: int, carryover_in: int,
		max_alive: int, walker_hp: int) -> void:
	if not _row.is_empty():
		_row["carryover_out"] = carryover_in
		_close_row("dusk")
	_row = {
		"run_id": run_id, "night": night, "night_type": night_type,
		# The position this night is fought at; a transit moves it at the
		# dawn AFTER, so night 9's row reads 1 and night 10's reads 2.
		"position": GameManager.current_position,
		"pool": pool, "carryover_in": carryover_in,
		"max_alive": max_alive, "walker_hp": walker_hp,
		"walker_kills_head": 0, "walker_kills_body": 0,
		"leaper_kills_head": 0, "leaper_kills_body": 0, "day_kills": 0,
		"max_alive_reached": 0, "player_hp_lost": 0, "ifaks_used": 0, "fighters_lost": 0,
	}
	_night_elapsed = 0.0
	_fps_timer = 0.0
	_fps_sum = 0.0
	_fps_count = 0
	_fps_min = 0.0
	_dawn_seen = false
	_earned_at_open = PointsManager.earned_this_run
	_spent_at_open = PointsManager.spent_this_run
	_by_category_at_open = PointsManager.spent_by_category.duplicate()

func mark_dawn() -> void:
	if _row.is_empty():
		return
	_dawn_seen = true
	_row["bank_at_dawn"] = PointsManager.points
	_earned_at_dawn = PointsManager.earned_this_run
	_spent_at_dawn = PointsManager.spent_this_run

## Main calls this once per scene with its player. Holds no reference: the
## connections are freed with the player, so a Restart's new player simply
## binds again.
func bind_player(player: Player) -> void:
	_last_hp = player.health.hp
	player.died_permanently.connect(on_player_died)
	player.health_changed.connect(_on_player_health)
	player.ifak_used.connect(_on_ifak_used)

## Player.died_permanently. A respawning death never fires that signal, so it
## never ends a row: the run goes on.
func on_player_died() -> void:
	if not _row.is_empty():
		_close_row("death")

## Player.health_changed fires on damage, heals and respawn alike; only a
## drop is a loss.
func _on_player_health(hp: int, _max_hp: int) -> void:
	if not _row.is_empty() and hp < _last_hp:
		_row["player_hp_lost"] += _last_hp - hp
	_last_hp = hp

func _on_ifak_used() -> void:
	if not _row.is_empty():
		_row["ifaks_used"] += 1

## Fighter.died, connected by Main where each fighter is created.
func on_fighter_died() -> void:
	if not _row.is_empty():
		_row["fighters_lost"] += 1

## Main reports the alive count after every spawn — the only moment it rises.
func note_alive(alive: int) -> void:
	if not _row.is_empty():
		_row["max_alive_reached"] = maxi(_row["max_alive_reached"], alive)

func _process(delta: float) -> void:
	if _row.is_empty() or GameManager.is_day():
		return
	_night_elapsed += delta
	if _night_elapsed < FPS_WARMUP:
		return
	_fps_timer += delta
	if _fps_timer < FPS_SAMPLE_INTERVAL:
		return
	_fps_timer -= FPS_SAMPLE_INTERVAL
	var fps := Engine.get_frames_per_second()
	_fps_min = fps if _fps_count == 0 else minf(_fps_min, fps)
	_fps_sum += fps
	_fps_count += 1

# --- Called by Zombie._die() -------------------------------------------------
## Night kills count by variant and killing blow. By Day, only kills a placed
## defense made count (day_kills) — the same rule that decides whether a Day
## kill scores. Outside a row (a test killing zombies before Night 1) nothing
## is recorded.
func record_kill(type_id: String, headshot: bool) -> void:
	if _row.is_empty():
		return
	if GameManager.is_day():
		if PointsManager.defense_credit_active():
			_row["day_kills"] += 1
		return
	var key := "%s_kills_%s" % [type_id, "head" if headshot else "body"]
	assert(_row.has(key), "[RUNLOG] no kill column for zombie type '%s'." % type_id)
	if _row.has(key):
		_row[key] += 1

# --- Quit --------------------------------------------------------------------
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _row.is_empty():
		_close_row("quit")

# --- Writing -----------------------------------------------------------------
func _close_row(ended_by: String) -> void:
	_row["ended_by"] = ended_by
	_row["points_earned"] = PointsManager.earned_this_run - _earned_at_open
	_fill_spend_columns()
	# Blank, not 0, when the night ended before the first sample.
	if _fps_count > 0:
		_row["fps_min"] = snappedf(_fps_min, 0.1)
		_row["fps_avg"] = snappedf(_fps_sum / _fps_count, 0.1)
	# Dusk only exists for a row that reached the next Night.
	if ended_by == "dusk":
		_row["bank_at_dusk"] = PointsManager.points
		if _dawn_seen:
			_assert_day_bank()
	_append(_row)
	print("[RUNLOG] night %d (%s): earned %d, kills W %d/%d L %d/%d (head/body), day kills %d, bank dawn %s dusk %s" % [
		_row["night"], ended_by, _row["points_earned"],
		_row["walker_kills_head"], _row["walker_kills_body"],
		_row["leaper_kills_head"], _row["leaper_kills_body"], _row["day_kills"],
		str(_row.get("bank_at_dawn", "-")), str(_row.get("bank_at_dusk", "-"))])
	_row = {}

## The Day's books must balance: every change to the bank between dawn and
## dusk is an award or a spend that went through PointsManager. A mismatch
## means something wrote `points` around it.
func _assert_day_bank() -> void:
	var day_earned: int = PointsManager.earned_this_run - _earned_at_dawn
	var day_spent: int = PointsManager.spent_this_run - _spent_at_dawn
	var expected: int = _row["bank_at_dawn"] + day_earned - day_spent
	assert(_row["bank_at_dusk"] == expected,
		"[RUNLOG] night %d: bank_at_dusk %d != bank_at_dawn %d + day earned %d - day spent %d (= %d). Something changed points without going through PointsManager." % [
			_row["night"], _row["bank_at_dusk"], _row["bank_at_dawn"], day_earned, day_spent, expected])

## Every spend in this row's window, by category. The categories must add up
## to everything PointsManager says was spent in the same window.
func _fill_spend_columns() -> void:
	assert(SPEND_COLUMNS.size() == PointsManager.SpendCategory.size(),
		"[RUNLOG] SPEND_COLUMNS out of step with PointsManager.SpendCategory.")
	var sum := 0
	for i in SPEND_COLUMNS.size():
		var spent: int = PointsManager.spent_by_category[i] - _by_category_at_open[i]
		_row[SPEND_COLUMNS[i]] = spent
		sum += spent
	var total: int = PointsManager.spent_this_run - _spent_at_open
	assert(sum == total,
		"[RUNLOG] night %d: spend categories sum to %d but %d was spent." % [_row["night"], sum, total])

func _append(row: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RUNS_DIR))
	var is_new := not FileAccess.file_exists(_path)
	var f := FileAccess.open(_path, FileAccess.WRITE if is_new else FileAccess.READ_WRITE)
	if f == null:
		push_error("[RUNLOG] could not open %s (error %d)." % [_path, FileAccess.get_open_error()])
		return
	f.seek_end()
	if is_new:
		f.store_line(",".join(COLUMNS))
	var cells: PackedStringArray = []
	for c in COLUMNS:
		cells.append(str(row[c]) if row.has(c) else "")
	f.store_line(",".join(cells))
	f.close()
