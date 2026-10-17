extends RefCounted
class_name Health
## One actor's health pool, and the single place a DamageInfo becomes damage
## dealt. Player, Zombie and Fighter each own one; obstacles keep their own
## structure-damage path.
##
## Owns the arithmetic and the moment of death, nothing else. What a hit
## LOOKS like (flash, shake, hurt sound, directional marker) and what death
## DOES (score, game over, respawn, leave the target groups) stay on the
## actor, which calls apply() and then checks is_depleted(). That keeps each
## actor's side effects in the same order they ran before this existed.
##
## The two per-actor differences are options, not subclasses:
##   honors_headshots      — a zombie has a head hitbox; a fighter and the
##                           player do not, so the flag is ignored for them.
##   takes_hits_when_dead  — a zombie's corpse stays valid until queue_free()
##                           runs, and the remaining pellets of a shotgun blast
##                           still land on it and report damage. A fighter or
##                           player that has died takes nothing and reports 0.

signal damaged(info: DamageInfo, dealt: int)
## Once per death. refill() re-arms it (the player's debug respawn).
signal died(info: DamageInfo)

const HEADSHOT_MULT := 2            # PROJECT_SPEC.md "Combat & Scoring"

var max_hp: int
var hp: int
var honors_headshots: bool
var takes_hits_when_dead: bool
var _depleted := false

func _init(max_value: int = 100, honors_headshots_: bool = false,
		takes_hits_when_dead_: bool = false) -> void:
	max_hp = max_value
	hp = max_value
	honors_headshots = honors_headshots_
	takes_hits_when_dead = takes_hits_when_dead_

## Damage this hit would deal, without applying it. Headshot first, then
## falloff, rounded ONCE at the end, never below 1. Rounding in between gives
## different numbers: 34 body at x0.4 is round(34*2*0.4) = 27 as a headshot,
## but round(34*0.4)*2 = 28.
func resolve(info: DamageInfo) -> int:
	var head: int = HEADSHOT_MULT if (honors_headshots and info.headshot) else 1
	return maxi(1, int(round(float(info.amount) * head * info.falloff_mult)))

## Applies the hit and returns the damage dealt (0 if this pool is spent and
## does not take hits when dead). HP floors at 0.
func apply(info: DamageInfo) -> int:
	if _depleted and not takes_hits_when_dead:
		return 0
	var dealt := resolve(info)
	hp = maxi(0, hp - dealt)
	damaged.emit(info, dealt)
	if hp <= 0 and not _depleted:
		_depleted = true
		died.emit(info)
	return dealt

## True from the hit that took HP to 0 until refill().
func is_depleted() -> bool:
	return _depleted

## Restores up to max_hp, never past it. Does not revive a spent pool.
func heal(amount: int) -> void:
	if _depleted:
		return
	hp = mini(max_hp, hp + amount)

## Back to full and alive again. Only the player's debug respawn does this.
func refill() -> void:
	hp = max_hp
	_depleted = false
