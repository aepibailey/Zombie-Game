extends Resource
class_name SupplyDropConfig
## Every tunable for the radio-callable Supply Drop enabler, in one editable
## file — same reason FireMissionConfig exists: SupplyDropSystem is
## instantiated in code, so exports directly on it would never reach an
## inspector.

# --- Economy ----------------------------------------------------------------
## THE PRICE. One flat integer. It does NOT scale with weapons owned, night
## number, points held, or anything else, and there is deliberately no code
## anywhere that makes it do so.
##
## THE GAP IS THE MECHANIC. The crate's VALUE scales with the loadout (2 mags
## per owned weapon); its PRICE does not. So the same 31 points buys:
##
##   1 weapon  → 23 pts of contents — a BAD BUY, you wasted 8 points
##   2 weapons → 27 pts             — still a mild loss
##   3 weapons → 31 pts             — roughly break-even
##   4 weapons → 37-39 pts          — a strong buy, the best resupply in the game
##
## Being a bad deal early is the intended early-game experience, not a bug to
## fix. This is a LATE-GAME mechanic that the player grows into.
##
## Derived from real store prices as bundle(3) over the three cheapest-to-
## resupply weapons: (1+2+2 ammo_cost) * 2 mags + 6 grenade + 15 IFAK = 31.
## SupplyDropSystem asserts the whole curve stays inverted on every call.
@export var supply_drop_cost: int = 31

# --- Timing -------------------------------------------------------------
## Delay between confirming the LZ and the crate appearing overhead.
@export var supply_drop_delay: float = 20.0
## How long the crate takes to descend under canopy once it appears. A
## deliberate visual and audible tell that pulls zombies toward the LZ —
## never instant.
@export var descent_time: float = 8.0
## Independent of every other enabler's cooldown, and separate from the short
## global radio lockout.
@export var supply_drop_cooldown: float = 120.0

# --- Landing ------------------------------------------------------------------
## The crate lands at a random offset up to this far from the painted point.
## Painting picks INTENT, not the exact metre — you call the LZ, the aircrew
## fly it.
@export var landing_scatter_radius: float = 5.0
## When true, the landing crate detonates `crush_profile` through the shared
## AreaDamageSystem. Default FALSE — a crate that kills you for standing on
## your own LZ is a trap, not a mechanic, until it's explicitly opted into.
@export var crate_crush_damage_enabled: bool = false
## Only used when crate_crush_damage_enabled. Routed through the shared area
## damage system unchanged — no new damage code exists for this.
@export var crush_profile: AreaDamageProfile

# --- Contents -----------------------------------------------------------------
## Magazines granted PER OWNED WEAPON, snapshotted from ownership at CONFIRM
## time — see SupplyDrop.magazines_by_weapon.
@export var mags_per_weapon: int = 2
@export var grenades_per_crate: int = 1
@export var ifaks_per_crate: int = 1
