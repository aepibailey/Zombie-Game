# Patrol Base Zero — Project Spec

## Concept
A lone Tier 1 operator holds a patrol base in the woods after everyone else is gone. Days are safe — repair, shop, upgrade at the tent. Nights bring zombies. NVGs and a weapon-mounted laser are mandatory for the dark; using either carelessly gives your position away.

## Engine & Stack
- **Godot 4.x**, GDScript
- Target: macOS (Apple Silicon), exported as signed .app
- Rendering: Forward+ (for the night lighting/NVG shader work)

---

## Core Loop: Day/Night Cycle
- **Day**: safe. The supply crate is open — spend points on weapons/attachments/ammo. No zombies spawn or move (they're wherever they ended the night, dormant).
- **Night**: zombies spawn in the woods and activate. Player must survive until dawn.
- Current playtest cadence: **30s day / 60s night** (`GameManager.DAY_LENGTH` / `NIGHT_LENGTH`). Spec default night is 6 min; shortened for iteration.

### Night scaling (implemented)
Escalation is live (formerly a v2 item). Tunables are `@export` vars on the **Main** node.
- **Spawn count per night:** `spawn_count = base_spawn + spawn_per_night * (night_number - 1)` → `base_spawn = 6`, `spawn_per_night = 3` (Night 1 = 6, Night 2 = 9, Night 3 = 12, …).
- **Concurrent cap:** never more than `max_concurrent = 20` zombies alive at once; remaining spawns queue and trickle in as others die.
- Zombies trickle in; the whole allotment never appears at once. The spawn interval **scales with pool size** so bigger nights still deliver: the pool is spread over `spawn_window_frac = 0.75` of the night, clamped to `spawn_interval_min = 0.6s` … `spawn_interval_max = 9.0s`, with `spawn_jitter = ±35%` per spawn.
- Survivors left alive at dawn carry over and are folded into the next night's total.
- A debug line prints at each night start: night number, total to spawn, cap, zombie HP, and the computed spawn interval.

### Zombie health scaling (implemented)
Zombies gain health every other night — negligible early, compounding later. Tunables are `@export` vars on **Main**.
- `zombie_hp = zombie_base_hp + hp_per_step * floor((night_number - 1) / nights_per_step)`
- Defaults: `zombie_base_hp = 100`, `hp_per_step = 8`, `nights_per_step = 2`.
- Nights 1–2 = **100**, nights 3–4 = **108**, nights 5–6 = **116**, … no cap.
- On every zombie death a debug line logs night number, that zombie's max HP, and shots-to-kill split by headshot/body — used to find the shots-to-kill breakpoints when tuning the step size.

## Movement & Noise
Noise is a radius-based broadcast — any zombie within radius of a noise event becomes **alerted to that location** (not necessarily to the player, just "something happened here") and moves to investigate.

| Action | Noise radius | Notes |
|---|---|---|
| Crouch-walk / slow-walk | 0m | Silent. Default safe movement state. |
| Standing walk | 5m | |
| Sprint | 15m | |
| Branch snap (random event) | 20m, single burst | Random chance per second while moving through woods terrain, only while standing/sprinting |
| Suppressed gunshot | 8m | |
| Unsuppressed gunshot | 40m | |

**Laser visibility (separate from noise):**
- Red laser (default, when ADS): any zombie within **10m** with line of sight instantly knows your exact position, regardless of noise state.
- IR laser (attachment, requires NVG to see): invisible to zombies. No positional giveaway.

## Zombie AI (walkers only for v1 — no runners/sprinters yet)
State machine:
1. **Wander** — idle, roams randomly. Default state.
2. **Investigate** — moves to last noise location. If nothing found within ~10s, returns to Wander.
3. **Alert/Chase** — has a confirmed player position (via laser proximity, or noise + direct line of sight). Moves straight at the player.
4. **Attack** — melee range, deals damage on contact, repeats until player dies or breaks line of sight/distance.

## Combat & Scoring
- Zombie HP: **100** baseline, scaled per night — see "Zombie health scaling" above
- Headshots deal **2x damage**
- Body-shot kill: **1 point**
- Headshot kill: **3 points** (not additive — headshot kill always awards 3 total)
- Player HP: **100**, zombie melee hit: **20 dmg** (placeholder, tune by playtest)

## Weapons (full roster — v1 ships pistol only, see Scope below)
| Weapon | Type | Mag size | Fire mode |
|---|---|---|---|
| Sig Sauer M17 | Pistol | 17 | Semi-auto |
| HK 416 | AR | 30 | Semi/Auto |
| SPAS-12 | Auto shotgun | 8 | Semi-auto |
| M249 SAW | Belt-fed | 100/200 belt | Auto |

Starting loadout: M17 + a few spare mags only, per the operator-stranded premise. No attachments by default.

## Attachments (spend points at tent)
- **Suppressor** — reduces gunshot noise radius drastically (40m → 8m); zombies within LOS won't clock the shot as a "you" event unless already alerted.
- **Foregrip** — reduces recoil.
- **IR Laser** — replaces red laser; invisible to zombies, NVG-only visibility for the player.
- (More attachments added as weapons are added — optics, extended mags, etc.)

## Economy
- Points earned from kills are the only currency. Spent directly at the tent during Day phase.
- No separate "money" layer for v1 — keep it simple.

## NVGs
- v1: always-on toggle, no battery mechanic. (Battery-limited NVGs flagged as a v2 tension mechanic.)
- Green-tint post-process shader, reduced far-clip / grain for atmosphere.

## Map (v1)
- Small woods clearing, ~60m x 60m, patrol base in the center (a few structures, sandbag cover, the tent).
- Woods perimeter dense enough to break sightlines and give zombies wander routes.
- Single entry approach for zombies is fine for the thin slice — no need for multiple lanes yet.

---

## V1 Thin-Slice Scope (what Claude Code builds first)
**In scope:**
- Player controller: walk/crouch/sprint, first-person camera, noise state per movement mode
- M17 pistol only: fire, reload, ADS with red laser, headshot damage multiplier
- One zombie type, full state machine (wander/investigate/chase/attack)
- Noise event bus (global signal zombies subscribe to)
- Day/night cycle with a timer, tent zone that opens only during day
- Points tracking + a minimal tent UI: buy suppressor for the M17 (proves the attachment pipeline end-to-end)
- One blockout map (primitives/greybox — no final art)

**Explicitly out of scope for v1:**
- HK 416, SPAS-12, M249
- Foregrip, IR laser (mechanically identical pattern to suppressor — trivial to add once suppressor pipeline works)
- Multiple zombie types, running zombies
- NVG battery mechanic
- Night escalation / difficulty scaling across multiple days
- Real art/animation — capsules and primitives are fine

## Acceptance Criteria for V1
- Can crouch-walk past a zombie at <10m without it noticing.
- Standing/sprinting near a zombie eventually triggers Investigate.
- Firing unsuppressed reliably pulls zombies from across the map; suppressed does not (unless already alerted).
- Landing a headshot kills in fewer hits than body shots and awards 3 points vs. 1.
- Day/night cycle transitions automatically; tent only usable in Day.
- Points earned in-game can be spent on a suppressor, and the suppressor visibly changes zombie behavior on the next shot.
