# Roadmap

**Last reconciled: 2026-08-22.** This document describes SHIPPED STATE —
what actually exists in the codebase, verified against source, not what a
spec once proposed. `PATROL_BASE_ZERO_V2_SPEC.md` describes design intent and
may run ahead of the code; when the two disagree, this file follows the code.

## Shipped

**Obstacles** — sandbag walls (`SandbagWall`/`SandbagPanel`, per-section HP,
repairable), C-wire (`CWireSection`, entangles, does not block frag),
minefields (`Minefield`), the ditch (revetment + navmesh mouth patch), all
placeable/repairable through the Engineers' Tent's `BuildMode`.

**Weapons and attachments** — five weapons (`Arsenal`/`WeaponData`: M17,
HK416, SPAS-12, M249 SAW, KAC M110), per-weapon suppressors and IR lasers,
HK416 foregrip, SPAS-12 breacher choke, M249 extended drum, M110 variable
zoom. Ammo (`AmmoManager`) is reserve-pool based and uncapped.

**Zombie AI** — walker and leaper variants (`ZombieType` resources), chase/
investigate/attack state machine, the leaper's ballistic leap (capped so it
can never outrun a sprint — see `PATROL_BASE_ZERO_V2_SPEC.md` "Leaper"),
per-night HP scaling, headshot multiplier.

**Grenades** — carry cap 4, `AreaDamageSystem`-driven blast (see below).

**M18A1 Claymore** — directional mine, arc-based detection and detonation,
look-and-hold recovery any time of day, carry cap 4.

**Shared area-damage substrate** (`AreaDamageSystem`, from the grenade step) —
one `detonate(origin, profile, facing, source_name)` entry point, faction-blind
by construction, real 3-ray LOS cover test, linear/quadratic/curve falloff,
optional obstacle damage, optional duration (damage-over-time). Every
explosive and every enabler burst in the game routes through this; nothing
implements its own damage math.

**Shared target-painting substrate** (`TargetPainter`) — camera raycast to a
world point, navmesh validity, live valid/invalid marker, confirm/cancel
callables. Generic: it does not know what is being called in. Consumed by
the mortar, the supply drop, and the Apache.

**Radio menu** (`RadioMenu`, `T` to open) — lists `EnablerManager
.callable_enablers`, a plain Dictionary contract
(`id`/`display_name`/`cost`/`call_fn`/`available_fn`), duck-typed in
`RadioMenu._build_row()`. `EnablerManager` itself owns only cooldowns and the
shared 10s global lockout — ownership (does the player have the radio at
all) is answered by `Player.owns_item_id()`, not by anything in
`EnablerManager`. The radio is purchased under the store's dedicated
**ENABLERS** tab (moved off WEAPONS in this pass).

**Six radio-callable enablers**, all night-phase-only, all built on the two
shared substrates above:

| Enabler | Cost | Cooldown | Notes |
|---|---|---|---|
| 120mm Mortar | 50 | 180s | Paints a point; 12 rounds scattered over 18s. |
| Shake-and-Bake (WP) | 80 | 240s | Same mission, adds a persistent burn zone. |
| UAV Overwatch | 60 | per-night | Through-wall zombie silhouettes + offscreen edge indicators; terminates on sunrise, never a timer. |
| Supply Drop | 31 (flat) | 120s | Player paints the LZ; 2 mags/owned weapon + grenade + IFAK, snapshotted at confirm; partial pickup persists, never destroys overflow. Priced deliberately BAD at 1 weapon owned and GOOD at 4 — see `PATROL_BASE_ZERO_V2_SPEC.md` §12 for the two-sided pricing assertion. |
| Apache — Patrol Box | 90 | 300s | Player paints a patrol box; aircraft holds a distant standoff orbit and autonomously engages every valid target in the box with its 30mm gun until winchester or bingo. Retaskable mid-sortie at no cost. Engagement is never gated on aircraft position — see `PATROL_BASE_ZERO_V2_SPEC.md` §13. |

Note the Supply Drop's free/guaranteed dawn-drop stopgap (nights 3/5/10) was
**removed** in this pass — the paid, painted drop is now the only way a crate
arrives. Two coexisting drop paths made the paid drop's pricing unreadable in
playtest.

## Planned

- **Fighter system** (a second, faster aircraft enabler distinct from the
  Apache) — not started.
- **Position Two map** — not started.
- **Transit night** — not started.
- **Second and third zombie variants** beyond walker/leaper — not started.
- **Art / audio pass** — every visual in the project is blockout-primitive;
  no dedicated audio work has been done beyond functional SFX hooks.
- **`EnablerType` resource** — the plain-Dictionary contract in
  `EnablerManager.callable_enablers` is still deliberately un-formalised.
  That deferral is unrelated to any of the above; it is being handled in its
  own separate pass.
