extends MeshInstance3D
class_name ArcWedge
## A flat translucent wedge drawn on the ground, showing a horizontal arc.
##
## Used twice by the claymore: on the placement ghost (always visible, so the
## arc is legible BEFORE committing) and optionally on emplaced claymores when
## the player is close. It is a pure readability aid and owns no logic — the
## geometry comes from AreaMath.arc_fan_points(), the same function nothing
## else is allowed to disagree with about what the arc is.
##
## +Z is "facing", matching AreaMath's convention, so orienting the wedge is
## the parent's job — no direction is baked into the mesh.

## Lifted off the ground so it doesn't z-fight with the terrain it sits on.
const GROUND_OFFSET := 0.03

var _mat: StandardMaterial3D

func setup(arc_degrees: float, radius: float, color: Color) -> void:
	position.y = GROUND_OFFSET
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var pts := AreaMath.arc_fan_points(arc_degrees, radius)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	# Fan: apex + each adjacent pair on the far edge.
	for i in range(1, pts.size() - 1):
		im.surface_add_vertex(pts[0])
		im.surface_add_vertex(pts[i])
		im.surface_add_vertex(pts[i + 1])
	im.surface_end()
	mesh = im

	_mat = StandardMaterial3D.new()
	# Unshaded and alpha-blended, never additive, no emission — same
	# discipline as the grenade arc: the night NVG pass has no glow stage, so
	# the risk is washing out a dark scene rather than blooming.
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Drawn flat on the ground it describes; depth-testing it against that
	# same ground is what GROUND_OFFSET exists to survive.
	_mat.albedo_color = color
	material_override = _mat

func set_color(color: Color) -> void:
	if _mat:
		_mat.albedo_color = color
