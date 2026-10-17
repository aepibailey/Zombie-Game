# PBZ Run Structure & Economy

Oct 17, 2026 · @Shawn

## Decision

Patrol Base Zero is an **endless run with saves, split into positions that act as chapters**. There is no win condition. Save & Quit works during Day and writes the run's one save slot. Continue puts you back exactly where you were. When you die, you can load your last save or restart. Dying or quitting loses everything since your last save.

Position One (nights 1–8) is the lone-operator act, built on noise and light discipline. Night 9 is "Last Night Alone". At dawn you transit to Position Two, and the rescue there hands you your first 4 fighters. From night 10 you are a commander. Later positions slot in at fixed nights (night 25 is the next transit).

The ceiling is a **soft wall**, not a final night. Zombie HP grows 6% per night after night 10, while the catalogue of things to buy is finite. Once you own everything, points per kill stay flat but ammo spent per kill keeps rising. Eventually net income reaches zero, and only enabler cooldowns stand between you and the horde. That wall is tuned so weak runs die around night 15, good runs around night 30 and exceptional runs around night 50.

**Why reloads still leave a wall:** past a certain night, no number of retries gets you through, because HP outgrows a fully bought kit. Reloads change how fast you find that night, not where it is. The game-over panel counts reloads, so a run with no reloads stands apart. **Why transit at night 9:** a weak player who stalls around night 15 still plays six nights as a commander, which is the fantasy you chose.

**The last night's fantasy:** no night is scripted as the last. It is the night the perimeter folds: fighters go down one at a time, the Apache is on cooldown and the ditch is full. Then you reload your last save and try that night again, until no retry gets you through.

**Shelve list (your question #6):** shelve nothing. Choosing commander makes fighters and all five enablers the late-game spending. Cut them and runs past night 20 have nothing left to buy. The map-size problem is solved by price: the mortar, white phosphorus, UAV and Apache become affordable around the time Position Two arrives. The M110 is the one item that isn't load-bearing. Keep it, but fix its damage before tuning its price.

**Session fit:** a night plus its Day takes about 3 minutes, so a 15-minute sitting covers about 5 nights. Night 30 is about 6 sittings, and night 50 about 10. There is no autosave on purpose: how often you save is your own risk call.

## Escalation, night types and Day

Escalation has no cap. Four knobs climb, nights 1–10 keep their current formulas, and every fifth night has its own shape.

| Knob | Nights 1–10 | After night 10 |
| --- | --- | --- |
| Pool | 6 + 3×(n−1), unchanged | Same formula |
| Zombie HP | 100 + 8×floor((n−1)/2), unchanged | 132 × 1.06^(n−10), rounded |
| Leaper share | 0% on nights 1–3, 10% on night 4, +5% a night, 30% cap (unchanged) | 30% |
| Max alive | 20 | +2 every 5 nights from night 10, ceiling 32 |

Around night 15 the pool outgrows what can spawn in 120s. From then on, max alive is the real density lever and carryover is the death spiral. The ceiling of 32 depends on frame rate (see Open questions).

**How the nights should feel:**

- **Night 1:** a quiet hunt. Six walkers, an M17 and a crouch key. You learn the dot and the noise.
- **Night 15:** you're juggling a perimeter. 22 alive, 6–8 fighters, one enabler call a night.
- **Night 30:** every night is a siege. Carryover keeps the cap full, and enabler calls are planned around their cooldowns.
- **Night 40 and later:** attrition. Ammo per kill eats your income, and you spend down your bank.

**Special nights** override existing tunables only. None of them needs a new system.

| Type | What it tests | Overrides | Nights |
| --- | --- | --- | --- |
| Swarm | Light discipline against leapers (18m sight) | Leaper share 70%, HP ×0.8 | 5, 15 |
| Siege | Obstacles and fighter placement | Pool ×1.5, max alive +8, spawn arc 120° on a random bearing | 20 |
| Hunters | Patience: few, tough, quiet | Pool ×0.5, HP ×2.0, max alive 8, points ×2 | 10 (arrival at Position Two) |
| Transit | Displacement (planned, not built) | Runs as Siege until built | 9 ("Last Night Alone"), 25 |

From night 30, every fifth night cycles Hunters → Swarm → Siege (30, 35, 40, 45, 50 …).

**Day (your question #4):** keep the 30s timer. The build and roster menus already pause the clock, so Day is untimed planning plus 30s of free movement for placing and recovering claymores. Add one input, **Ready**, which ends Day early. Don't add Day pressure: Night carries the tension, and Day pressure would need new systems. Day is also the only time you can save.

## Night-by-night table

The target: **a competent player owns a suppressed HK 416 by Day 3, arrives at Position Two with about 70 points banked, runs 6 suppressed fighters by night 15 and owns the whole catalogue by night 30.**

| Night | Type | Pool | Walker HP | Leapers | Max alive | Points earned (est.) | Total earned | Should own by the next Day |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Normal | 6 | 100 | 0% | 20 | 10 | 10 | Bank it (or an IR laser on the M17) |
| 2 | Normal | 9 | 100 | 0% | 20 | 15 | 25 | HK 416 |
| 3 | Normal | 12 | 108 | 0% | 20 | 20 | 45 | Suppressor on the 416 |
| 4 | Normal | 15 | 108 | 10% | 20 | 28 | 73 | IR laser on the 416, radio |
| 5 | Swarm | 18 | 93 | 70% | 20 | 43 | 116 | C-wire, or sandbags plus 2 claymores |
| 6 | Normal | 21 | 116 | 20% | 20 | 44 | 160 | IFAK, 2 grenades, sandbags |
| 7 | Normal | 24 | 124 | 25% | 20 | 53 | 213 | SPAS-12, 2 more claymores |
| 8 | Normal | 27 | 124 | 30% | 20 | 62 | 275 | Second C-wire, or a first mortar call for night 9 |
| 9 | Transit (Siege for now) | 45 | 132 | 30% | 28 | 83 | 358 | 4 free fighters arrive; suppress all 4 |
| 10 | Hunters | 17 | 264 | 30% | 8 | 78 | 436 | Fighter 5, suppressed; 2 tier-1 upgrades |
| 12 | Normal | 39 | 148 | 30% | 20 | 90 | 609 | M249 plus belts, a ditch |
| 15 | Swarm | 48 | 142 | 70% | 22 | 118 | \~930 | 6 fighters, all suppressed; 2–3 kitted weapons; a C-wire and ditch belt; one enabler call a night |
| 20 | Siege | 95 | 236 | 30% | 32 | \~160 | \~1,600 | 8 fighters, mostly tier 2; a minefield; the Apache on Siege nights |
| 25 | Transit (Siege for now) | 117 | 316 | 30% | 32 (cap) | \~170 | \~2,400 | About 75% of the catalogue; first tier-3 fighters |
| 30 | Hunters | 47 | 846 | 30% | 8 | \~185 | \~3,200 | The whole catalogue (about 2,300 points of one-time buys) |
| 40 | Siege | 185 | 758 | 30% | 32 (cap) | \~150 | \~4,900 | Everything; ammo is 50–70% of spending |
| 50 | Swarm | 153 | 1,086 | 70% | 32 | \~120 | \~6,500 | Everything; net income near zero, so the run lives on cooldowns |

These estimates assume 35% headshots, which makes a walker kill worth about 1.7 points and a leaper kill about 3.7. They also assume the whole pool dies through night 15, except 80% on Swarm and Siege nights. Ammo and consumables are assumed to take about 25% of income early and 40–60% late. Walker HP includes the special-night HP multiplier. Leapers keep their 60 base HP and get the same scaling, which Phase 0 should verify.

## New price list

Most of the feel-based prices already fit the curve, so only 7 change. The big changes are timing: when fighters arrive, how suppressors are priced, and the per-round cost of the M249. This list is a baseline to measure against, not a final balance. Enabler prices are assumed to be **per call** (as the supply drop is), not one-time unlocks. Phase 0 must confirm this.

| Item | Old | New | Why |
| --- | --- | --- | --- |
| HK 416 | 15 | 15 | Affordable on Day 2, which is the target |
| SPAS-12 | 20 | 20 | Arrives around Day 7 as the close-defence role |
| M249 | 30 | **40** | Most of its cost is ammo now. It arrives around night 11, in the commander act |
| M110 | 45 | 45 | Can't be priced until it out-damages the 416 (see code changes) |
| M249 belt (100 rounds) | 4 | **8** | At 4 it costs 0.04 a round, the cheapest gun to feed, so it would become the default. 0.08 puts it near the 416 (0.067) |
| Other mags (M17 1, 416 2, SPAS 2, M110 3) | — | Unchanged | Ammo is the endless sink and rising HP already makes it bite |
| Suppressor | 2× weapon price | **1× weapon price, minimum 12** | Noise discipline is the core verb. Paying double tax on every weapon punishes switching. New prices: M17 12, 416 15, SPAS 20, M249 40, M110 45 |
| IR laser | 8 per weapon | 8 | Cheap on purpose: the red dot is the trap, and the IR laser is the lesson |
| Foregrip, breacher choke | 12 | 12 | Fine as mid-game options |
| Extended drum, variable zoom | 25 | 25 | Low value on the 60×60 map, and nothing is lost by leaving them. Re-check at Position Two |
| Grenade, claymore, IFAK | 6 / 10 / 15 | Unchanged | Consumables are a healthy sink. Claymore day kills already make claymores pay for themselves |
| Sandbags, C-wire, ditch, minefield | 10 / 40 / 60 / 70 | Unchanged | Raised once already after playtest. They land on schedule (C-wire night 5, ditch night 12, minefield night 20) |
| Radio | 10 | 10 | The gate, not the cost |
| Supply drop | 31 | 31 | The flat-price design works: it gets better as you own more weapons |
| UAV | 60 per night | **40** | 60 is a whole night's income on night 8, for information that's weak on a small map. 40 makes it a staple at Position Two |
| Mortar, white phosphorus | 50 / 80 | Unchanged | First affordable around nights 8–12, matching the commander act |
| Apache | 90 | **120** | Its sortie covers nearly a whole night. At 90 it's trivial by night 20. 120 keeps it a Siege-night decision until about night 25. The 300s cooldown stays |
| Free fighters | 4 from night 1 | **4 granted at the Day after night 9** | This is the Position Two rescue. Position One stays a lone-operator act |
| Recruits 5–8 | 20 / 35 / 55 / 80 | Unchanged | They land on nights 10–20 |
| Fighter upgrades | 15 / 20 / 30 | Unchanged | Keeps the invariant: the full upgrade path (65) costs less than the top recruit (80) |
| Fighter suppressor | 25 | **15** | Matches a rifle suppressor. At 25 × 8 = 200 it's a tax, not a choice |

**Flags:**

- **Unaffordable early, on purpose:** the Apache, white phosphorus and UAV before Position Two. Price keeps big fire support off the 60×60 map without any locking system.
- **Trivially affordable late, on purpose:** every one-time buy by night 30. The endless sinks are ammo, consumables, enabler calls and replacing fighters.
- **At risk:** if fighters don't draw on the player's ammo, late-game sinks may be too thin. Watch the bank (see Open questions).

## Code change list

These are five separate prompts, each testable on its own, in this order. Every new number is an exported tunable. The live code wins on any conflict.

**Phase 0 audit (shared by all five; report only, no code):**

1. Where do pool, HP, leaper share, max alive and the spawn interval live?
2. Does unspawned pool carry over, or only living survivors?
3. Are enabler prices charged per call or once?
4. Do fighters consume the player's ammo or points?
5. Does leaper HP scale with the same formula as walker HP?
6. Is there a title or menu scene a Continue button could go on?

### Prompt A: run structure and escalation (Sonnet; escalate to Opus if night and spawn logic is spread across 3 or more scripts)

1. **HP curve.** In `GameManager`, add `hp_linear_until_night = 10` and `hp_growth_per_night = 1.06`. HP(n) uses the current linear formula for n ≤ 10. Above that, HP(n) = round(linear(10) × 1.06^(n−10)).
2. **Max alive.** Add `max_alive_base = 20`, `max_alive_step = 2`, `max_alive_step_every = 5`, `max_alive_step_start_night = 10` and `max_alive_ceiling = 32`. The ceiling applies after night-type bonuses.
3. **Night types.** Add a `NightTypeProfile` Resource, modelled on `ZombieType`. Its fields are `pool_mult`, `hp_mult`, `leaper_share_override` (−1 = none), `max_alive_bonus`, `max_alive_override` (−1 = none), `spawn_arc_deg` (360 = full ring) and `points_mult`. Create .tres files for Normal, Swarm, Siege and Hunters, with values from the Escalation section.
4. **Night schedule.** In `GameManager`, add `special_nights = {5: SWARM, 9: TRANSIT, 10: HUNTERS, 15: SWARM, 20: SIEGE, 25: TRANSIT}`. Also add `special_cycle_start = 30`, `special_cycle_every = 5` and `special_cycle = [HUNTERS, SWARM, SIEGE]`. Add `get_night_profile(n)`. TRANSIT resolves to `transit_standin_profile`, which is Siege. Pass the type name with the night-start signal so the HUD can show it.
5. **Spawn arc.** When `spawn_arc_deg` < 360, the spawner picks one random bearing per night. It spawns within ±arc/2 of that bearing on the existing 21–29m ring.
6. **Points multiplier.** In `PointsManager`, multiply each kill award by the night's `points_mult`, then round. Day kills by claymores and minefields use 1.0.
7. **Positions.** Add `position_transit_nights = [9, 25]`, `current_position = 1`, and a signal `position_changed(new_position)` emitted at the dawn after a transit night. No map changes yet, so log it and stop there.
8. **Fighter gate.** Add `fighters_unlock_position = 2` and `free_fighter_count = 4`. Before then, the roster menu is locked and reads "Rescue at Position Two". On `position_changed(2)`, grant the 4 free fighters. Prices for recruits 5–8 are unchanged.
9. **Ready input.** Add a `ready` action that ends Day early (`day_skip_enabled = true`), using `is_action_just_pressed`. The Day length stays 30s.
10. **Rank on game over.** Add `rank_thresholds` to the game-over panel: under 15 is "Overrun", 15 "Held the Line", 30 "Veteran", 50 "Legend". The panel shows "Night N · R reloads", and a run with 0 reloads gets an "Ironman" tag. Its buttons are Load Last Save (when a save exists) and Restart. Add no win condition and no run length.

### Prompt B: re-price (Sonnet)

1. Make every price in the price list an exported var if it isn't one already.
2. The suppressor price becomes a formula: max(weapon price, `suppressor_min_price = 12`). Delete the 2× rule outright; don't leave it as dead code.
3. Set M249 to 40, the M249 belt to 8, the UAV to 40, the Apache to 120 and the fighter suppressor to 15.
4. Keep the existing assertion that the full upgrade path costs less than the top recruit.

### Prompt C: per-night log (Sonnet; run before the first playtest)

1. Write `user://runs/<run_id>.csv` with one row per night.
2. Columns: night, type, position, pool, carryover in and out, kills by zombie type and by head or body, points earned, and points spent by category (ammo, weapons, attachments, equipment, defences, enablers, fighters).
3. More columns: bank at dawn, highest alive count reached, player HP lost, IFAKs used, fighters lost, reloads used so far, minimum and average FPS.

### Prompt D: save system (Opus)

1. Save & Quit is available only during Day. Each run has one slot. Continue resumes it. On death, the panel offers Load Last Save or Restart, and Restart deletes the slot. Before a load that follows a death, increment \`reloads\_used\` in the save file so the count survives the rollback. Quitting without saving loses everything since the last save.
2. Save everything a run needs: night, position, points, weapons with their attachments and ammo, equipment counts, placed claymores and obstacles (type, transform, state), and fighters (rolled stats, tier, suppressor, placement). Also save enabler cooldowns, carryover count and the RNG seed.
3. Acceptance test: save, load, save again, and the two files must be identical.
4. Out of scope: multiple slots, cloud saves and autosave. Leaving out autosave is deliberate: when to save is the player's risk call.

### Prompt E: M110 role fix (Sonnet)

1. Set M110 body damage to 120, so a 240 headshot one-shots walkers through night 20 (236 HP).
2. Keep its 3-zombie penetration.
3. Assert that M110 per-shot damage is greater than the 416's.

## Open questions

Every number above is a hypothesis until the per-night log (Prompt C) shows otherwise. Play three runs, then check each row. In the last column, the tunable to change is named first.

| Question | Measure | Target | If it misses |
| --- | --- | --- | --- |
| Is the early curve right? | Points earned per night, nights 1–10 | Within ±25% of the table | Too low: drop the 416 to 12. Too high: raise `suppressor_min_price` |
| When does carryover start compounding? | First night where kills fall below 80% of pool plus carryover | Nights 18–22 for a competent player | Too early: lower `max_alive_step`. Too late: raise it |
| Is the wall in the right place? | The night of each reload, and the night where reloads stop helping | Around 15 when you play sloppily, around 30 at your best | Move `hp_growth_per_night` in 0.01 steps (1.05 to 1.07) |
| Is ammo the right sink? | Ammo's share of points spent | 30% or less through night 15, 40–60% by night 30 | Over 70% before night 25: lower HP growth before touching points per kill |
| Are late sinks deep enough? | Bank at dawn | Under 2 nights' income from night 20 | Bank piles up: raise enabler call prices. A fighter upkeep cost would be a new system, so last resort |
| How high can max alive go? | Minimum FPS at 26–32 alive with 8 fighters and the Apache up | 60 FPS or better on your Mac | Lower `max_alive_ceiling` |
| Is the fighter suppressor a real choice? | Share of fighters suppressed by night 15 | 50–90% | At 100% the beacon penalty forces it. Under 50%, beacons don't matter or 15 is too much |
| Do Siege nights play differently? | Share of kills by obstacles and claymores, Siege versus Normal nights | At least 2× on Siege | Narrow the Siege `spawn_arc_deg` to 90 |
| Does one weapon dominate? | Kill share by weapon at night 20 | No weapon over 60% | M249 on top: raise the belt price |
