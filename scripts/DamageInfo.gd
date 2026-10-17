extends RefCounted
class_name DamageInfo
## One hit, typed. Built with bullet(), melee() or blast() and handed to an
## actor's Health.
##
## WHY A TYPE AND NOT ARGUMENTS. The three positional verbs this replaces —
## take_damage(amount, headshot, falloff), take_melee_damage(amount, source)
## and take_area_damage(amount, origin) — existed because their argument lists
## were incompatible: a Vector3 origin passed where `headshot` was expected is
## truthy, so every blast would have scored as a headshot. Named fields make
## that mistake unrepresentable rather than merely documented.
##
## Carries the hit as the CALLER saw it: the raw amount, before the headshot
## multiplier and falloff. Health.resolve() is the one place those are applied
## and rounded, so a caller never pre-multiplies.

enum Kind { BULLET, MELEE, BLAST }

var amount: int = 0
var kind: Kind = Kind.BULLET
## Only meaningful for BULLET. Whether it is honoured is the receiving
## Health's decision (a fighter registers no head and ignores it).
var headshot: bool = false
## Distance falloff (and penetration loss) for BULLET; 1.0 otherwise.
var falloff_mult: float = 1.0
## Where the hit came from: the attacker for MELEE, the blast centre for
## BLAST. Unset for BULLET. Read by the player's directional hit indicator.
var source_pos: Vector3 = Vector3.ZERO
var has_source: bool = false

## A round: the player's raycast or a fighter's hit roll.
static func bullet(amount_: int, headshot_: bool, falloff_mult_: float = 1.0) -> DamageInfo:
	var info := DamageInfo.new()
	info.amount = amount_
	info.kind = Kind.BULLET
	info.headshot = headshot_
	info.falloff_mult = falloff_mult_
	return info

## A zombie's swing. Never a headshot.
static func melee(amount_: int, source: Vector3) -> DamageInfo:
	var info := DamageInfo.new()
	info.amount = amount_
	info.kind = Kind.MELEE
	info.source_pos = source
	info.has_source = true
	return info

## An explosion, already falloff- and cover-resolved by AreaDamageSystem (or a
## mine's fixed charge). Never a headshot.
static func blast(amount_: int, origin: Vector3) -> DamageInfo:
	var info := DamageInfo.new()
	info.amount = amount_
	info.kind = Kind.BLAST
	info.source_pos = origin
	info.has_source = true
	return info
