extends Node3D
class_name HealthBar3D
## Reusable world-space health bar. NOT sandbag-specific — `attach_to()`
## takes any owner node plus the two property names to poll, so any future
## destructible (mortar-damaged sandbags, a destructible gate, whatever)
## gets a working bar by adding three lines at its own _ready(), not by
## subclassing or duplicating this file.
##
## Deliberately POLLING rather than signal-driven: requiring every future
## damageable to emit a specific health-changed signal would make this
## "reusable" component secretly coupled to a signal contract nothing is
## obligated to implement. Polling `owner.get(prop)` only needs the two
## properties to exist — the same duck-typed pattern already used elsewhere
## in this codebase (AreaDamageSystem's `s.get("destroyed")`,
## Obstacle's `set("_post_mat", mat)` for the minefield markers).
##
## Billboarding is material-level (BILLBOARD_ENABLED on an unshaded quad),
## not a per-frame look_at() — same technique Player.gd's laser dot/halo
## already use, so it costs nothing extra per frame and needs no script-side
## camera tracking.

const VISIBLE_DURATION := 4.0    # seconds shown at full opacity after a hit
const FADE_DURATION := 0.6       # seconds to fade out after that
const BAR_HEIGHT := 0.12
const MIN_WIDTH := 1.0
const MAX_WIDTH := 4.0
const MARGIN_ABOVE := 0.35       # clearance above the object's own top

## Set false to hide the numeric readout once this stops being a playtest aid.
@export var show_numeric: bool = true

var _owner: Node3D
var _health_prop: String
var _max_prop: String
var _bg: MeshInstance3D
var _fill: MeshInstance3D
var _fill_mat: StandardMaterial3D
var _label: Label3D
var _bar_width: float
var _last_current: float = -1.0
var _visible_timer: float = 0.0
var _fade_elapsed: float = 0.0
var _shown := false

## `bounds` sizes and positions the bar relative to the OWNER's own footprint
## rather than a fixed offset — a wide object gets a (clamped) wider bar, and
## a tall object gets its bar pushed further up. Property names default to
## "health"/"max_health", the convention every damageable in this project
## already follows (SandbagSection, Player, Zombie all use those names).
func attach_to(owner: Node3D, bounds: Vector3,
		health_prop: String = "health", max_health_prop: String = "max_health") -> void:
	_owner = owner
	_health_prop = health_prop
	_max_prop = max_health_prop
	_bar_width = clampf(maxf(bounds.x, bounds.z) * 0.4, MIN_WIDTH, MAX_WIDTH)
	position.y = bounds.y + MARGIN_ABOVE
	_build_visuals()
	visible = false
	owner.add_child(self)
	set_physics_process(true)

func _build_visuals() -> void:
	# Background: dark, slightly wider than the fill so the fill reads as
	# "inside" a frame rather than floating free — this is what keeps it
	# legible against both bright daylight and the green NVG tint, without
	# needing emission (which would bloom under the NVG glow pass).
	_bg = _make_quad(Vector2(_bar_width + 0.06, BAR_HEIGHT + 0.06), Color(0.05, 0.05, 0.05, 0.85))
	add_child(_bg)

	_fill = _make_quad(Vector2(_bar_width, BAR_HEIGHT), Color(0.2, 0.9, 0.25, 0.95))
	_fill_mat = _fill.material_override
	add_child(_fill)

	if show_numeric:
		_label = Label3D.new()
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = false
		_label.font_size = 28
		_label.pixel_size = 0.006
		_label.outline_size = 6
		_label.outline_modulate = Color(0, 0, 0, 0.9)
		_label.modulate = Color(1, 1, 1)
		_label.position.y = BAR_HEIGHT + 0.16
		add_child(_label)

func _make_quad(size: Vector2, color: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = size
	m.mesh = q
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.no_depth_test = false
	mat.albedo_color = color
	m.material_override = mat
	return m

func _physics_process(delta: float) -> void:
	if _owner == null or not is_instance_valid(_owner):
		queue_free()
		return

	var current: float = float(_owner.get(_health_prop))
	var max_value: float = float(_owner.get(_max_prop))
	if max_value <= 0.0:
		visible = false
		return
	var frac: float = clampf(current / max_value, 0.0, 1.0)

	# First poll establishes a baseline without counting as "damage".
	if _last_current < 0.0:
		_last_current = current
	elif current < _last_current:
		_visible_timer = VISIBLE_DURATION
		_fade_elapsed = 0.0
	_last_current = current

	if frac >= 1.0:
		visible = false
		return

	_update_fill(frac)
	if show_numeric and _label:
		_label.text = "%d/%d" % [int(round(current)), int(round(max_value))]

	var alpha := 1.0
	if _visible_timer > 0.0:
		_visible_timer -= delta
	else:
		_fade_elapsed += delta
		alpha = clampf(1.0 - _fade_elapsed / FADE_DURATION, 0.0, 1.0)

	if alpha <= 0.0:
		visible = false
		return
	visible = true
	_apply_alpha(alpha)

## Fill shrinks from the right edge, anchored on the left, so the bar reads
## like a conventional depleting gauge instead of shrinking from its centre.
## Colour grades green -> amber -> red with the fraction remaining.
func _update_fill(frac: float) -> void:
	var q: QuadMesh = _fill.mesh
	q.size = Vector2(maxf(0.001, _bar_width * frac), BAR_HEIGHT)
	_fill.position.x = -(_bar_width - q.size.x) * 0.5
	_fill_mat.albedo_color = Color(
		lerpf(0.85, 0.2, frac), lerpf(0.15, 0.9, frac), 0.2, _fill_mat.albedo_color.a)

func _apply_alpha(alpha: float) -> void:
	var bg_mat: StandardMaterial3D = _bg.material_override
	bg_mat.albedo_color.a = 0.85 * alpha
	_fill_mat.albedo_color.a = 0.95 * alpha
	if _label:
		_label.modulate.a = alpha
		_label.outline_modulate.a = 0.9 * alpha
