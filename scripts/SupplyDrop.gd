extends Area3D
class_name SupplyDrop
## A collectable resupply crate. Reusable by design: the caller supplies the
## contents config, a spawn anchor, and a radius — the guaranteed dawn drop
## and the purchasable radio-callable Supply Drop enabler both instance this
## exact scene with different contents and different anchors. See
## docs/ROADMAP.md.

signal collected(summary: String)
## Fired once, the moment the crate has nothing left to give and frees
## itself. Distinct from `collected`, which can fire multiple times — once
## per partial pickup — if the player was at a carry cap on an earlier visit.
signal emptied()

const PLACE_ATTEMPTS := 10
const MIN_PLAYER_DISTANCE := 2.0

## Live REMAINING contents — mutated in place as they're picked up, not a
## fixed order slip. `magazines_by_weapon` maps weapon id -> magazines still
## owed for that weapon, snapshotted from ownership at the moment the crate
## was configured (not re-evaluated against whatever's owned at loot time —
## "computed at call time from current loadout" is the point of a supply
## drop being tied to what you were carrying when you called it in).
var magazines_by_weapon: Dictionary = {}
## Grenades and IFAKs are carry-capped, so a pickup can be PARTIAL: whatever
## doesn't fit stays here rather than being destroyed, and is lootable on a
## later visit once the player has room. Magazines have no cap
## (AmmoManager.grant_ammo is uncapped) so they never have this problem —
## granted in full the instant the crate is first opened.
var grenades_remaining: int = 0
var ifaks_remaining: int = 0

var _player_inside := false
var _player: Player = null
var _hud: HUD = null
var _emptied := false

func _ready() -> void:
	add_to_group("supply_drops")
	# Layer 2 (like the crate trigger) keeps it out of the weapon ray mask.
	collision_layer = 2
	collision_mask = 1
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_build_visuals()

## contents_config shape: {"magazines_by_weapon": {weapon_id: mags, ...},
## "grenades": int, "ifaks": int}. Any key may be omitted (treated as empty/0).
func setup(hud: HUD, contents_config: Dictionary = {}) -> void:
	_hud = hud
	magazines_by_weapon = contents_config.get("magazines_by_weapon", {}).duplicate()
	grenades_remaining = contents_config.get("grenades", 0)
	ifaks_remaining = contents_config.get("ifaks", 0)

# --- Placement ------------------------------------------------------------
## Finds a valid spot within `radius` of `anchor`, at least MIN_PLAYER_DISTANCE
## from `player_pos`, on walkable ground and clear of geometry. Re-rolls up to
## PLACE_ATTEMPTS times, then falls back to a known-good offset from the anchor.
static func find_spawn_point(world: World3D, anchor: Vector3, radius: float,
		player_pos: Vector3) -> Vector3:
	var space := world.direct_space_state
	for i in PLACE_ATTEMPTS:
		var ang := randf() * TAU
		var r := sqrt(randf()) * radius          # uniform within the disk
		var candidate := anchor + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		if candidate.distance_to(player_pos) < MIN_PLAYER_DISTANCE:
			continue
		# Drop onto ground: trace down from above.
		var from := candidate + Vector3(0, 4.0, 0)
		var to := candidate + Vector3(0, -2.0, 0)
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.collision_mask = 1
		var hit := space.intersect_ray(q)
		if not hit:
			continue
		var ground: Vector3 = hit.position
		# Reject slopes and anything that isn't roughly flat, walkable ground.
		if hit.normal.dot(Vector3.UP) < 0.85:
			continue
		# Reject if the crate volume would intersect geometry (structures,
		# sandbags, trees, the supply crate itself).
		if volume_blocked(space, ground + Vector3(0, 0.45, 0)):
			continue
		return ground

	# Fallback: a fixed known-good offset from the anchor.
	return anchor + Vector3(2.5, 0.0, 2.5)

## Would a crate-sized volume centred here intersect world geometry?
## PUBLIC and static: SupplyDropSystem's landing solve asks the same question
## of its own candidate points, and "is there room for a crate" must mean one
## thing for both spawn paths.
static func volume_blocked(space: PhysicsDirectSpaceState3D, centre: Vector3) -> bool:
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.9, 0.9, 0.9)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, centre)
	params.collision_mask = 1
	return space.intersect_shape(params, 1).size() > 0

# --- Visuals --------------------------------------------------------------
func _build_visuals() -> void:
	# Deliberately distinct from the supply crate: a squat emissive orange
	# cylinder rather than a brown box, so it reads clearly under NVGs.
	var body := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.45
	cyl.bottom_radius = 0.45
	cyl.height = 0.7
	body.mesh = cyl
	body.position.y = 0.35
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.5, 0.05)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.45, 0.05)
	mat.emission_energy_multiplier = 2.0
	body.material_override = mat
	add_child(body)

	# A tall thin marker so it's findable across the clearing.
	var beacon := MeshInstance3D.new()
	var bcyl := CylinderMesh.new()
	bcyl.top_radius = 0.04
	bcyl.bottom_radius = 0.04
	bcyl.height = 2.5
	beacon.mesh = bcyl
	beacon.position.y = 1.9
	var bmat := StandardMaterial3D.new()
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bmat.albedo_color = Color(1.0, 0.6, 0.1, 0.35)
	bmat.emission_enabled = true
	bmat.emission = Color(1.0, 0.6, 0.1)
	bmat.emission_energy_multiplier = 3.0
	beacon.material_override = bmat
	add_child(beacon)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(3.0, 3.0, 3.0)
	col.shape = shape
	col.position.y = 1.0
	add_child(col)

# --- Interaction ----------------------------------------------------------
func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player"):
		_player_inside = true
		_player = body as Player

func _on_body_exited(body: Node3D) -> void:
	if body.is_in_group("player"):
		_player_inside = false
		_player = null
		if _hud:
			_hud.hide_prompt(self)

func _process(_delta: float) -> void:
	if _hud and _player_inside and not _emptied:
		_hud.show_prompt("Press E to collect resupply", self)

func _unhandled_input(event: InputEvent) -> void:
	if _emptied or not _player_inside or _player == null:
		return
	if event.is_action_pressed("interact"):
		_collect()
		get_viewport().set_input_as_handled()

## Grants everything that currently fits. Magazines are uncapped and always
## fully granted the first time this runs, then cleared. Grenades and IFAKs
## grant only what fits under the player's carry cap right now — whatever
## doesn't is left in `grenades_remaining`/`ifaks_remaining` for a later
## visit, never discarded. The crate only frees itself once every field is
## drained to zero.
func _collect() -> void:
	var granted: Array = []

	if not magazines_by_weapon.is_empty():
		for id in magazines_by_weapon.keys():
			var mags: int = magazines_by_weapon[id]
			if mags <= 0:
				continue
			# All ammo routes through AmmoManager — never a direct write.
			var rounds: int = AmmoManager.grant_ammo(id, mags)
			if rounds > 0:
				var w = Arsenal.get_weapon(id)
				granted.append("%s +%d" % [w.display_name if w else id, rounds])
		magazines_by_weapon.clear()

	# grant_grenades() reports exactly how many actually fit under the carry
	# cap, so the remainder IS simply what's left over — no separate
	# "lost"/destroyed branch needed the way the single-shot version had.
	if grenades_remaining > 0:
		var took: int = _player.grant_grenades(grenades_remaining)
		grenades_remaining -= took
		if took > 0:
			granted.append("Grenade +%d" % took)

	# add_ifak() only reports success/failure for ONE unit at a time (no
	# equivalent to grant_grenades()'s returned count), so it's called once
	# per remaining IFAK rather than all at once — the only way to learn
	# exactly how many fit without changing that shared API.
	var ifaks_taken := 0
	while ifaks_remaining > 0 and _player.add_ifak(1):
		ifaks_remaining -= 1
		ifaks_taken += 1
	if ifaks_taken > 0:
		granted.append("IFAK +%d" % ifaks_taken)

	var summary := ", ".join(granted) if granted.size() > 0 else "nothing to take right now"
	print("[RESUPPLY] collected — %s" % summary)
	if _hud:
		_hud.show_message("RESUPPLY: %s" % summary)
	collected.emit(summary)

	if magazines_by_weapon.is_empty() and grenades_remaining <= 0 and ifaks_remaining <= 0:
		_emptied = true
		if _hud:
			_hud.hide_prompt(self)
		emptied.emit()
		queue_free()
	# else: contents remain — the crate stays in the world, unchanged, for a
	# later visit once the player has carry-cap room.
