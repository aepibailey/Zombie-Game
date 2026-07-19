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
| Left click | Fire M17 (semi-auto) |
| Right click | Toggle ADS (red laser) |
| `R` | Reload |
| `Esc` | Free / recapture mouse (and close the tent) |

The HUD (top-left) shows phase + countdown, points, HP, ammo, movement state,
and whether the suppressor is fitted.

## Project structure

```
project.godot          # config + autoloads (NoiseManager, PointsManager, GameManager)
scenes/
  Main.tscn            # world bootstrap (map/nav/lighting built in code)
  Player.tscn          # CharacterBody3D + Camera3D + rays + laser dot
  Zombie.tscn          # CharacterBody3D + NavigationAgent3D
scripts/
  NoiseManager.gd      # global noise event bus: noise_emitted(pos, radius)
  PointsManager.gd     # points economy
  GameManager.gd       # day/night cycle + phase_changed signal
  Player.gd            # movement/noise states, ADS laser, M17 combat
  Zombie.gd            # Wander/Investigate/Chase/Attack state machine
  Main.gd              # builds map, bakes navmesh, spawns zombies per phase
  TentZone.gd          # Day-only shop trigger volume
  TentUI.gd            # minimal tent shop (buy suppressor)
  HUD.gd               # in-code HUD
  SuppressorResource.gd# attachment resource
resources/
  Suppressor.tres      # the suppressor attachment asset
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
   zombie; it should turn and path toward your last noise position.
3. **Unsuppressed vs suppressed shots** — fire once unsuppressed (40m): zombies
   across the map converge. After buying the suppressor (8m), a shot only alerts
   very close/already-alerted zombies.
4. **Headshots** — aim high: a headshot does 2×34 = 68 dmg (2 shots kill,
   **3 pts**); body shots do 34 (3 shots kill, **1 pt**). Watch the Points HUD.
5. **Day/night auto-transition** — the countdown flips phases automatically;
   lighting darkens at Night, zombies activate; they go dormant by Day.
6. **Buy the suppressor** — during Day, walk into the tent (green box, center-ish).
   The shop opens; buy the suppressor for 3 pts and confirm the next shot's
   noise radius drops (HUD shows `[Suppressed 8m]` and zombie reaction shrinks).
