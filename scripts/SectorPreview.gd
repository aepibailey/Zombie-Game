extends Node3D
class_name SectorPreview
## Live sector-of-fire visualization for one fighter (Step 8A Phase 4).
##
## Casts a fan of rays from the fighter's EYE POINT across its assigned arc
## and draws a ground wedge whose radius follows what each ray actually
## reached — so the shape on the ground IS the shape of the fighter's real
## coverage, with cover and concealment carved out of it. Segments that ran
## into something are drawn in a separate colour from segments that ran
## clear to full range.
##
## ASKS THE SAME QUESTION THE FIGHTER ASKS. Every ray goes through
## LineOfSight, against LineOfSight.LOS_MASK, from LineOfSight.eye_point() —
## the identical path Fighter.acquire_target() uses. A preview that traced its
## own rays could disagree with the fighter's own acquisition, which would
## make it worse than no preview at all: the player would place someone based
## on a picture the game does not honour.
##
## THIS IS WHY D4 IS LIVEABLE. A fighter has one fixed eye height and never
## crouches or peeks, so a fighter behind full cover sees nothing — a real
## consequence the player has to reason about. That is only fair if the
## consequence is VISIBLE before committing, and this is what makes it
## visible: put a fighter behind a full-height wall and the wedge collapses
## to a stub of occluded-coloured segments.
##
## OWNS NO PLACEMENT. It renders whatever fighter it is attached to, wherever
## that fighter currently is. There is no fighter placement/positioning mode
## in the project yet (fighters spawn in front of the player — see
## Main._spawn_fighter()); when one is built, it attaches one of these to its
## ghost and gets the live preview with no change here.

const RAY_LIFT := 0.02   ## ray lines sit just above the wedge fill

var config: CoverPreviewConfig
var _fighter: Fighter

var _clear_fill: MeshInstance3D
var _occluded_fill: MeshInstance3D
var _rays: MeshInstance3D
var _shown := false

func setup(fighter: Fighter, cfg: CoverPreviewConfig) -> void:
	_fighter = fighter
	config = cfg

func _ready() -> void:
	# top_level: vertices are built in WORLD space (each ray has its own
	# length, so there is nothing a shared node transform could contribute),
	# and the fighter's own capsule transform must not distort a ground
	# marker. Kept at identity for the same reason.
	top_level = true
	global_transform = Transform3D.IDENTITY

	_clear_fill = _make_surface(config.clear_color)
	_occluded_fill = _make_surface(config.occluded_color)
	_rays = _make_surface(config.ray_color)
	visible = false

func _make_surface(c: Color) -> MeshInstance3D:
	# Unshaded + transparent, matching TargetPainter's marker convention so
	# ground overlays read identically across the project.
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = c
	var mi := MeshInstance3D.new()
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

func set_shown(on: bool) -> void:
	_shown = on
	visible = on

func is_shown() -> bool:
	return _shown

func _process(_delta: float) -> void:
	if not _shown or _fighter == null or not is_instance_valid(_fighter):
		return
	_rebuild()

## One ray per fan step, each clipped to whatever it actually hit. Adjacent
## pairs become one triangle; the pair's colour is decided by whether EITHER
## of its two edge rays was blocked, so a segment straddling the edge of a
## sandbag wall reads as occluded rather than silently half-clear.
func _rebuild() -> void:
	var eye := LineOfSight.eye_point(_fighter)
	var reach: float = _fighter.fighter_type.engagement_range
	var half := _fighter.sector_half_angle_rad()
	var fwd := _fighter.facing()
	var n: int = maxi(2, config.sector_ray_count)
	var space := _fighter.get_world_3d().direct_space_state
	var exclude := _ray_exclude()

	var apex := Vector3(_fighter.global_position.x,
		_fighter.global_position.y + config.ground_offset,
		_fighter.global_position.z)

	var clear_mesh := ImmediateMesh.new()
	clear_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var occ_mesh := ImmediateMesh.new()
	occ_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var line_mesh := ImmediateMesh.new()
	line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)

	var prev_edge := Vector3.ZERO
	var prev_blocked := false
	var lift := Vector3(0.0, RAY_LIFT, 0.0)

	for i in range(n + 1):
		var a: float = -half + (2.0 * half) * (float(i) / float(n))
		var dir := fwd.rotated(Vector3.UP, a).normalized()
		var far := eye + dir * reach
		# THE shared sight ray — same function, same mask, same eye point the
		# fighter's own acquisition uses. Returns the distance too, so the
		# wedge can be drawn to where the shot line actually stops without a
		# second trace and without this file keeping its own query.
		var r := LineOfSight.trace(space, eye, far, exclude)
		var blocked: bool = not r["clear"]
		var dist: float = r["distance"]
		# Ground-projected: the wedge is a footprint, so each ray's reach is
		# laid flat rather than drawn at eye height.
		var edge := apex + dir * dist

		if i > 0:
			var target := occ_mesh if (blocked or prev_blocked) else clear_mesh
			target.surface_add_vertex(apex)
			target.surface_add_vertex(prev_edge)
			target.surface_add_vertex(edge)
		prev_edge = edge
		prev_blocked = blocked

		if config.draw_rays:
			line_mesh.surface_add_vertex(apex + lift)
			line_mesh.surface_add_vertex(edge + lift)

	clear_mesh.surface_end()
	occ_mesh.surface_end()
	line_mesh.surface_end()
	_clear_fill.mesh = clear_mesh
	_occluded_fill.mesh = occ_mesh
	_rays.mesh = line_mesh
	_rays.visible = config.draw_rays

## The fighter itself never blocks its own sector.
func _ray_exclude() -> Array[RID]:
	var out: Array[RID] = []
	out.append(_fighter.get_rid())
	return out
