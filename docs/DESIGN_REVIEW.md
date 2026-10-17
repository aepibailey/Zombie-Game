# Patrol Base Zero — Design & Architecture Review

**Purpose.** A candid audit of the project as it stands on 2026-10-17, written to
be taken into a Claude Chat conversation and argued over. Every finding cites
the file it comes from so the discussion can be about the game, not about
whether the claim is true. Recommendations are opinions; the "Questions"
under each one are the things actually worth deciding.

**Scope of what was read.** `PROJECT_SPEC.md`, `PATROL_BASE_ZERO_V2_SPEC.md`,
`docs/ROADMAP.md`, `README.md`, `project.godot`, and the full source of
`Main.gd`, `Player.gd`, `Zombie.gd`, `Fighter.gd`, `FighterType.gd`,
`GameManager.gd`, `GameState.gd`, `PointsManager.gd`, `NoiseManager.gd`,
`EnablerManager.gd`, `StoreCatalog.gd`, `Damageable.gd`, `LineOfSight.gd`,
plus the structure (function lists) of `HUD.gd`, `BuildMode.gd`,
`SupplyCrateUI.gd`, `RosterMenu.gd`, `AreaDamageSystem.gd`, `Arsenal.gd`.

**Numbers.** 55 commits (2026-08-06 → 2026-10-17). 61 scripts, 15,878 lines of
GDScript, of which 4,859 (31%) are comment lines. 2,700 lines of design docs
across three files. 11 autoloads. 3 scene files totalling 89 lines (everything
else is built in code). Zero automated tests until the branch this review
ships on (one headless smoke test).

**Status (2026-10-17).** The findings below are left as written; addressed ones
carry a **Status** line. Since the review:
- **§1 fail state** — death ends the run (`3c239de`). The run *goal* is still
  open.
- **§3.5 zombie sight** — shipped (`a462fe1`).
- **§3.6 target interval** — `target_reevaluate_interval` is now 0.25
  (`a462fe1`). The `Targets` registry is still open.
- **§3.9 / §4.8 day-time kills** — survivors retreat at dawn and day kills
  score nothing (`6fb5019`).
- **§3.3 damage verbs** — one `take_damage(DamageInfo)` and a `Health` per
  actor (`8a8d6ee`, `a77c58d` and the single-verb switch after them).
  SandbagPanel was left out.

---

## 0. What is genuinely good

Being fair matters, because the fixes below should not throw these away.

- **One line-of-sight implementation** (`LineOfSight.gd`) with eye-point
  contracts, and a startup assertion that cover and concealment masks differ.
  This is the right shape and it is rare to see it done at all.
- **One area-damage path** (`AreaDamageSystem.detonate()`) that grenades,
  claymores, mortars, WP, the Apache and the crate-crush all consume as
  `.tres` profiles. No explosive owns damage math.
- **Data-driven weapons and zombie variants** (`WeaponData`/`Arsenal`,
  `ZombieType`). Adding a variant is a resource, not a code change.
- **The noise bus** (`NoiseManager`) — location-based, not player-based. The
  single best design decision in the project; it is what makes "noise
  discipline" a real mechanic rather than a flag.
- **Refcounted clock halt** in `GameManager` instead of a bool. Correct.
- **The leaper's "a leap never beats a run" rule** was derived and checked,
  not asserted by hope.
- **Startup invariants that fail loud** (fighter bands, mask sanity, weapon
  ordering). The instinct is right even where the placement is wrong (§2.4).

The problem is not that the code is bad. The problem is that *a lot* of
carefully-built code sits on top of a core loop that was never closed.

---

## 1. The one finding that matters most: the game has no goal and no fail state

Everything else in this document is secondary to this.

**Evidence.**
- Death is a teleport-and-heal. `Player.take_damage()` → `_respawn()` restores
  100 HP and position *synchronously, in the same call* (`Player.gd:340-373`).
  The only persistent cost is that ammo is not refilled. The project has had to
  build a one-frame death latch (`_died_this_frame`) and document it in three
  files (`Player.gd:265`, `Zombie.gd:23-35`, `AreaDamageSystem` kill tally) so
  other systems can *notice* a death that is undone before the function returns.
- Nights escalate forever: `spawn = 6 + 3·(night−1)`, HP `100 + 8·⌊(night−1)/2⌋`,
  explicitly "no cap" (`PROJECT_SPEC.md` "Zombie health scaling").
- There is no win condition, no extraction, no "survive N nights", no score
  screen. "Position Two" and the "transit night" — the things that would give a
  run a shape — are "not started" (`docs/ROADMAP.md` Planned).
- Fighters' "first 4 free" recruitment is a stand-in for a rescue that happens
  on a map that does not exist (`Main.gd:67-77`, `ROADMAP.md:144`).

**Why it matters.** Without a fail state, every defensive system (sandbags,
wire, ditch, mines, claymores, fighters, IFAKs) is optional flavour: the worst
case of ignoring all of them is a free respawn. Without a goal, escalation is
just a difficulty ramp into an eventual stalemate. Pricing, scarcity and
"deliberately bad early" purchases (§12 supply drop) cannot be evaluated
against anything because nothing is at stake.

**Recommendation.** Decide the run structure before adding anything else:
1. Death ends the night (or the run). Respawn becomes a debug toggle.
2. A run is N nights (pick 7 or 10), with a defined end (extraction / transit /
   "relief arrives"). Escalation curves get a ceiling to tune toward.
3. Then re-price everything against "points per night × N nights".

**Status: partly addressed** (`3c239de`). Recommendation 1 is done: death ends
the run, `Player.respawn_on_death` (default off) is the debug toggle, and a
game-over panel offers Restart, which resets every run-scoped autoload. Items
2 and 3 (a run length or end, and re-pricing) are still open.

**Questions for discussion.**
- Is this a roguelite (a run is 20–40 minutes, death resets) or a campaign
  (persistent base, death costs a night)? The two have incompatible economies.
- What is the fantasy of the last night? That answer decides which of the
  enablers (§4.4) deserve to exist.

---

## 2. Process mistakes (the "younger self with AI" tells)

These are the patterns that look like a capable model being driven one request
at a time without a plan holding the requests together.

### 2.1 Specs that are commit logs

`PATROL_BASE_ZERO_V2_SPEC.md` is 2,024 lines. It records *what was asked*,
*what was found*, *what was deviated from and why*, "flagged, not changed",
"verified by simulation", "deliberately not designed around". That is a
decision log, not a spec. Three documents now have precedence rules between
them (`V2_SPEC.md` header: "if the two ever disagree…"; `ROADMAP.md`: "when the
two disagree, this file follows the code"), and a later audit found "real drift
between what this document claimed and what the code actually did"
(`V2_SPEC.md §10.0`).

**Cost.** A human cannot use these to understand the game. A model reading them
gets 2,700 lines of context that is mostly history, which crowds out the code.

**Recommendation.** Split into three things with different lifetimes:
- `DESIGN.md` (≤300 lines): what the game *is* — loop, rules, numbers table.
  Present tense. No history.
- `docs/decisions/NNNN-title.md`: one short ADR per non-obvious decision
  (why no faction filtering, why hits-not-kills, why the ditch is a real hole).
- `TUNING_BACKLOG.md`: every "flagged, not changed" item, as a checklist.
  There are at least a dozen scattered through the specs today.
Then delete the narrative. Git has it.

### 2.2 Comments as a defence against the next AI session

31% of the source is comments, and a large share of them are not explaining
code — they are explaining *to a future model* why it must not change
something: "LOAD-BEARING", "DELIBERATELY NOT", "do not add a second",
"this used to cast its own ray from `global_position + 1.4`…" (`Zombie.gd:948-958`),
40-line docstrings on `_acquire_target()` (`Zombie.gd:969-1000`), a
`_assert_not_rolled` setter on every fighter field (`Fighter.gd:38-75`).

This is a rational response to a real problem (a fresh session *will* undo a
subtle decision), but the cost is that `Player.gd` is 2,569 lines and
`Zombie.gd` 1,327, and the signal-to-noise of each file is low.

**Recommendation.** Keep the *invariant* (one line) where an `assert` already
enforces it; move the *history* into the ADRs above; delete the rest. A
`CLAUDE.md` at the repo root with the ten rules that must not be broken
("one LOS implementation", "no faction filtering", "damage axes stay
separate", "run tests as a scene, never `--script`") does the job of hundreds
of defensive comments and is read on every session.

### 2.3 No tests until now

55 commits, 16k lines, and the branch this review ships on carries the first
automated test. The spec already contains tables that *are* unit tests
written in prose: falloff per range (`PROJECT_SPEC.md` "Damage falloff"),
shots-to-kill per night (`V2_SPEC.md §4.4`), leap ballistics (`§2`), supply
drop bundle pricing (`§12`), spawn interval per night. Each was computed by
hand once and will silently rot.

**Recommendation.** The headless-scene pattern now works (`tools/smoke_test.tscn`).
Add a second scene that runs pure-function checks with no world:
`WeaponData.damage_mult_at()`, `Main._compute_spawn_interval()`,
`leaper_fraction_for_night()`, `_zombie_hp_for_type()`, the supply-drop bundle
math. Ten assertions, deterministic, sub-second. CI already runs scenes.

### 2.4 Balance rules enforced as boot-time asserts

`Arsenal._validate_damage_invariants()` (416 must out-damage the M17 at every
range), the supply-drop two-sided pricing assert, `FighterType.validate()`'s
"fighter noise must equal the M17's". These are *balance opinions* implemented
as crashes-on-launch. Two consequences: you cannot try a different balance
without first deleting the assert, and `assert()` is stripped from release
builds so they only protect the editor.

**Recommendation.** Structural invariants (mask bits, group membership, "never
reaches 1.0") stay as asserts. Balance relationships become tests (§2.3) that
fail in CI, not in the editor.

### 2.5 The editor was thrown away

`Main.tscn` is 10 lines. The world, lighting, HUD, store, build mode, radio,
roster, laser, viewmodel and every UI are constructed in GDScript with
`.new()`. The specs repeatedly hit the consequence and work around it rather
than fixing it: "exports on a `.new()` node never reach an inspector, so
tunables live on a Config resource" (`V2_SPEC.md §12`, `§13`), a 60-line
`_build_viewmodel()` placing boxes by coordinate (`Player.gd`), five UIs each
hand-laying labels.

**Recommendation.** Not a rewrite — a migration as each area is next touched:
UI panels become `.tscn` (the biggest win: layout, theming, and the inspector),
`Player.tscn` grows its viewmodel/laser children, the base structures become a
scene. Keep procedural generation where it is actually procedural (the tree
ring, the ground pieces).

### 2.6 Feature breadth outran loop validation

Five weapons, ten attachments, four obstacles, grenades, claymores, six radio
enablers (mortar, WP, UAV, supply drop, Apache, retask), fighters with a roster
and upgrade tiers, cover/concealment with two debug overlays, two zombie
variants — on a 60×60m greybox with no art, no objective, and a "playtest
cadence" of 30s days. Each session added a system; none closed the loop.

**Recommendation.** Feature freeze until §1 is answered. Then a cut list (§4.4).

---

## 3. Architecture

### 3.1 God objects

| File | Lines | Responsibilities |
|---|---|---|
| `Player.gd` | 2,569 | movement, noise, mantle, weapons, reload, falloff/penetration ray, laser *rendering* (~300 lines of mesh/material code), laser *detection*, grenade cook/throw, claymore placement/recovery, IFAK, attachments ×6, store purchase dispatch, audio bus creation, viewmodel construction, feedback/shake, death |
| `Zombie.gd` | 1,327 | 9-state machine, leap ballistics, structure attack, footsteps, screech, UAV silhouette, hitbox debug, hit flash, scoring |
| `Main.gd` | 1,146 | world geometry, ground-hole decomposition, lighting, NVG whiteout, two navmesh regions, wave director, all-clear, 7 UI systems' wiring, 9 debug keys, fighter spawning |

**Recommendation.** Extract by responsibility, not by line count:
- `Player` → `LaserSight` (render + detection), `WeaponController` (fire/reload/
  ray), `Equipment` (grenade/claymore slot), `Inventory` (owned/attachments/
  consumables + the store dispatch), `PlayerAudio`, `Mantle`.
- `Main` → `WorldBuilder`, `NavmeshManager` (the two-region dance + rebake
  queue), `WaveDirector` (spawn/all-clear/carryover), `DebugKeys`.
- `Zombie` → a `LeapBehaviour` child; UAV silhouette and footsteps as
  components. The state machine can stay an enum for now.

### 3.2 Eleven autoloads

`GameManager` is referenced 57 times from 14 files; `AreaDamageSystem` from 16
files; `PointsManager` from 12. `StoreCatalog`, `AmmoManager`, `Arsenal`,
`EnablerManager`, `ObstacleCatalog`, `UAVSystem` are all global state. Every
system reaches sideways into every other; nothing can be instantiated alone,
which is also why there were no tests.

**Recommendation.** Keep the two that are genuinely global *events*
(`NoiseManager`, `GameManager` as the clock). Make the rest owned by `Main`
(or a `Game` node) and handed to the systems that need them. `Arsenal` and
`ObstacleCatalog` are static data and could be plain `Resource`s loaded where
needed.

### 3.3 Three damage verbs is a symptom, not a design

`take_damage(amount, headshot, falloff)`, `take_melee_damage(amount, source)`,
`take_area_damage(amount, origin)` exist because the first two had
incompatible signatures and "a non-null Vector3 is truthy, so every blast
would register as a headshot" (`AreaDamageSystem.gd` header,
`Zombie.gd:980-995`). Three `has_method()` duck-typed contracts, three group
names, and a `Damageable` static class to resolve hits, all working around the
absence of one thing: a typed damage event.

**Recommendation.** A `Health` component (`hp`, `max_hp`, `died`, `damaged`)
plus a `DamageInfo` resource/class (`amount`, `kind: BULLET|MELEE|BLAST`,
`source`, `is_headshot`, `falloff_mult`). One verb: `take_damage(info)`. The
headshot/falloff ordering lives in one function. Player, Zombie, Fighter and
SandbagPanel all carry the same component; `HealthBar3D` reads it directly.

**Status: addressed for actors.** Player, Zombie and Fighter each own a
`Health` and take every hit through `take_damage(info: DamageInfo)`; the three
verbs are gone, and behaviour is unchanged (pinned first by
`tools/damage_tests.tscn`). `HealthBar3D` reads a fighter's `Health` directly.
`SandbagPanel` was deliberately left out: obstacle damage stays on its own
`take_structure_damage()` path. The groups are unchanged, since they decide
who a round or blast can reach, which is a separate question.

### 3.4 Stringly-typed everything

Store items dispatch on `match item.kind: "weapon" | "ammo" | "attachment" |
"consumable" | "equipment"` and `attachment_type: "foregrip" | "choke" | …`
inside `Player.gd` (`owns_store_item`, `apply_store_purchase`,
`store_item_blocked`). Enablers are plain Dictionaries with `call_fn` /
`available_fn` (deferred "until a real enabler defines what fields it needs" —
there are now six, so the fields are known). Groups are magic strings
(`"zombies"`, `"sandbags"`, `"player"`, `"claymores"`).

**Recommendation.** `StoreItem` gets a `grant: Callable` or a small
`Purchasable` interface so adding an item never touches `Player.gd` (the spec
already predicted "expect the same two edits in Player.gd"). `EnablerType`
resource now. Group names as constants on the class that owns them (half are
already).

### 3.5 Zombies are blind

This is architecture *and* design, so it appears in both sections. A zombie
acquires the player only by (a) being shot, (b) investigating a *laser dot*
and seeing the player within 16m, or (c) proximity transitions out of states
it is already in. `_do_wander()` "never reads the player's position"
(`Zombie.gd:422-428`); noise investigation "deliberately never looks for the
player" (`:434-438`). There is no sight cone, no awareness level.

Consequence: a player can walk in circles 1m from an active zombie at night,
making 5m footstep noise, indefinitely. The zombie investigates the spot,
arrives, finds "nothing", wanders. Stand still and it will never attack.

**Recommendation.** A short sight check in Wander/Investigate: cone (~90°),
range scaled by player state (crouch 4m / walk 8m / sprint 12m / muzzle-flash
or red-laser-on 20m), through `LineOfSight.between()`. That turns crouching
into a real decision instead of a free invisibility toggle, and it is ~20
lines on top of infrastructure that already exists.

**Status: addressed** (`a462fe1`), with different numbers than proposed here.
Sight runs in Wander and Investigate at night through `LineOfSight.between()`:
a 120° flat cone, 12m for the walker and 18m for the leaper, halved when
crouched, rather than a range per movement state. Seen for 0.75s → Chase;
seen for 0.25s and then lost → Investigate the last-seen spot. Tunables live on
`ZombieType`, validated at startup. Path (b) is unchanged: a zombie
investigating a laser dot still sees the player within 16m
(`Zombie.LASER_INVESTIGATE_SIGHT`). The radius at which the dot draws zombies
in the first place is now 20m (`Player.LASER_DETECT_RADIUS`; it was 15m).

### 3.6 Per-frame group scans

`Zombie._nearest_hostile_target()` walks `GROUP_HOSTILE_TARGET` on *every
query* at the default `target_reevaluate_interval = 0.0` — several times per
zombie per physics frame (`Zombie.gd:1001-1010`). `Fighter.acquire_target()`
walks every zombie with a raycast each, every 0.25s. `UAVOverlay`,
`ApacheSystem`, `Claymore` and `_update_laser_detection` all scan
`"zombies"`. 20 `get_nodes_in_group` call sites. Fine at 20 zombies; the
Apache and the map scale (§4.5) imply more.

**Recommendation.** Set `target_reevaluate_interval` to 0.25 (the refactor that
added it explicitly kept 0.0 to be behaviour-identical — that constraint is
over). A `Targets` registry on `Main` that zombies read instead of the tree.

**Status: partly addressed** (`a462fe1`). The interval is now 0.25. The
`Targets` registry has not been built.

### 3.7 Input

Seven actions are in the InputMap; everything else is hardcoded keycodes
(`KEY_C/R/B/H/1-5/ESCAPE` in `Player._unhandled_input`, `KEY_W/A/S/D/SHIFT`
polled by physical keycode, nine debug keys in `Main`). No rebinding, no
gamepad, and the spec devotes paragraphs to key-collision arbitration (N doing
double duty; T toggling; Esc meaning different things per menu).

**Recommendation.** All actions into the InputMap, one `UIStack` that owns
focus (open/close, who gets Esc, who halts the clock) instead of each of the
five menus inventing its own rules and `_ads_suppressed_until_release`-style
flags.

### 3.8 Persistence is partial

`GameState` captures obstacles, night and points, and the spec notes IFAKs,
grenades, claymores, fighters and attachments are all missing
(`V2_SPEC.md §6.8, §9.8`). Nothing writes to disk. A "scene change" is
designed for but nothing performs one.

**Recommendation.** Defer until §1 decides whether runs persist at all. If
they do, serialise the `Inventory` component (§3.1) and the fighter roster in
one pass.

### 3.9 Smaller things worth knowing

- `GameManager.NIGHT_LENGTH` is `@export` on an autoload — it never reaches an
  inspector, same problem the spec identifies for `UAVSystem`.
- `Zombie.take_damage()` has no day gate: dormant day-time zombies can be
  executed for full points (`_die()` → `PointsManager.add_points`). With
  carryover, a bad night is a free point piñata the next morning. Either
  despawn at dawn, or 0 points by day.
  **Status: addressed** (`6fb5019`), and both were done. At dawn survivors
  retreat past the tree line and despawn (or despawn in place after 20s),
  and carry into the next night as a count. Day kills score 0, except
  claymore and minefield kills.
- Headless Godot does not throttle `_process`; 900 idle frames in the smoke
  test are ~380 physics ticks (~6s), not the "~15s" the comment says.
  Anything timed in `_process` (the day/night clock, enabler cooldowns) runs
  at a different rate headless than in-editor.
- The ditch's ground hole and navmesh patch use the AABB, not the rotated
  footprint (`PROJECT_SPEC.md`, "Known approximation"). The two-region
  navmesh hack exists because `NavigationObstacle3D` was rejected on a
  description that reads as pre-4.2; its `affect_navigation_mesh` /
  `carve_navigation_mesh` in 4.3 may do the job with one region.
- A freed `Object` compares `== null` in Godot 4. The smoke test had this bug;
  `grep -n '== null' scripts/*.gd` on any variable that can hold a freed node
  is worth a pass (`Fighter._engage_target` is checked in the right order;
  others were not audited).

---

## 4. Game design

### 4.1 Day is a pause menu wearing a costume

Day is 30s. The two things you do by day — build mode and the roster — halt the
clock. The crate does not, but it is open at night anyway. So "Day" has
become: a 30s buffer that pauses when you use it. The spec default of 6-minute
nights was abandoned for a "playtest cadence" that has now shaped every
enabler's numbers (§4.5).

**Question.** Should Day be timed at all? If the answer is "Day is the
planning phase, take as long as you like", say so and remove the clock. If Day
should have pressure (dawn work before the next night), it needs more than 30s
and things to do under that pressure.

### 4.2 Stealth is solved on purchase

The concept is noise and light discipline. In practice: crouch is silent
*and* invisible (§3.5); an IR laser is 8 points and removes the light channel
for that weapon; a suppressor removes the noise channel. After one night the
stealth game is over. Nothing escalates against it — no zombie that hears
better, sees further, or hunts in groups.

**Recommendation.** Stealth counters that scale with nights: a variant that
investigates toward the *player* not the spot; a "screamer" that alerts
others; sight that improves after night N. The leaper is a *mobility*
counter; stealth has none.

### 4.3 The economy was priced without a curve

The spec admits it: "every price above was set by feel, not from measurement"
and telemetry was only added later. A perfect night 1 earns 18; realistic
8–12. Prices run from 6 (grenade) to 90 (Apache, M110 suppressor). IFAK is
15 — "60–125% of a night" — for 40 HP, when death is free (§1). A full radio
kit (radio 10 + Apache 90 + mortar 50) is a perfect night 8 or several real
ones. Sandbags cost 10 and a wall can be chewed through in ~80s.

**Recommendation.** Decide the target: "by night N a competent player owns
X", write the curve, then price against it. Until §1 is answered, pricing is
unmeasurable because loss is free.

### 4.4 Too much content for the loop — a cut list to argue about

For a 60×60m map, 120s nights, 2 variants and no objective, candidates to
*shelve* (not delete — branch them):

| Shelve | Why |
|---|---|
| Apache patrol box | 250m standoff orbit over a 60m map; sortie (115s) is longer than a night; its own spec says it has "no in-fiction drawback" and may be "press-to-win" |
| 120mm mortar + WP | 8s flight + 18s barrage on a 120s night; 10m radius on a map where zombies spawn 25m out |
| UAV | Wall-hack on a map you can see across |
| M110 + variable zoom | "The answer for the far edge of the 60m map" is a 3x scope; the 416 now dominates it on damage anyway (`V2_SPEC.md §4.4` flagged) |
| Breacher choke, foregrip | Attachments whose effect a playtester cannot feel on a greybox |
| Cover/concealment debug overlays, sector preview | Built for a placement mode that does not exist |

Keep: M17/416/SPAS/SAW, suppressor, IR, NVG, sandbags, wire, ditch, mines,
grenade, claymore, fighters (once placement exists), walker/leaper.

**Question.** Which of the shelved items is load-bearing for the fantasy in
§1? That is the only argument for keeping any of them now.

### 4.5 Scale mismatch

Zombies spawn 21–29m from centre; that is 6–8 seconds of chase speed. Fire
support is designed for a battlefield; the map is a backyard. Nights are 2
minutes; enabler cooldowns are 3–5 minutes (i.e. once per 2–3 nights — fine,
but then the "per-night" UAV and the sunrise-departure logic are fighting the
clock). Either the map and night length grow, or the enablers shrink. Both are
currently specified against each other.

### 4.6 Fighters are half of a feature

Stationary, no placement UI ("spawns in front of the player"), first four free
as a placeholder for a map that does not exist, and an unsuppressed fighter is
a 40m noise beacon every 1.2s — a genuine liability without the 25-point
suppressor each. The roster/upgrade/suppressor economy is complete; the thing
that makes them matter (placement into a defence) is not.

**Recommendation.** Either build placement (ghost + sector preview — the preview
already exists) or shelve the roster until Position Two.

### 4.7 Escalation is one-dimensional

More zombies, more HP, a leaper fraction. No new behaviours, no pressure on
the base (zombies only attack sandbags when there is no path to the player),
no night with a different shape. Ten nights of the same night with bigger
numbers.

**Recommendation.** Three or four *scripted* night types (siege night: they
attack the walls; runner night; quiet night with one big thing) beat an
infinite linear ramp, and they give the run (§1) a story.

### 4.8 Small design holes

- Out of ammo and no melee: the player is helpless; the "fix" is to die and
  respawn with full HP (and still no ammo). A knife or stock-bash closes it.
- Dormant zombies standing inside the base all day (carryover) can be shot for
  points at no risk (§3.9). **Addressed** (`6fb5019`).
- The crate at night "does not pause" — but neither does anything threaten a
  player who stands still (§3.5), so the exposure the spec describes is
  theoretical.
- `N` doubles as NVG toggle and "finish the night"; `T` opens and closes the
  radio; `Esc` closes some menus and toggles the mouse in others. Each is
  justified in prose; together they are a usability bill.

---

## 5. A suggested order of operations

1. **Answer §1** (run structure, fail state). Nothing below is priced or
   balanced until this exists. **Fail state done** (`3c239de`); run
   structure still open.
2. **Freeze features.** Shelve §4.4 to a branch.
3. **Give zombies sight** (§3.5) and **gate day-time kills** (§3.9). Two small
   changes that make the existing loop a game. **Done** (`a462fe1`,
   `6fb5019`).
4. **Docs collapse** (§2.1) + `CLAUDE.md` rules file (§2.2). Cheap, and every
   session after it is better.
5. **Tests for the prose tables** (§2.3); move balance asserts into them
   (§2.4).
6. **Health/DamageInfo component** (§3.3) — the refactor with the best
   payoff-to-risk ratio, because the three verbs are already funnelled.
   **Done for actors**; sandbags left on their own path.
7. **Split `Player.gd`** (§3.1), starting with `LaserSight` and `Inventory`,
   which are the most self-contained.
8. **Playtest the 10-minute loop** with a stopwatch and the ECONOMY log, then
   price (§4.3).
9. UI to scenes, input to InputMap, `UIStack` (§2.5, §3.7) — as each menu is
   next touched.

---

## 6. Things to ask Claude Chat directly

- "Roguelite or campaign?" (§1) — with the economy consequences of each.
- "What should a zombie be able to perceive, at what range, in what state?"
  (§3.5, §4.2) — write the table before writing code.
- "Which three enablers survive a cut to a 60×60m map and 3-minute nights?"
- "Design three night archetypes for a 7-night run." (§4.7)
- "Given `DamageInfo`, what does `Health` need to expose so `HealthBar3D`,
  the hitmarker, the kill tally and the fighter roster all read one thing?"
- "What are the ten rules that go in `CLAUDE.md`?"
