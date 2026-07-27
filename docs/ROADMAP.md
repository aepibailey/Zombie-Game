# Roadmap — Support Enablers

Planned but **not built**. Captured here so current architecture stays
compatible. See `PROJECT_SPEC.md` for everything that is implemented.

## Concept

Purchasable, killstreak-style support items bought with points at the supply
crate. The **Radio is the gateway purchase** — every other enabler requires it.

| Enabler | Requires | Effect |
|---|---|---|
| **Radio** | — | Comms link. Prerequisite for all enablers below. |
| **UAV** | Radio | Pings nearby zombies (reveals positions for a duration). |
| **Apache** | Radio | Kills zombies within 15m of the player. |
| **Supply Drop** | Radio | Resupplies ammo for **every owned weapon**. |

## Structure

- **Radio-as-prerequisite** is modelled by the generic prerequisite field the
  store already honours (`requires`). Nothing gameplay-facing needs to change
  to gate an item behind the Radio.
- `EnablerManager` (autoload) is the ownership registry — currently a stub with
  an owned dictionary, `has()`, `acquire()`, and no gameplay logic.
- Enablers will get their own **ENABLERS** store tab. Because the store builds
  tabs from `StoreCatalog.categories()`, that is a catalog change, not a UI
  rewrite. The Radio currently sits under WEAPONS as a stopgap and moves then.

## Compatibility checklist (verified this pass)

- ✅ **Prerequisite purchases** — `StoreItem.requires` is honoured by the store's
  purchase path and renders a `LOCKED` state naming the missing item. Wired and
  dormant; nothing uses it yet.
- ✅ **`AmmoManager.grant_ammo(weapon_id, magazines)`** is the single ammo entry
  point. A supply drop calls it in a loop over owned weapons — no refactor.
- ✅ **`SupplyDrop`** is a reusable scene taking a contents config, a spawn
  anchor, and a radius. The purchasable version instances the same scene with
  the player as anchor instead of the crate.
- ✅ **Drop scheduling** lives in `EnablerManager.guaranteed_drop_nights`,
  outside the scene, so the free-drop stopgap can be disabled wholesale.

## Known friction for later (flagged, not fixed)

1. **Player owns too much weapon state.** Loaded magazines, suppressor flags,
   and the owned-weapon list all live on `Player.gd`. Enablers that modify
   loadout (or any future save/load) would be cleaner with a `Loadout` object
   separate from the controller. Not urgent, but it grows with each enabler.
2. **No cooldown/duration primitive.** UAV (timed reveal) and Apache (one-shot
   with cooldown) both need "active for N seconds" and "usable again in N
   seconds". There's nothing generic for this — worth one small timer helper
   rather than three bespoke implementations.
3. **Zombie reveal has no channel.** The UAV needs to mark zombies as visible
   through geometry. There's no outline/marker system; it'd need either a HUD
   marker pass or a material swap. Decide which before building the UAV.
4. **Apache's 15m kill** needs a damage-source concept for scoring. Kills
   currently award points to the player unconditionally via `PointsManager`;
   if enabler kills should score differently, `Zombie._die()` needs to know
   what killed it. Cheap to add now, annoying to retrofit later.
