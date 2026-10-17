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
	"run_id", "night", "ended_by", "pool", "carryover_in", "carryover_out",
	"walker_kills_head", "walker_kills_body", "leaper_kills_head", "leaper_kills_body",
	"day_kills", "points_earned", "bank_at_dawn", "bank_at_dusk",
]

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
func begin_night(night: int, pool: int, carryover_in: int) -> void:
	if not _row.is_empty():
		_row["carryover_out"] = carryover_in
		_close_row("dusk")
	_row = {
		"run_id": run_id, "night": night, "pool": pool, "carryover_in": carryover_in,
		"walker_kills_head": 0, "walker_kills_body": 0,
		"leaper_kills_head": 0, "leaper_kills_body": 0, "day_kills": 0,
	}
	_dawn_seen = false
	_earned_at_open = PointsManager.earned_this_run

func mark_dawn() -> void:
	if _row.is_empty():
		return
	_dawn_seen = true
	_row["bank_at_dawn"] = PointsManager.points
	_earned_at_dawn = PointsManager.earned_this_run
	_spent_at_dawn = PointsManager.spent_this_run

## Wired by Main to Player.died_permanently. A respawning death never fires
## that signal, so it never ends a row: the run goes on.
func on_player_died() -> void:
	if not _row.is_empty():
		_close_row("death")

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
