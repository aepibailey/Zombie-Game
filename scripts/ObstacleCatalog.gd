extends Node
## Definitions for the defensive obstacles sold at the Engineers' Tent
## (autoload). Data only — placement lives in BuildMode, behaviour in Obstacle.
##
## Prices are the starting numbers from the design pass and are all tunable
## here; see PROJECT_SPEC.md "Economy" for the reasoning.

class ObstacleType:
	var id: String
	var display_name: String
	## x = length along the run, y = height, z = thickness.
	var size: Vector3 = Vector3(10, 1, 0.5)
	var cost: int = 10
	var color: Color = Color(0.55, 0.5, 0.3)
	## Solid: has real collision, blocks the player and zombies (sandbags).
	## Non-solid obstacles are trigger volumes only (wire, ditch, minefield).
	var solid: bool = false
	## Blocks zombie pathing — drives the "perimeter sealed" notice.
	var blocks_pathing: bool = false
	## Blocks the PLAYER — drives the "would trap player" rejection. Sandbags
	## are solid but only 1m, so the player mantles them and is never trapped;
	## the ditch can be mantled out of. Only wire is a true player barrier.
	var blocks_player: bool = false
	var description: String = ""

const ORDER := ["sandbags", "cwire", "ditch", "minefield"]

var types: Dictionary = {}

func _ready() -> void:
	_add({
		"id": "sandbags", "display_name": "Sandbags", "cost": 10,
		"size": Vector3(10, 1, 0.5), "color": Color(0.62, 0.56, 0.34),
		"solid": true, "blocks_pathing": true,
		"description": "10m wall, 1m tall. Destructible. You can mantle it; they can't.",
	})
	_add({
		"id": "cwire", "display_name": "Triple-strand C-wire", "cost": 40,
		"size": Vector3(10, 1.8, 1.0), "color": Color(0.7, 0.72, 0.75),
		"solid": false, "blocks_pathing": false, "blocks_player": true,
		"description": "Entangles up to 4. Permanent. Blocks YOU — you can't climb it.",
	})
	_add({
		"id": "ditch", "display_name": "Zombie ditch", "cost": 60,
		# x = length, y = depth, z = width. A real pit now, not a decorative
		# sunken box — see ZombieDitch.gd. "solid: false" because the pit's
		# walls/floor are custom-built on SOLID_NO_NAV_LAYER, not the generic
		# layer-1 solid path (which would make it a navmesh obstacle).
		"size": Vector3(8, 3.0, 3.0), "color": Color(0.18, 0.15, 0.11),
		"solid": false, "blocks_pathing": false,
		"description": "A real 3m pit. Zombies that walk over it fall in and stay — you climb out via the ramp.",
	})
	_add({
		"id": "minefield", "display_name": "Minefield", "cost": 70,
		"size": Vector3(10, 0.15, 5.0), "color": Color(0.5, 0.2, 0.15),
		"solid": false, "blocks_pathing": false,
		"description": "10x5m, 20 mines. Player-safe. Very loud.",
	})

func _add(d: Dictionary) -> void:
	var t := ObstacleType.new()
	for key in d:
		t.set(key, d[key])
	types[t.id] = t

func get_type(id: String) -> ObstacleType:
	return types.get(id)

## Builds the right Obstacle subclass for an id, already set up.
func create(id: String) -> Obstacle:
	var t := get_type(id)
	if t == null:
		return null
	var o: Obstacle
	match id:
		"sandbags": o = SandbagSection.new()
		"cwire": o = CWireSection.new()
		"ditch": o = ZombieDitch.new()
		"minefield": o = Minefield.new()
		_: o = Obstacle.new()
	o.setup(t)
	return o
