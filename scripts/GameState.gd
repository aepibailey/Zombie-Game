extends Node
## Serialisable run state (autoload).
##
## Exists so the multi-level work later doesn't silently lose the base. Placed
## obstacles and their mutable state — sandbag health, remaining mines — are
## captured to plain Dictionaries and rebuilt on the far side of a scene
## change. Nothing here holds node references across a transition.
##
## Everything is plain data (String / float / Vector3 / bool / Array), so this
## is already safe to hand to `var_to_str`, `JSON`, or a `FileAccess` save
## without further conversion.

## Last captured snapshot. Written by capture(), read by restore().
var obstacles: Array = []
var night_number: int = 0
var points: int = 0

var _captured := false

## Walk the live obstacle list and snapshot it. A sandbag wall stays in the
## roster even fully breached — it's repairable, never removed — so its
## to_dict() carries per-section health/destroyed state for all 5 panels
## rather than the wall simply being absent.
func capture(placed: Array) -> void:
	obstacles.clear()
	for o in placed:
		if is_instance_valid(o) and o.has_method("to_dict"):
			obstacles.append(o.to_dict())
	night_number = GameManager.night_number
	points = PointsManager.points
	_captured = true
	print("[STATE] captured %d obstacles, night %d, %d pts" % [
		obstacles.size(), night_number, points])

## True once capture() has run. Guards restore() so a normal cold boot never
## has night/points stomped by an empty snapshot.
func has_snapshot() -> bool:
	return _captured

## Rebuild obstacles under `root`. Returns the new list for BuildMode to adopt.
## Every value is pulled into an explicitly typed local first: `obstacles` holds
## untyped Dictionaries, so `d.get(...)` is a Variant and cannot be assigned
## straight into a typed property.
func restore(root: Node3D) -> Array:
	var rebuilt: Array = []
	for entry in obstacles:
		var d: Dictionary = entry
		var id: String = d.get("type", "")
		var o: Obstacle = ObstacleCatalog.create(id)
		if o == null:
			push_warning("[STATE] unknown obstacle type '%s' in snapshot — skipped" % id)
			continue
		root.add_child(o)
		var pos: Vector3 = d.get("pos", Vector3.ZERO)
		var yaw: float = d.get("yaw", 0.0)
		o.global_position = pos
		o.rotation.y = yaw
		o.apply_dict(d)
		rebuilt.append(o)
	print("[STATE] restored %d obstacles" % rebuilt.size())
	return rebuilt

## Push the non-obstacle run state back onto the autoloads. A no-op in practice
## for a plain scene reload (autoloads survive that untouched), but the multi-
## level work will need it the moment run state is ever rebuilt from a file.
func restore_meta() -> void:
	GameManager.night_number = night_number
	PointsManager.points = points
	PointsManager.points_changed.emit(points)

func clear() -> void:
	obstacles.clear()
	night_number = 0
	points = 0
	_captured = false
