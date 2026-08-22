extends Node3D
class_name Apache
## The AH-64 actor: transit in, hold a distant orbit, depart. Blockout visual
## only — primitive meshes and a running light, no art, animation or audio.
##
## THE ORBIT IS ATMOSPHERE. This node writes its own transform and nothing
## else reads it. The aircraft services targets from standoff with an optical
## sensor and a stabilized gun, so its POSITION MUST NEVER GATE A SHOT — see
## ApacheSystem's class docstring for how that is enforced structurally rather
## than by discipline. Nothing in this file may be handed to the targeting
## code, and this file must never query a zombie.
##
## EMITS NO NOISE. Deliberately does not reference NoiseManager at any point.
## The aircraft must never attract, alert or reorient a single zombie.
##
## Cannot be damaged, has no health, and joins no damageable group.

## The aircraft is in exactly one of these at a time.
enum State { TRANSIT, ON_STATION, DEPARTING }

## Distance beyond the orbit that the aircraft spawns at and departs to. Not
## a tunable: it only has to be far enough to be offmap at both ends, and a
## second knob for it would just be another number to keep consistent with
## standoff_distance.
const OFFMAP_DISTANCE := 400.0
## How long the departure run takes before the actor frees itself.
const DEPART_DURATION := 10.0
## Group used for the single-instance assertion.
const GROUP := "apache"

var config: ApacheConfig

var state: int = State.TRANSIT
## Centre of the painted patrol box. Stored so the orbit can be positioned
## relative to it. NEVER used for a distance test against a target.
var _box_centre := Vector3.ZERO
## Centre of the orbit — standoff_distance from the box, along _bearing.
var _orbit_centre := Vector3.ZERO
## Compass bearing the aircraft holds off the box, chosen once at spawn.
var _bearing := 0.0
var _orbit_angle := 0.0

## Where the orbit centre is drifting TOWARD after a retask. Purely cosmetic:
## it stops the orbit looking absurd when a box is called on the far side of
## the map, and it CANNOT gate firing, because nothing in the targeting path
## can see this node at all (see ApacheSystem._acquire_target()).
var _orbit_centre_target := Vector3.ZERO
## Metres per second the orbit centre drifts. Cosmetic only — not a tunable,
## because no gameplay outcome depends on it.
const ORBIT_DRIFT_SPEED := 12.0

var _transit_from := Vector3.ZERO
var _transit_elapsed := 0.0
## Counts ONLY while ON_STATION. Transit does not consume station time.
var _station_elapsed := 0.0
var _depart_elapsed := 0.0
var _depart_from := Vector3.ZERO
var _depart_to := Vector3.ZERO

var _on_station_cb: Callable
var _on_departed_cb: Callable
var _checked_in := false

## `on_station` fires once when the aircraft finishes transit and begins its
## orbit. `on_departed` fires once, just before the actor frees itself — that
## is the event the cooldown hangs off.
static func spawn(parent: Node, box_centre: Vector3, cfg: ApacheConfig,
		on_station: Callable, on_departed: Callable) -> Apache:
	# EXACTLY ONE APACHE AT A TIME. ApacheSystem's own _sortie handle is the
	# first line of defence; this asserts the scene tree actually agrees.
	var existing := parent.get_tree().get_nodes_in_group(GROUP)
	assert(existing.is_empty(),
		"[APACHE] tried to spawn a second Apache while %d already on station — exactly one may exist at a time." % existing.size())
	if not existing.is_empty():
		push_error("[APACHE] refusing to spawn a second Apache; one is already on station.")
		return null

	var a := Apache.new()
	a.name = "Apache"
	a.config = cfg
	a._box_centre = box_centre
	a._on_station_cb = on_station
	a._on_departed_cb = on_departed
	parent.add_child(a)
	a._begin_transit()
	return a

func _ready() -> void:
	add_to_group(GROUP)

func _begin_transit() -> void:
	# A bearing chosen once, held for the sortie. The orbit sits a long way
	# off the box on this bearing so the airframe reads as a distant
	# silhouette rather than an overhead gunship.
	_bearing = randf() * TAU
	var offset := Vector3(cos(_bearing), 0.0, sin(_bearing)) * config.standoff_distance
	_orbit_centre = _box_centre + offset
	_orbit_centre.y = _box_centre.y + config.orbit_altitude

	# Inbound from further out along the same bearing, so it arrives from
	# somewhere plausible instead of fading in on top of its own orbit.
	_transit_from = _orbit_centre + Vector3(cos(_bearing), 0.0, sin(_bearing)) * OFFMAP_DISTANCE
	_transit_from.y = _orbit_centre.y + 60.0

	_orbit_centre_target = _orbit_centre
	state = State.TRANSIT
	_transit_elapsed = 0.0
	global_position = _transit_from
	_build_visuals()

## A new patrol box has been designated. The aircraft DOES NOT reposition to
## service it — it keeps its orbit and its gun reaches the new box from
## wherever it is, because engagement never depends on where the airframe is.
## All this does is start a slow COSMETIC drift of the orbit centre toward the
## new standoff point, so a box called across the map doesn't leave the
## aircraft orbiting a visibly unrelated patch of sky.
##
## Deliberately touches no clock: retasking costs no station time.
func retask(new_box_centre: Vector3) -> void:
	_box_centre = new_box_centre
	var offset := Vector3(cos(_bearing), 0.0, sin(_bearing)) * config.standoff_distance
	_orbit_centre_target = new_box_centre + offset
	_orbit_centre_target.y = new_box_centre.y + config.orbit_altitude

func is_on_station() -> bool:
	return state == State.ON_STATION

## Seconds of station time left. Reads the clock that only advances while
## ON_STATION, so transit never eats into it.
func station_time_left() -> float:
	return maxf(0.0, config.time_on_station - _station_elapsed)

## Leave now rather than waiting out the station clock. Phase 3 calls this on
## winchester; departing early is otherwise identical to departing on time.
func depart_now(reason: String) -> void:
	if state == State.DEPARTING:
		return
	print("[APACHE] departing — %s" % reason)
	state = State.DEPARTING
	_depart_elapsed = 0.0
	_depart_from = global_position
	# Outbound along the holding bearing, climbing as it goes.
	_depart_to = _orbit_centre \
		+ Vector3(cos(_bearing), 0.0, sin(_bearing)) * OFFMAP_DISTANCE \
		+ Vector3(0.0, 80.0, 0.0)

func _process(delta: float) -> void:
	match state:
		State.TRANSIT:
			_tick_transit(delta)
		State.ON_STATION:
			_tick_station(delta)
		State.DEPARTING:
			_tick_depart(delta)

func _tick_transit(delta: float) -> void:
	_transit_elapsed += delta
	var t: float = clampf(_transit_elapsed / maxf(0.1, config.transit_time_in), 0.0, 1.0)
	# Ease-in-out: accelerates out of the spawn point and settles onto the
	# orbit rather than arriving at full speed and snapping.
	var eased: float = t * t * (3.0 - 2.0 * t)
	var entry := _orbit_point(0.0)
	global_position = _transit_from.lerp(entry, eased)
	_face_travel(entry)
	if t >= 1.0:
		_check_in()

func _check_in() -> void:
	state = State.ON_STATION
	_orbit_angle = 0.0
	_station_elapsed = 0.0
	if not _checked_in:
		_checked_in = true
		if _on_station_cb.is_valid():
			_on_station_cb.call()

func _tick_station(delta: float) -> void:
	_station_elapsed += delta
	# Cosmetic drift toward a retasked box's standoff point. Never gates
	# anything — the gun is already servicing the new box.
	if _orbit_centre != _orbit_centre_target:
		_orbit_centre = _orbit_centre.move_toward(
			_orbit_centre_target, ORBIT_DRIFT_SPEED * delta)
	_orbit_angle += config.orbit_speed * delta
	var prev := global_position
	global_position = _orbit_point(_orbit_angle)
	_face_travel(prev + (global_position - prev) * 2.0)
	if _station_elapsed >= config.time_on_station:
		depart_now("station time expired")

func _tick_depart(delta: float) -> void:
	_depart_elapsed += delta
	var t: float = clampf(_depart_elapsed / DEPART_DURATION, 0.0, 1.0)
	global_position = _depart_from.lerp(_depart_to, t * t)   # accelerating away
	_face_travel(_depart_to)
	if t >= 1.0:
		# Fired BEFORE queue_free so the listener can act while this node is
		# still valid. Cooldown hangs off this event — see ApacheSystem.
		if _on_departed_cb.is_valid():
			_on_departed_cb.call()
		queue_free()

## A point on the orbit at `angle`. Pure geometry, no side effects — and
## deliberately the only thing that knows where the aircraft is.
func _orbit_point(angle: float) -> Vector3:
	return _orbit_centre + Vector3(cos(angle), 0.0, sin(angle)) * config.orbit_radius

## Points the airframe along its direction of travel. Cosmetic only.
func _face_travel(toward: Vector3) -> void:
	var flat := toward - global_position
	flat.y = 0.0
	if flat.length_squared() < 0.01:
		return
	look_at(global_position + flat, Vector3.UP)

# --- Blockout visual ----------------------------------------------------------
## Primitive meshes only. Unshaded and emissive so the silhouette reads at
## night against a dark sky at standoff range, which is the whole point of
## having a visual at all.
func _build_visuals() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	body_mat.albedo_color = Color(0.14, 0.16, 0.14)

	# Fuselage.
	var hull := MeshInstance3D.new()
	var hull_mesh := BoxMesh.new()
	hull_mesh.size = Vector3(1.8, 1.6, 7.0)
	hull.mesh = hull_mesh
	hull.material_override = body_mat
	hull.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(hull)

	# Tail boom.
	var boom := MeshInstance3D.new()
	var boom_mesh := BoxMesh.new()
	boom_mesh.size = Vector3(0.5, 0.5, 4.5)
	boom.mesh = boom_mesh
	boom.position = Vector3(0.0, 0.3, 5.2)
	boom.material_override = body_mat
	boom.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(boom)

	# Main rotor disc — a thin flat cylinder, not blades. Blockout.
	var rotor := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 7.3
	disc.bottom_radius = 7.3
	disc.height = 0.06
	rotor.mesh = disc
	rotor.position.y = 1.5
	var rotor_mat := StandardMaterial3D.new()
	rotor_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rotor_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rotor_mat.albedo_color = Color(0.5, 0.53, 0.5, 0.22)
	rotor.material_override = rotor_mat
	rotor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(rotor)

	# Anti-collision light. The only thing reliably visible at 250m on a dark
	# night, and the cue the player uses to find the aircraft at all.
	var light := MeshInstance3D.new()
	var bulb := SphereMesh.new()
	bulb.radius = 0.32
	bulb.height = 0.64
	light.mesh = bulb
	light.position = Vector3(0.0, -0.9, 0.0)
	var light_mat := StandardMaterial3D.new()
	light_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	light_mat.albedo_color = Color(1.0, 0.1, 0.08)
	light_mat.emission_enabled = true
	light_mat.emission = Color(1.0, 0.1, 0.08)
	light_mat.emission_energy_multiplier = 6.0
	light.material_override = light_mat
	light.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(light)
