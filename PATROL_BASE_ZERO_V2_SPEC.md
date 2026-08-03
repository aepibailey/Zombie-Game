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
