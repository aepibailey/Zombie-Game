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

---

## 5. Area-damage system: audit findings

The shared area-damage system was built and partially playtested in an earlier
pass. It was audited before the grenade was built on top of it. **It was not
rebuilt**, and almost everything checked out; this section records what was
verified and the four things that were changed.

### 5.1 Interface

```gdscript
AreaDamageSystem.detonate(
    origin: Vector3,
    profile: AreaDamageProfile,
    facing: Vector3 = Vector3.ZERO,
    source_name: String = ""
) -> Dictionary        # {actors, structures, total_damage, killed}
```

Everything else is on the `AreaDamageProfile` resource. `AreaDamageSystem.gd`
is the "how"; the `.tres` is the "what".

### 5.2 Is it generic, or grenade-shaped?

Generic. All three planned consumers are expressible with the interface
unchanged:

| Consumer | Verdict |
|---|---|
| Directional claymore | Fully covered. `arc_degrees` + the `facing` argument, and `in_arc()` is applied to **both** actors and structures — so a directional charge won't blow up a wall behind it. Pure `.tres`. |
| White phosphorus | Covered. `duration > 0` spawns a ticking zone that re-queries the damageable group **every tick**, so a zombie that walks into an already-burning zone is burned. That is the part that is easy to get wrong and it is right. Pure `.tres`. |
| 120mm mortar | Covered, but **not via `duration`**. See below. |

**The mortar footgun, documented rather than coded around.** `duration`
repeats at ONE fixed origin — it models a persistent burn zone, not a barrage.
A 120mm mission is N separate `detonate()` calls at N scattered origins,
scheduled by the mortar itself: the delay before the first round and the
spread between impacts are the caller's business, because a profile describes
ONE burst. An implementer who reaches for `duration` gets a pillar of fire at
a single point. This is now stated on the field itself in
`AreaDamageProfile.gd`.

### 5.3 What was verified and left alone

- **No faction filtering, structurally.** Iterates the `damageable` group with
  no filter of any kind. Player and Zombie both join in `_ready()`. `source`
  is logging-only and explicitly not excluded — your own grenade kills you. A
  future allied fighter is picked up by joining the group and implementing
  `take_area_damage()`, and nothing else.
- **FALLEN and ENTANGLED zombies are valid targets**, confirmed by absence:
  nothing anywhere filters on zombie state. Two details make it actually work:
  **C-wire does not block frag** (`COVER_MASK` deliberately excludes
  `PLAYER_BARRIER_LAYER` — wire is strands, not cover), while **the ditch
  revetment does** (`SOLID_NO_NAV_LAYER` is in the mask). Both are correct: a
  grenade landing *in* the pit has clear line of sight to everything in it,
  and one on the lip is blocked by the wall.
- **Line of sight is multi-point, not a single ray.** `_exposure()` traces to
  3 body sample points and returns a 0–1 fraction. Zombies supply
  silhouette-scaled points, so a tall leaper is harder to fully cover than a
  walker; the player uses its **live** head height, so crouching genuinely
  reduces exposure. Actor bodies are excluded from the trace — bodies never
  shield each other, only real geometry does.
- **Per-section sandbag damage already worked**, and needed no change when
  sandbags were re-cut into 5 panels: `SandbagPanel` joins the `sandbags`
  group *directly* (the wall does not), and `_damage_structures()` measures to
  each panel's own `nearest_point()`. A **destroyed** panel also stops
  providing cover for free, because destruction disables the collision shape
  the LOS ray reads.

### 5.4 What was changed (four fixes)

1. **`tick_interval` is clamped to a 0.05s floor.** A profile authored with
   `0.0` never advanced `elapsed` and became a permanent damage zone —
   `create_timer(0)` still yields a frame, so it would not have hard-hung, it
   would have quietly burned forever. White phosphorus is the first consumer
   of that exact path.
2. **`Player.is_alive()` added.** `_apply_once()` guards on
   `has_method("is_alive")`, so the player was silently absent from every
   blast's `killed` tally. **`hp > 0` does not work here**: the player has no
   persistent dead state — `take_damage()` calls `_respawn()` synchronously at
   0 HP, restoring full HP before `take_area_damage()` even returns — so a
   naive HP test reads true on both sides of the killing blow. It uses a
   one-frame death latch set in `_respawn()` and cleared deferred, which is
   also what the grenade's "died while cooking" hook hangs on.
3. **`duration`'s mortar footgun documented** (5.2).
4. **`frag_grenade.tres`'s obstacle note corrected.** It justified
   `obstacle_damage_mult` against a **4000 HP** sandbag wall; sections are
   **200 HP**. The reasoning was wrong by 20x, not the value.

---

## 6. Hand grenade

### 6.1 Keybinds

| Key | Action | Input-map action |
|---|---|---|
| `N` | Toggle NVGs (**moved from G**) | `nvg_toggle` |
| `G` | Equip / stow hand grenade | `equip_grenade` |

Both are **input-map actions**, not keycodes, so they stay remappable; the
code refers to action names and never assumes which key is bound. Physical
keycodes, matching the existing `interact` convention.

**N was already taken.** `Main.KEY_FINISH_NIGHT` is `KEY_N` — the "finish the
night" answer on the all-clear prompt — and worse, the NVG check ran *before*
the prompt block in the same `_unhandled_input`, so N would have toggled NVGs
and the prompt would have looked broken. **Resolved by ordering, not
re-lettering:** `_unhandled_input()` now checks the modal prompt first and
marks the event handled. `Y`/`N` keeps its yes/no mnemonic, and NVGs get N
whenever the prompt is not up.

### 6.2 Equip state

`grenade_equipped` is a flag. **The weapon slot is never swapped out** — so
"stow and return to the previously equipped weapon" needs no save/restore,
because the weapon was always still there, merely gated.

- **Equipping forces un-ADS through the same function as a weapon switch.**
  The un-ADS block was *extracted* from `_equip()` into `_force_unads()`
  rather than copied, so the grenade rule cannot drift from the weapon rule.
- Switching to any weapon stows it, including re-pressing the already-equipped
  slot. Silent — the swap is its own feedback.
- Zero grenades: G does nothing, emits "No grenades."
- Firing is blocked while a grenade is in hand, **including the full-auto hold
  path** — otherwise holding LMB to cook would also empty a magazine.

### 6.3 Cooking and throwing

LMB = overhand, RMB = underhand. The throw type is **committed at press**; the
other button goes inert, and only the committed button's *release* throws.

- **`GRENADE_FUSE = 5.0`**, started the instant the button goes down. Cooking
  and flight share one clock, so a grenade cooked 2s has 3s of flight. That is
  the whole reason to cook.
- **Cook-off is genuinely lethal**, and the arithmetic was checked rather than
  assumed: 180 blast damage vs the player's 100 HP, detonated at the hand, and
  the player's own body is excluded from the LOS trace, so exposure is 1.0 and
  nothing softens it.
- **Death mid-cook** detonates where the body dropped. Position-captured and
  `call_deferred`, because `_respawn()` can itself be running *inside*
  `AreaDamageSystem`'s actor loop and detonating inline would re-enter that
  loop mid-iteration.
- Movement speed is untouched while cooking; **only sprint** is removed.
  Merely holding a grenade costs nothing.

**Deviation from the literal request, deliberate.** Stowing (G) or switching
weapons **while the fuse burns is refused**, with "Fuse is burning — throw
it." Allowing it would leave the player holding a live grenade with no way to
throw it — the throw lives behind `grenade_equipped` — i.e. a guaranteed death
they never chose. Guarded at both entry points and backstopped in
`_set_grenade_equipped()`. The three legitimate ways a cook ends (throw,
cook-off, death) all clear `_cooking` first, so none are blocked.

### 6.4 Projectile

`Grenade.gd`, a `RigidBody3D`. **It owns no damage code**: detonation is one
`AreaDamageSystem.detonate()` call with `frag_grenade.tres`.

- **Collision layer 0, on purpose.** Layer 1 would put the grenade inside the
  blast's own `COVER_MASK` and let a grenade act as its own cover. Its *mask*
  still covers world + sandbags + the ditch revetment, so it collides
  normally. C-wire is excluded — a grenade rolls under wire.
- `continuous_cd` on, so a fast throw cannot tunnel a sandbag.
- **Zero linear damping, with `DAMP_MODE_REPLACE`** — see 6.5.

### 6.5 Trajectory preview arc

`GrenadeArc.gd`. Visible only with a grenade in hand, rebuilt every frame,
terminates at first impact. No bounce or roll prediction, no impact marker, no
blast ring. Where it ends is where the grenade first *touches*, not where it
comes to rest; reading that difference is the player's job.

It reproduces the throw rather than resembling it: origin and velocity come
from `Player.grenade_launch_origin()`/`grenade_launch_velocity()` — the same
functions `_throw_grenade()` calls — gravity from
`Grenade.projectile_gravity()`, and raycasts on `Grenade.COLLISION_MASK`.
**Two things had to change to make that literally true:**

1. **The projectile's linear damping is now zero, with `DAMP_MODE_REPLACE`.**
   The mode matters: the default *combines* with the project's ambient
   `default_linear_damp` (0.1), which would have applied even at 0.0. Settling
   is left to friction and angular damping, which act only on contact.
2. **The simulation integrates at the PHYSICS tick rate**, emitting a drawn
   sample every 4 ticks, and raycasts every *sub*-step. Integrating
   sample-to-sample instead adds `g·t·(dt_sample − dt_physics)/2` of extra
   droop under semi-implicit Euler — about **1.0m low after 1s of flight**.
   The arc would have pointed a metre short of the real impact.

**Rendering.** A camera-facing ribbon, not `PRIMITIVE_LINE_STRIP` — Godot 4
fixes 3D line width at 1px, too thin to read against greybox terrain.
Unshaded, alpha-blended, **never additive**, no emission, albedo under 1.0.
Per-vertex alpha 0.85 → 0.10 along the curve under a 0.55 global dimmer, so
short throws read confident and long ones trail off.

**NVG legibility** was checked against the implementation, not assumed: the
night NVG path is a green `ColorRect` overlay with **no glow pass at all**
(`Main._apply_gain_limit()` enables glow only during the *daylight* gain-limit
whiteout), so the arc cannot bloom at night by construction. Keeping albedo
under 1.0 also holds it below the HDR glow threshold if glow is ever enabled
at night later.

Visibility sits behind `Player.grenade_arc_enabled`, read every frame so it
can be toggled at runtime.

### 6.6 Throw ballistics — and a gravity divergence

**Flagged: the grenade body runs at `gravity_scale = 0.5`. The player's own
fall is untouched.** The project's 24.0 gravity is tuned for how the *player*
falls (2.4x real, makes jumps crisp). Applied to a thrown object it is
crushing: an overhand throw travelled **6.5m and was in the air 0.42s**, which
is not a grenade throw. Halving it puts the projectile near real gravity.

| | Speed / pitch | Range | Peak | Flight |
|---|---|---|---|---|
| Overhand | 24 m/s @ 14° | 27.6m | 3.0m | 1.18s |
| Underhand | 10 m/s @ 45° | 9.7m | 3.6m | 1.37s |

The lob is **both shorter and higher** — both conditions checked, not inferred
from the loft angle. Both flights land well inside the 5s fuse, so an uncooked
throw lands and rolls before it goes off.

### 6.7 Detonation

`resources/frag_grenade.tres`. 4m lethal, 9m max, QUADRATIC falloff so damage
reaches exactly zero at max:

| 0–4m | 5m | 6m | 7m | 8m | 9m |
|---|---|---|---|---|---|
| 180 | 115 | 65 | 29 | 7 | 0 |

**Noise 50m.** Against the roster (M17 40, HK416 45, M249 47, M110 48, SPAS
50) a detonation out-pulls every unsuppressed rifle and ties the shotgun — so
it is at least as loud as anything you can fire, and louder than all but one.

> The M249 was 55m until the noise pass in §8 dropped it to 47m; before that
> it was the one weapon a detonation did not out-pull.

**Flagged: `max_damage` was raised 110 → 180, which was not requested.** At
110 the "lethal radius" was not lethal. Zombie HP is
`100 + 8·floor((night−1)/2)`, so a point-blank grenade **stopped one-shotting
anything from night 5 onward**, and "a grenade thrown into the ditch kills the
zombies trapped in it" was false for most of a run. 180 is the night-21
zombie's exact HP: a grenade inside 4m one-shots every zombie through night 22
and degrades gracefully after. **Accepted side effect: the player's own kill
zone widens from 4m to 5m.**

`obstacle_damage_mult` moved 0.25 → **0.153** to compensate, because
180 × 0.153 = 27.5 per sandbag section — *exactly* what 110 × 0.25 delivered.
Sandbag durability against grenades is unchanged at ~7 grenades per 200 HP
section. **The two numbers move together; change one and recompute the other.**

**Verified by simulation, not assumed:** a grenade falling the pit's full 3m
settles in **2 bounces** (rebound apex 0.24m, then 0.02m at `BOUNCE = 0.28`),
so it comes to rest in the ditch and cannot bounce back out.

### 6.8 Inventory

- **Hard cap 4.** `grant_grenades()` is the only path that raises the count and
  it clamps; every other write is a decrement. Store purchases and resupply
  drops both route through it, so the cap is enforced in exactly one place.
- **Not restocked at dawn.** `Main._begin_day()` has no refill path — nothing
  in the codebase does — matching the existing "ammo does NOT regenerate, not
  on death, not at dawn" rule. Grenades also survive death: `_respawn()`
  restores HP and position only.
- **Persist across nights**, because night transitions are phase changes on a
  live scene, never a reload.
- HUD shows `Grenades: N / 4  [G]` under the ammo readout, greyed at zero and
  amber while equipped.

**Noted, not fixed:** `GameState` captures obstacles, night and points but no
player-held inventory, so grenades inherit the gap **IFAKs already have** and
would be lost across a real scene transition. Latent for the multi-level work,
not a bug today; it should be fixed for IFAKs and grenades together rather
than as a grenade special case.

### 6.9 Resupply drops

Each guaranteed drop grants **1 grenade** alongside its ammo, through
`grant_grenades()` — the same capped path as a purchase. At 4 carried the
grenade is **lost**, not held over, and the collection summary says so
explicitly ("Grenade lost (carrying 4/4)") so a wasted grenade is visible
rather than silent.

Note that `SupplyDrop.setup()` **replaces** the contents dictionary rather
than merging into it, so `Main._spawn_supply_drop()` has to spell out
`"grenades": 1` even though `SupplyDrop` defaults to it. Omitting it would
silently drop the grenade.

---

## 7. Store: the EQUIPMENT tab, and what "data-driven" does not cover

A fourth tab, EQUIPMENT, alongside WEAPONS / ATTACHMENTS / SUPPLIES. Hand
grenade at **6 points**, repeatable, **Day-only**, blocked at the carry cap
with `CARRYING 4/4` on a disabled button — the same visual language the full
IFAK pouch uses.

**The store's "adding a category is a config change" claim is half true**, and
the half that isn't is worth knowing before the ENABLERS tab is built.

**Genuinely data-driven:** `categories()` builds the tabs, `items_in()` builds
the rows. Adding a category really does produce a working tab with no UI
changes.

**Not configuration — five things:**

1. **Purchase dispatch is a `match item.kind` in `Player.gd`.**
   `apply_store_purchase()` needed a new `"equipment"` arm.
   `owns_store_item()` did **not** — its `_` default already returns `false`,
   which is correct for anything repeatable.
2. **Carry caps are per-item by construction.** `store_item_blocked()` reads a
   different counter against a different maximum for each, so the grenade
   needed its own line beside the IFAK's. **Left per-item deliberately** —
   collapsing them behind a shared interface would hide which field a cap
   belongs to.
3. **There was no day-gating mechanism for store items at all.** The crate is
   deliberately open in *both* phases (`SupplyCrateZone`: "usable in BOTH
   phases now"), so Day-only is a per-item restriction with no precedent.
   Rather than hardcode it, `StoreItem` gained a **`day_only` flag** and
   `store_item_blocked()` checks it generically — a future Day-only item is
   now a catalog entry, not another branch.
4. **The key hint was a literal `"1/2/3"`** and went stale the instant a fourth
   category existed — exactly the hardcoding the claim rules out. Now derived
   from the tab count, bounded by the number keys actually bound (1–4).
5. **The empty-tab message was weapon-centric** ("buy a weapon first") and
   would have been wrong on any tab that is not weapon-gated. Now conditional.

**For ENABLERS:** the tab appears for free, but expect the same **two edits in
`Player.gd`** (an `apply_store_purchase` arm, plus a `store_item_blocked` line
if it has a cap) unless that dispatch is reworked first. The shape of a rework
would be a `grant_method` field on `StoreItem` that `apply_store_purchase`
calls.

**No other tab regresses.** All five item kinds were traced through the UI:
equipment has no `weapon_id` so it skips the owned-weapon filter, takes the
`item.cost` path rather than the drum-scaled ammo path, and can never render
as OWNED. The crate stays open across the day/night boundary, so
`phase_changed` now triggers a re-render (guarded on `visible`) — otherwise a
grenade row would still read "Buy" after dusk.

---

## 8. Weapon noise: M249 brought in line with the HK 416

**`M249.noise_unsuppressed`: 55m → 47m.**

The SAW and the 416 fire the **same cartridge (5.56×45 NATO)**, so a single
report should carry about the same distance. 55m against the 416's 45m implied
a fundamentally louder weapon, which the ammunition does not support. 47m keeps
the SAW marginally the louder of the two — longer barrel, open-bolt action —
without pretending it is a different class of noise.

**The SAW's threat was never its muzzle blast; it is its volume of fire.** A
100-round belt at 12.5 rounds/second emits a noise event *per shot*, so holding
the trigger still floods the area with overlapping 47m events. Nothing about
that changed. What changed is that one burst no longer announces itself 10m
farther than the same round out of a 416.

**This puts the whole roster in caliber order**, which it was not in before:

| Weapon | Cartridge | Unsuppressed | Suppressed |
|---|---|---|---|
| M17 | 9×19mm | 40m | 8m |
| HK 416 | 5.56×45mm | 45m | 10m |
| M249 SAW | 5.56×45mm | **47m** | 14m |
| KAC M110 | 7.62×51mm | 48m | 11m |
| SPAS-12 | 12 gauge | 50m | 12m |

9mm < 5.56 < 7.62 < 12ga, with the two 5.56 weapons 2m apart. Previously the
SAW sat above the 7.62 DMR and the 12-gauge shotgun on nothing but its own
say-so.

**Knock-on effect, intended:** the hand grenade's 50m blast now out-ranges
every rifle on the roster and ties only the SPAS-12. The M249 was previously
the single weapon that pulled zombies from farther than a detonation.

**Flagged, not changed:** `noise_suppressed` remains **14m** on the SAW
against the 416's **10m** — the same 5.56-parity argument applies there and was
left alone because the request specified the unsuppressed figure. There is a
defensible reason to keep a gap (suppressor performance depends on barrel
length and gas system, not just cartridge), but if the caliber argument is
meant to hold throughout, this is the other number to move.

---

## 9. M18A1 Claymore

A purchasable, carryable, emplaceable directional mine. Built as a **consumer**
of the two systems the hand grenade established — the shared area-damage
system and the equipment equip-state — not as a parallel implementation of
either. The whole claymore adds **no damage code at all**: `_detonate()` hands
`AreaDamageSystem` an origin and a facing vector, and everything else is
`.tres`.

### 9.1 Audit: what the grenade work actually left behind

| Claymore requirement | Already existed |
|---|---|
| Directional filter | `AreaDamageProfile.arc_degrees` + `in_arc()`, applied to **both** actors and structures; `facing` was already a `detonate()` parameter |
| Zero damage outside the cone | `in_arc()` fails → target skipped before damage is computed |
| Friendly fire on the player | No faction filtering anywhere; the player is in `damageable` |
| LOS blocked by sandbags/terrain, not C-wire | `COVER_MASK` deliberately excludes `PLAYER_BARRIER_LAYER` |
| Doesn't damage sandbags | `damages_obstacles`, the per-source opt-in |
| Noise matching the grenade | `noise_radius`; reused the grenade's 50m rather than inventing one |
| Equip / un-ADS / fire-gating | `_force_unads()` was already extracted and generic |

Two things did **not** exist and had to be built: a generic equipment slot (the
equip state was grenade-*specific*, though not grenade-*shaped*), and a
standalone arc test usable without an `AreaDamageProfile`.

### 9.2 The equipment slot, generalised

`Player.grenade_equipped` (a bool) became
`Player.equipped_item: Equipment { NONE, GRENADE, CLAYMORE }`, with
`grenade_equipped` / `claymore_equipped` / `equipment_equipped` as **read-only
property views**.

Two independent bools were rejected: they make "both equipped at once" a
representable state and force every gate to test both. Keeping
`grenade_equipped` as a property view (rather than replacing it with
`equipped_item ==` at each call site) meant **`HUD.gd` and `GrenadeArc.gd`
needed no changes at all**.

Behaviour-preserving for grenades, verified case by case — equip from none,
stow while not cooking, the refusal to stow a burning fuse, and the re-equip
early-out all take the same branches and emit the same values. One deliberate
new behaviour: **G while a claymore is out unequips it** — switching to the
grenade if you have any, cancelling placement if you don't — so the input is
never a silent no-op.

### 9.3 AreaMath

`scripts/AreaMath.gd`: static, stateless containment geometry
(`in_horizontal_arc`, `in_height_band`, `arc_fan_points`).

`AreaDamageProfile.in_arc()` now **delegates** to it — same signature, same
answers, internals only. This exists because the claymore's DETECTION arc and
the blast's DAMAGE arc were about to be two implementations of the same
question, and a mine that triggers over a different wedge than it damages is a
genuinely nasty bug to see from the outside. The Apache patrol box and the
mortar target-paint will both need containment tests and neither owns a
profile, which is why this cannot live on that resource.

### 9.4 Keybind

**V** (`equip_claymore`, physical 86), registered in `project.godot` alongside
`nvg_toggle` and `equip_grenade`.

**C was the obvious choice and is already crouch** — not incidental, either:
crouch is silent movement, it drives the M249 stance penalty, and it lowers
the player's blast-exposure sample points. Unlike the N/NVG collision, this
one could not be solved by ordering, because crouch and equip are both
always-live rather than modal. V was picked from the free keys (V/X/F) after
sweeping every keycode in `scripts/`.

### 9.5 Emplacement

Claymore is a **scene instantiated into the world**, parented to the current
scene and never to the player. Deliberately **not** an `Obstacle` subclass:
that hierarchy carries `ObstacleCatalog` pricing, a placement footprint on
layer 4, and BuildMode's placement cap, none of which apply to a store-bought
item emplaced from the equip state. Same reasoning that keeps `SandbagPanel`
out of it.

The ghost renders the **same body builder and the same wedge** as a real
claymore — a preview that looked different from the thing it previews would be
a lie in exactly the place the player is making a decision. Facing is the
**player's yaw**, not the camera pitch, so looking down to place doesn't tip
the mine at the dirt.

The aim ray is clamped to `placement_max_range` with a **downward probe
fallback**, so aiming at the horizon still previews a spot at your feet rather
than failing outright. Rejections: no ground in range, slope beyond 40°,
another claymore within 1m, an obstacle footprint (the same layer BuildMode's
own placement test uses), or a point off the navmesh.

### 9.6 Arming and detection

**Arming is structural, not a flag.** Detection and the trigger countdown both
sit *below* the arming early-return in `_physics_process`, so during the 2.0s
window neither can have started — there is no path by which a mine detonates
before it is live. An emissive dot blinks amber while arming and goes steady
green when live; it stops blinking once armed, because a mine flashing all
night is a beacon and the state it was signalling is over.

Detection runs on a **0.1s accumulator, not per frame**, cheapest test first,
returning on the first hit:

1. distance, squared, no `sqrt`
2. height band (`AreaMath.in_height_band`)
3. arc (`AreaMath.in_horizontal_arc` — the same function the blast uses)
4. line of sight — last, because it is the only expensive test

Zombie RIDs are excluded from the LOS ray so zombies never shield each other,
matching the blast's own rule that only real geometry is cover. The mask is
`AreaDamageSystem.COVER_MASK` **by reference**: a mine that could *see*
further than its blast can *reach* would trigger on targets it then failed to
damage.

**Only the `zombies` group is scanned**, so the player cannot trip a claymore
from any position at any range. The player can still be killed by one — but
only ever by something else setting it off.

The **0.15s trigger delay is committed**: once started it runs to detonation
whether or not the zombie that tripped it is still in the arc. That is what
catches a cluster rather than only the lead.

### 9.7 Damage

`resources/claymore_blast.tres`. 60° arc, and inside it:

| 0–6m | 7m | 8m | 9m | 10m+ |
|---|---|---|---|---|
| 250 | 202 | 155 | 107 | **0** |

**`FalloffMode.CURVE` is required, not stylistic.** `LINEAR` and `QUADRATIC`
both drive damage to *zero* at `max_radius` and cannot hold 60 at the edge.
The curve runs 1.0 → 0.24 across the 6→10m band with tangents set to the chord
slope, so the Hermite interpolation is exactly straight.

- Lethal to the 100 HP player anywhere inside **~9.1m of the cone**.
- **Zero outside the cone at any distance**, because `in_arc` fails before
  damage is computed. No backblast in either direction.
- One-shots a standard zombie inside 6m **through night 38**.
- A leaper is above the 2.0m band for ~10 consecutive detection sweeps of its
  1.29s arc, and below it only during the 0.145s of launch and 0.145s of
  landing — i.e. only while it is genuinely on the ground.

### 9.8 Persistence and recovery

> **Superseded by §10.2** (playtest fix pass) for the recovery mechanism
> itself. This subsection is kept for the persistence reasoning, which is
> still exactly accurate.

**Persistence is free.** Night transitions are phase changes on a live scene,
never a reload, and nothing frees scene children between phases — so an
emplaced claymore survives dawn by simply existing, exactly as placed
obstacles already do. No save step was written. (Same latent caveat as
grenades and IFAKs: `GameState` captures obstacles, night and points but no
player-held or player-placed state, so this would be lost across a real scene
transition. Not a bug today.)

Recovery was originally Day-only, proximity-based, and instant. **See §10.2
for the current mechanism** — look-at-and-hold, available any time, with a
3m noise cost on completion.

### 9.9 Store and inventory

> Cost and cap corrected in §10.1 — the numbers below are what shipped
> originally, not current. **15 points, cap 2** were the launch values;
> current values are **10 points, cap 4** (see §10.1).

Cap applies to **carried** claymores only, and always did — placing one
already removed it from the carried count with no separate cap on how many
can be emplaced in the world, before the playtest pass ever touched this
file. EQUIPMENT tab, separate line item and separate inventory from the
grenade. **Not in resupply drops** — the drop logic is untouched and still
grants exactly 1 grenade.

`grant_claymores()` was deliberately **not** merged with `grant_grenades()`
into a generic `grant_equipment(kind, n)`: they are independent inventories
with independent caps, and a shared function would take the counter and the
max as arguments anyway, so the only thing sharing buys is an indirection
between a purchase and the field it changes.

Adding the item cost exactly the **two `Player.gd` edits** §7 predicted — an
`apply_store_purchase()` arm and a `store_item_blocked()` cap line.
`owns_store_item()` needed nothing.

---

## 10. Playtest fix pass: night purchases, claymore rework, radio menu

Three isolated changes, one commit each, driven by a fresh audit against live
code rather than trusting this file. The audit found real drift between what
this document claimed and what the code actually did — corrected below,
alongside the actual changes.

### 10.0 Audit corrections (nothing changed, framing was wrong)

Two assumptions going into this pass turned out to be false, checked against
source rather than assumed:

- **The store was never gated behind the Engineers' Tent.** Purchases happen
  at the supply crate (`SupplyCrateZone`), which has been usable in **both**
  Day and Night since an earlier pass — its own comment says so explicitly.
  The Tent (`EngineersTentZone`) is a separate zone that gates **BuildMode**
  (obstacle placement) only, and is genuinely Day-only, but has nothing to do
  with buying anything. There was no spatial gate on purchases to preserve
  beyond what already existed: walking to the crate, exposed, at night.
- **Weapons, attachments, ammo and the radio were never Day-restricted
  either.** Only the grenade and the claymore had `day_only: true` set. The
  per-item `day_only` flag on `StoreItem` — the thing this pass needed to use
  — already existed, already had exactly the right generic semantics
  (opt-in restriction, default available), and needed no redesign. The whole
  of §10.1 below is two boolean flips.

### 10.1 Grenades and claymores purchasable at night

`StoreCatalog.gd`: `day_only: true` removed from the `grenade` and `claymore`
entries. Nothing else changed — `SupplyCrateUI` already rendered a `day_only`
item as a disabled, greyed `"DAY ONLY"` row (used for these two items
already), so no UI work was needed either.

**Claymore cost and cap corrected in the same pass** (bundled with the
recovery rework, §10.2, since both touch the same catalog entry and Player
fields): **15 → 10 points**, **carry cap 2 → 4** (`Player.claymore_max_carry`).
The "carried only, unlimited placed" rule needed **no code change** —
emplacing already decremented `claymores` with no separate placed-count cap
anywhere in the original implementation; that was already correct.

Grenade cost/cap (6 pts / 4 carried) were untouched — only its Day
restriction lifted.

### 10.2 Claymore recovery: look-and-hold, any time

Replaced entirely. Was: nearest claymore within 1.5m of the *player*,
Day-only, a single instant `E` press, no noise, `Player._update_claymore_recovery()`
doing a full linear scan of the `"claymores"` group **every physics frame**.

Now:
- Must be **looking at** a specific claymore within **2.0m**
  (`recovery_range`), **hold** interact for **0.5s** (`recovery_hold_time`),
  releasing early cancels with no penalty. Available **any time** — the Day
  gate is gone.
- Completion emits a **3m noise event** (`recovery_noise_radius`) at the
  player's position — browsing/holding is silent, committing costs you, the
  same convention the radio's transmission noise (§10.3) uses.
- "Looking at" is a **real raycast**, not a proximity/angle heuristic.
  `Claymore` previously had zero collision of any kind (pure visual meshes).
  Added a ray-detectable-only `Area3D` per claymore (`monitoring = false`,
  tagged via `set_meta("claymore", self)`) on a new dedicated layer,
  `Obstacle.INTERACT_LAYER` (64) — isolated from every other mask in the
  project, so weapon fire and the claymore's own detection LOS check cannot
  hit it. The query mask includes world geometry (layer 1) alongside it, so
  a wall between the player and the mine correctly blocks recovery.
- **This is also the performance fix.** A raycast query is O(1) with respect
  to how many claymores exist in the world; only the one actually being
  looked at is ever touched. This replaces the flagged-in-audit unbounded
  per-frame scan, which would have degraded as placed count grows — and
  Phase 2b/10.1 explicitly forbids capping placed count.
- `Claymore.can_recover()` **reversed**: previously refused a *triggered*
  mine outright, as an explicit, documented design choice ("not a mechanic
  that should exist even by accident"). That decision is overridden here —
  recovery is now required to be able to cancel a pending detonation, and
  does so for free: completing recovery calls `queue_free()`, which halts
  `_physics_process()` before `_detonate()` can run. In practice this rarely
  matters — the 0.15s trigger delay is far shorter than the 0.5s recovery
  hold, so it only changes anything if a mine triggers in roughly the last
  third of an *already in-progress* hold. Otherwise the mine wins the race
  and detonates on schedule; if the player is in the blast, that's the same
  friendly-fire outcome any other bystander gets.

Not implemented, left as explicitly flagged: blocking recovery while a
zombie is inside the detection arc. No such gate exists, matching the
default the earlier audit proposed.

### 10.3 Radio menu: `T`, currently empty

`scripts/RadioMenu.gd` (new `CanvasLayer`, built in code like every other UI
in this project). Bound to `T` (`radio_menu` input action, physical 84,
confirmed unbound in the audit).

**Genuinely empty today, and that's correct, not a placeholder bug.** It
lists `EnablerManager.callable_enablers` — a new `Array`, honestly empty
until the first real enabler (UAV, a *called* Supply Drop distinct from the
existing automatic Night 3+ crate, Apache, mortar, WP) registers into it.
Opening it with the Radio owned shows `"No transmissions available."`; the
row-rendering and selection/confirm code are fully written against a
documented minimal shape (`id` / `display_name` / `cost`) so the day a real
entry exists, **no menu-side changes are needed** — this is infrastructure,
not a stub.

- Gated on `Player.owns_item_id("radio")` — the radio's existing generic
  non-weapon purchase path (`owned_items`), left as-is. Not migrated to
  `EnablerManager`, and the radio's price/tab/purchase-time gating are
  unchanged — nothing in this pass asked for either.
- **Does not pause the game.** Movement stays enabled throughout; only
  mouse-look is suppressed (`Player.radio_menu_open`), so the camera can't
  spin by accident while reading, and combat otherwise keeps working. Read
  as: the menu blocks only the inputs it explicitly claims for itself, not
  everything indiscriminately.
- **Exit is `T`, on a dedicated `radio_menu_exit` action bound to the same
  physical key as `radio_menu`** — pressing T again closes it, like keying a
  handset rather than clicking through a dialog. Escape and RMB are
  deliberately NOT claimed by the menu at all: both fall through to Player's
  own normal handling exactly as if the menu weren't open — Escape toggles
  mouse capture, RMB toggles ADS. Neither key is gated on `radio_menu_open`
  anymore. (Previously Escape/RMB closed the menu and T did nothing while
  open; this pass reversed that.)
- **Transmission noise**: fixed **10m radius**, a single shared constant on
  `RadioMenu` — never a per-`EnablerType` field, so a mortar strike and a
  supply drop sound identical to key up. Fires only on **confirm**, never on
  open/browse. `NoiseManager.emit_noise()` has no duration parameter, so "3s
  of noise" is a repeating call on a 0.5s accumulator rather than a native
  sustained event, each pulse reading the player's **current** position so
  it follows them if they move mid-transmission. Currently unreachable in
  play (nothing to confirm), fully wired and correct once something is.

**Input-collision handling — all via explicit state checks, not
`_unhandled_input` dispatch order between sibling nodes**, deliberately, for
the same reason established earlier in the claymore/crate key collision:
relying on which node's handler runs first for a shared event is not
something to build correctness on.

- **RMB**: gated on `radio_menu_open`, plus a sticky
  `_ads_suppressed_until_release` flag that only clears on an actual
  button-*release* event. This is what makes "the click that closes the menu
  can never also open ADS" true regardless of processing order.
- **Escape**: gated on `control_enabled and not radio_menu_open`, mirroring
  the crate's existing "let the zone handle Esc instead" pattern. No pause
  menu exists anywhere in the codebase to leak into — confirmed, not
  assumed.
- **Number keys 1–9**: the menu claims them while open (selection), so
  `Player._try_equip_slot()` independently gates on `radio_menu_open` too —
  a weapon-slot switch must not fire on the same press that was meant for
  the menu. This is the one place a real input restriction was necessary;
  fire, reload, and the grenade/claymore equip keys are deliberately left
  unblocked while merely browsing, since they don't share a key with the
  menu and nothing in this pass asked for combat to freeze.

**Considered and reverted:** adding `day_only` to the radio's existing
catalog entry, to literally satisfy an earlier "radio remain Day-only"
phrasing. Reverted because the radio was never actually Day-restricted
(§10.0), and neither the night-purchase phase nor the radio-menu phase's
concrete diff asked for a *new* restriction on an item neither one otherwise
touches — that phrasing was describing weapons/attachments in general, not
instructing a behaviour change to the radio specifically.

---

## 11. Fire support: target painting, 120mm mortar, shake-and-bake

Two radio-callable indirect-fire missions built on a shared painting system.
Both are **consumers** of what already existed — the area-damage system from
the grenade work and the radio menu from the previous pass — and neither adds
a damage path of its own.

### 11.1 Audit findings (what actually existed going in)

The prior pass's "enabler architecture" was thinner than the spec implied,
and this section records the real starting state:

- **No `EnablerType` resource existed**, and still doesn't. Entries in
  `EnablerManager.callable_enablers` are plain Dictionaries. That was a
  deliberate deferral ("until a real enabler defines what fields it actually
  needs"); the shape those needs produced is documented on the field itself.
- **Nothing invoked anything.** `RadioMenu._select()` ended in a literal
  `TODO` — no `execute()`, no callback, no interface.
- **No cooldown state of any kind existed**, shared or otherwise.
- **Points were never actually spent.** `_select()` checked affordability and
  returned early, but never called `spend_points()`.
- **No painting or map-marking flow existed.** No enabler had one.
- **Sandbags already had full HP** (`SandbagPanel`, 200/section,
  `take_structure_damage()`), so mortar destruction needed no obstacle work.
- **C-wire and the ditch have no HP or damage entry point at all**, and
  `Minefield._detonate()` is private and requires a triggering zombie. Rounds
  therefore do **not** clear wire or cook off mines. Both would need new
  obstacle-system API and were reported rather than forced.

### 11.2 Target painting (`TargetPainter`)

Shared infrastructure, built generically — the Apache patrol box is the next
consumer and must need no changes to it. Nothing in it knows what a mortar is:

```gdscript
painter.begin(radius, max_range, on_confirm: Callable, on_cancel: Callable)
```

- Camera-centre raycast on `Obstacle.SOLID_SURFACE_MASK` — the same "what
  counts as ground" constant the grenade lands on and the claymore stands on.
- Marker is a filled ground disc plus a brighter rim band, drawn from
  `AreaMath.arc_fan_points(360, r)` — the same primitive the claymore's
  detection wedge uses. A circle that disagreed with the arc code about what a
  radius means would be a lie in the one place the player commits points.
- Unshaded, alpha-blended, **never additive** — must read on unlit ground at
  night without NVGs without washing the scene out.
- **150m max range** (`paint_max_range`, on `FireMissionSystem` — it is a
  property of the radio/observer, not of the ordnance). Flat distance, so
  painting into the ditch or onto a structure doesn't spend range on height.
  **No minimum: painting your own feet is legal, and lethal, by design.**
- **Does not pause, and deliberately does not suppress mouse-look or
  movement** — painting is aiming, not browsing. This is why it uses a new
  `Player.set_painting()` rather than `set_radio_menu_open()`, which
  correctly suppresses look for a menu and would be exactly wrong here.
- **LMB confirms, RMB and Escape cancel.** A cancel costs nothing: no points,
  no cooldown, no noise.

`Player.painting` gates firing, ADS, weapon slots and the equipment toggles.
The full-auto path is gated **separately and explicitly** because it is
*polled* — the painter marking its own input events handled does nothing for
a poll. Confirming also sets a release-gated fire suppression so the
confirming click can't double as a shot when paint mode ends.

### 11.3 The three radio-menu seams

The menu was declared out of scope, but two requirements could not be met
without it. All three changes are the seams the menu was explicitly built
with, and are surgical:

1. **Invocation.** Entries gained optional `call_fn` / `available_fn`;
   `_select()` invokes `call_fn` where the `TODO` was. Entries without them
   behave exactly as the old placeholder shape.
2. **Greying** now reads `EnablerManager.unavailable_reason()`, so the row and
   the selection path share one source of truth — a greyed row cannot be
   selected by pressing its number.
3. **Charging and noise moved out of `_select()`** into
   `RadioMenu.commit_transmission()`, called by the enabler once it has
   actually committed. **This is what makes a cancelled paint genuinely
   free** — otherwise selecting a mission and then cancelling would already
   have keyed the mic and pulled every zombie in earshot.

### 11.4 Cooldown model: independent, plus one global lockout

**Per-enabler cooldowns are independent**, keyed by enabler id on
`EnablerManager`. Deliberately not a shared pool: a shared pool means calling
a UAV locks out fire support, which pushes the player to hoard the radio
rather than use it.

**The one genuinely global thing** is `global_radio_lockout` (10s), applied
after *any* transmission, so three calls can't be chained back to back. "You
are still on the handset", distinct from and much shorter than any
per-enabler cooldown.

Cooldowns start at **last round impact**, not paint-confirm or menu
selection — see `_finish_mission()`. This means `cooldown` is the entire
recharge window the number on the tin promises, regardless of how long the
strike itself runs; it does not shrink as a strike is retuned longer. (A
cancelled paint still consumes nothing — the cooldown call happens far later
in the flow, well past the point a cancel could have occurred.)

| | Cost | Cooldown (from last impact) |
|---|---|---|
| 120mm Mortar | 50 | 180s |
| Shake-and-Bake | 80 | 240s |

**One mission in flight at a time**, shared across both — enforced by an
`available_fn` that greys the row to `IN FLIGHT`, and re-checked at confirm
because the menu closed several seconds earlier.

### 11.5 The 120mm mission

Paint → confirm → **8s time of flight** → **12 rounds over 18s**. Round
*times* are randomized within the window and sorted (the first always lands
at t=0, so "splash in 8 seconds" is honest); round *positions* are scattered
on the disc with a centre bias. A battery firing, not a metronome. Each
impact re-seats onto actual ground, so scatter that walks onto a structure or
into the ditch still detonates at the surface.

`round_count` and `mission_duration` were doubled together from an earlier
6/9s pass — never independently. The average gap between impacts is
`mission_duration / round_count`, so scaling only one would thin the beaten
zone out (longer duration, same rounds) or bunch it up (more rounds, same
duration); doubling both keeps that density exactly where it was and simply
runs the barrage twice as long.

**`effect_radius` (10m) IS ground truth — the paint circle the player aims
with, and the true outer bound of everything the mission can damage. The
player never sees a circle larger or smaller than where a round can actually
reach.** This holds because rounds are *not* scattered across the whole
painted circle: `FireMissionSystem._scatter_radius()` insets the landing locus
by `he_profile.max_radius` (7m — how far one round *reaches* from where it
lands), so a round landing at the very edge of its scatter locus still cannot
blast past the painted circle. Concretely: rounds land within 3m of the
painted point (10m − 7m), and each one's own 7m blast reach makes up the rest
— 3m + 7m = 10m, exactly the circle shown. `_validate()` warns at runtime if
a mission is ever tuned with `effect_radius` smaller than `he_profile.
max_radius`, since that would force every round onto the paint point.

Both `effect_radius` and `he_profile.max_radius` were halved together from an
original 20m/14m pass (along with WP's `wp_radius`, 15m → 7.5m) — same round
count, same cadence, same per-round damage at that point, landing in a
quarter of the original area. The beaten zone reads as denser and more
reliably lethal, and a player just outside the painted circle takes zero
damage, by construction.

Per round, from `mortar_he.tres`:

| 0–4m | 5m | 6m | 6.5m | 7m+ |
|---|---|---|---|---|
| 400 | 178 | 44 | 11 | **0** |

**Two deliberate departures from every other explosive in the project:**

- **`blocked_damage_mult` 0.35, not 0.0.** Grenades and claymores treat intact
  cover as total protection; a 120mm shell landing behind a sandbag wall
  should not. This is the profile that partially defeats cover, and it is why
  that field exists as a per-profile knob.
- **`obstacle_damage_mult` 2.5.** Sandbag sections are 200 HP, so any round
  within ~5.7m of a panel destroys it outright and a full mission reshapes a
  wall. Calling fire on your own perimeter costs you the perimeter.

**Noise 60m per round**, larger than any weapon (M249 47m) or the grenade
(50m). Every round is its own pull, and a full mission is now 12 of them
over 18s — **the mission is also a lure**, and that is a feature the player
can use deliberately.

### 11.6 Friendly fire

**Enabled, and it needed zero code.** `AreaDamageSystem` has no faction
filtering to begin with — the player is in the `damageable` group like
everything else, so the mortar and the WP hit them identically. Preventing it
would have required *adding* code.

- One round is lethal to the 100 HP player anywhere inside **~5.5m**
  uncovered, and inside **~4.5m** through cover.
- WP kills the player in **4.0s** of standing in it.
- The 8s time of flight is the entire mitigation *before* the first round
  lands, and the halved footprint makes it a more generous one than before:
  clearing the painted circle now means covering half the ground it used to.
  Once the barrage starts, it now keeps falling for 18s instead of 9s — the
  window to be caught in it is longer, by design; the window to get clear of
  it beforehand is unchanged.

### 11.7 Shake-and-bake (WP layer)

**Reuses the entire mortar pipeline.** `mission_shake_and_bake.tres` is the
mortar config with a nonzero `wp_radius`; that single field is what makes
`_finish_mission()` leave a zone behind. Same `he_profile`, same time of
flight, same round count and scatter — no second code path, no mode branch.

`WhitePhosphorusZone` owns no damage code either: the burn is one
`AreaDamageSystem.detonate()` call with a `duration > 0` profile, taking that
system's DoT path — the branch its own docstring named white phosphorus as the
intended first consumer of. The node exists for the two things that path does
not do: **be visible**, and tie the visual's lifetime to the damage's.

**The WP profile is built at runtime rather than authored as a `.tres`** —
deliberately the opposite of the HE round. Every number the burn needs is
already a tunable on the mission config, so a second resource would mean two
places to edit and would let the visible radius drift from the damaged one.

Damage shape, and why each field differs from a blast:

- **`lethal_radius == max_radius`** → flat damage inside, exactly zero
  outside. **The visible circle *is* the damage boundary.** No falloff: this
  is a denial area with a hard edge, not an explosion.
- **`blocked_damage_mult` 1.0** — cover does not protect you from standing in
  a fire. There is nothing for line of sight to block; the damage is the
  ground you are on.
- **`damages_obstacles` false** — the HE portion already did the demolition.
- **`noise_radius` 0** — the six HE impacts already pulled everything in
  earshot. A zone re-emitting noise for 45s would be a permanent lure rather
  than a denial area.

**dps is the tunable; per-tick damage is derived**, because
`AreaDamageProfile.max_damage` is an int. 25 dps at the 0.2s default tick is
exactly 5/tick; the system's old 0.5s default would have wanted 12.5 and
silently rounded. A retune that makes `dps * tick_interval` non-integral
`push_warning()`s at runtime with the dps actually delivered.

| | 100 HP player | Walker N1 (100) | Walker N15 (156) | Leaper N1 (60) |
|---|---|---|---|---|
| Time to die in the zone | 4.0s | 4.0s | 6.2s | 2.4s |

**Visibility is functional, not decorative** — an invisible damage zone is a
bug. Pulsing ground glow (same `arc_fan_points` primitive as the paint marker
and the claymore wedge) plus two particle layers: dense low smoke for the
footprint, and sparser bright embers that make the zone readable **from
outside its own radius at night**, where a ground disc alone is invisible
edge-on. Particle count scales with area.

**Zombies do not avoid it.** Nothing was added to the navmesh — they walk in
and burn, as specified.

The one-mission lock releases when **rounds** complete, not when the burn
expires; "in flight" means rounds still falling. Stacking is prevented by the
240s cooldown regardless.

### 11.8 Noted, not fixed

- With `blocked_damage_mult` 1.0 the shared system still runs its 3-ray
  exposure test per in-zone actor per tick and then lerps between 1.0 and 1.0.
  Wasted work, but optimising it means changing shared code for one consumer.
- C-wire, the ditch and minefields are untouched by fire missions — see 11.1.

## 12. Step 5 (rebuild): UAV + Supply Drop

Audited before writing anything: no `EnablerType` resource exists (confirmed
by `EnablerManager`'s own docstring), no UAV code of any kind existed, and
IFAK already existed in full (`Player.gd`, 40 HP over 4s, cancels on
sprinting/firing/weapon-switch/death — not on taking damage) — so the
originally-scoped "add IFAK" phase was skipped outright in favour of the
existing item, per instruction.

**Autoload, not a Main-instantiated node** — the one deliberate architectural
break from `FireMissionSystem`'s pattern. Every `Zombie` needs to query and
subscribe to UAV state without a reference threaded through the spawner
(spawn-time reveal, and the deactivate broadcast on sunrise), which is
exactly why `NoiseManager` is an autoload too. `UAVSystem` owns the call-in
flow, the night-based gating, and the sunrise termination; it draws nothing
itself.

**Tunables live on `UAVConfig` (`resources/uav.tres`), not as `@export` vars
on `UAVSystem` directly** — an autoload registered by script path has no
`.tscn` for its own exports to be edited from, so they would never actually
reach an inspector. `UAVSystem` preloads the resource as a `const` and reads
it, the same reason `FireMissionConfig` exists instead of exports directly on
`FireMissionSystem`. Silhouette colour is the one UAV-related tunable that
does NOT live on `UAVConfig` — it's per zombie variant, so it's an export on
`ZombieType` instead (`uav_silhouette_color`, walker default amber, leaper
red).

**Gating is night-number-based, not a timer.** `_available_reason()` blocks
on three things in order: day, currently active, or `_used_night ==
GameManager.night_number` (already called this same night). Comparing
against `night_number` directly — the same pattern
`EnablerManager.is_guaranteed_drop_night()` already used — means there's no
separate "new night" listener to keep in sync; the block clears itself the
moment `night_number` advances. No refund and no pro-rata exist anywhere in
the call path — calling late in the night is worse value than calling early
purely because nothing compensates for it.

**Termination is exclusively `GameManager.phase_changed` with `phase ==
Phase.DAY`** — there is no separate "sunrise" signal in this codebase
(`phase_changed` fires on both transitions), so the UAV listens for the
specific payload rather than "not night." No duration timer exists to race
against it.

**The radio call itself costs nothing beyond the shared mechanism.**
`_call_uav()` calls `EnablerManager.start_cooldown(UAV_ID, 0.0)` —
`seconds=0.0` deliberately skips creating a per-enabler cooldown entry (the
night-based gate already covers that) while still triggering the global 10s
lockout, reusing the exact function every other enabler calls rather than
duplicating its lockout logic. The UAV itself is silent afterward; only
`RadioMenu.commit_transmission()` at call time makes noise.

**The reveal is two independent, deliberately un-post-processed pieces:**

- **Through-wall silhouette**: a child `MeshInstance3D` capsule built once
  per zombie at spawn (`Zombie._build_uav_silhouette()`), sized identically
  to the real body capsule, `no_depth_test = true` plus `render_priority =
  100`, hidden until told otherwise. No shader, no post-process pass. It
  frees itself as a child the instant `Zombie._die()` runs `queue_free()` —
  which happens synchronously, same frame, no corpse lingers — so "drops the
  silhouette immediately" needed no extra code.
- **Offscreen edge indicators**: a new `UAVOverlay` CanvasLayer (layer 12 —
  above the HUD's 10, below the radio menu's 15), built entirely in code like
  every other UI here. Each frame, while active, it walks the `"zombies"`
  group, keeps whichever are off the visible viewport rect (an onscreen
  contact's own silhouette already covers it), sorts by 3D distance to the
  player, caps at `uav_offscreen_indicator_cap`, and draws a small triangle
  per contact clamped to the screen border — coloured from the same
  `ZombieType.uav_silhouette_color` the silhouette uses, so an indicator and
  the silhouette it becomes never disagree about what's coming.

Both zombie and overlay independently honour `uav_max_reveal_distance` (0 =
unlimited): the zombie re-checks its own distance every physics frame while
revealed (cheap — skipped entirely while not revealed), and the overlay
filters candidates by the same distance before considering them for an edge
indicator, so a capped reveal radius shrinks both halves of the picture
identically.

No new area-damage, noise, or pickup system was written for this phase —
`PointsManager.spend_points()`, `EnablerManager`'s cooldown/lockout, and
`RadioMenu.commit_transmission()` are the only substrates touched.

### Supply Drop

**`SupplyDrop.gd` — the existing pickup scene — was reworked, not replaced.**
The audit found it already served the guaranteed free drop at dawn
(`Main._spawn_supply_drop()`, nights 3/5/10), but as a single atomic
collection: one E-press granted everything it could and immediately
`queue_free()`d, silently discarding any grenade that didn't fit under the
carry cap. That directly conflicted with the requirement that overflow stay
lootable, so the collection model changed: `contents` is no longer a flat
one-shot dict but three live REMAINING fields —
`magazines_by_weapon: Dictionary` (weapon id → mags still owed, snapshotted
at creation), `grenades_remaining: int`, `ifaks_remaining: int`. Magazines
are always granted in full on the first visit (`AmmoManager.grant_ammo()` is
uncapped, so there's no partial case for them) and cleared; grenades and
IFAKs grant only what currently fits — `grant_grenades()` already reports
the exact count taken, and `add_ifak(1)` is called once per remaining IFAK
since it only reports success/failure for a single unit — and whatever
doesn't fit simply stays on the fields for a later visit. The crate frees
itself only once every field is drained to zero. `Main._spawn_supply_drop()`
was updated to the new contents shape (still 1 mag per owned weapon, 1
grenade, no IFAK — its own fixed contents, unrelated to `SupplyDropConfig`)
so both consumers share one mechanism with one contract.

**`SupplyDropSystem`** (Main-instantiated `Node`, same pattern as
`FireMissionSystem`) owns the call flow only — no pickup code, no placement
solve; both stay on `SupplyDrop.gd`. It shares the guaranteed dawn drop's own
LZ, passed into `setup()` as `_crate_position`/`drop_radius` rather than
looked up, so it stays decoupled from `Main`. Contents are snapshotted **at
call time** from `Player.owned_weapons()`, not at delivery or at pickup —
tying a drop to what you were carrying when you called it in, not to
whatever you happen to own later. Multiple drops per night are allowed
(no "already used" state, unlike the UAV) — only the independent 120s
cooldown and the shared 10s global lockout gate a re-call, both from the one
`EnablerManager.start_cooldown()` call every enabler uses.

**Cooldown starts at call-in, not delivery** — a deliberate difference from
the mortar/WP fix earlier in this document. That earlier fix mattered because
`mission_duration` is a retunable value whose length would otherwise eat into
the nominal cooldown window; here `delay` is a single fixed constant (default
20s), so starting the cooldown at call vs. at delivery only ever differs by
that same constant, never a variable amount. No stronger reason existed to
prefer one over the other, so call-in was kept as the simpler default.

**Pricing lives on `SupplyDropConfig`** (`resources/supply_drop.tres`), not
as `@export` vars directly on `SupplyDropSystem` — same reason as
`FireMissionConfig`: a code-instantiated node's own exports never reach an
inspector. `pricing_mode` is `FLAT` (a fixed `cost`) or `SCALED` (`floori(
discount_pct * contents_value)`, recomputed from the CURRENT loadout).
`FLAT`'s default of **16** is `floori(0.7 * 23)`, where 23 is the M17-only
bundle (2 mags @ 1pt + 1 grenade @ 6pt + 1 IFAK @ 15pt, all read from
`Arsenal`/`StoreCatalog` at the time this was written) — owning more weapons
only ever raises contents value, so 16 stays valid at any loadout; the
one-weapon case is the floor, not an edge case to special-case around.

**SCALED mode's displayed cost stays live with zero menu-side changes.**
`RadioMenu` reads `entry.get("cost", 0)` from the SAME `Dictionary` instance
`SupplyDropSystem` registered — Dictionaries are reference types in
GDScript, so `SupplyDropSystem._process()` rewriting `_entry["cost"]` every
frame (SCALED mode only; FLAT never changes) is exactly what the menu reads
whenever it happens to render, with nothing added to `RadioMenu` itself.

**The pricing invariant is a real runtime assertion, checked on every
call** — same spirit as `Arsenal`'s HK416-beats-M17 damage invariant:
`assert(cost < value, ...)` plus a `push_error()` fallback so the failure is
visible even where asserts are stripped (release exports). Verified
numerically at 1/2/3/4 weapons owned under both pricing modes before
shipping — FLAT's 16 stays below contents value (23/27/31/39) at every
count, and SCALED's `floor(0.7x) < x` holds by construction for any positive
contents value.
