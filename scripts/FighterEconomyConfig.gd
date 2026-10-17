extends Resource
class_name FighterEconomyConfig
## Every tunable for the fighter roster's economy, in one editable file.
##
## A Resource because RosterMenu is INSTANTIATED IN CODE — exports on a
## code-instantiated node never reach the inspector, so they would not
## actually be tunable. Same pattern FireMissionConfig/UAVConfig/
## SupplyDropConfig/ApacheConfig use.

## Hard cap on live fighters: the rescue grant's four plus recruits 5-8.
const FIGHTER_CAP := 8

## The roster is locked ("Rescue at Position Two") until the run reaches this
## position. On arriving there (GameManager.position_changed) the player is
## granted free_fighter_count fighters, once per run — the Position Two
## rescue. That grant is the ONLY way a fighter is ever free.
@export var fighters_unlock_position: int = 2
@export var free_fighter_count: int = 4

## Cost to recruit the 5th, 6th, 7th and 8th fighter, in that order — index 0
## is the 5th fighter's price. With fewer than free_fighter_count alive (the
## granted ones died), a replacement costs index 0: replacing fighters is an
## endless sink (docs/RUN_STRUCTURE.md "New price list"), not a free refill. Recruiting adds another gun; see
## upgrade_tier1_cost and friends below for the DIFFERENT axis of improving a
## gun you already have. validate() asserts these strictly increase.
@export var recruit_costs: Array[int] = [20, 35, 55, 80]

## Three upgrade tiers, each raising a fighter's rolled hit chance and damage
## WITHIN its FighterType band — never past FighterType.hit_chance_max, which
## is what keeps a fighter's hit chance below 100% at any tier. Exposed as
## three named variables rather than an array because the design intent
## (Tier 1 < Tier 2 < Tier 3, and the SUM matters as its own quantity against
## the recruit curve) is easier to read and to assert against this way.
@export var upgrade_tier1_cost: int = 15
@export var upgrade_tier2_cost: int = 20
@export var upgrade_tier3_cost: int = 30

## One-time per fighter, lost permanently if that fighter dies. Independent
## of the stat tiers above — a fighter can be suppressed at tier 0.
@export var suppressor_cost: int = 25

## Sum of all three upgrade tiers. Not a separate exported field: it is
## DERIVED so it can never drift from the three costs above by being edited
## independently of them.
func upgrade_path_total() -> int:
	return upgrade_tier1_cost + upgrade_tier2_cost + upgrade_tier3_cost

## Startup invariants, in the spirit of Arsenal's HK416 > M17 damage check.
## Called once, not at point-of-purchase — these are static properties of the
## config, not something that can become true or false at runtime.
##
## THE DESIGN INTENT THIS REPLACES AN OLDER, WRONG ASSERTION: recruiting and
## upgrading are not substitutes. Recruiting adds another gun; upgrading
## improves a gun you already have. An earlier pass compared upgrade-path
## total directly against every recruit tier, which is wrong on its face for
## the cheap tiers (65 was never going to be cheaper than the 5th fighter's
## 20) — deleted outright, not disabled, per instruction. What actually
## matters is the RELATIONSHIP to the marginal cost of a NEW body once the
## roster is full: deepening a fighter you already have must be cheaper than
## the most expensive body you could add instead, so that keeping fighters
## alive is rewarded at every roster size, not just some.
## What recruiting the next fighter costs with `live_count` alive. Index 0 of
## recruit_costs is the 5th fighter's price; below the grant's count it is
## also what a replacement costs. Nothing is ever free here: the grant is.
func recruit_cost(live_count: int) -> int:
	return recruit_costs[clampi(live_count - free_fighter_count, 0, recruit_costs.size() - 1)]

func validate() -> void:
	var total := upgrade_path_total()
	var highest_recruit: int = recruit_costs[recruit_costs.size() - 1]

	# 1. The full upgrade path must be strictly cheaper than the highest
	#    recruit tier — the actual design intent (65 < 80).
	assert(total < highest_recruit,
		"[FIGHTER ECONOMY] full upgrade path (%d) is not below the highest recruit cost (%d). Deepening an existing fighter must always be cheaper than the most expensive new body." % [total, highest_recruit])
	if total >= highest_recruit:
		push_error("[FIGHTER ECONOMY] upgrade path total %d >= highest recruit cost %d." % [total, highest_recruit])

	# 2. Recruit costs strictly increase — no tier may cost the same as or
	#    less than the one before it.
	for i in range(1, recruit_costs.size()):
		assert(recruit_costs[i] > recruit_costs[i - 1],
			"[FIGHTER ECONOMY] recruit_costs must strictly increase; tier %d (%d) does not exceed tier %d (%d)." % [
				i, recruit_costs[i], i - 1, recruit_costs[i - 1]])
		if recruit_costs[i] <= recruit_costs[i - 1]:
			push_error("[FIGHTER ECONOMY] recruit_costs not strictly increasing at index %d." % i)

	# 3. Each individual upgrade tier must cost less than the full path total
	#    — guards a single tier being mispriced above the sum of all three.
	for tier_cost in [upgrade_tier1_cost, upgrade_tier2_cost, upgrade_tier3_cost]:
		assert(tier_cost < total,
			"[FIGHTER ECONOMY] an individual upgrade tier costs %d, not below the full path total %d." % [tier_cost, total])
		if tier_cost >= total:
			push_error("[FIGHTER ECONOMY] upgrade tier %d >= path total %d." % [tier_cost, total])

	# 4. The grant plus one priced recruit per remaining slot fills the cap
	#    exactly — recruit_costs indexes from the first fighter past the grant.
	assert(free_fighter_count + recruit_costs.size() == FIGHTER_CAP,
		"[FIGHTER ECONOMY] free_fighter_count (%d) + recruit_costs (%d) must equal FIGHTER_CAP (%d)." % [
			free_fighter_count, recruit_costs.size(), FIGHTER_CAP])
	if free_fighter_count + recruit_costs.size() != FIGHTER_CAP:
		push_error("[FIGHTER ECONOMY] grant + recruit tiers != FIGHTER_CAP.")
