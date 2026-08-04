# Patrol Base Zero — V2 Spec

> **Scope note.** This file did not exist when the V2 work began — the repo
> contained only `PROJECT_SPEC.md` and `README.md`. It was created to hold the
> V2 additions requested for this pass. **`PROJECT_SPEC.md` remains the master
> spec** for everything built before V2 (weapons, obstacles, economy, day/night
> loop, build mode); this document covers only what V2 adds on top and does not
> restate it. If the two ever disagree, `PROJECT_SPEC.md` wins for V1 systems
> and this file wins for the zombie-variant architecture below.

---

## 1. ZombieType resource architecture

Zombie stats were hardcoded as constants on `Zombie.gd`. They are now a
`Resource`, so adding a variant is a `.tres` file rather than a code change —
the same pattern `WeaponData` / `Arsenal` already use for the weapon roster.

**`scripts/ZombieType.gd`** (`extends Resource`, `class_name ZombieType`)

| Group | Fields |
|---|---|
| Identity | `id`, `display_name` |
| Health & scoring | `max_health`, `points_body_kill`, `points_headshot_kill` |
| Movement | `move_speed_wander`, `move_speed_chase`, `chase_speed_sprint_fraction`, `acceleration_time`, `chase_entry_delay` |
| Melee | `melee_damage`, `melee_cooldown` |
| Leap | `can_leap`, `jump_apex_height`, `max_horizontal_distance`, `jump_cooldown`, `landing_recovery`, `leap_path_ratio_threshold` |
| Appearance | `body_radius`, `body_height`, `head_radius`, `albedo_active` |
| Audio | `sfx_chase_entry` |

**What deliberately stays on `Zombie.gd`:** anything shared by every variant and
not expected to differ — LOS ranges (`CHASE_LOSE_RANGE`,
`LASER_INVESTIGATE_SIGHT`), `INVESTIGATE_TIMEOUT`, `REPATH_INTERVAL`,
`WANDER_RADIUS`, `ATTACK_RANGE`, `HEADSHOT_MULT`, and the noise-bus wiring.
Pushing genuinely-global tuning into a per-variant resource would mean editing
N files to change one rule.

**Wiring.** `Zombie.tscn` exports `zombie_type` and defaults to
`zombie_walker.tres`, so a hand-placed zombie still works. `Main._spawn_zombie()`
picks a type and assigns it (plus `max_hp`) **before `add_child()`**, since
`_ready()` seeds health and builds the silhouette from it.

**Per-instance resource duplication.** Sub-resources declared in a `.tscn` are
*shared* across instances of that scene. `_apply_type_appearance()` therefore
duplicates the capsule shape, capsule mesh, sphere shape, sphere mesh and
material before touching any of them — mutating in place would resize and
recolour every zombie in the world at once. (The material was already guarded
this way; the geometry needed the same treatment.)

**Derived geometry.** `body_center_y() = body_height/2` and
`head_center_y() = body_height + head_radius`, keeping the head sphere tangent
to the top of the capsule so the two volumes never overlap — headshot
resolution depends on that (see `PROJECT_SPEC.md` "Zombie geometry & hitboxes").

**Per-night HP scaling** now applies to each variant's own base:
`max_hp = type.max_health + hp_per_step * floor((night-1) / nights_per_step)`.
The step is absolute (+8 per 2 nights), not proportional, so a leaper stays
exactly 40 HP squishier than a walker for the entire run.

### Walker extraction — verified byte-for-byte

`resources/zombie_walker.tres` carries the old constants unchanged:

| Field | Value | Replaced |
|---|---|---|
| `max_health` | 100 | `BASE_HP` |
| `move_speed_wander` | 1.6 | `WANDER_SPEED` |
| `move_speed_chase` | 3.6 | `CHASE_SPEED` |
| `melee_damage` | 20 | `ATTACK_DAMAGE` |
| `melee_cooldown` | 1.0 | `ATTACK_INTERVAL` |
| `points_body_kill` / `points_headshot_kill` | 1 / 3 | literals in `_die()` |
| `body_radius` / `body_height` / `head_radius` | 0.4 / 1.56 / 0.12 | `Zombie.tscn` sub-resources |
| `acceleration_time` / `chase_entry_delay` | 0.0 / 0.0 | *(no such mechanic existed)* |
| `can_leap` | false | *(new)* |

Derived geometry reproduces the scene's hardcoded transforms exactly:
body centre 0.78, head centre 1.68, total height 1.80m. With
`acceleration_time` and `chase_entry_delay` both 0, `_current_chase_speed()`
returns full chase speed on the first frame of Chase — identical to reading
the old constant. With `can_leap` false, `_try_enter_leap()` returns on its
first check, so a walker never evaluates a leap condition.

---

## 2. Leaper variant

`resources/zombie_leaper.tres`. Fragile, fast, and **the leap is traversal, not
a pounce** — it exists to cross obstacles, never to close ground.

| Stat | Value | Notes |
|---|---|---|
| `max_health` | 60 | vs walker's 100 |
| `move_speed_wander` | 1.6 | **identical to the walker** — indistinguishable by movement until Chase |
| `move_speed_chase` | **0.85 × player sprint = 6.375 m/s** | derived at runtime, not hardcoded |
| `acceleration_time` | 1.2s | wander speed → chase speed |
| `chase_entry_delay` | 0.5s | screech + lurch, no acceleration — the player's tell |
| `melee_damage` / `melee_cooldown` | 20 / 1.0 | same as walker |
| Points | 3 body / 5 headshot | vs walker's 1 / 3 |

**Chase speed is a relationship, not a number.** `chase_speed_sprint_fraction
= 0.85` resolves against `Player.SPEED[MoveState.SPRINT]` at runtime via
`ZombieType.resolved_chase_speed()`. If sprint speed is ever retuned the leaper
follows automatically instead of silently becoming faster or slower than
intended. When the fraction is 0 (walker), `move_speed_chase` is used directly.

### Leap mechanic — confirmed ballistics

All values read from source: gravity `24.0` (`project.godot`), sprint `7.5`
(`Player.gd`), apex `5.0m`, cap `6.0m`, recovery `0.35s`.

```
v_vertical  = sqrt(2 · g · apex) = sqrt(2 · 24 · 5) = 15.4919 m/s
arc time    = 2 · v / g                             =  1.2910 s   ← fixed by apex, independent of distance
horiz speed = distance / arc_time,  distance clamped to 6.0m
            = 6.0 / 1.2910                          =  4.6476 m/s  (72.9% of run speed)
```

The **6m cap is enforced at launch**, not merely aimed at: `_launch_leap()`
clamps distance with `minf(flat.length(), max_horizontal_distance)` and then
derives horizontal speed from it, so total travel physically cannot exceed the
cap.

**HARD RULE verification — a leap must never close distance faster than
running it.** Arc time is constant, so the run wins by a larger margin at every
distance below the cap; the 6m cap is the tightest case:

| Distance | Run | Leap (arc + recovery) | Leap is |
|---|---|---|---|
| 1m | 0.157s | 1.641s | +1.484s slower |
| 3m | 0.471s | 1.641s | +1.170s slower |
| 6m (cap) | **0.941s** | **1.641s** | **+0.700s slower** |

**20m closure, measured wall-clock:**

| Approach | Time | vs run |
|---|---|---|
| Pure run, 20m | **3.137s** | baseline |
| One max leap (6m) + run 14m | **3.837s** | +0.700s |
| All-leap (4 leaps) | **6.564s** | +3.427s |

Effective leap-chain speed is **3.656 m/s = 57.4% of running**. Leaping is
strictly a worse way to cover open ground — exactly as required. **Rule
satisfied; shipped.**

### Leap trigger — all five gates must hold

Evaluated in `_try_enter_leap()`, cheapest first so the common case (a leaper
running at an open player) costs almost nothing:

1. **`can_leap`** and **cooldown elapsed** (`jump_cooldown` 3.0s)
2. **State is CHASE**
3. **Path is genuinely obstructed** — the `NavigationServer3D` route is
   ≥ **1.6×** the straight-line distance, or there is no route, or it stops
   more than 2m short of the player
4. **Obstruction within 6m** — a ray on layers 1 | 6 (world + ditch shells)
   hits something inside the cap
5. **A clear ballistic arc exists** — the parabola is sampled in 8 segments and
   ray-traced; the landing point must be real navmesh within 1.5m of where it
   was aimed

**It never leaps at an unobstructed player.** Gate 3 is the guarantee: a
straight run the navmesh agrees with means there is nothing to leap over.
Landing spots are searched **far-to-near** so the leaper clears the obstruction
outright rather than landing on top of it.

### Leap state behaviour

- **`NavigationAgent3D` is parked** at launch; movement is pure ballistics.
- **No mid-air steering** — the arc is committed at launch. Deliberate: an
  airborne leaper is a predictable, high-value target.
- **Fully damageable in flight**, headshots included — hitboxes are untouched.
- Noise, laser-dot curiosity and **being shot** are all blocked from redirecting
  a leaper mid-flight (`_is_committed()`), which would otherwise cancel the arc.
  For walkers this reads exactly as the old CHASE-or-ATTACK test, since they
  never reach these states.
- A committed leap resolves **before** the dormant-by-day check, so dawn
  breaking mid-arc cannot freeze a zombie in the air.
- **On landing:** `LEAP_RECOVER`, fully immobile for **0.35s**, then back to
  Chase.
- **Rooftop fallback:** if the landing point is not on navmesh, the leaper
  immediately re-leaps toward the player with the **cooldown waived** — being
  stranded on a roof is worse than an off-cadence leap. If no validated arc is
  available it takes the capped hop toward the player anyway.

### Readability (functional, stealth-critical)

- **Silhouette:** capsule `0.28r × 1.94h` (total **2.18m**) vs the walker's
  `0.4r × 1.56h` (**1.80m**) — taller and visibly thinner at NVG range, so a
  leaper is identifiable *before* it is within charge distance.
- **Albedo:** `Color(0.72, 0.66, 0.30)` — pale yellow, brighter than the
  walker's `(0.25, 0.60, 0.25)` green. Dormant grey is shared across variants
  on purpose: "asleep" should read the same for everything; it is the *active*
  silhouette that must be tellable apart.
- **Screech on Chase entry**, played through a per-variant
  `AudioStreamPlayer3D`. **Deliberately NOT routed through `NoiseManager`** — it
  is a player-facing tell, not a zombie-facing alert, and must not pull other
  zombies in. Placeholder generated by `tools/gen_leaper_screech.py` (rising
  420→1150Hz warbling shriek, 0.55s, sized to fit the 0.5s tell window and to
  be unmistakable against the low, noise-based footstep and death samples).
- `F4` hitbox debug volumes are type-driven, so they draw the correct
  silhouette per variant rather than always the walker's.

### Spawning

`Main.leaper_fraction_for_night()` — leapers debut **night 4** at **10%** of the
spawn budget, **+5% per subsequent night**, capped at **30%**. Nights 1–3 are
100% walkers. Every spawn rolls independently against that fraction.

| Night | 1–3 | 4 | 5 | 6 | 7 | 8 | 9+ |
|---|---|---|---|---|---|---|---|
| Leapers | 0% | 10% | 15% | 20% | 25% | 30% | 30% (capped) |

Tunable via `@export` on `Main`: `leaper_first_night`, `leaper_start_fraction`,
`leaper_fraction_step`, `leaper_max_fraction`. Each night logs its mix:
`[Night N] mix: X% leapers (walker H HP / leaper H HP)`.

### Shots-to-kill — leaper at base 60 HP, point blank

| Weapon | Body dmg | Body STK | Head dmg | Head STK |
|---|---|---|---|---|
| Sig Sauer M17 | 34 | **2** | 68 | **1** |
| HK 416 | 30 | **2** | 60 | **1** |
| SPAS-12 | 22 × 9 | **1 shell** (3 of 9 pellets) | 44 × 9 | **1 shell** (2 pellets) |
| M249 SAW | 28 | **3** | 56 | **2** |
| KAC M110 | 60 | **1** | 120 | **1** |

At 40m (a typical cross-map engagement), body shots: M17 **2**, 416 **3**,
SAW **3**, M110 **1**; SPAS is past its 40m max range and irrelevant.

**Night-scaled reality.** Leapers debut on night 4, so base 60 is never what
you actually shoot — `HP = 60 + 8·floor((night−1)/2)`. Body shots at point
blank:

| Night | Leaper HP | M17 | 416 | SPAS | SAW | M110 |
|---|---|---|---|---|---|---|
| 4 | 68 | 2 | 3 | 4 pellets | 3 | **2** |
| 6 | 76 | 3 | 3 | 4 pellets | 3 | **2** |
| 8 | 84 | 3 | 3 | 4 pellets | 3 | **2** |
| 10 | 92 | 3 | 4 | 5 pellets | 4 | **2** |
| 12 | 100 | 3 | 4 | 5 pellets | 4 | **2** |

> **Flagged — exact-boundary interaction.** At base 60 HP the M110's 60 body
> damage is an *exact* one-shot kill, with zero margin. It holds (the M110 has
> no falloff, so it is always exactly 60), but it is the kind of coincidence
> that breaks silently if either number moves by one. It is also moot in
> practice: leapers debut at night 4 with 68 HP, where the M110 needs 2 body
> shots. The headshot one-shot is robust at every night through 12 (120 dmg vs
> 100 HP). Worth deciding whether the base-60 one-shot is intended before
> either value is retuned.

---

## 3. Sandbags: 5-section obstacle

The sandbag obstacle was a single 4000 HP object, destroyed and freed as one
10m piece. It's now **`SandbagWall`** (`scripts/SandbagWall.gd`, extends
`Obstacle`) — a placement/pricing/footprint/persistence registry holding no
health of its own — aggregating 5 **`SandbagPanel`** (`scripts/SandbagPanel.gd`,
plain `Node3D`, not an `Obstacle` subclass) sections, each independently
destructible, each 2m of the wall's 10m length.

**Why a plain `Node3D` for the panel, not another `Obstacle`:** `Obstacle`
owns placement/footprint/pricing/persistence concerns that belong to the
*wall* — the thing actually bought and placed — not to one fifth of it. A
panel is purely a destructible geometry+health unit the wall constructs.

**Why this needed almost no changes to the systems that damage sandbags.**
`AreaDamageSystem._damage_structures()` and `Zombie._try_enter_attack_structure()`
already iterated *every* member of the `"sandbags"` group independently,
judging each by its own `nearest_point()`/distance — that was already
correct, generic code. Sectioning the sandbag was entirely a property of
**what's in the group**: panels join `"sandbags"` directly (the wall does
not), so both consumers now operate at per-section granularity automatically.
Neither file needed a code change.

**The one place that genuinely needed a fix, not just a reclassification:**
`Zombie._do_attack_structure()`'s guard for "has my target become invalid"
was `not is_instance_valid(_structure_target)`. The old sandbag queue_free()'d
itself on destruction, so invalidation *was* the re-acquire signal. Panels now
persist even when destroyed (see below — a wall must stay repairable), so a
destroyed panel stays `is_instance_valid() == true` forever, and without a
fix a zombie would stand at a pile of rubble "attacking" it indefinitely
instead of re-acquiring or walking through the gap it just made. Fixed by
checking `_structure_target.destroyed` explicitly alongside validity.

### Health tuning

```gdscript
## ALTERNATIVE (uncomment to use instead — same total-wall cost, no length
## discount, i.e. durability roughly matches the old 4000 HP wall spread
## across 5 tougher sections):
## @export var section_health: float = 4000.0 * 0.25          # 1000/section
@export var section_health: float = 4000.0 * 0.25 / 5.0        # 200/section
```

| | Per section | Whole wall (×5) | vs old 4000 HP |
|---|---|---|---|
| **Primary (active)** | 200 HP | 1000 HP | **25%** |
| Alternative (commented) | 1000 HP | 5000 HP | 125% |

The primary formula is a real durability cut, not just a granularity change,
because each section is also 1/5 the material — at the zombie siege rate
(15 dmg/1.2s = 12.5 dps), **one section falls to a single zombie in ~16s**,
and a full sequential 5-section breach takes **~80s**, down from the old
wall's ~320s. Reported here rather than silently retuned further — if this
reads as too fragile once played, the alternative line above restores
roughly the old per-length durability with one edit.

### Damage routing

- **Zombie melee:** `_try_enter_attack_structure()` picks the nearest panel
  (by `nearest_point()`) across every wall's panels, same generic search as
  before. `_do_attack_structure()` re-checks reachability periodically and
  now *also* re-checks `_structure_target.destroyed` every frame (the fix
  above) — a zombie whose panel dies re-acquires the next intact one, or
  finds the player newly reachable through the gap, whichever the existing
  reachability check decides first.
- **Explosives (`AreaDamageSystem`):** no changes needed. Every panel within
  blast radius is damaged independently, exactly per its own distance —
  this was already the system's behaviour once panels replaced one wall
  object in the `"sandbags"` group.
- **Player fire:** unchanged — bullets hit whichever panel's collision shape
  is actually in the way; a destroyed panel has no collision shape enabled,
  so rounds pass through the gap.

### Destruction

At 0 HP a panel (`SandbagPanel._destroy()`):
- **Disables its `CollisionShape3D`** (`set_deferred`, since this can fire
  from inside a physics query callback — a zombie's melee hit or an
  area-damage raycast pass) — zombies path through the resulting gap on the
  next navmesh rebake.
- **Does not free itself.** Unlike the old wall, a destroyed panel must
  persist and stay repairable. `_visual` swaps to a flattened, sunk copy of
  the SAME box mesh (scale `(1.05, 0.12, 1.05)`, sunk to `size.y * 0.06`) —
  no new art, and deliberately more collapsed than the "critical" standing
  state (0.7 vertical scale) so it silhouettes as gone, not merely hurt.
- **Never touches a neighbour.** Panels share no adjacency link; damage and
  destruction are purely local to the panel hit.
- **Persists across the day/night boundary** via `SandbagWall.to_dict()`,
  which serialises all 5 panels' `{health, destroyed}` (not a single float —
  see Persistence below).

If every panel is destroyed, `SandbagWall.active` flips to `false`
(`_refresh_active()`, called on any panel's `changed` signal) — the wall
itself is **never freed**, its footprint stays reserved on the placement
grid, and it's still fully repairable. Repairing any panel flips `active`
back to `true`.

### Visual readability

Four states per panel (`_refresh_visual_state()`), tint + vertical sag,
reusing the wall's original two thresholds:

| State | Health | Tint | Vertical scale |
|---|---|---|---|
| Intact | > 66% | base colour | 1.0 |
| Damaged | 33–66% | darkened 25%, warmed | 0.88 |
| Critical | < 33%, still standing | darkened 50%, warmed | 0.7 |
| Destroyed | 0, rubble | darkened 70%, desaturated | **0.12**, sunk |

Both cues read under the NVG green tint by construction, not by luck: tint is
a **brightness** change (`darkened()`), and the NVG overlay is a translucent
green multiply that preserves relative brightness — a hue-coded scheme
(red/yellow/green) would wash toward monochrome under it, a
darkness-graded one doesn't. Sag is a **geometric silhouette** change,
entirely independent of colour grading, so it reads identically in daylight,
NVG, or a hue this scheme didn't anticipate. Repair calls
`_refresh_visual_state()` fresh from full health — there's no incremental
tint/scale blending to leave a residue, so a repaired panel returns to
exactly the intact state with nothing left over.

**Deliberately no per-panel health bar.** `HealthBar3D` (built for the
whole-wall version) is generic and still exists, but 5 simultaneous floating
bars on one wall was judged clutter beyond what tint+sag already reads as —
matching the brief's own "tint plus a small vertical sag is sufficient."
Left wired up for nothing today; the right tool for a future single-object
destructible (a gate, say) where one bar per object is exactly right again.

### Repair

Reuses the existing interact/selection pattern — right-click under the
cursor in build mode — rather than a new UI paradigm. The old flow
immediately repaired a single flat health value on right-click; a wall is
now 5 independently-priced repairs plus a summed total, which doesn't fit a
one-line message, so right-clicking a sandbag wall now **opens a panel**
(top-right, mirroring the palette's position on the left) instead of
repairing immediately. Right-clicking a minefield still replenishes
immediately, unchanged — a single flat action still fits the old pattern.

The panel lists all 5 sections (`Section N — STATE (health/max)`), each with
its own repair button, plus a summed **Repair All**. Escape closes the panel
first if one is open, and only closes build mode itself on a second press or
when nothing is open; right-clicking empty ground also closes it (mirrors
the palette's click-to-deselect).

```gdscript
## PRIMARY: ceil(wall_price / 5). Set for real from the catalog price in
## SandbagWall.setup(); 10 pts / 5 = 2 pts per section.
@export var section_repair_cost: int = 2
```

- **Destroyed section:** costs the full `section_repair_cost` (2 pts) —
  falls out of the same formula as "damaged", since missing HP / max HP = 1.0
  in that case; no special-cased branch.
- **Damaged-but-standing:** `ceil(section_repair_cost × missing_fraction)`,
  minimum 1 point (`SandbagPanel.repair_cost()`).
- **Repair All**, all 5 destroyed: `5 × 2 = 10 pts` — **exactly the wall's
  10 pt placement price.** Not a bug, but worth knowing: fully rebuilding a
  breached wall currently costs the same as placing a brand new one
  elsewhere. Flagged, not silently adjusted.
- **Every repair button is always visible and priced**, disabled (not
  hidden) when unaffordable — `font_color_disabled` red, matching the store
  UI's existing convention (`SupplyCrateUI._add_row`) rather than inventing
  a new disabled-state treatment.
- Points spend through `PointsManager.spend_points()` — the same call every
  other purchase and the old whole-wall repair already used. No new
  transaction path.
- Build mode only opens during Day (unchanged, pre-existing gate at the
  Engineers' Tent), so "no repair during Night" holds without any extra
  check in the repair path itself. No repair-count limit is enforced.

### Persistence

`SandbagWall.to_dict()` serialises `{health, destroyed}` for all 5 panels as
an array (`"sections"`), not a single float — a wall chewed to 40% on one
section and untouched on the other four restores exactly that split, not an
average. `GameState`/`BuildMode.adopt()` needed **no changes**: both already
call `to_dict()`/`apply_dict()` polymorphically through the `Obstacle`
interface, so a wall's richer per-section payload flows through the existing
generic pipeline unmodified. A restored wall's `active` flag is recomputed
from the restored panel states (`apply_dict()` → `_refresh_active()`), not
itself persisted.

---

## 4. Weapon damage: M17 falloff, HK 416 buff, and the damage-order fix

Scope: this section covers only the M17 and the HK 416. **SPAS-12, M249, and
M110 stats are untouched in this pass, as are zombie HP scaling and every
weapon price.** Their pre-existing tuning stays under `PROJECT_SPEC.md`.

### 4.1 The bug found first (fixed before any tuning)

The reported symptom was "the M17 kills late-night zombies in 2 headshots
while the 416 takes 3". Diagnosing it turned up **two separate things**, one a
code defect and one a data fact.

**Defect — headshot and falloff were applied in the wrong order, with a
rounding step between them.** `Player._fire_ray()` computed

```gdscript
var dmg: int = maxi(1, int(round(weapon.body_damage * mult)))   # falloff, ROUNDED
var dealt: int = target.take_damage(dmg, headshot)              # headshot, applied after
```

and `Zombie.take_damage()` then did `amount * HEADSHOT_MULT`. So falloff was
applied **first**, truncated to an integer, and the headshot multiplier was
applied to that already-rounded value. That is not equivalent to
headshot-then-falloff, because the intermediate `round()` throws away a
fraction that the ×2 would otherwise have doubled:

| body dmg | falloff | old order (falloff → round → ×2) | correct order (×2 → falloff → round) |
|---|---|---|---|
| 34 | 0.40 | `round(34×0.40)=14`, `×2` = **28** | `round(34×2×0.40)` = **27** |
| 34 | 0.52 | `round(34×0.52)=18`, `×2` = **36** | `round(34×2×0.52)` = **35** |

The old order quietly inflated long-range headshots by up to one point per
half-unit of discarded fraction. It was never large, but it was wrong, and it
made the headshot damage of any weapon with falloff impossible to predict from
its stated numbers.

**Fix:** the entire formula now lives in one place, `Zombie.take_damage()`:

```gdscript
func take_damage(amount: int, headshot: bool, falloff_mult: float = 1.0) -> int:
	var dmg: int = maxi(1, int(round(float(amount) * (HEADSHOT_MULT if headshot else 1) * falloff_mult)))
```

Callers pass **raw, un-multiplied `body_damage`** plus the multiplier, and
never pre-multiply. Headshot applies first, falloff second, and rounding
happens exactly once at the end. The `falloff_mult: float = 1.0` default keeps
the two existing non-weapon callers (`Zombie.take_area_damage()` and
`Minefield.gd`) working unchanged — explosions and mines pass no multiplier
and are unaffected by this change.

**Data fact — the 416 genuinely had lower base damage than the M17** (30 vs
34). That is not a bug and was not "fixed" as one; it is the balance problem
§4.3 addresses. Note that the rounding defect did **not** cause the reported
symptom: at the ranges involved the two orders agree, and the M17's 2-headshot
kill came purely from its higher base damage. Both were fixed, but only the
second was the player-visible complaint.

**Correction to the framing of the request.** The request assumed other
weapons "default to no falloff". They did not: **all four of M17, HK 416,
SPAS-12, and M249 already had falloff curves** under the pre-existing
piecewise system; only the M110 had none. The SPAS and M249 curves are left
exactly as they were.

### 4.2 Falloff as a reusable per-weapon property

`WeaponData` now carries **two** falloff models, and each weapon selects
exactly one:

| Model | Fields | Used by |
|---|---|---|
| Simple 2-point (new) | `use_simple_falloff`, `falloff_start_distance`, `falloff_end_distance`, `falloff_min_multiplier` | M17 |
| Piecewise 3-segment (pre-existing) | `falloff_near`, `falloff_mid`, `falloff_mid_mult`, `falloff_far`, `falloff_far_mult` | SPAS-12, M249 |
| None | *(no fields set — inert defaults)* | HK 416, M110 |

`damage_mult_at(distance)` branches on `use_simple_falloff` and evaluates
**one model or the other, never both**. This is deliberate: adding the new
fields as an additional multiplier on top of the old ones would have silently
double-applied falloff to any weapon carrying values under both systems. The
flag defaults to `false`, so the SPAS and M249 keep their existing curves with
no edit to their definitions at all.

**This is the pattern for future falloff tuning.** Reach for the simple
2-point model by default — it is two distances and a floor, and it reads
directly off a design intent like "full damage to 15m, 40% by 40m". Use the
piecewise model only when a curve genuinely needs three segments with a
different slope in each (the SPAS's cliff between 10m and 20m, then a second
shallower drop, is the case it exists for).

### 4.3 M17 — range falloff

```gdscript
"use_simple_falloff": true,
"falloff_start_distance": 15.0,
"falloff_end_distance": 40.0,
"falloff_min_multiplier": 0.4,
```

Full damage at or under 15m, linear to ×0.4 at 40m, flat ×0.4 beyond. Falloff
applies to **both body and headshot damage** — the headshot multiplier is
applied first, then falloff (§4.1).

| Range | Multiplier | Body | Headshot |
|---|---|---|---|
| 0–15m | 1.000 | 34 | 68 |
| 20m | 0.880 | 30 | 60 |
| 25m | 0.760 | 26 | 52 |
| 30m | 0.640 | 22 | 44 |
| 35m | 0.520 | 18 | 35 |
| 40m+ | 0.400 | 14 | 27 |

This replaces the M17's previous piecewise curve (full damage to 25m, ×0.70 at
60m, ×0.50 at 100m). **The new curve is substantially harsher**: the old one
still paid 34 body damage at 25m where the new one pays 26, and bottomed out
at ×0.50 rather than ×0.40. That is the intent — the starter pistol should not
be a viable rifle — but it is a real nerf to the M17 at 15–40m, not a
like-for-like reshaping, and it is stated here rather than left to be
discovered in play.

### 4.4 HK 416 — damage

**`body_damage`: 30 → 66.**

This number is derived, not chosen by feel. The requirement was that the 416
kill in **strictly fewer headshots than the M17 at every night tier and every
range**. The binding case is a **night-9/10 zombie (132 HP) at point-blank**,
where the M17 headshots for 68 and kills in 2. Beating 2 strictly means a
one-headshot kill, which needs ≥132 headshot damage, i.e. **≥66 base**. Every
lower value fails somewhere:

| 416 base | First failure |
|---|---|
| 30 (old) | night 1, 100 HP, 0m — both kill in 2 |
| 50 | night 3, 108 HP, 0m — both kill in 2 |
| 60 | night 7, 124 HP, 0m — both kill in 2 |
| 64 | night 9, 132 HP, 0m — both kill in 2 |
| 65 | night 9, 132 HP, 0m — both kill in 2 |
| **66** | **none** — verified across nights 1–200 × 0–150m at 0.25m steps |

Resulting **headshot** shots-to-kill (zombie HP = `100 + 8×floor((night−1)/2)`):

| Night | HP | M17 @10m (68) | M17 @35m (35) | 416 @any range (132) |
|---|---|---|---|---|
| 1 | 100 | 2 | 3 | **1** |
| 3 | 108 | 2 | 4 | **1** |
| 5 | 116 | 2 | 4 | **1** |
| 7 | 124 | 2 | 4 | **1** |
| 9 | 132 | 2 | 4 | **1** |
| 11 | 140 | 3 | 4 | **2** |
| 13 | 148 | 3 | 5 | **2** |
| 15 | 156 | 3 | 5 | **2** |
| 17 | 164 | 3 | 5 | **2** |
| 19 | 172 | 3 | 5 | **2** |
| 21 | 180 | 3 | 6 | **2** |

**Flagged, not acted on.** 66 base damage puts the 416 **above the M110's 60**,
and the 416 also has a 30-round magazine, an 11.1 rps cycle, and now
penetration. On the numbers the M110 is strictly dominated except by its scope
and its tighter moving cone. The request explicitly forbade touching the M110,
the SPAS, the M249, prices, or HP scaling in this pass, so none of them were
changed — but the roster consequence is real and this is the note it asked
for. The cleanest resolutions, if wanted later, are (a) raise the M110's damage
and the top-tier zombie HP together, or (b) relax the rule from "strictly fewer
headshots at *every* night tier" to "from night 11 on", which drops the minimum
416 base from 66 to **51** — still a large buff over 30, still comfortably
ahead of the M17 at all ranges, but back below the M110's 60. Option (b) costs
only the early nights, where a 100 HP zombie dying to 1 headshot instead of 2
is the least interesting part of the change anyway.

### 4.5 HK 416 — penetration

```gdscript
"max_penetration_targets": 2,
"penetration_damage_multiplier": 0.6,
```

A 416 round passes through the zombie it hits and continues into **up to 2
additional zombies** behind it. Both fields live on `WeaponData` and default to
`0` / `0.6`, so **every other weapon is unaffected** — with
`max_penetration_targets == 0` the trace loop in `Player._fire_ray()` runs
exactly once and behaves identically to the single-hit ray it replaced.

Rules:

- **60% damage per target after the first, flat — not compounded.** The 2nd
  and 3rd zombie each take ×0.6, not ×0.6 and ×0.36. This is modelled as flesh
  resistance, distinct from ballistic falloff (the 416 has none).
- **The headshot multiplier is resolved independently per target.** A round can
  body the first zombie and head the second; each hit is graded by whichever
  collider that segment struck, exactly as a single-target shot is.
- **Penetration is flesh-only. The round stops dead on the first non-zombie
  collider** — world geometry, obstacles, sandbag panels, the player. This is
  enforced structurally: the loop breaks on any hit that is not in the
  `zombies` or `zombie_heads` group, so no obstacle type has to opt out and a
  future obstacle inherits the behaviour for free.
- A zombie can only be damaged **once per round**. Its head `Area3D` and body
  collider are separate, so consecutive ray segments can both strike the same
  zombie; the second strike is skipped and, importantly, **does not consume
  penetration budget**.

Per-target damage at base 66:

| Target | Body | Headshot |
|---|---|---|
| 1st | 66 | 132 |
| 2nd | 40 | 79 |
| 3rd | 40 | 79 |

### 4.6 HK 416 — no falloff

The 416 deals flat damage to its 200m max range. Achieved **by absence**: its
falloff fields are simply not set, so `WeaponData`'s inert defaults
(`9999` / `1.0`) make `damage_mult_at()` return `1.0` everywhere. Its previous
curve (full to 30m, ×0.85 at 85m) was removed.

### 4.7 The invariant

`Arsenal._validate_damage_invariants()` runs once at startup and asserts that
the **416's effective per-shot damage exceeds the M17's at every distance from
0 to max range**, sweeping in 0.25m steps and using each weapon's own
`damage_mult_at()` curve. It fires both an `assert()` (with the offending
distance and both damage figures in the message) and a `push_error()`, because
asserts are stripped from release builds.

This exists because the exact inversion it forbids is what shipped: the free
starter pistol out-damaged the 15-point rifle at every range, and nothing in
either weapon's definition made that visible — it only appears when the two
are compared across the whole range band. Any future tuning that re-introduces
it fails loudly at boot rather than silently in play.

The check compares **body** damage. The headshot multiplier is a single shared
constant (`Zombie.HEADSHOT_MULT`) applied identically to both weapons
downstream, so it cancels out of the comparison entirely and checking the body
figure proves the headshot figure. This also avoids adding a `class_name` to
`Zombie.gd` purely to expose a constant to the check.
