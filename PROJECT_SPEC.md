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

## Zombie audio (implemented)
Audio is the player's primary sensor at night — a threat you can't see must still be locatable.
- **Footsteps** play from an `AudioStreamPlayer3D` parented to each zombie, so position is inherent.
- **Listener:** an explicit `AudioListener3D` parented to the player's **Head** (not the Camera3D). A camera is the implicit listener, but the explicit node keeps the listener pinned to the operator's head if a second camera is ever added, and the head carries yaw+pitch *without* the per-shot camera shake — so directionality doesn't jitter when firing.
- **Attenuation:** `ATTENUATION_INVERSE_DISTANCE` (not linear) so proximity reads sharply in the last few metres. Defaults: `footstep_max_distance = 20m`, `footstep_unit_size = 1.5`, `footstep_volume_db = 6.0` — all `@export` on Zombie, tuned by ear.
- **Cadence is derived from actual velocity**, not a fixed timer: the interval interpolates between `step_interval_wander = 0.75s` (at wander speed) and `step_interval_chase = 0.45s` (at chase speed), updated after `move_and_slide()` so it never desyncs from visible movement. A zombie moving slower than `step_min_speed = 0.15 m/s` is silent.
- **Variation:** a random sample of 5 per step, pitch varied ±`step_pitch_variance` (8%), and each zombie's step phase randomised on spawn so a converging group sounds like many creatures rather than one.
- **Placeholder assets** are generated by `tools/gen_placeholder_audio.py` into `assets/audio/zombie/` (5 variations, 120–200ms filtered noise bursts). Re-roll by editing `CONFIG` and re-running.
- **Debug:** `F3` toggles an on-screen list of every zombie within footstep range with its distance, to verify the ~20m threshold by walking toward one.

## Combat & Scoring
- Zombie HP: **100** baseline, scaled per night — see "Zombie health scaling" above
- Headshots deal **2x damage**
- Body-shot kill: **1 point**
- Headshot kill: **3 points** (not additive — headshot kill always awards 3 total)
- Player HP: **100**, zombie melee hit: **20 dmg** (placeholder, tune by playtest)

## Weapons (full roster — all four implemented)
Weapons are data-driven: `WeaponData` resources built by the `Arsenal` autoload.

| Weapon | Type | Mag size | Fire mode | Cost | Ammo cost / mag |
|---|---|---|---|---|---|
| Sig Sauer M17 | Pistol | 17 | Semi-auto | starter | 1 pt |
| HK 416 | AR | 30 | Semi/Auto | 15 pts | 2 pts |
| SPAS-12 | Auto shotgun | 8 | Semi-auto (8 pellets) | 20 pts | 2 pts |
| M249 SAW | Belt-fed | 100 | Auto | 30 pts | 4 pts |

Starting loadout: M17 only, per the operator-stranded premise. No attachments by default.

### Ammunition scarcity (implemented)
- **Every weapon starts with exactly 2 magazines total — one loaded, one spare** (`WeaponData.starting_mags = 2`). M17 = 17+17, HK416 = 30+30, SPAS-12 = 8+8, M249 = 100+100.
- Weapons bought at the crate arrive with the same 2 magazines — no more.
- **Ammo does not regenerate.** Not between nights, and not on death/respawn. What you have at dawn is what you have.
- Ammo is bought separately at the crate, **priced per magazine** (`WeaponData.ammo_cost`).
- **All ammo granting routes through the single function `AmmoManager.grant_ammo(weapon_id, magazines)`** — starting loadout, crate purchases, and any future supply drop / enabler. Nothing else writes reserve ammo. `AmmoManager` (autoload) owns reserve pools; the Player owns only the currently-loaded magazine per weapon.
- HUD shows `mag / reserve` for the equipped weapon; the reserve turns **red at 0**.

## Attachments (spend points at tent)
- **Suppressor** — reduces gunshot noise radius drastically (40m → 8m); zombies within LOS won't clock the shot as a "you" event unless already alerted.
- **Foregrip** — reduces recoil.
- **IR Laser** — replaces red laser; invisible to zombies, NVG-only visibility for the player.
- (More attachments added as weapons are added — optics, extended mags, etc.)

## Economy
- Points earned from kills are the only currency. Spent at the supply crate during Day phase.
- No separate "money" layer — keep it simple.
- The crate's purchase flow supports an optional **prerequisite item** (`WeaponData.requires`): an item can require another to be owned first. Unused by weapons today; it exists so future enablers (Radio → UAV/Apache/supply drop) need no new plumbing.

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
