extends Resource
class_name SupplyDropConfig
## Every tunable for the radio-callable Supply Drop enabler, in one editable
## file — same reason FireMissionConfig exists: SupplyDropSystem is
## instantiated in code, so exports directly on it would never reach an
## inspector.

enum PricingMode { FLAT, SCALED }

# --- Economy ----------------------------------------------------------------
## Which cost model applies. FLAT: `cost` below, a single fixed number.
## SCALED: `discount_pct` of the summed individual price of the actual
## contents for the CURRENT loadout, recomputed live (see
## SupplyDropSystem._current_cost()) — a crate is always worth less than its
## contents under either mode; the runtime assertion in
## SupplyDropSystem._call() checks this on every call regardless of mode.
@export var pricing_mode: PricingMode = PricingMode.FLAT
## FLAT mode's cost. Default is ~70% of the M17-only bundle value (2 mags @
## 1pt + 1 grenade @ 6pt + 1 IFAK @ 15pt = 23pts; 70% of that is 16.1,
## floored to 16) at current store prices — see StoreCatalog. Owning more
## weapons only ever RAISES contents value, so this stays valid at any
## loadout; it's the one-weapon case that sets the floor.
@export var cost: int = 16
## The discount SCALED mode applies, and the ceiling FLAT mode is checked
## against — see the runtime assertion.
@export_range(0.0, 1.0) var discount_pct: float = 0.7

# --- Timing -------------------------------------------------------------
## Delay between confirming the call and the crate actually landing on the LZ.
@export var delay: float = 20.0
## Independent of every other enabler's cooldown, and independent of the
## short global radio lockout — this is how often a NEW drop can be called
## in, not how long the crate takes to arrive.
@export var cooldown: float = 120.0

# --- Contents -----------------------------------------------------------------
## Magazines granted PER OWNED WEAPON, snapshotted from ownership at call
## time — see SupplyDrop.magazines_by_weapon.
@export var mags_per_weapon: int = 2
@export var grenades_per_crate: int = 1
@export var ifaks_per_crate: int = 1
