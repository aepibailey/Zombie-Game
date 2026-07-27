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
- **Max height 2.0m** (`mantle_max_height`) — deliberately equal to the planned ditch depth, so climbing out is possible but effortful. Minimum 0.35m.
- **Duration scales with height:** ~0.4s at 1m, ~0.9s at 2m. A locked interpolation — no gravity, no steering, and firing/ADS are blocked throughout.
- **Zombies cannot jump or mantle.** They have no such capability and none was added.

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
| SPAS-12 | Auto shotgun | 8 | Semi-auto (9 pellets) | 20 pts | 2 pts |
| M249 SAW | Belt-fed | 100 | Auto | 30 pts | 4 pts |

### Damage falloff (implemented)
Piecewise-linear over distance from the muzzle: full damage to `falloff_near`, then linear to `falloff_mid_mult` at `falloff_mid`, then to `falloff_far_mult` at `falloff_far`, flat beyond. Every hit logs its distance and multiplier.

| Weapon | Full to | → mult @ range | → mult @ range |
|---|---|---|---|
| M17 | 25m | 0.70 @ 60m | 0.50 @ 100m |
| HK 416 | 30m | 0.85 @ 85m | 0.85 @ 120m |
| SPAS-12 | 10m | 0.40 @ 20m | 0.15 @ 30m |
| M249 | 30m | 0.80 @ 85m | 0.80 @ 120m |

### SPAS-12 close-range lethality (implemented)
**9 pellets × 22 dmg** (198 at point blank), **3°** cone, each pellet raycast independently with the headshot multiplier applied per pellet.
- **≤7m:** pattern ~0.7m across; 5+ pellets on a torso = 110+ dmg → **one-shot** a 100 HP zombie. At night 10 (132 HP) six pellets = 132 → still one-shot with margin.
- **~12m:** falloff ×0.88, wider pattern → reliable **two-shot**.
- **20m:** ×0.40 and a ~2m pattern → clearly a bad choice. **30m+:** ×0.15, useless.
- Max range 40m; the proportional per-shell reload is unchanged.

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

## Attachments (spend points at tent)
- **Suppressor** — reduces gunshot noise radius drastically (40m → 8m); zombies within LOS won't clock the shot as a "you" event unless already alerted.
- **Foregrip** — reduces recoil.
- **IR Laser** — replaces red laser; invisible to zombies, NVG-only visibility for the player.
- (More attachments added as weapons are added — optics, extended mags, etc.)

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
- No separate "money" layer — keep it simple.
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
| Triple-strand C-wire | 10 × 1.8 × 1m | 20 | no | no |
| Zombie ditch | 10 × 2 × 1m | 35 | no | no |
| Minefield | 10 × 5m | 50 | no | no |

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
- The navmesh parses **`PARSED_GEOMETRY_STATIC_COLLIDERS` on collision layer 1**, not mesh instances. Only things with real collision block pathing — so a sandbag wall carves the navmesh, while the ditch's sunken visual and the minefield's marker plate (both collider-less) correctly do not.
- Placed obstacles are parented to an `Obstacles` node **under the `NavigationRegion3D`** so rebakes see them.
- Only `solid` obstacles trigger a rebake; wire, ditch and minefield don't change pathing.
- Each bake logs its duration: `[NAVMESH] rebake finished in N ms (reason)`.

**Also fixed here:** the supply crate and Engineers' Tent were parented to `Main` rather than the nav region, so they were never in the navmesh and zombies pathed straight through both. They're now nav-region children.

*Still to come: obstacle behaviour (destructible sandbags, entanglement, trapping, mines), the new zombie states, and repair/persistence.*

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
