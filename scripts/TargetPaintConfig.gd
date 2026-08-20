extends Resource
class_name TargetPaintConfig
## Every tunable for the shared target-painting substrate.
##
## A Resource because TargetPainter is INSTANTIATED IN CODE (Main builds it
## with .new()) — exports on a code-instantiated node never reach the
## inspector, so they would not actually be tunable. Same pattern
## FireMissionConfig, UAVConfig and ClaymoreConfig use.
##
## CONTAINS NOTHING ABOUT WHAT IS BEING CALLED IN. No cost, no cooldown, no
## payload, no consumer names. The painter is a designation service; a mortar,
## a supply drop and the future Apache patrol box all hand it a radius and get
## back a point.

# --- Range ------------------------------------------------------------------
## Furthest the player may designate from their own position. Measured as
## FLAT 2D distance, so painting down into the ditch or up onto a structure
## doesn't spend range on the height difference.
@export var max_designation_range: float = 150.0

# --- Validity ---------------------------------------------------------------
## Require the designated point to be on the baked navmesh. This is what
## rejects tree canopies, rooftops and the sky — anything nothing can path
## to. Per-call overridable via TargetPainter.begin(), because it is a
## property of the ORDNANCE, not of the designation: indirect fire can
## legitimately land somewhere nothing can walk, a delivered crate cannot.
@export var paint_requires_navmesh: bool = true
## How far off the navmesh a point may sit and still count as on it. Matches
## ClaymorePlacer's own tolerance — "on the navmesh" means one thing
## project-wide.
@export var navmesh_tolerance: float = 1.5

# --- Marker -----------------------------------------------------------------
## Fill colours. Emissive/unshaded and alpha-blended, never additive — the
## night NVG path has no glow stage, so the risk is washing out a dark scene
## rather than blooming (same discipline as GrenadeArc and ArcWedge).
@export var marker_valid_color: Color = Color(0.15, 1.0, 0.25, 0.22)
@export var marker_invalid_color: Color = Color(1.0, 0.15, 0.1, 0.22)
## The rim is drawn brighter than the fill so the radius edge — the thing the
## player is actually judging — reads at a glance from across the base.
@export var marker_rim_valid_color: Color = Color(0.3, 1.0, 0.4, 0.85)
@export var marker_rim_invalid_color: Color = Color(1.0, 0.25, 0.2, 0.85)
@export var marker_rim_width: float = 0.35
