extends Resource
class_name UAVConfig
## Every tunable for the UAV enabler, in one editable file.
##
## UAVSystem is an AUTOLOAD (registered by script path in project.godot, not
## a .tscn) — an autoload script's own @export vars have no scene to be
## edited FROM, so they would not actually be inspector-tunable. Same reason
## FireMissionConfig exists instead of exports on FireMissionSystem: the
## values live on a Resource, preloaded as a const, and the system script
## just reads it. See UAVSystem.CONFIG.
##
## Per-variant silhouette colour is NOT here — it lives on ZombieType, since
## it differs per zombie variant rather than being a single system-wide knob.

## Points deducted at call. No refund, no pro-rata — calling late in the
## night is intentionally worse value than calling early.
@export var uav_cost: int = 60
## 0 = unlimited. Distance from the PLAYER beyond which a silhouette hides,
## even while the UAV is active.
@export var uav_max_reveal_distance: float = 0.0
## Offscreen edge indicators are capped to the N nearest contacts.
@export var uav_offscreen_indicator_cap: int = 12
