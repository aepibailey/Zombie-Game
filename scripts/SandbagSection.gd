extends Obstacle
class_name SandbagSection
## A destructible 10m sandbag wall. Each section is independent: damage never
## spreads between sections, so a breach opens exactly one gap.
##
## Pacing: 4000 HP against 15 damage per 1.2s per zombie = 12.5 dps each.
## One zombie needs ~320s (longer than a 120s night); eight need ~40s. Turtling
## is viable, but a mass of zombies will eventually come through.

signal destroyed_section(section)

@export var max_health: float = 4000.0
## Health fractions at which the visual state changes.
@export var damaged_at: float = 0.66
@export var heavily_damaged_at: float = 0.33

const SFX_IMPACT := "res://audio/impact.wav"

var health: float = 4000.0
var destroyed := false

var _mat: StandardMaterial3D
var _sfx: AudioStreamPlayer3D
var _sfx_cooldown := 0.0

func setup(t) -> void:
	super.setup(t)
	add_to_group("sandbags")
	health = max_health
	_mat = _visual.material_override
	_build_audio()
	_refresh_damage_state()

func _build_audio() -> void:
	_sfx = AudioStreamPlayer3D.new()
	# Spatialised so the player can hear WHICH section is being worked.
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

## Closest point on the wall's face to `from` — what attackers walk up to.
func nearest_point(from: Vector3) -> Vector3:
	var size: Vector3 = obstacle_type.size
	var local := (from - global_position).rotated(Vector3.UP, -rotation.y)
	var hx: float = size.x * 0.5
	var clamped := Vector3(clampf(local.x, -hx, hx), 0.0, 0.0)
	return global_position + clamped.rotated(Vector3.UP, rotation.y)

## Damage from a zombie. `from` positions the impact sound at the point being
## worked rather than at the section's centre.
func take_structure_damage(amount: float, from: Vector3) -> void:
	if destroyed:
		return
	health = maxf(0.0, health - amount)
	_play_impact(from)
	_refresh_damage_state()
	if health <= 0.0:
		_destroy()

func _play_impact(from: Vector3) -> void:
	# Rate-limited per section, so eight zombies on one wall read as a heavier,
	# busier sound rather than a distorted overlap of sixty samples.
	if _sfx_cooldown > 0.0 or _sfx.stream == null:
		return
	_sfx_cooldown = 0.12
	_sfx.global_position = nearest_point(from) + Vector3(0, 0.6, 0)
	_sfx.pitch_scale = randf_range(0.75, 0.95)
	_sfx.play()

## Three states, driven by health. Not decoration: if the player is enclosed,
## they need to see at a glance which section is about to fail.
func _refresh_damage_state() -> void:
	if _mat == null:
		return
	var frac: float = health / max_health
	if frac > damaged_at:
		_mat.albedo_color = obstacle_type.color
		_visual.scale = Vector3.ONE
	elif frac > heavily_damaged_at:
		_mat.albedo_color = obstacle_type.color.darkened(0.25) * Color(1.1, 0.95, 0.85)
		_visual.scale = Vector3(1.0, 0.88, 1.0)
	else:
		_mat.albedo_color = obstacle_type.color.darkened(0.5) * Color(1.2, 0.8, 0.7)
		_visual.scale = Vector3(1.0, 0.7, 1.0)

func health_fraction() -> float:
	return health / max_health

## Repair cost scales with what's missing — see BuildMode.
func repair_cost(full_cost: int) -> int:
	return int(ceil(full_cost * (1.0 - health_fraction())))

func repair() -> void:
	health = max_health
	_refresh_damage_state()

func _destroy() -> void:
	destroyed = true
	destroyed_section.emit(self)
	queue_free()
