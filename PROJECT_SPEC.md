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
- Current playtest cadence: **30s day / 120s night** (`GameManager.DAY_LENGTH` / `NIGHT_LENGTH`). Spec default night is 6 min. Night length is the most-tuned value, so it's an editable var rather than a const.

### Night scaling (implemented)
Escalation is live (formerly a v2 item). Tunables are `@export` vars on the **Main** node.
- **Spawn count per night:** `spawn_count = base_spawn + spawn_per_night * (night_number - 1)` → `base_spawn = 6`, `spawn_per_night = 3` (Night 1 = 6, Night 2 = 9, Night 3 = 12, …).
- **Concurrent cap:** never more than `max_concurrent = 20` zombies alive at once; remaining spawns queue and trickle in as others die.
- Zombies trickle in; the whole allotment never appears at once. The spawn interval is **derived from night length and pool size**, never hardcoded: the pool is spread over `spawn_window_frac = 0.75` of the night, clamped to `spawn_interval_min = 0.6s` … `spawn_interval_max = 20.0s`, with `spawn_jitter = ±35%` per spawn. At 120s nights that gives a 90s spawn window and a 30s tail for cleanup: **Night 1 = 15.0s, Night 3 = 7.5s, Night 5 = 5.0s, Night 10 = 2.7s**.

### All-clear (implemented)
- **`Main.alive_count()` is the single source of truth** — derived by walking the zombie roster each call, never a running counter. Both the HUD readout and the all-clear condition read it, so they cannot disagree.
- It uses `Zombie.is_alive()` (a `_dead` flag) rather than `is_instance_valid()`, because `queue_free()` is deferred and a corpse stays valid for the rest of the frame.
- The prompt requires **both**: the spawn queue exhausted **and** alive count exactly zero. Zombies in any state count as alive.
- **Safety re-check** every frame: if the prompt is showing while anything is alive, it's retracted automatically — a future regression becomes a flicker, not a game-breaking prompt.
- Every all-clear evaluation prints queue remaining, alive count, and each live zombie's state.
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
| Jump landing | 12m | `jump_noise_radius` |
| Mantle completion | 10m | `mantle_noise_radius` |

### Jump & mantle (implemented)
- **Jump:** `Space`, height **0.9m** (`jump_height`). Blocked while crouched or mid-mantle.
- **Mantle:** `Space` is a single contextual button — with **forward held** and a mantleable ledge in front it mantles, otherwise it jumps. Chosen over a dedicated key (one more thing to remember mid-fight) and over auto-mantle-on-collision (fires accidentally whenever you jump beside cover).
- **Detection** is a three-stage probe: forward ray at chest height (1.0m) to find a roughly vertical face → downward ray past its top edge to find a standable ledge → capsule sweep confirming the player fits at the destination.
- **Max height 2.0m** (`mantle_max_height`), minimum 0.35m. (Originally sized to match the ditch's depth so mantling was the way out of it; the ditch is now a real 3m pit exited via a built-in ramp instead — see "Zombie ditch" — so this value now stands on its own, for sandbags and other ledges.)
- **Duration scales with height:** ~0.4s at 1m, ~0.9s at 2m. A locked interpolation — no gravity, no steering, and firing/ADS are blocked throughout.
- **Zombies cannot jump or mantle.** They have no such capability and none was added.

**Laser visibility (a separate sensory channel — NOT noise):**

> **This REPLACES the original rule.** The old behaviour — "any zombie within 10m of the *player* with line of sight instantly knows your exact position" — is gone entirely, not extended. The zombie notices *the dot*, not the operator.

- **Red laser (default, when ADS):** the laser's impact point is the dot. **Any zombie within `LASER_DETECT_RADIUS` = 15m of the dot that has line of sight to the dot** becomes alerted. **Distance from the player is irrelevant** — a zombie 200m away is alerted if you put the dot within 15m of it.
- On alert the zombie enters **Investigate targeting the dot's world position**. It is curious about the light and has no idea where you are. If it acquires line of sight to the player during that investigation it transitions to **Chase** by the normal rules (`LASER_INVESTIGATE_SIGHT` = 16m).
- **IR laser:** never triggers any of this, at any range. That is its entire point.
- **Completely separate from the noise system.** It is not routed through `NoiseManager` and generates no noise event.
- Evaluated on a **0.25s timer** (`LASER_DETECT_INTERVAL`), not per frame.
- **Debounced per zombie:** one alert per zombie per continuous dwell. A zombie re-arms only once the dot has moved **`LASER_REARM_DISTANCE` = 5m** from where it alerted that zombie, or once the laser has been off/IR for **`LASER_OFF_REARM_TIME` = 3s**, which clears every mark. Holding the dot still never re-alerts.
- All five constants live at the top of `scripts/Player.gd` under "Red laser detection"; `LASER_INVESTIGATE_SIGHT` lives in `scripts/Zombie.gd`.
- **Scoping note:** the player-sighting check is deliberately limited to *laser* investigations. Noise investigation still never looks for the player — that is what makes crouch-past-undetected work, and re-adding it globally would reintroduce the old "investigate silently becomes a homing chase" bug.

## Zombie AI (walkers only for v1 — no runners/sprinters yet)
State machine:
1. **Wander** — idle, roams randomly. Default state.
2. **Investigate** — moves to last noise location. If nothing found within ~10s, returns to Wander.
3. **Alert/Chase** — has a confirmed player position (spotted during a laser investigation, or being shot). Moves straight at the player.
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

## Weapons (full roster — all five implemented)
Weapons are data-driven: `WeaponData` resources built by the `Arsenal` autoload.

| Weapon | Type | Mag size | Fire mode | Cost | Ammo cost / mag |
|---|---|---|---|---|---|
| Sig Sauer M17 | Pistol | 17 | Semi-auto | starter | 1 pt |
| HK 416 | AR | 30 | Semi/Auto | 15 pts | 2 pts |
| SPAS-12 | Auto shotgun | 8 | Semi-auto (9 pellets) | 20 pts | 2 pts |
| M249 SAW | Belt-fed | 100 | Auto | 30 pts | 4 pts |
| KAC M110 | DMR | 20 | Semi-auto only | 45 pts | 3 pts |

### KAC M110 — dedicated long-range weapon (implemented)
The map is close-range and NVG-lit, so a red-dot optic never made sense. The M110 fills the gap deliberately left open: a semi-auto-only DMR with a **built-in fixed 3x scope**, precision handling, and no falloff — the answer for the far edge of the 60×60m map (≈85m diagonal), where the shotgun is useless and even the 416 loses 15%.

- **No auto mode exists for it at all** — `fire_mode = SEMI`, `auto_penalty = NONE` (the default). None of the bloom/ramp systems can touch it; `B` (fire-mode toggle) is a no-op, same as any other semi-only weapon.
- **20-round mag, 2 starting mags (1 loaded + 1 spare) = 40 rounds total**, same rule as every other weapon.
- **Damage: 60 per body shot.** Two body shots (120) kill a 100 HP baseline zombie with a 20 HP margin; a headshot (60 × 2 = 120) is a clean one-shot. That's double the 416's 30 — meaningfully above it, which is the entire point of the weapon. Unchanged since the first pass.
  - **Two-body-shot kill holds through night 6** (116 HP). It **stops being guaranteed at night 7** (124 HP > 120) — reported per the same convention as the SPAS one-shot threshold, not rebalanced around.
- **Cycle time 0.24s → 4.17 rounds/sec, 37.5% of the 416's 11.11 rps.** Cut down from the first pass's 0.16s/56% — that read as no real rate-of-fire tradeoff, so this was slowed further to land in the 35–40% target band.
- **Moving-fire cone: 2.5° added while moving** (`moving_cone_extra_deg`), well above the 416's 1.0° — **2.35× the 416's total moving cone** (2.58° vs 1.1°). This is the "fired from a stable stance" side of the tradeoff: standing/crouched accuracy (`ads_cone_deg = 0.08°`, tighter than the 416's 0.1°) is completely unaffected — the penalty only exists while `is_moving` is true.
- **Time-to-kill vs. the 416, both landing every shot from a stationary position:**

  | | Shots to kill (body) | Cycle | TTK | DPS |
  |---|---|---|---|---|
  | HK 416 | 4 (4×30=120) | 0.09s | **0.27s** | 333/s |
  | KAC M110 | 2 (2×60=120) | 0.24s | **0.24s** | 250/s |

  DPS comes out as intended — the M110 is lower (250 vs 333/s), the rate-of-fire cost is real. **TTK does not**: the M110 is marginally *faster* in raw kill-time (0.24s vs 0.27s), not slower, because needing only 2 shots instead of 4 means one fewer "wasted" cycle-time gap even though each gap is longer. Closing this would need a cycle time of ≥0.27s (≈33% of the 416's rate), which falls *outside* the requested 35–40% band — so the two instructions are in tension at exactly 2-vs-4 shots-to-kill, and 0.24s (the middle of the requested band) was kept as specified rather than overridden. Headshots make the M110's advantage explicit rather than incidental: **1 headshot (0s) vs. 2 (0.09s)** for the 416.
- **No laser of any kind.** ADS shows a **scope reticle** (a simple crosshair, HUD-only, `HUD._build_reticle()`) instead of the laser dot/beam every other weapon draws. Not just visually hidden — `Player._update_laser()` and `_update_laser_detection()` both return immediately for `current_weapon_id == "m110"`, before any raycast or zombie-alert work runs, so no zombie can ever be alerted by aiming an M110 regardless of range or angle. Consequently the M110 **never appears in the crate's laser-purchase list** (neither red — which was never purchasable for anyone — nor IR).
- **No damage falloff at all** (`falloff_near` left at the WeaponData default of effectively-unreachable) — stronger than the 416's "minimal" ≤15% loss at 85m; this is the weapon that's supposed to work at the far end of the map with zero penalty.
- **Recoil is cosmetic, not accuracy-affecting**: `recoil_per_shot 0.06` / `horizontal_recoil 0.02` (more pronounced than the 416's 0.025 / 0.014, reflecting the bigger cartridge) drive camera kick only — the firing cone is `ads_cone_deg + bloom + moving_cone_extra_deg`, and bloom never applies without an auto_penalty, so recoil cannot degrade follow-up-shot accuracy the way it does on the 416/SAW. Waiting for the sight picture costs nothing mechanically.
- **Built-in scope: fixed 3x**, implemented as a per-weapon ADS field-of-view override (`ads_fov = 28.7°`, derived from `2·atan(tan(37.5°)/3)` against the player's 75° hip FOV). Being a pure FOV change with no separate reticle render pass, it renders correctly under the NVG shader by construction — there's nothing for the shader to conflict with.
- **Attachments (both new, M110-only):**
  - **Suppressor — 90 pts** (2× weapon cost, see the pricing rule below). Same noise-radius mechanic as every other weapon: 48m → 11m.
  - **Variable Zoom Optic — 25 pts.** Replaces the fixed 3x with a **binary 2x/8x scope**, not a continuous dial — fixed at playtest's request after the original continuous 2x–8x version read as sloppy. `Player._scope_far` is a bool, not a float, and no `clampf()` or interpolated in-between value exists anywhere in the path; the FOVs are two stored constants (`SCOPE_FOV_NEAR = 41.98°`, `SCOPE_FOV_FAR = 10.96°`). **Scroll wheel while ADS, either direction, flips to the other position** (unclaimed elsewhere in first-person) — there's no "in-between" to scroll past. A **0.08s tween** (`SCOPE_TWEEN_TIME`) carries the camera FOV across so the cut doesn't jar the eye, but it always lands exactly on one of the two values; a fresh toggle kills any tween still in flight rather than stacking. Entering/exiting ADS itself is an instant snap, not tweened — only the in-ADS toggle animates. **Exiting ADS keeps the last scope position** (`_scope_far` isn't touched by `_toggle_ads()`), so re-entering ADS on the M110 resumes wherever the scope was left. A `Scope: 2x`/`Scope: 8x` message confirms each toggle. Damage, accuracy and fire rate are untouched — purely a targeting-convenience upgrade for the far edge of the map vs. closer engagements.
- `hip_spread_radius = 70` (worse than the 416's 55 — this weapon wants to be aimed, not hip-fired) and `noise_unsuppressed/suppressed = 48/11` (between the 416 and SPAS) are both judgment calls, not specified in the brief; flagged for playtest sanity-check.

### Weapon-switch ADS reset (implemented)
Switching weapons while ADS'd used to leave the outgoing weapon's zoom/FOV active on the new one. Fixed at the single choke point every switch passes through (`Player._equip()`): if `ads_active` is true when a switch starts, it's forced false and `camera.fov` is reset to the hip default before the new weapon is assigned. Verified against all five weapons, not just the M110 where it was noticed. The M110's own scope position (`_scope_far`, if the Variable Zoom Optic is owned) is deliberately **not** reset by this — swapping away and back to the M110 keeps its scope at whichever of the two positions it was left on, the same way a real scope doesn't rezero itself when you sling the rifle.

### Damage falloff (implemented)
Piecewise-linear over distance from the muzzle: full damage to `falloff_near`, then linear to `falloff_mid_mult` at `falloff_mid`, then to `falloff_far_mult` at `falloff_far`, flat beyond. Every hit logs its distance and multiplier.

| Weapon | Full to | → mult @ range | → mult @ range |
|---|---|---|---|
| M17 | 25m | 0.70 @ 60m | 0.50 @ 100m |
| HK 416 | 30m | 0.85 @ 85m | 0.85 @ 120m |
| SPAS-12 | 10m | 0.40 @ 20m | 0.15 @ 30m |
| M249 | 30m | 0.80 @ 85m | 0.80 @ 120m |
| KAC M110 | — | 1.00 (always) | 1.00 (always) |

### SPAS-12 close-range lethality (implemented)
**9 pellets × 22 dmg** (198 at point blank), **3°** cone, each pellet raycast independently with the headshot multiplier applied per pellet.
- **≤7m:** pattern ~0.7m across; 5+ pellets on a torso = 110+ dmg → **one-shot** a 100 HP zombie. At night 10 (132 HP) six pellets = 132 → still one-shot with margin.
- **~12m:** falloff ×0.88, wider pattern → reliable **two-shot**.
- **20m:** ×0.40 and a ~2m pattern → clearly a bad choice. **30m+:** ×0.15, useless.
- Max range 40m; the proportional per-shell reload is unchanged.
- Pattern diameter is `2 × range × tan(pellet_spread_deg)` — this is the same approximation the numbers above were derived from (7m → 0.734m ≈ "~0.7m", 20m → 2.096m ≈ "~2m").

### SPAS-12 Breacher Choke (implemented, 12 pts)
Widens the **hip-fire-only** pellet spread from 3.0° to 3.75° (+25%); ADS keeps the baseline 3.0° untouched (`_fire()` only applies the multiplier when `not ads_active`). Pellet count, per-pellet damage and the falloff curve are all unchanged — only the cone widens.
- Using the same pattern-diameter approximation: the choked pattern hits the baseline's "~0.7m at 7m" reliable-one-shot size at **~5.6m instead of 7m** — the one-shot-kill range genuinely shrinks, not just the label.
- At every range beyond that the choked pattern stays wider than baseline (e.g. 20m: 2.62m vs 2.10m), so it is **not** a strict upgrade at any distance — a real tradeoff, not a stealth buff, as required.
- The tradeoff is a real geometric effect, not narrative flavour: every pellet is an independent raycast against the zombie's 0.8m-diameter body capsule, so a wider cone genuinely sends more pellets wide of the target at a given range.

### Long-range viability (implemented)
Weapon max ray distance was **not** the problem — M17 150m, HK 416 200m, SPAS 40m, M249 220m, all beyond the ~85m map diagonal.
- **HK 416 semi-auto:** `ads_cone_deg = 0.1°` — effectively a laser at map scale — with only 15% damage loss at 85m. Full-auto penalties are unchanged, keeping semi the sharp long-range answer.
- **M249:** bloom tightened to `bloom_min_deg 0.08` / `bloom_max_deg 0.8` so a **crouched** (1.1×) 3–5 round burst holds ~0.5m at 60m (torso-sized), while **moving** (3.0×) scatters to ~1.4m. The moving penalty is deliberately unchanged.

Starting loadout: M17 only, per the operator-stranded premise. No attachments by default.

### Weapon handling (implemented)
**Full-auto penalty** (`WeaponData.auto_penalty`). Semi-auto is unaffected and stays the precise choice at range.
- **HK 416 — `RAMP`:** vertical recoil starts at **1.4x** the semi value and climbs **12% per consecutive shot**, capping at **3.5x**. Horizontal recoil is random left/right per shot on the same curve, so the muzzle *walks* unpredictably rather than straight up. Cone bloom runs **0.3° → 4.0° over 10 consecutive shots**. The accumulator resets after **0.4s** without firing (`auto_reset_time`).
- **M249 SAW — `STANCE`:** same recoil/bloom system, but the multiplier is driven by stance and re-evaluated **per shot in real time**: moving **3.0x**, standing still **1.5x**, crouched **1.1x** (`stance_mult_moving` / `_standing` / `_crouched`, `@export` on Player). Starting to move mid-burst degrades control immediately.
- Bloom applies in ADS too — that *is* the penalty.

**HK 416 — moving-fire cone (implemented).** A new mechanic, added for the Foregrip: no per-weapon "moving" accuracy penalty existed anywhere before this pass (the M249's STANCE system is a full-auto-only bloom/recoil ramp, not a general cone). `WeaponData.moving_cone_extra_deg` adds a flat cone contribution whenever `is_moving` is true, hip or ADS, on top of `ads_cone_deg + bloom_deg`, and is fully independent of the RAMP recoil-climb system.
- 416 baseline: **1.0°** while moving (unowned baseline, invented for this pass — not a measured prior value). Stationary/crouched cone is unaffected: **0.1°** either way.
- **Foregrip (12 pts):** cuts the moving-only 1.0° component by **40%** to **0.6°**. Total moving cone: **1.1° → 0.7°** (a 36% reduction overall, since the 0.1° mechanical baseline is untouched). No effect on stationary/crouched accuracy, no effect on the RAMP recoil climb.

**M249 SAW — Extended Drum (implemented, 25 pts).** Belt capacity 100 → 200 rounds (`Player.effective_mag_size()`), replacing the standard belt rather than stacking. **-10% sprint speed (7.5 → 6.75 m/s) whenever the drum is fitted** — carried-gear weight, not a firing-state effect, so it applies regardless of which weapon is currently equipped or whether the SAW is being fired.
- **Ammo purchases scale with it.** Previously: 4 pts → +1 magazine (100 rounds), always, via `AmmoManager.grant_ammo(id, 1)`. With the drum fitted, a purchase becomes **8 pts → +1 full drum (200 rounds)** — same per-round price (0.04 pts/round) — via `AmmoManager.grant_ammo(id, 2)`. Still the single ammo-granting path; `Player.ammo_purchase_magazines()`/`ammo_purchase_cost()` only decide how many magazines that one call is worth.
- No change to fire rate, recoil, or accuracy.

**SPAS-12 — per-shell reload** (`shell_reload`): `reload_start` 0.35s + **0.55s per shell** + `reload_end` 0.35s. Two shells ≈ **1.8s**, a full eight ≈ **5.1s**. The reload is **interruptible** — firing after any completed shell cancels the remainder and fires immediately.

### Laser (implemented)
Rendered as a **beam plus a terminal dot**. The **raycast originates at the camera** (so it matches point of aim); the **beam is drawn from a `Muzzle` Marker3D** on the weapon viewmodel to that hit point. The resulting offset — visible up close, converging at distance — is correct weapon-mounted-laser behaviour. Because the marker is a child of the viewmodel it inherits the ADS pose, recoil kick and bob, so the origin stays welded to the muzzle. If nothing is hit in range the beam draws to the max-range point and no dot is shown (there's no surface to paint).
- **Red** (default): visible **with or without NVGs** and clearly brighter than IR at every range — the tradeoff against the 10m detection rule. Beam radius **0.012m**, alpha **0.35**, emission **7.0**, dot **0.075m**.
- **IR** (attachment, 8 pts): rendered **only when NVGs are on**, and **invisible to zombies** — the 10m reveal is skipped entirely while equipped. Beam radius **0.006m**, alpha **0.15**, emission **2.2**, dot **0.045m**.
- The laser ray uses the same mask as gunfire, so the dot lands on zombies (body and head hitboxes) as well as world geometry.

**Long-range visibility.** A fixed world-space dot falls below a pixel at 60m, so both the dot and the beam get a **screen-space size floor**: below the threshold their world size is scaled up proportionally to distance (`world = frac × distance × 2·tan(fov/2)`). Defaults `dot_min_screen_frac = 0.009` (~10px at 1080p) and `beam_min_screen_frac = 0.0016`. The dot also has a **ceiling** (`dot_max_screen_frac = 0.045`) so it can never grow large enough to obscure the target.

**Beam thickness is tapered, not uniform.** Each end's radius is sized for its own distance from the camera (`bottom_radius` = muzzle end, `top_radius` = hit end), so apparent thickness stays roughly constant along the beam. A single uniform radius sized for an 85m hit produced an absurdly fat tube at the muzzle.

**Degenerate-geometry guards.** The beam is not drawn at all below `beam_min_length` (0.1m), and the cylinder has **no end caps** — a low-segment cap viewed face-on renders as a bright polygon. When the ray hits nothing the beam uses its **base radius** (nothing to scale against) with a length-wise alpha fade, and **no dot is drawn at all**. `F3` shows laser telemetry (hit true/false, hit distance, beam length, computed radii).

**Dot appearance.** A bright **core** plus a soft **falloff halo**, both **billboarded** and **additively blended**, using a radial white→transparent gradient texture. Billboards were chosen over surface-aligned quads because a surface-aligned disc is back-face culled from one side and collapses to a line at grazing angles; a billboard always presents full-on and reads as scattered glow, and additive blending blooms naturally under the NVG glow pass. Tunables: `dot_halo_scale` (3.2), `dot_halo_falloff` (2.2), `dot_halo_alpha` (0.55).
- All laser values are `@export` on Player (`laser_red_*` / `laser_ir_*` / `dot_*` / `beam_min_screen_frac`) — starting points, tune by eye.

### Suppressor audio (implemented)
Each weapon has **two audio states**, selected purely by whether a suppressor is attached — **fully independent of the noise-radius logic** (40m → 8m). One attachment drives two separate systems.
- Unsuppressed: the existing report, unchanged.
- Suppressed: routed through a runtime-created **"Suppressed" audio bus** (low-pass at 900Hz + compressor for a shortened tail), ~13dB quieter and pitched for a snappier decay, with the **mechanical action mixed up** so it reads as mostly slide/bolt noise. Placeholder built from the existing sample via bus effects.

### NVGs in daylight (implemented)
Leaving NVGs on during Day ramps to a heavy **gain-limit whiteout** over ~0.5s: near-opaque white overlay plus a large glow/bloom boost. Navigable but precise aiming is effectively impossible. A **`NVG — GAIN LIMIT`** HUD indicator shows while active so it reads as intentional. Clears immediately when NVGs are toggled off or Night begins.

### Guaranteed ammo drops (implemented — stopgap)
A temporary resupply until the purchasable supply-drop enabler exists.
- Spawns at the **dawn following nights 3, 5 and 10** (`EnablerManager.guaranteed_drop_nights`, an editable array). Scheduling deliberately lives **outside** the drop scene so the whole stopgap can be disabled wholesale.
- Grants **1 magazine per owned weapon** (nothing for unowned), always via `AmmoManager.grant_ammo()`.
- **Placement:** random within `drop_radius` (5m) of the crate, at least **2m from the player**, on flat walkable ground, with a box-shape check rejecting anything intersecting geometry. Re-rolls up to **10 times**, then falls back to a fixed known-good offset.
- Available for the whole Day and **persists if uncollected** — it never despawns at nightfall.
- Visually distinct from the crate (emissive orange cylinder + tall beacon, readable under NVGs). Collect with `E`; grants are logged and summarised on the HUD. A `RESUPPLY — DROPPED NEAR BASE` message fires at the dawn it spawns.
- `SupplyDrop` is a **reusable scene** taking a contents config, spawn anchor, and radius — the future purchasable enabler instances the same scene with the player as anchor.

### Ammunition scarcity (implemented)
- **Every weapon starts with exactly 2 magazines total — one loaded, one spare** (`WeaponData.starting_mags = 2`). M17 = 17+17, HK416 = 30+30, SPAS-12 = 8+8, M249 = 100+100.
- Weapons bought at the crate arrive with the same 2 magazines — no more.
- **Ammo does not regenerate.** Not between nights, and not on death/respawn. What you have at dawn is what you have.
- Ammo is bought separately at the crate, **priced per magazine** (`WeaponData.ammo_cost`).
- **All ammo granting routes through the single function `AmmoManager.grant_ammo(weapon_id, magazines)`** — starting loadout, crate purchases, and any future supply drop / enabler. Nothing else writes reserve ammo. `AmmoManager` (autoload) owns reserve pools; the Player owns only the currently-loaded magazine per weapon.
- HUD shows `mag / reserve` for the equipped weapon; the reserve turns **red at 0**.

## Attachments (spend points at the crate)
**Suppressor pricing rule (implemented):** a suppressor costs **2× the weapon's own purchase price**, so every future weapon prices its suppressor automatically with no new data entry (`StoreCatalog._suppressor_cost()`). The one exception is the **M17**, the free starter weapon — there's no price to derive 2× from, so it gets a flat cost instead.

| Weapon | Weapon cost | Suppressor cost |
|---|---|---|
| M17 | starter | 12 (flat) |
| HK 416 | 15 | 30 |
| SPAS-12 | 20 | 40 |
| M249 SAW | 30 | 60 |
| KAC M110 | 45 | 90 |

Suppressors reduce gunshot noise radius drastically per-weapon (see the falloff-adjacent noise table in each weapon's entry above); zombies within LOS won't clock the shot as a "you" event unless already alerted. Fully independent of the suppressed-audio system (two systems, one attachment).

**Weapon-specific attachments (implemented, flat cost — not derived from the 2× rule):**

| Attachment | Weapon | Cost | Effect |
|---|---|---|---|
| Foregrip | HK 416 | 12 | Tightens the moving-fire cone by 40% (1.0° → 0.6° added-while-moving). No effect stationary/crouched, no effect on recoil climb. |
| Breacher Choke | SPAS-12 | 12 | Widens hip-fire pellet spread 3.0° → 3.75° (+25%). ADS untouched. Pulls the one-shot-kill range in from ~7m to ~5.6m — a genuine tradeoff, not a strict upgrade. |
| Extended Drum | M249 SAW | 25 | Belt 100 → 200 rounds. -10% sprint while fitted (any weapon equipped). Ammo purchases scale to match, same per-round price. |
| Variable Zoom Optic | KAC M110 | 25 | Replaces the fixed 3x scope with a binary 2x/8x scope (scroll wheel while ADS toggles, 0.08s tween, no in-between position). Targeting convenience only — no damage/accuracy/rate change. |

**IR Laser — per-weapon purchase (implemented), not a global unlock.** Originally a single item that applied everywhere once bought; the price was already 8 (already cheap enough per the "under 10" threshold, so it carries over unchanged) but the *ownership* is now tracked exactly like the suppressor — one purchase per weapon, one attached-state per weapon.
- Offered for **every laser-equipped weapon: M17, HK 416, SPAS-12, M249 SAW** — each its own crate entry (`ir_laser_<weapon>`), each **8 pts**. Buying it for the M17 does not unlock it on any other weapon.
- **Not offered for the KAC M110** — it has no laser of any kind (see its "Weapons" entry) and is excluded from the catalog loop entirely, not merely hidden, so it can never appear in a laser-purchase list.
- Same effect as before: replaces the red laser; invisible to zombies, NVG-only visibility for the player.

- A weapon can carry its suppressor, its IR laser, **and** its second (handling) attachment simultaneously — up to three at once on a weapon that has all three slots — each tracked independently (`Player._suppressed` / `_has_ir_laser` / `_has_foregrip` / `_has_choke` / `_has_drum` / `_has_variable_zoom`, all keyed by weapon id, same shape as the original suppressor dictionary).
- Every attachment follows the same purchase pattern: buy at the crate, effect applies from the next shot/frame. All are added to `StoreCatalog` as `attachment_type`-tagged items and dispatch through `Player.owns_store_item()` / `apply_store_purchase()` — no UI changes were needed for any of them, per the existing data-driven store design.

## Zombie geometry & hitboxes (implemented)
- The zombie is two visually distinct parts: a **body capsule** (r 0.4, height 1.56, centred y=0.78) and a **head sphere** (r 0.12, centred y=1.68) in bright emissive magenta so it's unambiguous at 40m under NVGs. Total height stays **1.8m**.
- **Boundary resolution:** the body capsule is shortened to end at the neck (y=1.56) and the head sphere spans 1.56–1.80, so the two shapes **do not overlap volumetrically** — they meet at a single tangent point. With closest-hit raycasting, any ray entering the head region returns the head and nothing else; a ray blocked by the torso correctly returns the body.
- The head is its own `Area3D` on **collision layer 3** (`monitoring = false`, mask 0) so it costs nothing at runtime and never affects movement collision. The supply-crate trigger was moved to **layer 2** so weapon rays don't pick it up.
- Weapon rays use `collision_mask = 1|4` with `collide_with_areas = true`. **Headshots are determined by which collider was hit** — the old hit-height inference (`HEAD_LOCAL_Y`) has been removed entirely.
- Scoring is unchanged: head = **2x damage** and a headshot kill awards **3 points**; body = 1x and **1 point**.
- Every hit prints `[HIT] HEAD|BODY — N dmg, N HP remaining` and shows the same on-screen briefly. Shots-to-kill logging on death still works and splits head vs body.
- **`F4`** toggles translucent head/body hitbox volumes; **`F3`** toggles the audible-zombie distance overlay.

## Store UI (implemented)
The supply crate store is **tab-based and data-driven**, built from the `StoreCatalog` autoload.
- **Tabs: WEAPONS / ATTACHMENTS / SUPPLIES**, generated from `StoreCatalog.categories()`. SUPPLIES holds consumables — ammo (filtered to owned weapons) and the IFAK (always shown) — because both are rebought every few nights and represent the same kind of decision. Adding an item with a new `category` produces a working tab with **no UI code changes** (an `ENABLERS` tab will be added this way).
- Catalog entries are `StoreItem` objects built in code rather than `.tres` files, because every entry is derived from the Arsenal roster — hand-authoring resources would duplicate that data and drift from it. The UI only reads `id / category / display_name / description / cost / requires / weapon_id / kind`, so entries can become Resources later without touching the UI.
- **Filtering:** ATTACHMENTS and AMMO only list entries whose parent weapon is owned, grouped visually by weapon. AMMO shows the current reserve per entry.
- **Four item states:** affordable (normal), unaffordable (dimmed, cost highlighted red), owned (`OWNED`, not repurchasable — ammo is always repurchasable), locked (greyed, `Requires: X`). The locked state is wired to the prerequisite system and dormant until enablers use it.
- Points balance is always visible on every tab and updates immediately on purchase.
- **Navigation:** mouse click, number keys `1`/`2`/`3`, and `←`/`→`. Deliberately **not** bound to `E` (the interact key). Opens on `E` at the crate during Day only; `Esc` closes. Defaults to WEAPONS.
- Purchases play a confirmation sound; failed (unaffordable/locked) purchases give distinct negative feedback rather than failing silently.
- The **Radio** is a stopgap entry under WEAPONS; it moves to ENABLERS when those exist.

## IFAK (implemented)
The only way to recover health.
- Heals **40 HP**, capped at 100 — no overheal. Max carry **3**; the store shows `CARRYING 3/3` and blocks a fourth.
- Bound to **`H`** (verified free of collisions).
- **Application takes 4s** (`ifak_apply_time`), not instant. During application the player is capped at walking speed and cannot fire or ADS. **Sprinting or firing cancels it** with no IFAK consumed and no healing — it's only spent on a completed application. A progress bar shows during application and the count is always on the HUD.
- **Using at full HP is blocked** (with a message) rather than silently consuming the item: a consumable this scarce should never be spent for nothing.
- Cost **15 points**, `StoreCatalog.IFAK_COST`. Basis: no per-night earnings telemetry exists (kill logs are per-kill and nothing aggregates them), so this is the specified fallback. For reference, a night of 6–12 kills at 1–3 pts each is roughly 12–25 pts, putting one IFAK at ~60–125% of a night — **at the expensive end**, and worth re-pricing once per-night earnings are actually measured.
- Tunables: `ifak_heal`, `ifak_max_carry`, `ifak_apply_time` (`@export` on Player).

## Crate at night (implemented)
The Day gate is removed — the crate works in **both phases**.
- **The game does not pause while the store is open.** Zombies keep moving, pathing and attacking; the player can be hit, damaged and killed mid-shop. That exposure is the cost of resupplying at night.
- Movement and camera look stay disabled while shopping.
- **Player HP is shown prominently in the store header**, live-updating and turning red at ≤40. Being hit while shopping triggers the screen flash plus a **directional damage marker** (a wedge on a ring around screen centre at the bearing of the attacker).
- The store **does not auto-close on damage** — bailing is the player's decision.
- Dying with the store open emits `died_while_busy`, which closes the UI cleanly (restoring control and mouse capture) before the normal death flow, avoiding a soft-lock.

## Economy
- Points earned from kills are the only currency. Spent at the supply crate during Day phase.
- **Award: 1 point per body-shot kill, 3 per headshot kill.** Mine kills award 1.
- No separate "money" layer — keep it simple.

**Full price list (single reference — see the tech-debt note below; superseded by the suppressor-pricing-rule and weapon-roster passes, updated here):**

| Item | Cost | Repeatable |
|---|---|---|
| Sig Sauer M17 | 0 (starting) | — |
| HK 416 | 15 | no |
| SPAS-12 | 20 | no |
| M249 SAW | 30 | no |
| KAC M110 | 45 | no |
| Radio | 10 | no |
| Suppressor — M17 | 12 | no |
| Suppressor — HK 416 | 30 | no |
| Suppressor — SPAS-12 | 40 | no |
| Suppressor — M249 SAW | 60 | no |
| Suppressor — KAC M110 | 90 | no |
| IR Laser — M17 / 416 / SPAS-12 / SAW (each) | 8 | no |
| HK 416 Foregrip | 12 | no |
| SPAS-12 Breacher Choke | 12 | no |
| M249 Extended Drum | 25 | no |
| M110 Variable Zoom Optic | 25 | no |
| IFAK | 15 | yes |
| M17 ammo (1 mag, 17 rds) | 1 | yes |
| HK 416 ammo (1 mag, 30 rds) | 2 | yes |
| SPAS-12 ammo (1 mag, 8 rds) | 2 | yes |
| M249 ammo (1 belt, 100 rds; 200 with the Drum) | 4 (8 with the Drum) | yes |
| KAC M110 ammo (1 mag, 20 rds) | 3 | yes |
| Sandbags | 10 | yes |
| Triple-strand C-wire | 40 | yes |
| Zombie ditch | 60 | yes |
| Minefield | 70 | yes |
| Mine replenishment (to 20) | 10 | yes |

**Per-night earnings telemetry (implemented).** `PointsManager` tracks `earned_this_night` / `spent_this_night`, reset by `Main._begin_night()` and logged at dawn as
`[ECONOMY] night N earned X pts, spent Y, balance Z`.
This is the **first** earnings data the project has had — every price above was set by feel, not from measurement.

**Theoretical income ceiling.** The night pool is `6 + 3 × (night − 1)`, so a perfect night with every kill a headshot caps at `3 × pool`:

| Night | Pool | Max (all headshots) | Realistic (mixed) |
|---|---|---|---|
| 1 | 6 | 18 | ~8–12 |
| 3 | 12 | 36 | ~16–24 |
| 5 | 18 | 54 | ~24–36 |
| 8 | 27 | 81 | ~36–54 |

Carried-over survivors add to a later night's total, so the real curve runs slightly above this.

> **Tech debt (flagged, deliberately not refactored):** obstacle prices live in `ObstacleCatalog.gd`, weapon and ammo prices in `Arsenal.gd`, store-only prices (suppressor rule, `IFAK_COST`, `IR_LASER_COST`, Radio, and the flat per-weapon attachment costs) in `StoreCatalog.gd`, and **mine replenishment in `BuildMode.gd` (`REPLENISH_COST`)** — the one price that lives nowhere near the others. Worth consolidating into a single pricing table once the numbers stop moving.
- The crate's purchase flow supports an optional **prerequisite item** (`WeaponData.requires`): an item can require another to be owned first. Unused by weapons today; it exists so future enablers (Radio → UAV/Apache/supply drop) need no new plumbing.

## Engineers' Tent & build mode (in progress)
**Lore:** the engineers are civilian construction workers sheltering at the patrol base. They're too frightened to work at night, so the tent is **Day only** — unlike the supply crate, which is usable in both phases. They build fortifications for points.

**Shell (implemented):**
- An `EngineersTentZone` Area3D at `(-7, 0, 7)`, across the base from the crate. Khaki canvas box with a peaked roof — deliberately unlike the crate's brown box.
- Opens with `E` during **Day**. At night it shows *"The engineers won't leave the tent after dark."* and does not open.
- On entry the **day timer pauses** (`GameManager.set_paused`), the view lifts to a top-down camera, and the build UI opens. **The player body stays where it is** — only control is suspended.
- The camera is **orthogonal**, not perspective: a build view wants consistent scale across the map, and zoom collapses to a single `size` value. Default `size = 72` frames the 60×60m map with margin.
- **Pan** with WASD (clamped to ±34m so the base can't be lost); **zoom** with the wheel or `[` / `]`, between 24 and 90. Middle-mouse drag-pan was tried and removed — the build UI CanvasLayer swallowed the motion events, and the mouse is needed for ghost placement.
- `Esc` exits, restores the first-person camera, and resumes the timer. Re-enterable freely during a Day.
- Tunables on the BuildMode node: `default_zoom`, `min_zoom`, `max_zoom`, `zoom_step`, `pan_speed`, `camera_height`, `pan_limit`.

**Ghost placement (implemented):**
- Left-side palette lists all four obstacles with cost; unaffordable entries show their price in red. Click to select, click again to deselect. Points and a `Placed: n / 30` counter are visible at all times.
- A semi-transparent ghost follows the cursor, positioned by projecting a ray from the camera through the cursor onto the ground plane.
- **Rotation:** wheel steps 15° (`rotation_step_deg`); **Shift+wheel** free-rotates in 2° increments. Rotation **persists between placements** so parallel runs are quick to lay. `[` / `]` always zoom, so rotating never costs camera control.
- **Validity:** the ghost is green when legal, red when not, with a reason line on screen (`Overlaps another obstacle`, `Outside the map`, `Ground too steep`, `Not enough points`, `Obstacle limit reached`).
- **Placement commits on left click, and points are deducted only then.** An invalid click does nothing and plays the denial tone.
- **Rejection rules are only:** overlap (another obstacle, the crate, the engineers' tent, base structures, trees), out of bounds, ground too steep, the 30-obstacle cap, or insufficient points. Dormant zombies and the player are explicitly *not* obstructions.
- **Sealing the perimeter is allowed.** A coarse 2m-grid flood-fill from the map edge to the base centre detects when the current ghost would close the last gap and shows `PERIMETER WILL BE SEALED` — **informational only, the placement still goes through.** The result is cached per ghost cell/rotation so the fill runs only when something changes.
- Obstacles carry a dedicated **footprint `Area3D` on collision layer 4**, used purely for placement overlap. Keeping it separate from solid collision lets non-solid obstacles (wire, ditch, minefield) reject overlapping placements without physically blocking anything.

| Obstacle | Footprint | Cost | Solid | Blocks pathing |
|---|---|---|---|---|
| Sandbags | 10 × 1 × 0.5m | 10 | yes | yes |
| Triple-strand C-wire | 10 × 1.8 × 1m | 40 | no | no |
| Zombie ditch | 8 × 3m mouth, 3m deep | 60 | no | no |
| Minefield | 10 × 5m | 70 | no | no |

### Navmesh strategy (implemented) — threaded rebake

**Chosen: full `NavigationRegion3D.bake_navigation_mesh(on_thread = true)`, not `NavigationObstacle3D` carving.**

Why carving was rejected:
- `NavigationObstacle3D`'s **avoidance** mode (RVO) doesn't change the navmesh at all — agents steer locally around a radius. For a **10m wall** that's the wrong shape entirely: zombies would path *through* the wall and then grind along it, instead of routing around the end. Avoidance solves "don't bump into each other", not "this line is impassable".
- Its **navmesh-affecting** mode is applied *during a bake* anyway, so it doesn't avoid the rebake — it just changes what the bake reads. Given the sandbags already have real static collision, a plain rebake gets the same result with one less moving part.

Why a rebake is affordable here, including the unpaused case:
- The bake runs **on a worker thread**. While it runs the **old navmesh stays live**, so a mid-night breach costs no frame hitch — zombies keep moving on stale paths for a few hundred ms and then re-route. That reads as "they notice the breach a moment later", which is the behaviour we want anyway.
- Requests are **coalesced**: several placements, or several sections breaching at once, produce one bake rather than one each. A bake requested while another is running is queued behind it.
- The startup bake is the only synchronous one, because nothing is moving yet and the first path query must not race it.

Configuration:
- The main navmesh parses **`PARSED_GEOMETRY_STATIC_COLLIDERS` on collision layer 1**, not mesh instances. Only things with real collision block pathing — so a sandbag wall carves the navmesh, while the minefield's marker plate (collider-less) correctly does not.
- **A second `NavigationRegion3D` (`_mouth_region`) exists solely for ditch mouths.** It parses `PARSED_GEOMETRY_MESH_INSTANCES` instead — thin, invisible, collider-free patches placed exactly over each ditch's hole, so the mouth stays walkable in the navmesh permanently, independent of the fact that it has zero physical collision (see "The obstacles" → Zombie ditch, below, for why this had to be a second region rather than a collider on the main one). Both regions rebake together and both must report `bake_finished` before a rebake is considered complete (`Main._nav_bakes_in_flight`).
- Placed obstacles are parented to an `Obstacles` node **under the `NavigationRegion3D`** so rebakes see them.
- Only `solid` obstacles and ditches trigger a rebake; wire and minefield don't change pathing. (A ditch triggers its own rebake from `ZombieDitch.finalize_in_world()`, once its world position is final, rather than through the generic `t.solid` check in `BuildMode._try_place()`.)
- Each bake logs its duration: `[NAVMESH] rebake finished in N ms (reason)`.

**Also fixed here:** the supply crate and Engineers' Tent were parented to `Main` rather than the nav region, so they were never in the navmesh and zombies pathed straight through both. They're now nav-region children.

### The obstacles (implemented)

**Sandbags — 10 pts, destructible.** 10 × 1 × 0.5m. Each section is independent; damage never spreads between sections, so a breach opens exactly one gap.
- **4000 HP** (`max_health`). Zombies deal **15 damage per 1.2s** (`structure_damage` / `structure_attack_interval` on Zombie) — deliberately separate from the 20 damage they deal the player, so anti-structure and anti-player pacing tune independently.
- That's **12.5 dps each**: one zombie needs ~320s (longer than a 120s night); eight need ~40s. Turtling is viable, but a mass will come through.
- **Three visual damage states** at >66% / >33% / below — colour darkens and the wall visibly slumps. Not decoration: an enclosed player needs to see which section is about to fail.
- **Spatialised impact audio** at the point being worked (not the section centre), rate-limited per section so eight attackers read as busier rather than as sixty overlapping samples.
- Solid collision on layer 1, so it blocks zombies, blocks the player, **and stops bullets** — and at 1m it's well under the 2.0m mantle limit, so the player can climb it while zombies must go around or through. Zombies at the wall can still reach a player standing behind or on top of it.
- **Repair** in build mode: right-click a damaged section. Cost is `full_cost × (missing HP / max HP)`. Destroyed sections are gone and must be rebought.
- **World-space health bar** (implemented, `HealthBar3D.gd`) — billboarded, hidden at full HP, appears on damage, fades ~4s after the last hit and reappears on the next one. Width and vertical offset scale with the object's own bounds rather than a fixed number. Shows a numeric `current/max` readout while playtesting (`show_numeric`, trivial to flip off later). Built as a generic component — `attach_to(owner, bounds)` polls whatever `health`/`max_health` properties already exist on the owner, so it isn't sandbag-specific and any future destructible gets a working bar for three lines of code, not a subclass.
- **`take_structure_damage()` now logs remaining HP, and `_destroy()` logs an explicit `DESTROYED` line** — both include the section's exact position and instance id. Added while diagnosing a report of "destruction logged, sandbag still looks intact": every segment previously logged only as `SandbagSection`, indistinguishable from any other segment in a multi-segment wall, which made it impossible to confirm from the log alone *which* segment a hit applied to.
  > **Diagnosis.** Code review of the destroy path itself found no defect: `_destroy()` calls a real `queue_free()` (not just a flag) on the node whose mesh and collision *are* children of it, not siblings, and Godot removes freed nodes from `get_nodes_in_group()` queries automatically. The far more likely explanation, given BuildMode explicitly shrinks the placement-overlap test box 4% *"so obstacles can sit flush against each other"*: **multiple 10m segments placed end-to-end read as one continuous wall, but a blast only reaches the segment(s) within its own radius.** A grenade (5m lethal / 12m max) centred on one segment can fully destroy it while a neighbour one segment further along — visually part of "the same wall" — sits outside the 12m max radius entirely and takes zero damage, not partial damage: genuinely indistinguishable from "intact." `_destroy()` also now hides the mesh and disables the collision synchronously, ahead of the deferred `queue_free()`, closing a real (if minor) same-frame gap — not the reported bug's root cause, but a legitimate hardening regardless.

**Triple-strand C-wire — 40 pts, permanent, indestructible.** 10 × 1.8 × 1m.
- Holds **4** zombies (`capacity`) permanently as **Entangled** — alive, immobile, and still able to swing if the player comes within melee range. Don't hug your own wire.
- Once full the section is trampled and further zombies push through at **40%** speed (`inside_speed_mult`), keeping a **permanent −15%** (`exit_speed_penalty`) on exit. The wire shreds them on the way past even when it can't hold them.
- Killing an entangled zombie frees its slot.
- **Wire is a hard barrier to the PLAYER** (this *replaces* the original "no effect on the player" rule). You cannot walk through it, jump it (1.8m), or mantle it. Implemented with a `StaticBody3D` on a dedicated **player-barrier collision layer (5)** that only the player's `collision_mask` includes. That one choice satisfies every constraint at once: zombie bodies mask layer 1 so they still walk in and get held; the navmesh parses layer 1 so wire stays **navmesh-passable** (carving it would break both the held-in-wire mechanic and the seal logic); weapon rays mask 1|4 so **bullets pass straight through**; and the mantle surface probes mask layer 1 so wire can never be a climb target. The mantle *destination* check does include the barrier layer, so a mantle over something else can't drop the player inside wire either.
- Because wire can trap the player, placement adds **two separate rejections** with distinct messages: **`CAN'T BUILD ON YOURSELF`** if the volume would land on the player, and **`WOULD TRAP PLAYER`** if it would leave the player with no route to the map edge. Both are hard rejections, unlike the informational seal notice.

**Zombie ditch — 60 pts, permanent, indestructible.** Rebuilt from scratch as a real pit — the "above-ground revetment wall" design (see history below) produced physical barriers the navmesh never knew about, so zombies got stuck against them at the edge instead of falling in.

> **History — why the walls-only version was wrong.** Its collision sat on a solid-but-non-navmesh layer specifically so the navmesh would ignore it and zombies would "path into" the trench. But the navmesh, seeing an unbroken flat ground plane the whole way through (the walls only ran along the two long sides, not across the mouth), had no reason to route anyone toward it at all — and a zombie approaching from the side simply hit a real wall the pathing system didn't know was there, sliding along it instead of routing around. Fixed properly this pass, not patched.

**The pit is now a literal hole**, built on the insight that Godot's navigation and physics systems are entirely independent — a zombie's *path* can say "flat ground here" while its *physics body* falls straight through, because pathfinding never consults collision to decide walkability:
- **The ground genuinely has a hole in it.** The 60×60m ground plane, previously one collision box, is now a rebuildable set of rectangular pieces (`Main._ground_body` / `_ground_holes` / `_rebuild_ground_pieces()`). Placing a ditch subtracts its world-space AABB from the ground via a standard rectangle-minus-rectangle decomposition (up to 4 remainder strips — west/east/north/south — applied per hole), with no runtime CSG needed. There is no floor there any more; gravity does the rest.
- **A second, physics-free `NavigationRegion3D` (`Main._mouth_region`) keeps the mouth walkable in the navmesh, permanently.** It's baked from `PARSED_GEOMETRY_MESH_INSTANCES` rather than colliders — a thin, fully transparent `MeshInstance3D` patch exactly over the hole's footprint. Because it has zero physical collision, it can never be "discovered" as a gap by a future rebake the way a since-removed temporary collider would be; the patch is permanent, so the mouth stays flat and walkable across every rebake for the rest of the game, independent of anything physical. Both regions share the default navigation map, so Godot stitches their polygons into one connected graph automatically.
- **The pit itself (walls, floor, ramp) is real collision on the solid-but-non-navmesh layer** (layer 6, same one the old revetment used) — solid to both actors, invisible to the navmesh, so **the pit interior has no navmesh at all**.
- **A dirt ramp** at the pit's local −X end (`Player.floor_max_angle` default of 45° comfortably covers it): a sloped slab from the floor up to ground level at roughly **37°** (a 3-4-5 right triangle at the default 8×3×3m size — 4m run, 3m rise), leaving the rest of the pit's length as flat floor. **The ramp end is fixed to a specific local side, not auto-oriented toward the base** — rotate the ghost before placing to point it wherever you want. Exploiting the ramp is a non-issue: fallen zombies have no pathing at all (below), so nothing ever seeks it out.
- **`Zombie.State.FALLEN`** (replaces the old `TRAPPED`, which existed only for this obstacle): an `Area3D` over the mouth (inset from the edges, spanning from just above ground through the full depth) transitions any zombie that enters. Once FALLEN:
  - Gravity applies normally (unlike the old TRAPPED, which zeroed velocity and skipped `move_and_slide` outright) — it genuinely falls.
  - The `NavigationAgent3D` is never touched — no target is set, `get_next_path_position()` is never called — so there is no pathing at all, by construction rather than by disabling a node.
  - On landing (`is_on_floor()` first true), it emits a **10m noise event** — a body hitting the pit floor makes a sound, and pulling more zombies toward the same lane is intentional — then mills within **1m** of the landing spot, drifting to a new point every 2–4s.
  - **One-way, permanently**: `is_immobilised()` now includes FALLEN, which already gated every exit (noise, laser-dot curiosity, being-shot-triggers-chase) — so no code path can ever pull a fallen zombie back into Investigate/Chase/Attack, regardless of proximity, noise, or laser.
  - Fully damageable throughout: normal hit­boxes, the 2× headshot multiplier, and normal point awards are untouched, and it still counts toward the wave's alive total until killed.
  - No capacity limit — unlike the old TRAPPED (capped at 6, extra zombies crossed over at reduced speed), the pit holds however many physically fit; there is no overflow behaviour to speak of.
- **Known approximation:** the ground hole and the navmesh patch both use the ditch's world-space *axis-aligned bounding box*, not its exact rotated footprint. At a non-cardinal rotation this is conservatively larger than the visible pit at its corners — tune later if a rotated ditch reads as having "extra" invisible hole at the corners.

**Minefield — 70 pts, most expensive.** 10 × 5m, **20 mines** (~1 per 2.5 m²), boundary marked with emissive posts.
- **Player-safe** — the engineers marked the field.
- On detonation: **125** to the triggering zombie, **50** to everything within **10m**, and a **permanent −50%** to every survivor of either. **No chain detonation** — one mine per trigger event.
- **Remaining count is displayed**: a billboarded world-space `MINES n / 20` readout appears within `readout_range` (5m) of the emplacement, and is forced on for every field while build mode is open. A spent field greys its readout *and* its boundary markers stop glowing, so armed and empty fields are distinguishable at a glance. At 0 mines the field detonates nothing.
- Mines are **consumed**. The emplacement is permanent, its ammunition isn't; right-click in build mode to replenish for **10 pts**. That price is *deliberately profitable* over repeated use — it is not an oversight.
- Loud blast plus a **60m noise event** — the field announcing itself and pulling more zombies in is intended.
- **Known property, deliberate:** 125 one-shots a baseline zombie, but zombie HP reaches 132 by night 9 under the current scaling curve, so **from night 9 the minefield wounds rather than kills.** Left as-is pending playtest.

> **V2 — zombie variants.** Stats are no longer hardcoded: they live in
> `ZombieType` resources (`resources/zombie_walker.tres`,
> `zombie_leaper.tres`), and a second variant (the Leaper, with a LEAP state)
> now exists. See **[PATROL_BASE_ZERO_V2_SPEC.md](PATROL_BASE_ZERO_V2_SPEC.md)**
> for the resource architecture, leaper stats, leap ballistics and spawn mix.
> The walker's behaviour is unchanged by that refactor.

### Zombie states & speed modifiers (implemented)
Added to Wander / Investigate / Chase / Attack:
- **Entangled** — stationary, alive, attacks at melee range. Immune to noise and laser events.
- **Fallen** (replaces the old **Trapped**) — fell into a ditch pit. Gravity-driven until it lands, then mills within a small radius, permanently. Cannot attack, immune to noise and laser events — `is_immobilised()` covers both Entangled and Fallen, so every transition-out check (noise, laser curiosity, being shot) is already gated by the same one flag.
- **AttackStructure** — entered from Chase when a navmesh path to the player stops short. Targets the nearest intact sandbag section, and **re-checks reachability every second**, abandoning the wall the moment a route opens elsewhere. Being shot no longer breaks a zombie out of Entangled/Fallen, since it has nowhere to go.

Speed modifiers **stack multiplicatively** with a floor: permanent (mine survivor ×0.5, wire exit ×0.85) compound for life; temporary (inside wire ×0.4) applies only inside the volume — the ditch no longer has a "crossing a full pit" case, since there's no capacity to overflow. Total is clamped to **`min_speed_mult` = 0.30** — a mined-then-wired zombie never approaches zero and becomes a de-facto permanent obstacle.

### Obstacle persistence (implemented)
Obstacles survive between nights, and — the point of doing this now rather than later — they survive a **scene change**, so the multi-level work can't silently lose the base.

- **`GameState` (autoload)** holds the run as plain data: `obstacles` (an Array of Dictionaries), `night_number`, `points`. Every value is `String` / `float` / `Vector3` / `bool` / `Array`, so the snapshot is already safe to hand to `var_to_str`, `JSON`, or `FileAccess` without further conversion. **No node references cross a transition.**
- Each obstacle serialises itself: `Obstacle.to_dict()` carries `type` / `pos` / `yaw`, and subclasses override to merge their own mutable state.
  - **Sandbags persist with their current health** — a wall left at 40% comes back at 40%, not repaired.
  - **Minefields persist per-mine**, as a `live` array, so a half-spent field comes back half-spent with the right marker and readout state.
  - **C-wire and ditches are permanent and carry no mutable state** — entangled and fallen zombies are transient by definition, so a restored section comes back empty. (A restored ditch does need its ground hole and navmesh mouth patch re-registered against the fresh scene, since those are world-level side effects `GameState` doesn't persist — handled by `ZombieDitch.finalize_in_world()`, called again from `BuildMode.adopt()`.)
- **Destroyed sandbag sections stay destroyed.** They're removed from the roster on destruction, so they're simply absent from the snapshot — no "destroyed" flag to get out of sync.
- **Capture** runs at every phase boundary (`Main.capture_state()` from `_on_phase_changed`), so `GameState` is always current and a transition never has to hunt for a safe moment to serialise. `Main.capture_state()` is public for whatever drives a level change later.
- **Restore** runs inside `Main._build_ui()` — *before* the initial navmesh bake in `_ready()` — so restored sandbags are baked in on the first pass and no extra rebake is needed.
- Restored obstacles are **adopted by `BuildMode`** (`adopt()`), not merely spawned: they're appended to `_placed`, so they count against the **30-obstacle cap**, and restored sandbags reconnect `destroyed_section` so a later breach still triggers a rebake.
- `GameState.has_snapshot()` guards the whole path, so a cold boot is never stomped by an empty snapshot.

## Roadmap
Support enablers (Radio → UAV / Apache / Supply Drop) are **planned, not built**. See [docs/ROADMAP.md](docs/ROADMAP.md) for the concept, the radio-as-prerequisite structure, the compatibility checklist, and known friction to resolve before building them.

## NVGs
- v1: always-on toggle, no battery mechanic. (Battery-limited NVGs flagged as a v2 tension mechanic.)
- Daylight use is punished — see "NVGs in daylight" above.
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
