extends Resource
class_name CoverPreviewConfig
## Every tunable for the two Step 8A visualizations: the fighter's
## sector-of-fire preview and the cover/concealment debug tint.
##
## A Resource because both consumers are INSTANTIATED IN CODE (Main and
## Fighter build them with .new()) — exports on a code-instantiated node
## never reach the inspector, so they would not actually be tunable. Same
## pattern TargetPaintConfig, FireMissionConfig, UAVConfig and ApacheConfig
## use.
##
## CONTAINS NO RANGE OR ARC. Deliberately: the preview's reach and width are
## FighterType.engagement_range and FighterType.sector_arc_degrees, read
## straight off the fighter being previewed. A separate copy here could drift
## from the real numbers, and a preview that draws a different wedge than the
## fighter actually engages is worse than no preview — it would actively lie
## at exactly the moment the player is deciding where to put someone.

# --- Sector-of-fire preview -------------------------------------------------
## How many rays the fan casts across the arc. Higher = finer resolution on
## where cover cuts the sector, at linear cost. 24 across a 90-degree arc is
## one ray every 3.75 degrees.
@export var sector_ray_count: int = 24

## Height above ground the wedge is drawn at, matching TargetPainter's own
## GROUND_OFFSET so two ground markers never z-fight against each other.
@export var ground_offset: float = 0.04

## Portions of the arc with a clear line of fire from the fighter's eye.
@export var clear_color: Color = Color(0.15, 1.0, 0.25, 0.20)
## Portions cut short by cover or concealment. Deliberately a different HUE,
## not just a different alpha — this has to read at a glance under the NVG
## green tint, which preserves relative brightness but washes out anything
## distinguished only by intensity.
@export var occluded_color: Color = Color(1.0, 0.35, 0.1, 0.28)

## Draw the individual ray lines on top of the filled wedge. The fill alone
## shows WHERE the sector is cut; the rays show the actual traced lines, which
## is what makes a narrow gap between two cover objects legible.
@export var draw_rays: bool = true
@export var ray_color: Color = Color(1.0, 1.0, 1.0, 0.35)

# --- Cover / concealment debug tint -----------------------------------------
## Overlay colour for cover_solid volumes (stops rounds AND sight).
@export var debug_cover_color: Color = Color(0.2, 0.55, 1.0, 0.35)
## Overlay colour for concealment volumes (stops sight only). Must stay
## clearly distinct from debug_cover_color — telling the two apart at a
## glance is the entire purpose of the mode.
@export var debug_concealment_color: Color = Color(0.35, 1.0, 0.4, 0.30)
