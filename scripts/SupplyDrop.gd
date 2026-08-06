extends Area3D
class_name SupplyDrop
## A collectable resupply crate. Reusable by design: the caller supplies the
## contents config, a spawn anchor, and a radius, so the future purchasable
## supply-drop enabler instances this exact scene with the player as anchor and
## different contents — no changes here. See docs/ROADMAP.md.

signal collected(summary: String)

const PLACE_ATTEMPTS := 10
const MIN_PLAYER_DISTANCE := 2.0

## Contents config.
##   `magazines` — mags granted per owned weapon.
##   `grenades`  — hand grenades granted, subject to the carry cap.
## Future enablers can pass a different config (e.g. specific weapons only).
var contents: Dictionary = {"magazines": 1, "grenades": 1}

var _player_inside := false
var _player: Player = null
var _hud: HUD = null
var _collected := false

func _ready() -> void:
	add_to_group("supply_drops")
	# Layer 2 (like the crate trigger) keeps it out of the weapon ray mask.
	collision_layer = 2
	collision_mask = 1
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_build_visuals()

func setup(hud: HUD, contents_config: Dictionary = {}) -> void:
	_hud = hud
	if not contents_config.is_empty():
		contents = contents_config

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
		if _volume_blocked(space, ground + Vector3(0, 0.45, 0)):
			continue
		return ground

	# Fallback: a fixed known-good offset from the anchor.
	return anchor + Vector3(2.5, 0.0, 2.5)

static func _volume_blocked(space: PhysicsDirectSpaceState3D, centre: Vector3) -> bool:
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
	if _hud and _player_inside and not _collected:
		_hud.show_prompt("Press E to collect resupply", self)

func _unhandled_input(event: InputEvent) -> void:
	if _collected or not _player_inside or _player == null:
		return
	if event.is_action_pressed("interact"):
		_collect()
		get_viewport().set_input_as_handled()

func _collect() -> void:
	_collected = true
	var mags: int = contents.get("magazines", 1)
	var granted: Array = []
	# One magazine per OWNED weapon; unowned weapons grant nothing.
	for id in _player.owned_weapons():
		# All ammo routes through AmmoManager — never a direct write.
		var rounds: int = AmmoManager.grant_ammo(id, mags)
		if rounds > 0:
			granted.append("%s +%d" % [Arsenal.get_weapon(id).display_name, rounds])

	# Grenades go through the SAME capped grant path a crate purchase uses, so
	# the carry cap is enforced in exactly one place. grant_grenades() returns
	# what it actually took: at 4 carried it takes 0 and the drop's grenade is
	# LOST rather than overflowing the cap or being held for later. Reported
	# either way, so a wasted grenade is visible and not silent.
	var want_nades: int = contents.get("grenades", 0)
	if want_nades > 0:
		var took: int = _player.grant_grenades(want_nades)
		if took > 0:
			granted.append("Grenade +%d" % took)
		else:
			granted.append("Grenade lost (carrying %d/%d)" % [
				_player.grenades, _player.grenade_max_carry])

	var summary := ", ".join(granted) if granted.size() > 0 else "nothing (no weapons owned)"
	print("[RESUPPLY] collected — %s" % summary)
	if _hud:
		_hud.hide_prompt(self)
		_hud.show_message("RESUPPLY: %s" % summary)
	collected.emit(summary)
	queue_free()
