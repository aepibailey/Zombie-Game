extends Node
## Weapon registry (autoload). Builds the WeaponData definitions in code so the
## roster is a single source of truth for the player and the crate shop.
## Full roster per PROJECT_SPEC.md "Weapons"; v1 shipped the M17 only.

var weapons: Dictionary = {}
var order: Array[String] = ["m17", "hk416", "spas12", "m249"]

func _ready() -> void:
	_add({
		"id": "m17", "display_name": "Sig Sauer M17", "fire_mode": WeaponData.FireMode.SEMI,
		"mag_size": 17, "spare_ammo": 85, "fire_interval": 0.15, "reload_time": 1.6,
		"body_damage": 34, "hip_spread_radius": 80.0, "recoil_per_shot": 0.03,
		"max_range": 150.0, "noise_unsuppressed": 40.0, "noise_suppressed": 8.0, "cost": 0,
	})
	_add({
		"id": "hk416", "display_name": "HK 416", "fire_mode": WeaponData.FireMode.BOTH,
		"mag_size": 30, "spare_ammo": 120, "fire_interval": 0.09, "reload_time": 2.0,
		"body_damage": 30, "hip_spread_radius": 55.0, "recoil_per_shot": 0.025,
		"max_range": 200.0, "noise_unsuppressed": 45.0, "noise_suppressed": 10.0, "cost": 15,
	})
	_add({
		"id": "spas12", "display_name": "SPAS-12", "fire_mode": WeaponData.FireMode.SEMI,
		"mag_size": 8, "spare_ammo": 40, "fire_interval": 0.7, "reload_time": 3.0,
		"body_damage": 14, "pellets": 8, "pellet_spread_deg": 4.0,
		"hip_spread_radius": 45.0, "recoil_per_shot": 0.09,
		"max_range": 40.0, "noise_unsuppressed": 50.0, "noise_suppressed": 12.0, "cost": 20,
	})
	_add({
		"id": "m249", "display_name": "M249 SAW", "fire_mode": WeaponData.FireMode.AUTO,
		"mag_size": 100, "spare_ammo": 200, "fire_interval": 0.08, "reload_time": 5.0,
		"body_damage": 28, "hip_spread_radius": 110.0, "recoil_per_shot": 0.03,
		"max_range": 220.0, "noise_unsuppressed": 55.0, "noise_suppressed": 14.0, "cost": 30,
	})

func _add(dict: Dictionary) -> void:
	var w := WeaponData.new()
	for key in dict:
		w.set(key, dict[key])
	weapons[w.id] = w

func get_weapon(id: String) -> WeaponData:
	return weapons.get(id)
