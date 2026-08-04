extends Obstacle
class_name SandbagWall
## The placed sandbag obstacle: placement/pricing/footprint/persistence
## registry for 5 independent SandbagPanel sections. The wall itself holds no
## health — see SandbagPanel.gd for the actual destructible unit.
##
## Was a single 4000 HP object destroyed and freed as one piece. Rebuilt so a
## breach opens exactly one 2m gap instead of the whole 10m wall, and so a
## fully-breached wall stays in the world, repairable, rather than vanishing.

## Fires whenever ANY panel's collision state changes — damage that doesn't
## destroy, a destroy, or a repair. BuildMode listens for this (same
## connection point the old `destroyed_section` used) to request a navmesh
## rebake; repair needs that exactly as much as destruction does, since
## restoring a collision shape closes a gap the navmesh has to relearn.
signal section_changed(wall)

const SECTIONS := 5
## PRIMARY: ceil(wall_price / 5). Flat per-section constant, not scattered
## across files — BuildMode's repair UI and SandbagPanel.repair_cost() both
## read this one value. Set for real from the catalog price in setup(); the
## default here is just ceil(10 / 5.0) for a wall never run through setup().
@export var section_repair_cost: int = 2

## True once every panel has been destroyed. Reactivates the moment any panel
## is repaired. The wall is NEVER freed either way — see _refresh_active().
var active := true

var _panels: Array[SandbagPanel] = []

func setup(t) -> void:
	section_repair_cost = maxi(1, int(ceil(float(t.cost) / float(SECTIONS))))
	super.setup(t)   # _build_visual() below + _build_footprint(); _build_solid() is a no-op here
	add_to_group("sandbag_walls")

## Overrides Obstacle's generic single-box visual: builds 5 SandbagPanel
## children spanning the wall's length instead of one box. The wall's own
## FOOTPRINT (placement-overlap grid, built by the base class right after
## this returns) is untouched — it still reserves the whole 10m span as one
## placement, matching "footprint on the placement grid unchanged".
func _build_visual() -> void:
	var size: Vector3 = obstacle_type.size
	var section_len: float = size.x / float(SECTIONS)
	var panel_size := Vector3(section_len, size.y, size.z)
	for i in SECTIONS:
		var local_x: float = -size.x * 0.5 + (float(i) + 0.5) * section_len
		var panel := SandbagPanel.new()
		panel.name = "Panel%d" % i
		add_child(panel)
		panel.setup(panel_size, local_x, obstacle_type.color)
		panel.changed.connect(_on_panel_changed)
		_panels.append(panel)

## The wall has no collision of its own — each panel owns its own
## StaticBody3D. ObstacleCatalog keeps "solid": true for sandbags so
## BuildMode's placement-time rebake request still fires (it's keyed off
## t.solid); this override just makes sure Obstacle.setup() doesn't ALSO
## build a second, whole-wall solid on top of the 5 panels' own.
func _build_solid() -> void:
	pass

func _on_panel_changed() -> void:
	_refresh_active()
	section_changed.emit(self)

func _refresh_active() -> void:
	var any_standing := false
	for p in _panels:
		if not p.destroyed:
			any_standing = true
			break
	active = any_standing

func panels() -> Array[SandbagPanel]:
	return _panels

## Nearest point on the WHOLE wall's face — used only for "is the cursor near
## this wall at all" in BuildMode's right-click selection. Distinct from any
## per-panel nearest_point() (SandbagPanel's own): damage routing always goes
## through a specific panel, never the wall.
func nearest_point(from: Vector3) -> Vector3:
	var size: Vector3 = obstacle_type.size
	var local := (from - global_position).rotated(Vector3.UP, -rotation.y)
	var hx: float = size.x * 0.5
	var clamped := Vector3(clampf(local.x, -hx, hx), 0.0, 0.0)
	return global_position + clamped.rotated(Vector3.UP, rotation.y)

## Summed cost to fully repair every damaged or destroyed panel. 0 if the
## wall is already at full health everywhere.
func repair_all_cost() -> int:
	var total := 0
	for p in _panels:
		if p.health_fraction() < 1.0:
			total += p.repair_cost(section_repair_cost)
	return total

## Repairs every damaged/destroyed panel and returns the total points spent.
## Caller (BuildMode) is responsible for confirming affordability BEFORE
## calling this — same convention as the rest of the repair UI, so a partial
## "repaired 3 of 5, ran out of points" state can never happen silently.
func repair_all() -> int:
	var total := 0
	for p in _panels:
		if p.health_fraction() < 1.0:
			total += p.repair_cost(section_repair_cost)
			p.repair()
	return total

# --- Persistence ----------------------------------------------------------
## Per-section health/destroyed state, not a single float — a wall chewed to
## 40% on one section and untouched on the rest must restore exactly that,
## not an averaged or wall-wide value.
func to_dict() -> Dictionary:
	var d := super.to_dict()
	var sections: Array = []
	for p in _panels:
		sections.append(p.to_dict())
	d["sections"] = sections
	return d

func apply_dict(d: Dictionary) -> void:
	var sections: Array = d.get("sections", [])
	for i in range(_panels.size()):
		if i < sections.size():
			_panels[i].apply_from_dict(sections[i])
	_refresh_active()
