# Patrol Base Zero — V1 Thin Slice

A first-person zombie-survival prototype in **Godot 4.x (GDScript)**, targeting
macOS on Apple Silicon. This repo is the V1 thin slice defined in
[`PROJECT_SPEC.md`](PROJECT_SPEC.md) — greybox primitives only, no final art.

## Running it

1. Open the project folder in **Godot 4.3+** (Forward+ renderer).
2. Let it import (the SVG icon and scenes import on first open).
3. Press **F5** / Play. `scenes/Main.tscn` is the main scene.

> The game starts in **Day**. To spend points you need kills, which come at
> **Night** — so the natural loop is Day → Night (earn) → Day (buy) → Night (test).
> A full night is 6 min (spec default). To iterate faster, lower
> `NIGHT_LENGTH` in `scripts/GameManager.gd`.

## Controls

| Input | Action |
|---|---|
| `W A S D` | Move |
| Mouse | Look |
| `Shift` (hold) | Sprint |
| `C` | Toggle crouch (silent movement) |
| Left click | Fire (semi = click, auto = hold) — inaccurate from the hip |
| Right click | Toggle ADS (red laser) — pinpoint accurate |
| `R` | Reload |
| `1` – `4` | Switch weapon (M17 / HK416 / SPAS-12 / M249, if owned) |
| `B` | Toggle fire mode (HK416: semi ↔ auto) |
| `E` | Interact — open/close the supply crate when in range (Day only) |
| `G` | Toggle NVGs (green night-vision tint + brightness) |
| `Esc` | Free / recapture mouse (and close the crate) |
| `Y` / `N` | On the all-clear prompt: skip to Day / finish the night |
| `F3` | Debug: list audible zombies + their distance |

`E` is bound via a remappable **Input Map** action (`interact`) in Project
Settings, not hardcoded.

The HUD shows a top-center day/night clock with a **"Night N"** counter and the
live **wave count** (hostiles alive · spawned/total) beneath it, plus points,
HP, ammo, movement state, and the current weapon + fire mode + suppressor state
(top-left).

**Weapons** are data-driven (`WeaponData` defined in the `Arsenal` autoload).
You start with the M17; buy the rest at the crate and switch with `1`–`4`:

| Weapon | Type | Mag | Fire | Cost |
|---|---|---|---|---|
| Sig Sauer M17 | Pistol | 17 | Semi | starter |
| HK 416 | AR | 30 | Semi/Auto (`B`) | 15 |
| SPAS-12 | Shotgun (8 pellets) | 8 | Semi | 20 |
| M249 SAW | LMG | 100 | Auto | 30 |

Ammo, suppressor state, and reloads are tracked **per weapon**. The suppressor
fits the currently-equipped gun (per-weapon attachment).

**Ammo is scarce:** every weapon (starting or purchased) arrives with just **2
magazines — one loaded, one spare**, and ammo **never regenerates** (not at dawn,
not on death). Buy more by the magazine at the crate. All granting goes through
`AmmoManager.grant_ammo()`; the HUD's reserve count turns red at zero.

**Nights** spawn an escalating pool of zombies — `base_spawn + spawn_per_night *
(night_number - 1)` (6, 9, 12, … tunable on the Main node), capped at
`max_concurrent` alive at once — that trickle in over the night. Any zombies
left alive at dawn go dormant and **carry over**, folded into the next night's
total. Once every zombie for the night (carryover + pool) has spawned *and* been
killed, an **all-clear** prompt lets you skip straight to Day (`Y`) or ride out
the timer (`N`).

**Aiming:** there is no always-on crosshair. Hip-firing is blind and each shot
is scattered within a spread cone (`HIP_FIRE_SPREAD_RADIUS` in `Player.gd`) — a
tracer shows where it actually went. Aim down sights (right click) to get the
red laser dot and pinpoint-accurate shots.

**Feedback / juice:** first-person weapon viewmodel with recoil kick, muzzle
flash + light, camera recoil/shake, tracers, a hitmarker + impact sound when a
shot connects, a red damage vignette + screen shake + grunt when you're hit, and
a zombie hit-flash + death growl. Sound effects are small procedurally-generated
WAVs in `audio/` (loaded at runtime, so a missing one just means silence).

## Project structure

```
project.godot          # config + autoloads (NoiseManager, PointsManager, GameManager, Arsenal)
scenes/
  Main.tscn            # world bootstrap (map/nav/lighting built in code)
  Player.tscn          # CharacterBody3D + Camera3D + rays + laser dot
  Zombie.tscn          # CharacterBody3D + NavigationAgent3D
scripts/
  NoiseManager.gd      # global noise event bus: noise_emitted(pos, radius)
  PointsManager.gd     # points economy
  GameManager.gd       # day/night cycle + night counter + phase_changed
  Arsenal.gd           # weapon registry autoload (builds WeaponData defs)
  WeaponData.gd        # per-weapon data resource (mag/fire mode/damage/noise…)
  Player.gd            # movement/noise states, ADS laser, data-driven weapons
  Zombie.gd            # Wander/Investigate/Chase/Attack state machine
  Main.gd              # builds map, bakes navmesh, runs nightly waves
  SupplyCrateZone.gd   # Day-only crate trigger volume (press E in range)
  SupplyCrateUI.gd     # crate shop: buy weapons + suppressor
  HUD.gd               # in-code HUD
  SuppressorResource.gd# attachment resource
resources/
  Suppressor.tres      # the suppressor attachment asset
audio/
  gunshot.wav player_hurt.wav impact.wav zombie_death.wav  # procedural SFX
assets/audio/zombie/
  footstep_01..05.wav  # generated by tools/gen_placeholder_audio.py
tools/
  gen_placeholder_audio.py  # re-roll footstep variations (edit CONFIG)
```

## Noise model (from the spec)

| Action | Radius |
|---|---|
| Crouch-walk | 0m (silent) |
| Standing walk | 5m |
| Sprint | 15m |
| Branch snap (woods, standing/sprint) | 20m burst |
| Suppressed gunshot | 8m |
| Unsuppressed gunshot | 40m |

Red laser (ADS): any zombie within **10m + line of sight** instantly knows your
exact position.

## Testing against the Acceptance Criteria

1. **Crouch past a zombie (<10m) undetected** — at Night, press `C` and walk
   slowly past a zombie a few metres away. It should stay in Wander (no laser).
2. **Standing/sprint triggers Investigate** — walk (5m) or sprint (15m) near a
   zombie; it should turn and path to the fixed spot the noise came from, then
   give up (~10s) and return to Wander if it finds nothing there. A fresh noise
   within range retargets it to that new location.
3. **Unsuppressed vs suppressed shots** — fire once unsuppressed (40m): zombies
   across the map converge. After buying the suppressor (8m), a shot only alerts
   very close/already-alerted zombies.
4. **Headshots** — ADS (right click) for accuracy and aim high: a headshot does
   2×34 = 68 dmg (2 shots kill, **3 pts**); body shots do 34 (3 shots kill,
   **1 pt**). Watch the Points HUD. Hip-fire is intentionally too loose to land
   reliable headshots.
5. **Day/night auto-transition** — the countdown flips phases automatically;
   lighting darkens at Night, zombies activate; they go dormant by Day.
6. **Nightly wave + all-clear** — watch the wave counter as zombies trickle in.
   Kill all 5 and an "AREA CLEAR" prompt appears: press `Y` to skip to Day or
   `N` to keep playing the night out. The "Night N" counter bumps each night.
7. **Crate shop (weapons + suppressor)** — during Day, walk up to the supply
   crate (wooden box, center-ish). A "Press E to open the supply crate" prompt
   appears; press `E` to open (it won't auto-open). Buy a weapon (it equips
   automatically) and switch owned guns with `1`–`4`; fit the suppressor to the
   equipped gun for 3 pts and confirm the next shot's noise radius drops. Press
   `E` again, `Esc`, the Close button, or walk away to shut it.
8. **Fire modes** — the HK 416 toggles semi/auto with `B`; the M249 is full-auto
   (hold to fire); the SPAS-12 throws a pellet spread. Ammo is tracked per gun.
