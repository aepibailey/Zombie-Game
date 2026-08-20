extends Resource
class_name FireMissionConfig
## Every tunable for one radio-callable fire mission, in one editable file.
##
## A Resource rather than @export vars on a script, because the systems that
## consume this are INSTANTIATED IN CODE — exports on a code-instantiated node
## never reach the inspector, so they would not actually be tunable. Same
## pattern WeaponData, ZombieType, ClaymoreConfig and AreaDamageProfile use.
##
## DAMAGE GEOMETRY lives on the AreaDamageProfile (`he_profile` below), not
## here: this project keeps blast geometry in exactly one kind of resource and
## duplicating radii into a second one is how the two drift apart. The fields
## here that MUST agree with that profile are checked at runtime — see
## FireMissionSystem._validate().

# --- Identity ---------------------------------------------------------------
## Menu id. Also the key the per-mission cooldown is tracked under.
@export var id: String = ""
## Shown in the radio menu.
@export var display_name: String = ""

# --- Economy ----------------------------------------------------------------
## Charged on PAINT CONFIRM, never on menu selection — cancelling a paint
## costs nothing. See TargetPainter.
@export var cost: int = 50
## Per-mission cooldown, independent of every other enabler's. Deliberately
## NOT a shared radio pool: a shared pool means calling a UAV locks out fire
## support, which makes the player hoard the radio instead of using it. The
## short GLOBAL lockout that stops back-to-back chaining is separate — see
## EnablerManager.global_radio_lockout.
@export var cooldown: float = 180.0

# --- Ballistics -------------------------------------------------------------
## Time of flight: delay between confirming the paint and the FIRST round
## landing. The window the player has to break contact or reposition.
@export var time_of_flight: float = 8.0
## How many rounds the battery fires.
@export var round_count: int = 6
## Wall-clock span the rounds land across, first to last. Impacts are
## scattered randomly within this rather than evenly spaced — a battery
## firing, not a metronome.
@export var mission_duration: float = 9.0
## The paint circle radius, and the TRUE OUTER BOUND of everything this
## mission can damage — ground truth, not an approximation. The player must
## never see a circle that is larger or smaller than where a round can
## actually reach.
##
## Rounds are NOT scattered across this whole radius: FireMissionSystem insets
## the actual landing locus by he_profile.max_radius (a round's own blast
## reach), so a round landing at the very edge of its scatter locus still
## cannot blast past this circle. See FireMissionSystem._scatter_radius().
## Must be >= he_profile.max_radius, or every round is forced to land dead on
## the paint point — FireMissionSystem._validate() warns if so.
@export var effect_radius: float = 10.0

# --- Damage -----------------------------------------------------------------
## The HE blast each round delivers. Routed through AreaDamageSystem
## unchanged — the mission contributes only an origin per round.
@export var he_profile: AreaDamageProfile

# --- White phosphorus (Shake-and-Bake only) ---------------------------------
## 0 = pure HE mission, no WP layer. > 0 = after the last round impacts, a
## persistent burn zone of this radius is left over the impact area.
## Deliberately smaller than effect_radius by default: the burn covers the
## heart of the impact area, not its whole footprint.
@export var wp_radius: float = 0.0
## How long the burn zone persists after the LAST round lands.
@export var wp_duration: float = 45.0
## Damage per second inside the zone, for everything — zombies and the player
## alike. THIS is the tunable; the underlying profile's per-tick damage is
## derived from it (dps * tick_interval), because AreaDamageProfile.max_damage
## is an int and a raw 25 dps at the default 0.5s tick would be 12.5/tick,
## which is not representable. See FireMissionSystem._spawn_wp_zone().
@export var wp_damage_per_second: float = 25.0
## Tick rate for the burn. Smaller = smoother damage and finer dps
## granularity; 0.2s makes 25 dps land exactly as 5 damage per tick.
@export var wp_tick_interval: float = 0.2
