extends Node3D
class_name CoverDebugDraw
## Debug overlay tinting every cover_solid and concealment volume in the
## world, in two clearly distinct colours (Step 8A Phase 4).
##
## EXPLICITLY FOR BUILDING POSITION TWO (Step 8B). Cover and concealment are
## invisible properties of collision layers — a sandbag wall and a decorative
## block look identical, and a concealment volume may have no visual at all.
## Laying out a map against a system you cannot see is guesswork; this makes
## the layers legible in-world so the geometry can be authored deliberately.
##
## READS THE LAYERS, NOT A REGISTRY. It finds volumes by testing collision
## layer bits on every CollisionObject3D in the tree, so it shows what the
## PHYSICS ENGINE actually sees rather than what some bookkeeping list claims.
## That difference matters: the bug class this whole step guards against is
## state and layers disagreeing, and an overlay driven by the same bookkeeping
## as the bug would render the bug invisible.
##
## A DESTROYED SANDBAG CORRECTLY VANISHES from the overlay: CoverSurface
## clears the layer bit on destruction, and this reads the bit.

const REFRESH_INTERVAL := 0.5   ## rescan cadence; the world changes rarely

var config: CoverPreviewConfig

var _on := false
var _timer := 0.0
## Overlay mesh per source collider, keyed by that collider's instance id, so
## a rescan reuses what is already drawn instead of rebuilding every frame.
var _overlays: Dictionary = {}

func setup(cfg: CoverPreviewConfig) -> void:
	config = cfg

func is_on() -> bool:
	return _on

func toggle() -> bool:
	_on = not _on
	if _on:
		_rescan()
	else:
		_clear()
	return _on

func _process(delta: float) -> void:
	if not _on:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = REFRESH_INTERVAL
	_rescan()

func _clear() -> void:
	for id in _overlays:
		var mi: Node = _overlays[id]
		if is_instance_valid(mi):
			mi.queue_free()
	_overlays.clear()

## Walk every CollisionObject3D and draw an overlay for each shape belonging
## to one that carries a cover or concealment bit.
func _rescan() -> void:
	var seen := {}
	_collect(get_tree().root, seen)
	# Anything that stopped being cover (a destroyed sandbag panel) or left
	# the tree loses its overlay on the next pass.
	var stale: Array = []
	for id in _overlays:
		if not seen.has(id):
			stale.append(id)
	for id in stale:
		var mi: Node = _overlays[id]
		if is_instance_valid(mi):
			mi.queue_free()
		_overlays.erase(id)

func _collect(node: Node, seen: Dictionary) -> void:
	var body := node as CollisionObject3D
	if body != null:
		var is_cover: bool = (body.collision_layer & Obstacle.COVER_SOLID_LAYER) != 0
		var is_conceal: bool = (body.collision_layer & Obstacle.CONCEALMENT_LAYER) != 0
		if is_cover or is_conceal:
			var id := body.get_instance_id()
			seen[id] = true
			if not _overlays.has(id) or not is_instance_valid(_overlays[id]):
				var mi := _build_overlay(body, is_cover)
				if mi != null:
					_overlays[id] = mi
			else:
				# Keep it aligned — nothing in the project moves cover today,
				# but a hulk on a vehicle or a placed obstacle being dragged
				# in a future build mode would.
				var existing: Node3D = _overlays[id]
				existing.global_transform = body.global_transform
	for c in node.get_children():
		_collect(c, seen)

## One overlay node per collider, carrying a slightly-inflated copy of each of
## that collider's BoxShape3D children.
##
## Box shapes only, and that is not a shortcut: every cover and concealment
## volume in the project today is a box (sandbag panels, the debug
## concealment test box). A non-box cover shape would silently draw nothing,
## so it warns rather than failing quietly.
func _build_overlay(body: CollisionObject3D, is_cover: bool) -> Node3D:
	var root := Node3D.new()
	root.top_level = true
	add_child(root)
	root.global_transform = body.global_transform

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = config.debug_cover_color if is_cover else config.debug_concealment_color

	var drew := 0
	for child in body.get_children():
		var cs := child as CollisionShape3D
		if cs == null or cs.disabled:
			continue
		var box := cs.shape as BoxShape3D
		if box == null:
			push_warning("[COVERDBG] %s has a non-box cover shape (%s); not drawn."
				% [body.name, cs.shape])
			continue
		var mesh := BoxMesh.new()
		# Inflated a hair so the overlay never z-fights the real surface.
		mesh.size = box.size * 1.02
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.transform = cs.transform
		root.add_child(mi)
		drew += 1

	if drew == 0:
		root.queue_free()
		return null
	return root
