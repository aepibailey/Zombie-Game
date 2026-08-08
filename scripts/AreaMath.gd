extends RefCounted
class_name AreaMath
## Shared containment geometry for anything that cares about "is this point
## inside my area of effect".
##
## Extracted so the claymore's DETECTION test and the area-damage system's
## DAMAGE test cannot disagree about what "inside a 60 degree arc" means —
## they were about to be two implementations of the same question.
## AreaDamageProfile.in_arc() delegates here rather than keeping its own copy.
##
## Deliberately static and stateless: the Apache patrol box and the mortar
## target-paint both need containment tests and neither of them owns an
## AreaDamageProfile, so this cannot live on that resource.

## Is `point` inside a horizontal wedge of `arc_degrees`, centred on `facing`,
## with its apex at `origin`?
##
## HORIZONTAL: y is flattened out of both vectors before the test, so height
## never affects the arc. A claymore covers a wedge on the ground plane, not a
## cone in 3D — vertical limits are a separate test (see in_height_band).
##
## Degenerate cases both answer TRUE, matching the pre-existing behaviour this
## replaced: a 360-degree arc is omnidirectional, a zero facing vector has no
## direction to be outside of, and a point sitting exactly on the origin has
## no bearing to measure.
static func in_horizontal_arc(origin: Vector3, facing: Vector3, point: Vector3,
		arc_degrees: float) -> bool:
	if arc_degrees >= 360.0 or facing.length_squared() < 0.001:
		return true
	var to := point - origin
	to.y = 0.0
	if to.length_squared() < 0.001:
		return true
	var f := Vector3(facing.x, 0.0, facing.z).normalized()
	# Half-angle: arc_degrees is the TOTAL width, so a 60 degree arc reaches
	# 30 degrees either side of `facing`.
	return f.dot(to.normalized()) >= cos(deg_to_rad(arc_degrees * 0.5))

## Is `point_y` within [origin_y, origin_y + ceiling]? Used to let something
## pass OVER an area effect — a leaper at the apex of its jump is above a
## claymore's band and does not trigger it.
##
## The lower bound is the origin's own plane, not minus-infinity: something in
## a pit below the emplacement is also outside the band.
static func in_height_band(origin_y: float, point_y: float, ceiling: float) -> bool:
	return point_y >= origin_y and point_y <= origin_y + ceiling

## Local-space fan describing a horizontal wedge, for drawing it on the ground.
## Index 0 is the apex; the rest sweep the far edge from one side to the other.
## +Z is treated as `facing`, so the caller orients it with the node's own
## transform rather than baking a direction into the geometry.
static func arc_fan_points(arc_degrees: float, radius: float,
		segments: int = 24) -> PackedVector3Array:
	var pts := PackedVector3Array()
	pts.append(Vector3.ZERO)
	var half := deg_to_rad(arc_degrees * 0.5)
	var n: int = maxi(2, segments)
	for i in range(n + 1):
		var a: float = -half + (2.0 * half) * (float(i) / float(n))
		pts.append(Vector3(sin(a), 0.0, cos(a)) * radius)
	return pts
