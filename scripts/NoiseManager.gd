extends Node
## Global noise event bus (autoload).
##
## Any gameplay system that makes a sound calls emit_noise(position, radius).
## Every zombie subscribes to `noise_emitted` and decides for itself whether
## the event falls inside its hearing range. Noise is location-based, not
## player-based: a zombie only learns "something happened HERE", never "the
## player is here" (see PROJECT_SPEC.md "Movement & Noise").

signal noise_emitted(position: Vector3, radius: float)

## Broadcast a noise event. A radius of 0 (crouch-walk) is silent and is
## dropped here so nothing downstream has to special-case it.
func emit_noise(position: Vector3, radius: float) -> void:
	if radius <= 0.0:
		return
	noise_emitted.emit(position, radius)
