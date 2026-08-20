extends Node
class_name FireMissionSystem
## Runs radio-called indirect fire: paint a point, wait out the time of
## flight, then land a scattered sheaf of rounds over a duration.
##
## OWNS NO DAMAGE CODE. Every round is one AreaDamageSystem.detonate() call
## with an AreaDamageProfile — the blast geometry, falloff, line-of-sight
## cover, faction-blind targeting, obstacle damage and per-round noise all
## live in the .tres. This script only decides WHERE and WHEN rounds land.
##
## Registers its missions into EnablerManager.callable_enablers, so they
## appear in the radio menu with no menu-side changes. Adding a third fire
## mission is a FireMissionConfig .tres plus one line in _register().

## Missions this system offers, in menu order. Both are pure configuration —
## the 120mm and the shake-and-bake run the identical pipeline, and the only
## code difference between them is that a nonzero wp_radius leaves a burn
## zone behind (see _finish_mission()).
@export var missions: Array[FireMissionConfig] = []

## How far the player may paint a fire mission from their own position.
## Shared by every mission here rather than per-config: this is a property of
## the radio/observer, not of the ordnance.
@export var paint_max_range: float = 150.0

## Rounds land at a random point within the scatter locus (see
## _scatter_radius()) of the painted point. This biases WHERE in that circle:
## 1.0 = uniform over the disc, higher values cluster toward the centre. Not
## uniform by default — a real sheaf groups around the aim point rather than
## scattering evenly to the edge.
@export var impact_centre_bias: float = 1.6

## Vertical offset the blast originates at. Rounds detonate on impact, so
## slightly above the ground rather than exactly on it — a blast originating
## at y=0 can have its line-of-sight traces clipped by the very surface it
## landed on.
@export var impact_height: float = 0.4

var _player: Player
var _hud: HUD
var _painter: TargetPainter
var _radio: RadioMenu

## Only ONE fire mission may be in flight at a time, across every config.
## Shared deliberately: a shake-and-bake stacked on top of an in-flight HE
## mission would be two overlapping barrages the player cannot read.
var _active_mission_id := ""

func setup(player: Player, hud: HUD, painter: TargetPainter, radio: RadioMenu) -> void:
	_player = player
	_hud = hud
	_painter = painter
	_radio = radio
	_validate()
	_register()

## INVARIANT: config.effect_radius is GROUND TRUTH — the paint circle the
## player aims with, and the true outer bound of everything a mission can
## damage. That only holds because rounds are never scattered across the
## whole circle: _scatter_radius() insets the landing locus by
## he_profile.max_radius, so a round landing at the very edge of its scatter
## locus still can't blast past effect_radius. If a mission's effect_radius
## and he_profile.max_radius ever diverge the wrong way, the preview would be
## lying about where damage can reach — the one thing a targeting marker must
## never do.
func _validate() -> void:
	for m in missions:
		if m == null:
			push_error("[FIREMISSION] null entry in missions[]")
			continue
		if m.he_profile == null:
			push_error("[FIREMISSION] '%s' has no he_profile" % m.id)
			continue
		if m.round_count <= 0:
			push_error("[FIREMISSION] '%s' has round_count %d" % [m.id, m.round_count])
		if m.effect_radius <= 0.0:
			push_error("[FIREMISSION] '%s' has effect_radius %.1f" % [m.id, m.effect_radius])
		elif m.effect_radius < m.he_profile.max_radius:
			# Not fatal — _scatter_radius() clamps to 0 and every round lands
			# dead on the paint point — but it means the mission was tuned
			# with a paint circle smaller than one round's own blast reach,
			# which is almost certainly not what was intended.
			push_warning("[FIREMISSION] '%s' has effect_radius %.1f smaller than he_profile.max_radius %.1f — every round will land on the paint point" % [
				m.id, m.effect_radius, m.he_profile.max_radius])

func _register() -> void:
	for m in missions:
		if m == null:
			continue
		# Captured per-iteration so each entry's callables bind to their own
		# config rather than all sharing the loop's last value.
		var cfg := m
		EnablerManager.callable_enablers.append({
			"id": cfg.id,
			"display_name": cfg.display_name,
			"cost": cfg.cost,
			"call_fn": func(): _begin_paint(cfg),
			"available_fn": func() -> String:
				# Cooldown and the global lockout are answered by
				# EnablerManager itself; this only adds the reason it alone
				# knows about.
				return "IN FLIGHT" if _active_mission_id != "" else "",
		})

# --- Call flow ---------------------------------------------------------------
## Radio selection opens paint mode. NOTHING is charged here — see
## _on_painted() for where cost, noise and cooldown actually commit.
func _begin_paint(cfg: FireMissionConfig) -> void:
	if _active_mission_id != "":
		return
	_painter.begin(cfg.effect_radius, paint_max_range,
		func(point: Vector3): _on_painted(cfg, point),
		func(): _on_paint_cancelled(cfg))

## THE COMMIT POINT. Everything the player pays happens here and nowhere
## earlier, so cancelling a paint costs nothing at all.
func _on_painted(cfg: FireMissionConfig, point: Vector3) -> void:
	# Re-checked rather than trusted from selection time: the menu closed
	# several seconds ago and the player may have spent points, or another
	# mission may have launched, while they were still aiming.
	if _active_mission_id != "":
		_hud.show_message("Fire mission already in flight.")
		return
	if not PointsManager.spend_points(cfg.cost):
		_hud.show_message("Not enough points for %s." % cfg.display_name)
		return

	_active_mission_id = cfg.id
	EnablerManager.start_cooldown(cfg.id, cfg.cooldown)
	# The handset noise, from the radio's own shared constant — identical for
	# every transmission regardless of what is being called in.
	_radio.commit_transmission()
	_hud.show_message("%s — SHOT, OVER. Splash in %ds." % [
		cfg.display_name, int(round(cfg.time_of_flight))])
	print("[FIREMISSION] %s called at (%.1f, %.1f, %.1f) — TOF %.1fs, %d rounds over %.1fs" % [
		cfg.id, point.x, point.y, point.z, cfg.time_of_flight,
		cfg.round_count, cfg.mission_duration])
	_run_mission(cfg, point)

func _on_paint_cancelled(_cfg: FireMissionConfig) -> void:
	# Deliberately silent beyond the painter's own feedback: no charge, no
	# cooldown, no noise, nothing to report.
	pass

# --- Mission execution -------------------------------------------------------
## Schedules the sheaf, then lands it. Rounds are placed at randomized offsets
## and randomized TIMES within the mission window rather than on a fixed
## cadence — a battery firing, not a metronome.
##
## Awaits rather than accumulating in _process: the whole mission is a
## sequence of delays, and a timer-driven coroutine expresses that directly.
## Guarded on is_instance_valid(self) at each step so a scene teardown
## mid-mission can't resume into a freed node.
func _run_mission(cfg: FireMissionConfig, centre: Vector3) -> void:
	# Times within the window, sorted so rounds land in order. Random rather
	# than evenly spaced — but the FIRST round always lands at t=0 of the
	# window, so "splash in 8 seconds" is honest.
	var times: Array[float] = [0.0]
	for i in range(1, cfg.round_count):
		times.append(randf() * cfg.mission_duration)
	times.sort()

	await get_tree().create_timer(cfg.time_of_flight).timeout
	if not is_instance_valid(self):
		return

	var elapsed := 0.0
	for i in cfg.round_count:
		var wait: float = maxf(0.0, times[i] - elapsed)
		if wait > 0.0:
			await get_tree().create_timer(wait).timeout
			if not is_instance_valid(self):
				return
		elapsed = times[i]
		_land_round(cfg, centre, i + 1)

	_finish_mission(cfg, centre)

## One round: pick a scattered impact point, hand it to the shared system.
func _land_round(cfg: FireMissionConfig, centre: Vector3, index: int) -> void:
	var impact := _scatter_point(centre, _scatter_radius(cfg))
	if _player and is_instance_valid(_player):
		_player.add_shake(_shake_for(impact))
	AreaDamageSystem.detonate(impact, cfg.he_profile, Vector3.ZERO,
		"%s r%d" % [cfg.id, index])

## The radius impact POINTS may land within — smaller than effect_radius by
## the round's own blast reach, so that no round, however far out it lands,
## can blast past the painted circle. This is what makes effect_radius ground
## truth instead of an approximation: the preview never has to lie in either
## direction. Clamped to 0 rather than going negative — see _validate().
func _scatter_radius(cfg: FireMissionConfig) -> float:
	return maxf(0.0, cfg.effect_radius - cfg.he_profile.max_radius)

## Random point on the disc around `centre`. sqrt(randf()) would be uniform
## over the area; raising the exponent past 0.5 pulls impacts toward the
## middle, which is what impact_centre_bias controls.
func _scatter_point(centre: Vector3, radius: float) -> Vector3:
	var ang := randf() * TAU
	var r: float = radius * pow(randf(), impact_centre_bias * 0.5)
	var p := centre + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
	# Re-seat on the actual ground: the painted point may be on a slope, or
	# the scatter may have walked onto a structure or into the ditch.
	return _ground_at(p) + Vector3(0.0, impact_height, 0.0)

func _ground_at(at: Vector3) -> Vector3:
	var space := get_tree().root.world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		at + Vector3(0.0, 30.0, 0.0), at - Vector3(0.0, 30.0, 0.0))
	q.collision_mask = Obstacle.SOLID_SURFACE_MASK
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	return hit.position if hit else at

## Camera shake scaled by how close the impact was. Purely feedback — the
## damage itself is entirely the shared system's business.
func _shake_for(impact: Vector3) -> float:
	if _player == null or not is_instance_valid(_player):
		return 0.0
	var d := _player.global_position.distance_to(impact)
	if d > 60.0:
		return 0.0
	return lerpf(0.9, 0.05, clampf(d / 60.0, 0.0, 1.0))

## Last round has landed. Releases the one-mission lock, and — for a mission
## configured with a WP layer — leaves the burn zone behind. Phase 3 fills
## _spawn_wp_zone(); a wp_radius of 0 means this is a pure HE mission and
## nothing is left over.
func _finish_mission(cfg: FireMissionConfig, centre: Vector3) -> void:
	if cfg.wp_radius > 0.0:
		_spawn_wp_zone(cfg, centre)
	else:
		_hud.show_message("%s — ROUNDS COMPLETE." % cfg.display_name)
	print("[FIREMISSION] %s complete" % cfg.id)
	_active_mission_id = ""

## Shake-and-bake's second half: the burn zone the HE mission leaves behind.
##
## Parented to the CURRENT SCENE, not to this system — the zone is a fixture
## that outlives the mission that made it (the lock releases the moment rounds
## complete, but the burn keeps going), and it must not move or free with
## anything else.
##
## Every number comes from the mission config, so the visible radius and the
## damaged radius cannot drift — see WhitePhosphorusZone's own note on why its
## profile is built rather than authored.
func _spawn_wp_zone(cfg: FireMissionConfig, centre: Vector3) -> void:
	var ground := _ground_at(centre)
	WhitePhosphorusZone.spawn(get_tree().current_scene, ground,
		cfg.wp_radius, cfg.wp_duration, cfg.wp_damage_per_second,
		cfg.wp_tick_interval)
	_hud.show_message("%s — WILLIE PETE ON THE DECK. %.0fm, %ds." % [
		cfg.display_name, cfg.wp_radius, int(round(cfg.wp_duration))])
