extends Node
## Weapon registry (autoload). Builds the WeaponData definitions in code so the
## roster is a single source of truth for the player and the crate shop.
## Full roster per PROJECT_SPEC.md "Weapons".
##
## Ammo is scarce: every weapon ships with `starting_mags` = 2 (one loaded, one
## spare) and is topped up only by buying magazines at the crate.

var weapons: Dictionary = {}
var order: Array[String] = ["m17", "hk416", "spas12", "m249"]

func _ready() -> void:
	_add({
		"id": "m17", "display_name": "Sig Sauer M17", "fire_mode": WeaponData.FireMode.SEMI,
		"mag_size": 17, "starting_mags": 2, "ammo_cost": 1,
		"fire_interval": 0.15, "reload_time": 1.6,
		"body_damage": 34, "hip_spread_radius": 80.0, "recoil_per_shot": 0.03,
		"max_range": 150.0, "noise_unsuppressed": 40.0, "noise_suppressed": 8.0, "cost": 0,
		# Pistol: reliable in close, meaningfully weaker at rifle ranges.
		"falloff_near": 25.0, "falloff_mid": 60.0, "falloff_mid_mult": 0.70,
		"falloff_far": 100.0, "falloff_far_mult": 0.50,
	})
	_add({
		"id": "hk416", "display_name": "HK 416", "fire_mode": WeaponData.FireMode.BOTH,
		"mag_size": 30, "starting_mags": 2, "ammo_cost": 2,
		"fire_interval": 0.09, "reload_time": 2.0,
		"body_damage": 30, "hip_spread_radius": 55.0, "recoil_per_shot": 0.025,
		"max_range": 200.0, "noise_unsuppressed": 45.0, "noise_suppressed": 10.0, "cost": 15,
		# Semi-auto is the long-range answer: a 0.1 deg cone is effectively a
		# laser at map scale, and damage only drops 15% by 85m.
		"ads_cone_deg": 0.1,
		"falloff_near": 30.0, "falloff_mid": 85.0, "falloff_mid_mult": 0.85,
		"falloff_far": 120.0, "falloff_far_mult": 0.85,
		# Full auto walks off target fast; semi stays the precise choice at range.
		"auto_penalty": WeaponData.AutoPenalty.RAMP,
		"auto_recoil_start_mult": 1.4, "auto_recoil_growth": 0.12,
		"auto_recoil_max_mult": 3.5, "horizontal_recoil": 0.014,
		"bloom_min_deg": 0.3, "bloom_max_deg": 4.0, "bloom_shots_to_max": 10,
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
		"max_range": 220.0, "noise_unsuppressed": 55.0, "noise_suppressed": 14.0, "cost": 30,
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

func _add(dict: Dictionary) -> void:
	var w := WeaponData.new()
	for key in dict:
		w.set(key, dict[key])
	weapons[w.id] = w

func get_weapon(id: String) -> WeaponData:
	return weapons.get(id)
