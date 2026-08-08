extends Node3D
class_name Claymore
## An emplaced M18A1 claymore: a directional, autonomous proximity mine.
##
## Instantiated into the WORLD, never parented to the player — once emplaced
## it is a fixture like an obstacle, and the player walking away or dying does
## not move or free it.
##
## Deliberately NOT an Obstacle subclass. Obstacle carries ObstacleCatalog
## pricing, a placement footprint on layer 4, and BuildMode's placement cap —
## none of which apply to a store-bought item emplaced from the equip state.
## Same reasoning that keeps SandbagPanel out of that hierarchy.
##
## PERSISTENCE IS FREE: night transitions are phase changes on a live scene,
## never a reload, so an emplaced claymore survives dawn by simply not being
## freed. There is no save step here, matching how placed obstacles already
## persist.
##
## It owns no damage code — see Claymore.detonate() in the detection pass.

## Front plate faces local -Z, matching Node3D's forward convention, so
## `facing()` and the AreaMath arc (which treats +Z as facing on its own fan
## geometry, oriented by the wedge child's own rotation) stay consistent.
const GROUP := "claymores"

## Greybox dimensions — a small curved front plate on two wire legs.
const BODY_SIZE := Vector3(0.30, 0.14, 0.05)
const LEG_HEIGHT := 0.12
const LEG_OFFSET := 0.10

## Front face colour, so "which way is it pointing" is readable at a glance
## without reading the wedge. The back is deliberately drab.
const COLOR_FRONT := Color(0.72, 0.26, 0.18)
const COLOR_BODY := Color(0.24, 0.26, 0.22)
## Ground wedge tint while emplaced — dim, and the same discipline as the
## grenade arc: alpha-blended, never additive.
const WEDGE_COLOR := Color(0.85, 0.35, 0.25, 0.10)

var config: ClaymoreConfig

var _wedge: ArcWedge
var _player: Node3D

func setup(cfg: ClaymoreConfig) -> void:
	config = cfg
	_validate_config()
	add_to_group(GROUP)
	_build_visual()
	_build_wedge()

## The direction the front plate points, flattened to the ground plane. This
## is what gets handed to AreaDamageSystem.detonate() as `facing`, and what
## the detection arc is measured against.
func facing() -> Vector3:
	var f := -global_transform.basis.z
	f.y = 0.0
	return f.normalized()

## INVARIANT: the detection wedge and the damage wedge must describe the SAME
## volume. They are configured in two different resources — detection here,
## damage on the AreaDamageProfile — because this project keeps blast geometry
## in exactly one kind of resource. That split is only safe if the two agree,
## and a silent disagreement would be brutal to diagnose from play: zombies
## would trip a mine that then failed to damage them, or die to a mine that
## never should have seen them.
func _validate_config() -> void:
	if config == null:
		push_error("[CLAYMORE] setup() with a null config")
		return
	var p := config.damage_profile
	if p == null:
		push_error("[CLAYMORE] config has no damage_profile")
		return
	assert(is_equal_approx(config.detection_range, p.max_radius),
		"CLAYMORE CONFIG MISMATCH: detection_range %.2f but damage max_radius %.2f — the mine would trigger and damage over different distances." % [config.detection_range, p.max_radius])
	assert(is_equal_approx(config.detection_arc_degrees, p.arc_degrees),
		"CLAYMORE CONFIG MISMATCH: detection_arc %.1f but damage arc %.1f — the mine would trigger and damage over different arcs." % [config.detection_arc_degrees, p.arc_degrees])
	# Asserts are stripped from release builds; fail loudly there too.
	if not is_equal_approx(config.detection_range, p.max_radius) \
			or not is_equal_approx(config.detection_arc_degrees, p.arc_degrees):
		push_error("[CLAYMORE] detection geometry does not match damage geometry — see ClaymoreConfig.")

# --- Visual ----------------------------------------------------------------
## Builds the greybox body. Static so the placement ghost can render the exact
## same silhouette without instancing a live claymore — a ghost that looked
## different from the thing it previews would be its own small lie.
static func build_body(front_color: Color, body_color: Color,
		alpha: float = 1.0) -> Node3D:
	var root := Node3D.new()

	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = BODY_SIZE
	body.mesh = box
	body.position.y = LEG_HEIGHT + BODY_SIZE.y * 0.5
	body.material_override = _flat_mat(body_color, alpha)
	root.add_child(body)

	# Front plate: a thin slab on the -Z face, so which way it points reads
	# instantly from any angle.
	var front := MeshInstance3D.new()
	var fbox := BoxMesh.new()
	fbox.size = Vector3(BODY_SIZE.x * 0.94, BODY_SIZE.y * 0.8, 0.015)
	front.mesh = fbox
	front.position = Vector3(0.0, LEG_HEIGHT + BODY_SIZE.y * 0.5,
		-BODY_SIZE.z * 0.5 - 0.008)
	front.material_override = _flat_mat(front_color, alpha)
	root.add_child(front)

	for side in [-1.0, 1.0]:
		var leg := MeshInstance3D.new()
		var lbox := BoxMesh.new()
		lbox.size = Vector3(0.012, LEG_HEIGHT, 0.012)
		leg.mesh = lbox
		leg.position = Vector3(side * LEG_OFFSET, LEG_HEIGHT * 0.5, 0.0)
		leg.material_override = _flat_mat(body_color, alpha)
		root.add_child(leg)

	return root

static func _flat_mat(c: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _build_visual() -> void:
	add_child(build_body(COLOR_FRONT, COLOR_BODY))

## The emplaced ground wedge is behind config.show_emplaced_arc, and only
## drawn when the player is close, so a base with a dozen mines doesn't turn
## the night view into a light show. The PLACEMENT wedge is not behind this —
## see ClaymorePlacer.
func _build_wedge() -> void:
	if not config.show_emplaced_arc:
		return
	_wedge = ArcWedge.new()
	add_child(_wedge)
	# The fan is built with +Z as facing; the plate points -Z, so the wedge is
	# turned to match rather than the geometry being rebuilt mirrored.
	_wedge.rotation.y = PI
	_wedge.setup(config.detection_arc_degrees, config.detection_range, WEDGE_COLOR)
	_wedge.visible = false

func _process(_delta: float) -> void:
	if _wedge == null:
		return
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return
	_wedge.visible = global_position.distance_to(_player.global_position) \
		<= config.emplaced_arc_visible_range

# --- Placement validity ----------------------------------------------------
## Is `pos` far enough from every claymore already emplaced? Static because
## the placement ghost needs to answer this before any claymore exists there.
static func separation_clear(tree: SceneTree, pos: Vector3, min_sep: float) -> bool:
	for c in tree.get_nodes_in_group(GROUP):
		var n := c as Node3D
		if n == null or not is_instance_valid(n):
			continue
		if n.global_position.distance_to(pos) < min_sep:
			return false
	return true
