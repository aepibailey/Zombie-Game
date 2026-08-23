extends Node3D
class_name SandbagPanel
## One of 5 independently destructible sections making up a SandbagWall.
## Damage never spreads between panels — a breach opens exactly one 2m gap,
## not the whole 10m wall.
##
## This is deliberately NOT an Obstacle subclass. Obstacle owns
## placement/footprint/persistence concerns that belong to the WALL (the
## thing actually placed and priced), not to one fifth of it — see
## SandbagWall.gd, which builds 5 of these instead of calling the generic
## single-box Obstacle._build_visual().
##
## Joins the "sandbags" group directly (not the wall) so the EXISTING
## consumers — AreaDamageSystem._damage_structures() and
## Zombie._try_enter_attack_structure() — automatically operate at
## per-section granularity with no changes of their own: both already
## iterate every group member independently and judge each by its own
## nearest_point()/distance. Sectioning the sandbag was a property of WHAT'S
## in the group, not of the code that queries it.

## Fires on any change to health/destroyed state (damage, destroy, OR
## repair) — SandbagWall forwards this up so BuildMode can request a navmesh
## rebake. Repair needs this exactly as much as destruction does: restoring
## a collision shape closes a gap the navmesh has to know about again.
signal changed

## PRIMARY: current_total_health * 0.25 / 5 — 5 sections replace one 4000 HP
## wall at a QUARTER of its total durability (1000 HP across the wall, was
## 4000), because each section is also 1/5 the material to chew through.
## At the zombie siege rate of 15 dmg/1.2s (12.5 dps), one section (200 HP)
## falls in ~16s to a single zombie — a full 5-section breach is ~80s,
## still much faster than the old wall's ~320s. Reported, not silently
## changed further: see PATROL_BASE_ZERO_V2_SPEC.md "Sandbags" for the full
## pacing comparison.
##
## ALTERNATIVE (uncomment to use instead — same total-wall cost, no length
## discount, i.e. durability roughly matches the old 4000 HP wall spread
## across 5 tougher sections):
## @export var section_health: float = 4000.0 * 0.25          # 1000/section
@export var section_health: float = 4000.0 * 0.25 / 5.0        # 200/section

## Health fractions at which the visual state changes — same thresholds the
## whole-wall version used, now per-panel.
@export var damaged_at: float = 0.66
@export var heavily_damaged_at: float = 0.33

const SFX_IMPACT := "res://audio/impact.wav"

var health: float
var destroyed := false

var _size: Vector3           # this panel's own local box size (not the wall's)
var _base_color: Color
var _visual: MeshInstance3D
var _solid: StaticBody3D
var _shape: CollisionShape3D
var _mat: StandardMaterial3D
var _sfx: AudioStreamPlayer3D
var _sfx_cooldown := 0.0
## Cover retrofit (Step 8A): SOLID, blocking both rounds and LOS. Wraps the
## SAME _solid body above — the panel keeps owning its own HP/destroy/repair,
## this only tracks the panel's cover/concealment layer membership. Not given
## a `world` reference: SandbagWall's own `changed` -> BuildMode ->
## request_navmesh_rebake() pipeline already fires on every destroy/repair,
## so a second rebake request here would be redundant.
var _cover: CoverSurface

## `size` is THIS PANEL's own box (wall_size / 5 along X), `local_x` is its
## centre offset along the wall's length, `color` is the wall type's colour.
func setup(size: Vector3, local_x: float, color: Color) -> void:
	_size = size
	_base_color = color
	position.x = local_x
	health = section_health
	_build_visual()
	_build_solid()
	_build_audio()
	add_to_group("sandbags")
	_refresh_visual_state()

func _build_visual() -> void:
	_visual = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = _size
	_visual.mesh = box
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = _base_color
	_visual.material_override = _mat
	_visual.position.y = _size.y * 0.5
	add_child(_visual)

func _build_solid() -> void:
	_solid = StaticBody3D.new()
	_solid.collision_layer = 1
	_solid.collision_mask = 1
	_shape = CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = _size
	_shape.shape = shape
	_shape.position.y = _size.y * 0.5
	_solid.add_child(_shape)
	add_child(_solid)
	_cover = CoverSurface.new()
	_cover.cover_type = CoverSurface.Type.SOLID
	add_child(_cover)
	_cover.attach_to(_solid)

func _build_audio() -> void:
	_sfx = AudioStreamPlayer3D.new()
	_sfx.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_sfx.max_distance = 45.0
	_sfx.unit_size = 4.0
	_sfx.volume_db = 2.0
	if ResourceLoader.exists(SFX_IMPACT):
		var res = load(SFX_IMPACT)
		_sfx.stream = res
	_sfx.position.y = 0.6
	add_child(_sfx)

func _process(delta: float) -> void:
	if _sfx_cooldown > 0.0:
		_sfx_cooldown -= delta

## Closest point on THIS PANEL's own face — clamped to its own 2m span, not
## the whole wall's 10m. Same contract as the old whole-wall nearest_point(),
## so Zombie.gd and AreaDamageSystem need no changes.
func nearest_point(from: Vector3) -> Vector3:
	var local := (from - global_position).rotated(Vector3.UP, -global_rotation.y)
	var hx: float = _size.x * 0.5
	var clamped := Vector3(clampf(local.x, -hx, hx), 0.0, 0.0)
	return global_position + clamped.rotated(Vector3.UP, global_rotation.y)

func take_structure_damage(amount: float, from: Vector3) -> void:
	if destroyed:
		return
	health = maxf(0.0, health - amount)
	print("[SANDBAG] %s#%d @ (%.1f,%.1f,%.1f) — %.0f dmg, %.0f/%.0f HP left" % [
		name, get_instance_id(), global_position.x, global_position.y, global_position.z,
		amount, health, section_health])
	_play_impact(from)
	_refresh_visual_state()
	changed.emit()
	if health <= 0.0:
		_destroy()

func _play_impact(from: Vector3) -> void:
	if _sfx_cooldown > 0.0 or _sfx.stream == null:
		return
	_sfx_cooldown = 0.12
	_sfx.global_position = nearest_point(from) + Vector3(0, 0.6, 0)
	_sfx.pitch_scale = randf_range(0.75, 0.95)
	_sfx.play()

func health_fraction() -> float:
	return health / section_health

## Human-readable state for the repair UI — same thresholds _refresh_visual_state()
## grades by, named for a player rather than expressed as a fraction.
func state_label() -> String:
	if destroyed:
		return "DESTROYED"
	var frac := health_fraction()
	if frac > damaged_at:
		return "INTACT"
	if frac > heavily_damaged_at:
		return "DAMAGED"
	return "CRITICAL"

## `section_repair_cost` is the WALL's per-section constant (ceil(wall price
## / 5), computed once in SandbagWall.setup()) — repair pricing is derived
## pro-rata from what a full section costs to rebuild, same relationship the
## old whole-wall repair used. Minimum 1 point so a barely-scratched section
## is never a free top-up.
func repair_cost(section_repair_cost: int) -> int:
	return maxi(1, int(ceil(section_repair_cost * (1.0 - health_fraction()))))

func repair() -> void:
	health = section_health
	destroyed = false
	if _shape:
		_shape.set_deferred("disabled", false)
	if _cover:
		_cover.restore()
	_refresh_visual_state()
	changed.emit()

## Three READABLE states while standing (intact / damaged / critical) plus a
## fourth, visually distinct DESTROYED rubble state. Tint is a brightness
## change (darkened, not hue-shifted), and sag is a geometric silhouette
## change — both read under the NVG green tint, which multiplies toward
## green but preserves relative brightness/outline, unlike a colour-coded
## (e.g. red/yellow/green) scheme that a monochrome tint could wash out.
func _refresh_visual_state() -> void:
	if destroyed:
		_apply_rubble_state()
		return
	var frac: float = health_fraction()
	if frac > damaged_at:
		_mat.albedo_color = _base_color
		_visual.scale = Vector3.ONE
		_visual.position.y = _size.y * 0.5
	elif frac > heavily_damaged_at:
		_mat.albedo_color = _base_color.darkened(0.25) * Color(1.1, 0.95, 0.85)
		_visual.scale = Vector3(1.0, 0.88, 1.0)
		_visual.position.y = _size.y * 0.5 * 0.88
	else:
		_mat.albedo_color = _base_color.darkened(0.5) * Color(1.2, 0.8, 0.7)
		_visual.scale = Vector3(1.0, 0.7, 1.0)
		_visual.position.y = _size.y * 0.5 * 0.7

## Flattened/scattered rubble: a scaled-down, sunk copy of the SAME box mesh
## — no new art, as specified. Deliberately more collapsed than the
## "critical" standing state (0.12 vs 0.7 vertical scale) and sunk toward
## ground level rather than merely shortened, so it silhouettes as "gone",
## not "badly hurt but still up".
func _apply_rubble_state() -> void:
	_mat.albedo_color = _base_color.darkened(0.7) * Color(1.0, 0.9, 0.8)
	_visual.scale = Vector3(1.05, 0.12, 1.05)
	_visual.position.y = _size.y * 0.06

func _destroy() -> void:
	destroyed = true
	print("[SANDBAG] %s#%d @ (%.1f,%.1f,%.1f) — DESTROYED" % [
		name, get_instance_id(), global_position.x, global_position.y, global_position.z])
	# Collision disabled, NOT freed: unlike the old whole-wall version, a
	# destroyed panel must persist and stay repairable (see SandbagWall's
	# "all 5 destroyed -> inactive, never removed" behaviour). set_deferred
	# because this can be called from within a physics query callback
	# (a zombie's melee hit, an area-damage raycast pass).
	if _shape:
		_shape.set_deferred("disabled", true)
	# Deferred, and queued AFTER the shape-disable above: notify_destroyed()'s
	# own assertion reads _shape.disabled, which set_deferred() above hasn't
	# actually applied yet at this point in the same callback — queuing both
	# as deferred calls (in this order) means the assertion sees the real
	# post-teardown state instead of a stale one.
	if _cover:
		_cover.call_deferred("notify_destroyed")
	_refresh_visual_state()
	changed.emit()

# --- Persistence (called by SandbagWall, not GameState directly) ----------
func to_dict() -> Dictionary:
	return {"health": health, "destroyed": destroyed}

func apply_from_dict(d: Dictionary) -> void:
	destroyed = d.get("destroyed", false)
	health = clampf(d.get("health", section_health), 0.0, section_health)
	if _shape:
		_shape.set_deferred("disabled", destroyed)
	_refresh_visual_state()
