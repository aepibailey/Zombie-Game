extends Resource
class_name ApacheConfig
## Every tunable for the AH-64 Apache fire support enabler.
##
## A Resource because ApacheSystem and the Apache actor are both INSTANTIATED
## IN CODE — exports on a code-instantiated node never reach the inspector, so
## they would not actually be tunable. Same pattern FireMissionConfig,
## UAVConfig, SupplyDropConfig and ClaymoreConfig use.

# --- Identity / economy -------------------------------------------------------
@export var id: String = "apache"
@export var display_name: String = "Apache — Patrol Box"
## Deliberately above the mortar's 50: a 90-second on-station gun that
## services every target in its box is worth more than one six-round sheaf.
@export var apache_cost: int = 90
## Starts on DEPARTURE, not at call-in and not at winchester — see
## ApacheSystem._on_departed(). Same rule the mortar and WP follow.
@export var apache_cooldown: float = 300.0

# --- The patrol box -----------------------------------------------------------
## Radius of the painted patrol area, and the radius of the paint marker the
## player aims with — one value, so the circle shown IS the area serviced.
## Ground truth, the same rule the mortar's paint circle follows.
##
## NOT in the brief's tunable list, but the box has to have a size and
## nothing else defines one. Named a "box" in player-facing text; it is a
## circle, because that is the footprint the shared painting substrate
## natively supports and the brief said not to build a second painting mode.
@export var patrol_radius: float = 35.0
## Furthest the player may paint the box from their own position. 0 uses the
## shared TargetPaintConfig.max_designation_range.
@export var paint_max_range: float = 0.0

# --- Timing -------------------------------------------------------------------
## Delay between confirming the box and the aircraft checking in on station.
@export var transit_time_in: float = 25.0
## How long the aircraft stays once on station. Departs at expiry, or earlier
## on winchester (out of ammunition).
@export var time_on_station: float = 90.0

# --- Orbit (ATMOSPHERE ONLY — never gates firing) ------------------------------
## The aircraft services targets from standoff with an optical sensor and a
## stabilized gun. Its orbit is a visual reference and NOTHING ELSE: no code
## path may test the distance between the airframe and a target. See
## ApacheSystem's own note.
@export var orbit_radius: float = 60.0
@export var orbit_altitude: float = 70.0
## Radians per second around the orbit centre.
@export var orbit_speed: float = 0.25
## How far the ORBIT CENTRE sits from the patrol box. Large on purpose — the
## aircraft should read as a distant silhouette, not an overhead gunship.
@export var standoff_distance: float = 250.0

# --- Gunnery ------------------------------------------------------------------
## Sensor acquisition time before each burst.
@export var slew_time: float = 1.2
## Sensor reacquisition pause after a retask. Firing resumes after exactly
## this long — see the runtime assertion in ApacheSystem.
@export var retask_slew_time: float = 2.0
@export var rounds_per_burst: int = 20
@export var burst_duration: float = 0.8
## Total ammunition for the whole sortie. On winchester the aircraft departs
## immediately rather than waiting out the station clock.
@export var total_rounds: int = 300

# --- Damage -------------------------------------------------------------------
## The 30mm burst, resolved through the SHARED AreaDamageSystem. Its
## noise_radius MUST be 0 — the Apache emits no noise events of any kind, and
## ApacheSystem asserts this at startup.
##
## Its max_damage MUST stay below a single mortar round's: the Apache is
## sustained attrition, the mortar is alpha. ApacheSystem asserts that too,
## reading the mortar's real profile rather than a copied number.
@export var burst_profile: AreaDamageProfile

# --- Tracers (COSMETIC ONLY — never gate a shot) -------------------------------
## Tracer streaks drawn from the airframe's gun to the burst's impact point.
##
## THESE ARE DRAWN AFTER THE BURST HAS ALREADY RESOLVED, and read the
## aircraft's position ONLY to know where to start the line. Nothing here
## feeds back into targeting: no tracer can fail, be blocked, or miss, and
## the aircraft's position still cannot gate a shot. If a future change makes
## a tracer's outcome affect damage, that breaks the Apache's core rule — see
## ApacheSystem's own note on _acquire_target's signature.
@export var tracer_enabled: bool = true
## Seconds for a tracer to travel muzzle-to-impact. Purely a look: the rounds
## have already landed. Short enough to read as fast, long enough to see.
@export var tracer_travel_time: float = 0.30
## How many streaks per burst. Not rounds_per_burst — tracer belting is
## typically every few rounds, and 20 lines would read as a solid beam.
@export var tracer_count: int = 5
## Stagger between streaks, as a fraction of tracer_travel_time.
@export var tracer_stagger: float = 0.10
## Length of each streak in metres.
@export var tracer_length: float = 14.0
@export var tracer_color: Color = Color(1.0, 0.72, 0.28)
## Ground flash at the impact point as each streak lands.
@export var tracer_impact_flash: bool = true
@export var tracer_impact_color: Color = Color(1.0, 0.85, 0.45)
@export var tracer_impact_radius: float = 1.6

# --- Safety -------------------------------------------------------------------
## No-fire bubble around the PLAYER'S LIVE POSITION, re-read every cycle.
## The aircraft refuses any burst whose impact point falls inside it, and
## simply does not engage zombies within it. There is no override.
@export var no_fire_radius: float = 12.0
