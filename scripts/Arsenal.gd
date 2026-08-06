extends Node
## Weapon registry (autoload). Builds the WeaponData definitions in code so the
## roster is a single source of truth for the player and the crate shop.
## Full roster per PROJECT_SPEC.md "Weapons".
##
## Ammo is scarce: every weapon ships with `starting_mags` = 2 (one loaded, one
## spare) and is topped up only by buying magazines at the crate.

var weapons: Dictionary = {}
var order: Array[String] = ["m17", "hk416", "spas12", "m249", "m110"]

func _ready() -> void:
	_add({
		"id": "m17", "display_name": "Sig Sauer M17", "fire_mode": WeaponData.FireMode.SEMI,
		"mag_size": 17, "starting_mags": 2, "ammo_cost": 1,
		"fire_interval": 0.15, "reload_time": 1.6,
		"body_damage": 34, "hip_spread_radius": 80.0, "recoil_per_shot": 0.03,
		"max_range": 150.0, "noise_unsuppressed": 40.0, "noise_suppressed": 8.0, "cost": 0,
		# Pistol: full damage in close, linear falloff to 40% by 40m. Uses the
		# simple 2-point model rather than the piecewise falloff_near/mid/far
		# one the SPAS and M249 use — a weapon picks exactly one model (see
		# WeaponData.damage_mult_at()), so falloff can never double-apply.
		# This is the pattern for future falloff tuning; set the piecewise
		# fields only when a curve genuinely needs three segments.
		"use_simple_falloff": true, "falloff_start_distance": 15.0,
		"falloff_end_distance": 40.0, "falloff_min_multiplier": 0.4,
	})
	_add({
		"id": "hk416", "display_name": "HK 416", "fire_mode": WeaponData.FireMode.BOTH,
		"mag_size": 30, "starting_mags": 2, "ammo_cost": 2,
		"fire_interval": 0.09, "reload_time": 2.0,
		# 66, up from 30. NOT a taste-based number: it is the MINIMUM integer
		# that satisfies the requested invariant "the 416 kills in strictly
		# fewer headshots than the M17 at every night tier and every range".
		# The binding case is a night-9/10 zombie (132 HP) at point-blank,
		# where the M17 headshots for 68 and kills in 2 — beating that
		# strictly means a ONE-headshot kill, i.e. >= 132 headshot damage,
		# i.e. >= 66 body. See PATROL_BASE_ZERO_V2_SPEC.md "Weapon damage"
		# for the full derivation and for the roster consequence (this now
		# exceeds the M110's 60), which is flagged, not silently softened.
		"body_damage": 66, "hip_spread_radius": 55.0, "recoil_per_shot": 0.025,
		"max_range": 200.0, "noise_unsuppressed": 45.0, "noise_suppressed": 10.0, "cost": 15,
		# Semi-auto is the long-range answer: a 0.1 deg cone is effectively a
		# laser at map scale.
		"ads_cone_deg": 0.1,
		# NO falloff: flat damage to max_range. Achieved by absence — with no
		# falloff fields set at all, WeaponData's inert defaults (9999 / 1.0)
		# make damage_mult_at() return 1.0 everywhere.
		# Rifle rounds carry through flesh: up to 2 zombies BEHIND the first,
		# at 60% each. Never through obstacles/sandbags/the player — see
		# Player._fire_ray(), which stops the ray on any non-zombie collider.
		"max_penetration_targets": 2, "penetration_damage_multiplier": 0.6,
		# Full auto walks off target fast; semi stays the precise choice at range.
		"auto_penalty": WeaponData.AutoPenalty.RAMP,
		"auto_recoil_start_mult": 1.4, "auto_recoil_growth": 0.12,
		"auto_recoil_max_mult": 3.5, "horizontal_recoil": 0.014,
		"bloom_min_deg": 0.3, "bloom_max_deg": 4.0, "bloom_shots_to_max": 10,
		# Moving-fire penalty (Foregrip tightens this specifically — see
		# Player.gd _fire()). No prior mechanic existed for this; 1.0° is a
		# fresh baseline, not a measured pre-existing value.
		"moving_cone_extra_deg": 1.0,
	})
	_add({
		"id": "spas12", "display_name": "SPAS-12", "fire_mode": WeaponData.FireMode.SEMI,
		"mag_size": 8, "starting_mags": 2, "ammo_cost": 2,
		"fire_interval": 0.7, "reload_time": 3.0,
		# Dominates 0-10m, falls off hard past 20m. 9 x 22 = 198 at point blank,
		# so ~5 pellets on target one-shots a 100HP zombie (6 at night-10's 132).
		"body_damage": 22, "pellets": 9, "pellet_spread_deg": 3.0,
		"hip_spread_radius": 45.0, "recoil_per_shot": 0.09,
		"max_range": 40.0, "noise_unsuppressed": 50.0, "noise_suppressed": 12.0, "cost": 20,
		"falloff_near": 10.0, "falloff_mid": 20.0, "falloff_mid_mult": 0.40,
		"falloff_far": 30.0, "falloff_far_mult": 0.15,
		# Tube-fed: 0.35s in + 0.55s/shell + 0.35s out, interruptible by firing.
		"shell_reload": true, "shell_time": 0.55,
		"reload_start": 0.35, "reload_end": 0.35,
	})
	_add({
		"id": "m249", "display_name": "M249 SAW", "fire_mode": WeaponData.FireMode.AUTO,
		"mag_size": 100, "starting_mags": 2, "ammo_cost": 4,
		"fire_interval": 0.08, "reload_time": 5.0,
		"body_damage": 28, "hip_spread_radius": 110.0, "recoil_per_shot": 0.03,
		# Noise 47m, down from 55m. The SAW and the 416 are the same cartridge
		# (5.56x45 NATO), so a single report should sound broadly the same —
		# the SAW's threat is its volume of fire, not a louder muzzle blast.
		# 2m over the 416's 45m is the whole difference, for the longer barrel
		# and open-bolt action. This also puts the roster in caliber order:
		# 9mm 40 < 5.56 45/47 < 7.62 48 < 12ga 50.
		"max_range": 220.0, "noise_unsuppressed": 47.0, "noise_suppressed": 14.0, "cost": 30,
		# Penalty is driven by stance, not shot count: controllable prone-ish
		# (crouched), sloppy standing, near-useless on the move.
		"auto_penalty": WeaponData.AutoPenalty.STANCE,
		"horizontal_recoil": 0.016,
		# Bloom tightened so a crouched (1.1x) 3-5 round burst still lands on a
		# torso at 60m (~0.5m spread), while moving (3.0x) scatters to ~1.4m.
		"bloom_min_deg": 0.08, "bloom_max_deg": 0.8, "bloom_shots_to_max": 10,
		"falloff_near": 30.0, "falloff_mid": 85.0, "falloff_mid_mult": 0.80,
		"falloff_far": 120.0, "falloff_far_mult": 0.80,
	})
	_add({
		"id": "m110", "display_name": "KAC M110", "fire_mode": WeaponData.FireMode.SEMI,
		"mag_size": 20, "starting_mags": 2, "ammo_cost": 3,
		# Cycle time 0.24s = 4.17 rps = 37.5% of the 416's 11.11 rps
		# (fire_interval 0.09) — cut down from the first pass's 0.16s/56%,
		# which read as no real rate-of-fire tradeoff at all. See
		# PROJECT_SPEC.md "Weapons" for the resulting per-shot vs per-second
		# comparison against the 416.
		"fire_interval": 0.24, "reload_time": 2.4,
		# 60 dmg: 2 body shots (120) kills a 100 HP baseline zombie with margin;
		# a headshot (x2 = 120) is a clean one-shot. Meaningfully above the
		# 416's 30 — that's the point of the gun. Unchanged from the first
		# pass — only rate of fire and moving accuracy change here.
		"body_damage": 60, "hip_spread_radius": 70.0, "recoil_per_shot": 0.06,
		"horizontal_recoil": 0.02,
		# Tight standing/crouched cone — comparable to or tighter than the
		# 416's 0.1°. No auto_penalty is set (defaults to NONE), so none of
		# the bloom/ramp systems can touch this weapon; it has no auto mode.
		"ads_cone_deg": 0.08,
		# Moving-fire penalty: 2.5°, well above the 416's 1.0° — a precision
		# weapon meant to be fired from a stable stance. Stationary/crouched
		# (ads_cone_deg above) is completely unaffected; this only stacks on
		# top while is_moving is true, same mechanism as the 416's.
		"moving_cone_extra_deg": 2.5,
		"max_range": 250.0, "noise_unsuppressed": 48.0, "noise_suppressed": 11.0, "cost": 45,
		# No falloff at all — the DMR is meant to work at the far edge of the
		# 60x60m map (≈85m diagonal) with zero penalty, stronger than the
		# 416's "minimal" ≤15% loss.
		# Built-in fixed 3x scope: FOV = 2*atan(tan(37.5°)/3) ≈ 28.7°, derived
		# from the player's 75° hip FOV so 1x reads as "no zoom" consistently.
		"ads_fov": 28.7,
	})

	_validate_damage_invariants()

# --- Startup invariants ---------------------------------------------------
## INVARIANT: the HK 416's effective per-shot damage must exceed the M17's at
## EVERY distance from 0 to the M17's max range, using each weapon's own
## falloff curve.
##
## This exists because the exact inversion it forbids is what shipped: the
## 416 sat at 30 base damage against the M17's 34, so the free starter pistol
## out-damaged the 15-point rifle inside the M17's full-damage band and
## killed late-night zombies in fewer headshots. That is a data error no
## reader can see by looking at either weapon's definition alone — it only
## appears when the two curves are compared across the whole range band — so
## it is asserted rather than left to review.
##
## Compared on BODY damage: the headshot multiplier is a single shared
## constant applied identically to both weapons downstream (Zombie.gd's
## HEADSHOT_MULT), so it cancels out of the comparison entirely. Checking
## the body figure proves the headshot figure. Deliberately NOT reaching
## into Zombie.gd for the constant — that would need a class_name added
## purely to satisfy this check.
func _validate_damage_invariants() -> void:
	var m17 := get_weapon("m17")
	var hk := get_weapon("hk416")
	if m17 == null or hk == null:
		return
	# 0.25m steps: fine enough to catch a crossing anywhere in a falloff
	# ramp, and this runs once at startup, not per frame.
	var step := 0.25
	var d := 0.0
	var limit: float = maxf(m17.max_range, hk.max_range)
	while d <= limit:
		var m17_dmg: float = float(m17.body_damage) * m17.damage_mult_at(d)
		var hk_dmg: float = float(hk.body_damage) * hk.damage_mult_at(d)
		assert(hk_dmg > m17_dmg,
			"WEAPON BALANCE INVARIANT VIOLATED at %.2fm: HK 416 deals %.2f but M17 deals %.2f. The 416 must out-damage the M17 at every range — see Arsenal._validate_damage_invariants()." % [d, hk_dmg, m17_dmg])
		# asserts are stripped from release builds, so fail loudly there too.
		if hk_dmg <= m17_dmg:
			push_error("WEAPON BALANCE INVARIANT VIOLATED at %.2fm: HK 416 %.2f <= M17 %.2f" % [d, hk_dmg, m17_dmg])
			return
		d += step

func _add(dict: Dictionary) -> void:
	var w := WeaponData.new()
	for key in dict:
		w.set(key, dict[key])
	weapons[w.id] = w

func get_weapon(id: String) -> WeaponData:
	return weapons.get(id)
