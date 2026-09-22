extends Node3D
class_name PropScatter

## Mesh-collider safety valve: a model with more raw triangles than
## this gets a convex HULL collider instead of a concave trimesh (a
## 788k-face lighthouse as a trimesh would weigh more than the whole
## 524k-face terrain). Everything else gets real mesh collision.
const MAX_TRIMESH_FACES := 200000
## One physics shape per MODEL (not per instance): two hundred maples
## upload their collider triangles once, then share the shape. Both
## build paths feed this cache.
static var _shape_cache := {}
## Scatters the viking prop pack across the terrain island at runtime:
## houses, floating ships and lost gear as grounded solid props, plus
## warriors as VikingWanderer characters that stroll around their
## landing spot. Everything is grounded on the real terrain surface by
## raycast, rejected on slopes too steep for their kind, kept clear of
## the arena, spaced apart, and given box collision so the world is
## solid — stand on it, detonate fireballs on it.
##
## The layout uses a FIXED seed, so the world is identical every run.
##
## Ships are special: they float. They only accept spots where the
## ground has dropped well below sea level, and they ride AT the water
## surface (hull slightly submerged) instead of sitting on whatever
## seafloor depth they found.
##
## Warriors are special too: they spawn as VikingWanderer characters
## that stroll around their landing spot (see VikingWanderer.gd),
## walking with the GLB's own clips when it has any, else a procedural
## gait built on its skeleton (or a march-bob for the rigid models).
##
## Trees cluster into mini forests: a handful of shared grove centres
## are drawn once per world, and most trees land inside them with a
## density falloff toward the middle — the rest stay island loners.
## The grove FLOORS are dressed too: mushrooms, fallen logs and rocks
## place strictly inside the woods (grove_fill rules; mushrooms and
## logs are built procedurally from primitives — no meshes exist).

## Everything inside this radius of the world origin stays clear — that
## is the arena (platforms, ramps, cubes) and the spawn area.
##
## COLLISION LAYER MAP:
##   1  terrain + solid props (houses, trees, barrels, rocks...)
##   2  the player
##   4  the viking wanderers (capsules)
##   16 soft flora (grass tufts, flowers, reeds, mushrooms) — solid to
##      the player, but fireball rays (mask 1|4) never detonate on a
##      bloom, so shots still fly clean over the meadows.
const KEEP_OUT_RADIUS := 26.0
## Mini forests: shared grove centres that the tree rules cluster
## around (see _ensure_groves).
const GROVE_COUNT := 5
const GROVE_RADIUS := 24.0
const GROVE_MIN_GAP := 55.0
## Trees pack this much tighter inside a grove than in the open.
const GROVE_SPACING_SCALE := 0.42
## Density falloff exponent: >1.0 packs trunks toward the grove centre.
const GROVE_FALLOFF := 1.3
## Little tree clusters (thickets): how many are drawn island-wide,
## how big each patch is, and how close together their saplings
## crowd. Thickets are separate from the five big groves: they dress
## the meadows with small copse-like clumps of young trees.
const THICKET_COUNT := 24
const THICKET_RADIUS := 6.5
const THICKET_MIN_GAP := 34.0
## Sapling models (little tree clusters reuse the big pack at a
## fraction of the size) — chosen per cluster, one model per clump.
const THICKET_MODELS: Array[String] = [
	"res://imports/jabami_anime_tree_v1.glb",
	"res://imports/jabami_anime_tree_v3.glb",
	"res://imports/jabami_anime_tree_v4.glb",
	"res://imports/jabami_anime_tree_v6.glb",
	"res://imports/maple_tree.glb",
]

## --- Natural climbing spots ---------------------------------------------
## Replaces the removed jumping platforms with world-made parkour:
## stacked-rock cairns, big fallen climbing trees and hillside stone
## ledges. Every formation is a short staircase whose consecutive step
## TOPS rise at most CLIMB_MAX_STEP metres — reachable with the
## player's jump from a standstill — so a climb never dead-ends, and
## each top is a lookout (or a fireball perch). Step-top heights are
## recorded on the placement record ("tops") for the verification
## harness to assert.
const CLIMB_CAIRNS := 12
const CLIMB_TREES := 10
const CLIMB_LEDGES := 12
const CLIMB_SPACING := 8.0
## Max rise between consecutive step tops (m) — jump-reachable.
const CLIMB_MAX_STEP := 0.95
## Nominal rise the builders aim for (leaves margin under the cap).
const CLIMB_STEP := 0.72
## Props scatter between this radius and scatter_max_radius. The world
## is three times bigger now, so the ring follows.
@export var scatter_min_radius := 65.0
@export var scatter_max_radius := 300.0
## Sea level: ground below this counts as water (ships only). The
## terrain GLB has no water mesh — its "sea" is painted onto a very
## shallow basin whose floor sits about 0.25–0.35 m below the surface
## at the x3 terrain scale — so the water surface lives just above
## that shelf.
@export var sea_level := -0.5
## Minimum ground height for land props (ships ignore this).
@export var min_land_height := -8.0
## Fixed seed so the world is deterministic.
@export var seed_value := 20260915
## Try this many times per prop before giving up on it.
@export var attempts_per_prop := 400
## Print the placement summary (diagnostics).
@export var verbose := true

## Physics layer for the baked prop collision.
@export_flags_3d_physics var collision_layer := 1

## Placement records: {kind, node, pos, wanderer} (diagnostics/tests).
var placed: Array[Dictionary] = []
## True once the post-placement tail (thickets, wind, warm-up...) has
## fully finished — harnesses must wait for this before measuring, or
## they catch the load-time warm-up as a "storm".
var setup_done := false
## Number of props that found no valid spot and were skipped.
var skipped := 0
## Chests placed THIS run (land + sea hoard): persisted to chests.cfg
## so the title summary can show progress like "12 of 46 plundered".
var _chests_placed := 0

var _rng := RandomNumberGenerator.new()
## Placed props: {xz: Vector2, r: float} — position and world-space
## footprint radius, so spacing is enforced surface-to-surface (a sword
## must never spawn inside a house's walls).
var _taken: Array[Dictionary] = []
## Shoreline sample for reeds: [{p: Vector2 waterline point,
## n: Vector2 inland direction}], collected on first shore request.
var _shore: Array[Dictionary] = []
## The island's four outer corners (lighthouse placement):
## [{dir: Vector2 outward, tip: Vector2, y: float}] — the farthest
## dry point of each quadrant, found by one radial sweep. Determin
## istic (no RNG draws), collected on first corner request.
var _corners: Array[Dictionary] = []
## Indices into _corners not yet claimed by a placed beacon.
var _corner_free: Array[int] = []
## Shared mini-forest centres: [{xz: Vector2, r: float, n: int}] where
## n counts trees already placed there (groves are filled evenly).
var _groves: Array[Dictionary] = []
var _groves_done := false
## Little tree clusters: [{xz: Vector2, r: float}] drawn by the
## thicket pass (fireflies nested in the big groves only).
var _thickets: Array[Dictionary] = []
## Private RNG for the thicket pass — consuming draws from _rng here
## would reshuffle every downstream placement, so thickets run on
## their own deterministic stream (same trick as the forage seeding).
var _thick_rng := RandomNumberGenerator.new()
## Ships: how many may still convert into the sailable flagship.
var _sailable_left := 1

const WANDERER_SCRIPT := preload("res://Player/VikingWanderer.gd")
const HOUSE_SCRIPT := preload("res://Player/HouseProp.gd")
const BARREL_SCRIPT := preload("res://Player/BarrelProp.gd")
const FIREFLY_SCRIPT := preload("res://Player/Fireflies.gd")
const BEACON_SCRIPT := preload("res://Player/BeaconLights.gd")
const WIND_SCRIPT := preload("res://Player/WindSway.gd")
const BIRDS_SCRIPT := preload("res://Player/GroveBirds.gd")
const AMBIENCE_SCRIPT := preload("res://Player/DuskAmbience.gd")
const VNL_SCRIPT := preload("res://Player/VillageNightLights.gd")
const RACE_SCRIPT := preload("res://Player/RaceCourse.gd")
const RAID_SCRIPT := preload("res://Player/RaidManager.gd")
const CHEST_SCRIPT := preload("res://Player/TreasureChest.gd")
const BUTTERFLY_SCRIPT := preload("res://Player/Butterflies.gd")
const RUSTLE_SCRIPT := preload("res://Player/GrassRustle.gd")
const FORAGE_SCRIPT := preload("res://Player/ForageProp.gd")
const FLOWER_PATCH_SCRIPT := preload("res://Player/FlowerPatch.gd")
const SAIL_SCRIPT := preload("res://Player/Sailboat.gd")
const SAIL_RACE_SCRIPT := preload("res://Player/SailRace.gd")
const SAIL_LAP_SCRIPT := preload("res://Player/SailLapTracker.gd")
## How deep the house sinks (fraction of model height) so the interior
## floor slab sits flush with the terrain: you step straight in.
const HOUSE_SINK_FRAC := 0.075
## The ocean: an ANIMATED water shader (OceanWater.gdshader) — vertex
## swell, animated wave normals, depth-based shore fade, a broken foam
## line and synthesized caustics dancing over the shallows. The
## template's old ocean look, rebuilt on our own swell clock.
const OCEAN_SHADER := preload("res://Player/OceanWater.gdshader")
## How far the visible water plane stretches past the island (metres).
const OCEAN_SIZE := 3600.0
## Swell shape: how many wave crests cross the whole ocean (both axes).
const SWELL_CRESTS := 9.0
## Swell amplitude (metres, peak height above the rest surface).
const SWELL_HEIGHT := 0.22
## Swell period (seconds between crests passing a fixed point).
const SWELL_PERIOD := 5.0


## One entry of the scatter table: how many, target size, footprint
## spacing, max slope (deg), and whether it prefers water.
class PropRule:
	var scene_path: String
	var count: int
	## Uniform scale is solved so this dimension matches (m):
	## `by_length` = scale so the LONGEST AABB axis equals this,
	## otherwise so the height equals it.
	var size := 1.0
	var by_length := false
	var spacing := 6.0
	var max_slope_deg := 30.0
	var wants_water := false
	## Spawn as a VikingWanderer (walking character) instead of a
	## static prop with static collision.
	var as_wanderer := false
	## Hollow-interior prop (the house): wraps the model in HouseProp,
	## which swaps in the carved mesh and builds door-aware compound
	## collision instead of the generic solid box.
	var solid_interior := false
	## Own sampling ring (used when the shore is far out; -1 = default).
	var min_radius := -1.0
	var max_radius := -1.0
	## Own attempt budget (-1 = default).
	var attempts := -1
	## Accept a shallow-water spot (beached) once this many attempts
	## fail the deep-water test (-1 = never fall back).
	var shallow_fallback_after := -1
	## Span real water channels with the model (stone bridge): special
	## placement that measures each channel and buries the ends.
	var bridge := false
	## Anchor placement: sample spots NEAR an already-placed prop of
	## this kind (barrel piles and wells beside the houses).
	var near_kind := ""
	## Trunk-only collision (trees): a cylinder at the base instead of
	## a full-height box, so canopies stay fly-through.
	var trunk_collision := false
	## Pure decoration: no collision body at all (grass tufts).
	var no_collision := false
	## Breakable prop (barrels): wrapped in BarrelProp, which owns its
	## collision and smashes into debris when a fireball blast reaches it.
	var breakable := false
	## Fraction of placements clustered around the shared grove centres
	## (mini forests); the rest scatter island-wide. 0 = never clusters.
	var grove_share := 0.0
	## Fraction of the prop's own height to sink into the ground:
	## models whose skirt is not flat at their base (castle rock
	## profiles, decorative bases) settle so they never perch on a dome.
	var sink_frac := 0.0
	## Grove-floor dressing (mushrooms/logs/rocks): places ONLY inside
	## the groves, with scaled-down spacing so floors feel lived-in.
	## scene_path is a GLB path — or "mushroom_cluster" / "fallen_log",
	## which are built procedurally (see _build_grove_prop).
	var grove_fill := false
	## Shoreline placement (reeds): samples only the wet/dry transition
	## band hugging the waterline, ignoring slope (reeds bend).
	var wants_shore := false
	## Coastal placement (lighthouse): samples the shoreline and steps
	## INLAND several metres, so the prop stands on the beach/bluff
	## ABOVE the waterline — a beacon on the coast, not in the surf.
	var wants_coast := false
	## One of this rule's placements becomes the sailable flagship
	## (the first ship found at conversion time), wrapped in Sailboat.
	var sailable := false
	## CORNER placement (lighthouse): each beacon claims one of the
	## island's four outer corners — the farthest dry point of a
	## quadrant, stepped inland so the tower overlooks its sea. Corners
	## are consumed one per prop, so two lighthouses watch two different
	## compass corners. Falls back to the coastal band if the corners
	## are all used or unusable.
	var wants_corner := false
	## Claim a corner-safe footprint: the spacing ledger records the
	## footprint's half-DIAGONAL instead of half its longest side, so
	## big rectangular landmarks (castles) keep other props out of
	## their corner gaps too.
	var rect_claim := false
	## Collision = the actual MESH (trimesh) instead of the AABB box:
	## for landmarks with turrets, ramparts and courtyards, a full box
	## would put an invisible flat floor at the tallest point and
	## walls around empty air. A trimesh follows the real geometry —
	## land on the roofline, walk the courtyard.
	var mesh_collision := false

	func _init(p_path: String, p_count: int, p_size: float, p_spacing: float,
			p_slope: float, p_by_length := false, p_water := false,
			p_wanderer := false) -> void:
		scene_path = p_path
		count = p_count
		size = p_size
		spacing = p_spacing
		max_slope_deg = p_slope
		by_length = p_by_length
		wants_water = p_water
		as_wanderer = p_wanderer


func _rules() -> Array[PropRule]:
	var rules: Array[PropRule] = [
		# Stone bridge FIRST: spans are measured against bare terrain,
		# before any other prop can pollute the bank raycasts. It spans
		# the island's small water channels (see _place_bridges).
		PropRule.new("res://imports/stone_bridge.glb", 3, 1.0, 60.0, 0.0,
				true, false),
		# Buildings: big, flat ground only, far apart. Flatter than most
		# props (7 deg): the house sits FLUSH now (interior floor level
		# with the terrain), so sloped ground would intrude inside.
		# LANDMARKS first: the two old castles are placed before
		# everything else solid so their huge footprints claim real
		# ground on the big island — villages and woods then form
		# around them. Authored at unit scale (~1 m), so they solve
		# into 30–40 m fortresses; sink_frac buries the rock skirt.
		PropRule.new("res://imports/old_castle.glb", 2, 34.0, 90.0,
				6.0),
		PropRule.new("res://imports/old_castle (1).glb", 2, 40.0, 90.0,
				6.0),
		PropRule.new("res://a_viking_house.glb", 4, 7.0, 40.0, 7.0),
		# The medieval pack's houses: five distinct little cottages
		# (4–7.6 m tall as authored) joining the viking longhouses,
		# same flat-ground placement, each kind placed separately.
		PropRule.new("res://imports/low_poly_medieval_house_1.glb", 2,
				4.5, 30.0, 7.0),
		PropRule.new("res://imports/low_poly_medieval_house_2.glb", 2,
				4.0, 30.0, 7.0),
		PropRule.new("res://imports/low_poly_medieval_house_3.glb", 2,
				4.2, 30.0, 7.0),
		PropRule.new("res://imports/low_poly_medieval_house_4.glb", 2,
				5.0, 30.0, 7.0),
		PropRule.new("res://imports/low_poly_medieval_house_5.glb", 2,
				4.0, 30.0, 7.0),
		# Longships riding at anchor: they sample the deep-water ring
		# beyond the island's shore, with a huge attempt budget.
		PropRule.new("res://viking_ship_low_poly.glb", 3, 14.0, 45.0, 25.0,
				true, true),
		# Warriors: a raiding party wandering the island — multiples of
		# each kind, so the island feels peopled (and worth shooting at).
		# Counts raised for a livelier village: parked wanderers are
		# cheap, and the wake cap bounds how many ever move at once.
		PropRule.new("res://viking_warrior.glb", 16, 1.9, 7.0, 30.0,
				false, false, true),
		PropRule.new("res://warrior_of_the_north.glb", 14, 1.9, 7.0, 30.0,
				false, false, true),
		PropRule.new("res://viking_lowpoly.glb", 14, 1.9, 7.0, 30.0,
				false, false, true),
		# Lost gear, scattered where battles happened. (The nordic
		# "helmet" GLB is actually a full armor display bust — a 10k-tri
		# chest plate + helmet stand whose dense convex hull stalled the
		# player whenever they walked near it — so it was removed.)
		PropRule.new("res://axe.glb", 5, 1.0, 5.0, 35.0),
		PropRule.new("res://sword.glb", 5, 1.1, 5.0, 35.0),
		PropRule.new("res://vikings_shield_2017_old_version.glb", 4, 1.0,
				5.0, 35.0),
		PropRule.new("res://thorsoshield.glb", 4, 1.1, 5.0, 35.0),
		# Village clutter around the houses: wells first (they claim a
		# spot near a hut), then the barrels ring in around them.
		PropRule.new("res://imports/water_well.glb", 3, 2.0, 6.0, 8.0),
		PropRule.new(
				"res://imports/lowpoly_boxes_and_barrels_pack_free.glb",
				5, 2.2, 3.0, 12.0, true),
		# Wagon camp: the pack (7.3 m of carts and gear) anchors NEAR a
		# house like the barrels do — a little caravan parked outside
		# the village. Sand castle: the playful toy fort ON A BEACH —
		# it is a 4 m toy, so inland it read as a "tiny castle" between
		# the real ones; the coast-tuning below pins it to the sand.
		PropRule.new("res://imports/low_poly_medieval_pack_wagons.glb", 2,
				3.6, 12.0, 12.0, true),
		PropRule.new("res://imports/low_poly_sand_castle.glb", 3, 4.0,
				25.0, 8.0),
		PropRule.new("res://imports/psx_wooden_barrel.glb", 4, 0.95,
				2.5, 12.0),
		PropRule.new(
				"res://imports/rustic_rotten_wooden_barrel_whiskey_cask.glb",
				4, 0.94, 2.5, 12.0),
		PropRule.new("res://imports/old_barrel_of_wine.glb", 3, 1.0,
				2.5, 12.0),
		PropRule.new("res://imports/old_wooden_barrel.glb", 3, 1.0,
				2.5, 12.0),
		# The jabami anime tree pack + the maple, DENSER than before:
		# a proper tree line. Trunk-only collision: canopies stay
		# fly-through for flight.
		PropRule.new("res://imports/jabami_anime_tree_v1.glb", 26, 8.0,
				5.0, 18.0),
		PropRule.new("res://imports/jabami_anime_tree_v2.glb", 26, 12.0,
				5.0, 18.0),
		PropRule.new("res://imports/jabami_anime_tree_v3.glb", 26, 7.0,
				5.0, 18.0),
		PropRule.new("res://imports/jabami_anime_tree_v4.glb", 26, 8.5,
				5.0, 18.0),
		PropRule.new("res://imports/jabami_anime_tree_v5.glb", 26, 11.0,
				5.0, 18.0),
		PropRule.new("res://imports/jabami_anime_tree_v6.glb", 26, 10.0,
				5.0, 18.0),
		PropRule.new("res://imports/jabami_anime_tree-grass_v1.glb", 34,
				13.0, 5.0, 18.0),
		PropRule.new("res://imports/maple_tree.glb", 22, 11.0, 7.0, 16.0),
		# MORE VEGETATION: procedural bushes and flower patches dress
		# the meadows (55% of them cluster in the groves' shade), and
		# reeds fringe the shoreline's wet/dry band.
		PropRule.new("bush_patch", 20, 0.9, 3.5, 20.0),
		PropRule.new("flower_patch", 26, 0.6, 2.8, 16.0),
		PropRule.new("reeds", 14, 1.0, 3.0, 45.0),
		# Coastal beacon: the old lighthouse, 14 m tall. CORNER mode:
		# one per island corner — the farthest dry point of a quadrant
		# (see _corner_probe), stepped inland so the tower stands on
		# the bluff ABOVE the waterline, overlooking its sea.
		PropRule.new("res://imports/old_lighthouse.glb", 2, 14.0, 14.0,
				10.0),
		# Grove-floor dressing — strictly inside the woods: toadstool
		# clusters, fallen logs and scattered boulders (real GLBs from
		# the open-world pack, scaled down hard).
		PropRule.new("mushroom_cluster", 7, 0.5, 1.4, 15.0),
		PropRule.new("fallen_log", 6, 1.0, 2.4, 14.0),
		PropRule.new("res://demo/assets/models/RockA.glb", 5, 0.55,
				2.0, 18.0),
		PropRule.new("res://demo/assets/models/RockB.glb", 4, 0.45,
				2.0, 18.0),
		PropRule.new("res://demo/assets/models/RockC.glb", 4, 0.35,
				2.0, 18.0),
	]
	# Ships: they float, so they sample the deep-water ring beyond the
	# island's shore (the terrain is three times bigger now) with
	# thousands of attempts. Rule flags are matched by PATH, not index
	# — the rule table is long and edits reshuffle indices constantly.
	for r in rules:
		if r.scene_path.ends_with("old_castle.glb") \
				or r.scene_path.begins_with("res://imports/old_castle ("):
			# The castles: sink a tenth of their height so the rock
			# skirt settles into the terrain, never perched on a dome.
			# A big attempt budget: a 50+ m footprint needs genuinely
			# flat ground, and there are few such discs per island.
			# rect_claim: nothing may overlap their corners either.
			# mesh_collision: turrets and courtyards are real — no
			# invisible box floor at the tallest point.
			r.sink_frac = 0.10
			r.attempts = 3000
			r.rect_claim = true
			r.mesh_collision = true
		elif r.scene_path.ends_with("a_viking_house.glb"):
			# The a_viking_house is a hollow interior: carved
			# doorways + walkable walls.
			r.solid_interior = true
		elif r.scene_path.ends_with("old_lighthouse.glb"):
			# CORNER mode + a big attempt budget: each beacon claims a
			# quadrant's outermost dry point (see _corner_probe) —
			# there are only so many usable bluff spots.
			r.wants_corner = true
			r.attempts = 1200
			r.sink_frac = 0.05  # settle the rock base
		elif r.scene_path.ends_with("viking_ship_low_poly.glb"):
			var ship := r
			ship.min_radius = 200.0
			ship.max_radius = 300.0
			ship.attempts = 6000
			# After the fallback budget, accept shallow bays too —
			# this map's sea has no deep water at all (the shelf
			# bottoms out ~0.3 m under the surface), so a
			# moored-in-the-shallows longship beats no longship.
			ship.shallow_fallback_after = 2000
			# One of the three becomes the FLAGSHIP — the sailable one
			# (conversion happens after placement, in _spawn_sailboat;
			# the fleet's RNG draws must stay identical, so the count
			# and placement stream here are untouched).
			ship.sailable = true
		elif r.scene_path.ends_with("low_poly_sand_castle.glb"):
			# The toy fort belongs on the sand: sample the shoreline band
			# and step inland only a few metres (a child builds it right
			# at the top of the beach, waves at its back). A generous
			# attempt budget: 25 m spacing needs room on a narrow coast.
			r.wants_coast = true
			r.attempts = 2400
	# New-asset flags: the bridge spans channels, village clutter
	# anchors beside the houses, trees get trunk-only collision.
	for r in rules:
		if r.scene_path.ends_with("stone_bridge.glb"):
			r.bridge = true
		elif r.scene_path.ends_with("water_well.glb") \
				or r.scene_path.contains("barrel") \
				or r.scene_path.contains("wagons"):
			r.near_kind = "a_viking_house.glb"
			if r.scene_path.contains("barrel"):
				r.breakable = true
		elif r.scene_path.ends_with("jabami_anime_tree-grass_v1.glb"):
			r.no_collision = true
			r.grove_share = 0.6  # meadows too, not only grove shade
		elif r.scene_path == "mushroom_cluster" \
				or r.scene_path == "fallen_log" \
				or r.scene_path.begins_with("res://demo/assets/models/Rock"):
			r.grove_fill = true
			r.grove_share = 1.0
			if r.scene_path == "mushroom_cluster":
				r.no_collision = true  # toadstools never block the player
		elif r.scene_path == "bush_patch" or r.scene_path == "flower_patch":
			# Meadow plants: over half cluster in the groves' shade.
			r.grove_share = 0.55
			if r.scene_path == "flower_patch":
				r.no_collision = true  # flowers never block
		elif r.scene_path == "reeds":
			r.no_collision = true
			r.wants_shore = true
			r.min_radius = 55.0
		elif r.scene_path.begins_with("res://imports/jabami") \
				or r.scene_path.ends_with("maple_tree.glb"):
			r.trunk_collision = true
			r.grove_share = 0.85
	return rules


## --- Shared collision "bins" -------------------------------------------
## A moving character against this world cost ~40 ms/frame until the
## trigger was isolated with bare-engine micro-benchmarks: it is the
## STATIC BODY COUNT, not the shapes (1 body with 300 box shapes:
## clean; 925 bodies: constant 36 ms storms on every contact). Each
## prop used to carry its own StaticBody3D (~700 bodies); now every
## prop adds its shape to a REGIONAL shared body — a 64 m grid, one
## body per cell and layer. Regional because respawning props
## (barrels, wanderers) are body insertions, and an insertion against
## an island-wide mega-bin re-paired ~300 shapes (measured ~1 s
## hitches); against a 64 m cell it re-pairs only its neighbourhood.
var _bin_bodies := {}

## Bin grid cell size (m).
const BIN_CELL := 64.0


## Returns (creating on first use) the shared static body for a
## collision layer at a world position. All props parent their
## shapes here; the bins themselves stay at identity — each shape
## carries the prop's world transform.
func _bin_body(layer: int, pos: Vector3) -> StaticBody3D:
	var key := "%d_%d_%d" % [layer, int(floorf(pos.x / BIN_CELL)),
			int(floorf(pos.z / BIN_CELL))]
	if not _bin_bodies.has(key):
		var b := StaticBody3D.new()
		b.name = "PropBin_%s" % key
		b.collision_layer = layer
		b.collision_mask = 0
		b.top_level = true
		add_child(b)
		_bin_bodies[key] = b
	return _bin_bodies[key]


func _ready() -> void:
	# The terrain's collision is built in its own _ready (this node is
	# ordered after it in the scene), but the physics server needs one
	# frame to register the shapes before raycasts can find them.
	_scatter.call_deferred()


func _scatter() -> void:
	await get_tree().physics_frame
	_rng.seed = seed_value
	_add_water_plane()
	_sync_death_plane()
	var props_root := Node3D.new()
	props_root.name = "Props"
	add_child(props_root)
	for rule in _rules():
		# grove_fill rules may name a PROCEDURAL prop (no res:// path) —
		# they are built at placement time and never load from disk.
		var packed: PackedScene = null
		if rule.scene_path.begins_with("res://"):
			packed = load(rule.scene_path)
		if packed == null and rule.scene_path.begins_with("res://"):
			push_warning("[PropScatter] missing %s" % rule.scene_path)
			skipped += rule.count
			continue
		var before := placed.size()
		if rule.bridge:
			_place_bridges(props_root, packed, rule)
		else:
			for i in rule.count:
				_place_one(props_root, packed, rule)
		if verbose:
			print("[PropScatter] %s: %d/%d placed"
					% [rule.scene_path.get_file(), placed.size() - before,
					rule.count])
	# Collision per prop. Static props: one small StaticBody parented to
	# the prop. Full-mesh trimesh for ~12M triangles of sculpted props
	# is pathological for the physics server; boxes are cheap, robust
	# and plenty for gameplay (stand on them, detonate on them).
	# Wanderers are CharacterBody3D on their OWN layer 4 with a CAPSULE
	# of their model's size (rounded bottom rides over slopes instead of
	# digging in). They must NOT also carry a layer-1 StaticBody hitbox:
	# a body overlapping its own child collider depenetrates itself
	# every physics frame and launches across the map. (Trade-off:
	# fireballs mask layer 1 only, so they no longer detonate on
	# wanderers — they never did before this either.)
	# Houses are the third path: HouseProp builds a door-aware
	# COMPOUND body (walls with real door gaps, lintels, interior
	# floor, roof) so the carved doorways are actually walkable.
	var wanderers := 0
	for rec in placed:
		var aabb: AABB = rec.aabb
		if rec.get("wanderer", false):
				wanderers += 1
				var wprop := rec.node as CharacterBody3D
				wprop.collision_layer = 4
				# Bump the player, ride the CHARACTER HEIGHTFIELD (layer 8,
				# box-prism ground built by TerrainWorld) — and NEVER the
				# terrain trimesh: a moving capsule against concave trimesh
				# costs ~6-7 ms/frame per walker on the stock physics
				# server (the village-wide lag), and even masked together
				# the bumpy trimesh pokes through the box tops and keeps
				# the expensive contacts alive. Boxes-only ground is a
				# small fraction of the cost; _probe_ground still uses the
				# full trimesh (mask 1) for accurate stroll targets.
				wprop.collision_mask = 2 | 8
				# The body itself is unscaled (see _place_one); the AABB
				# is model-space, so pre-scale it to world size.
				_add_capsule(wprop, AABB(aabb.position
						* (rec.scale as float),
						aabb.size * (rec.scale as float)))
				continue
		if rec.get("custom", false):
			continue  # Bridge: compound collision built at placement.
		if rec.get("sailable", false):
			continue  # Flagship: Sailboat owns its own moving hull body.
		var prop: Node3D = rec.node
		if rec.get("no_collision", false):
			# Soft flora (grass tufts, flowers, reeds, mushrooms): SOLID
			# on their own layer 16 — the player brushes and stands on
			# them, while fireball rays (mask 1|4) pass straight
			# through, so blasts land on the target, not on a petal.
			var dbody := _bin_body(16, prop.global_position)
			# (dbody already lives under PropScatter as a shared bin —
			# NOT a child of this prop; only the shape is added.)
			# Every collision is mesh now: the tuft's real stalks and
			# blooms are the shape (per-model cached for procedural
			# plants too, via their build stream).
			_add_prop_mesh_shape(dbody, prop)
			continue
		if rec.get("breakable", false):
			# Barrel: physically IMMORTAL — its collider is a shape in
			# the regional bin, added once here and never changed.
			# BarrelProp only swaps mesh materials (husk <-> fresh);
			# mutating or re-inserting the body would storm the
			# broadphase for up to a second (measured).
			var bbody := _bin_body(collision_layer, prop.global_position)
			_add_shaped(bbody, mesh_shape_for(prop),
					prop.global_transform)
			continue
		if prop.has_method("floor_top_model_y"):
			continue  # HouseProp: owns its compound body.
		var body := _bin_body(collision_layer, prop.global_position)
		if rec.get("mesh", false):
			_add_mesh_shape(body, prop)
		elif rec.get("trunk", false):
			_add_trunk(body, aabb, prop)
		else:
			_add_prop_mesh_shape(body, prop)
		if rec.get("beacon", false):
			# Lighthouse night-light kit: a warm lamp in the lamp room
			# plus the long rotating beam. A BeaconLights controller
			# owns the pulse and the spin (the old looping tweens), and
			# the whole kit registers in the "night_lights" group so
			# DayNight fades it out at dawn and back in after sunset —
			# the beacons live only at night now.
			var lamp := OmniLight3D.new()
			lamp.name = "Beacon"
			lamp.light_color = Color(1.0, 0.94, 0.78)
			lamp.light_energy = 0.0
			lamp.omni_range = 44.0
			lamp.shadow_enabled = false
			lamp.position = Vector3(0.0, aabb.size.y * 0.5, 0.0)
			prop.add_child(lamp)
			# The visible beam: a spot cone pitched slightly DOWN from
			# horizontal (beams read best grazing the mist band),
			# parented to a spinner node so rotation and tilt never
			# fight.
			var spinner := Node3D.new()
			spinner.name = "BeaconSpinner"
			spinner.position = lamp.position
			prop.add_child(spinner)
			var beam := SpotLight3D.new()
			beam.name = "BeaconBeam"
			beam.light_color = Color(1.0, 0.9, 0.62)
			beam.light_energy = 0.0
			beam.spot_range = 190.0
			beam.spot_angle = 9.0
			beam.spot_angle_attenuation = 1.6
			beam.shadow_enabled = false
			beam.rotation.x = -0.12
			spinner.add_child(beam)
			var ctl := Node.new()
			ctl.name = "BeaconController"
			ctl.set_script(BEACON_SCRIPT)
			prop.add_child(ctl)
			ctl.call("setup", lamp, beam, spinner,
					_rng.randf() * 10.0)
	if verbose:
		print("[PropScatter] placed %d props (%d skipped), %d wanderers"
				% [placed.size(), skipped, wanderers])
	var tail_t0 := Time.get_ticks_usec()
	_place_thickets(props_root)
	if verbose:
		print("[tail] thickets %d ms" % ((Time.get_ticks_usec()
				- tail_t0) / 1000))
	var tc := Time.get_ticks_usec()
	_place_climb_spots(props_root)
	if verbose:
		print("[tail] climb spots %d ms" % ((Time.get_ticks_usec() - tc)
				/ 1000))
	var tf := Time.get_ticks_usec()
	_spawn_fireflies(props_root)
	if verbose:
		print("[tail] fireflies %d ms" % ((Time.get_ticks_usec() - tf)
				/ 1000))
	var tw := Time.get_ticks_usec()
	_spawn_wind(props_root)
	if verbose:
		print("[tail] wind %d ms" % ((Time.get_ticks_usec() - tw) / 1000))
	var tb := Time.get_ticks_usec()
	_spawn_birds(props_root)
	if verbose:
		print("[tail] birds %d ms" % ((Time.get_ticks_usec() - tb)
				/ 1000))
	var tbf := Time.get_ticks_usec()
	_spawn_butterflies(props_root)
	if verbose:
		print("[tail] butterflies %d ms" % ((Time.get_ticks_usec() - tbf)
				/ 1000))
	var tr := Time.get_ticks_usec()
	_spawn_rustle(props_root)
	if verbose:
		print("[tail] rustle %d ms" % ((Time.get_ticks_usec() - tr)
				/ 1000))
	var tn := Time.get_ticks_usec()
	_spawn_village_night(props_root)
	_spawn_sailboat(props_root)
	_spawn_boat_race(props_root)
	_spawn_ambience(props_root)
	_spawn_race(props_root)
	_spawn_raid(props_root)
	await _spawn_chests(props_root)
	await _spawn_sea_hoard(props_root)
	await _spawn_dive_site(props_root)
	# The "X of Y plundered" denominator: the real placed total (land
	# + hoard), merged with any previous run's count when the map
	# changes size — the max keeps a shrunken map from dropping the
	# denominator under chests already opened.
	var cfg := ConfigFile.new()
	cfg.load(TreasureChest.SAVE_PATH)
	cfg.set_value("progress", "placed",
			maxi(int(cfg.get_value("progress", "placed", 0)), _chests_placed))
	cfg.save(TreasureChest.SAVE_PATH)
	if verbose:
		print("[tail] night dressing %d ms" % ((Time.get_ticks_usec() - tn)
				/ 1000))
	await _warmup_physics()
	setup_done = true
	# One sea-hoard chest carries the relic. Deferred: the chest group
	# registers in _ready, which can land after this line.
	_mark_relic_chest.call_deferred()
	# ... and each one has a guardian. Same deferred rule.
	_spawn_serpents.call_deferred()
	# ... and the gold sink waits in the village.
	_spawn_merchant.call_deferred(props_root)
	# ... and the saga's counsel: the elder and his quest board.
	_spawn_elder.call_deferred(props_root)


## First-contact warm-up: the physics broadphase builds its terrain
## pair cache lazily — the first time a body MOVES anywhere after
## boot, the engine stalls for seconds (measured ~3.4 s once per
## session; fires even with every game script disabled — engine
## level). This invisible probe drops and slides at several spots at
## LOAD time so the player never meets that stall mid-gameplay:
## random ring spots AND every wanderer's wake-site (the village
## cluster is exactly where the player first arrives).
func _warmup_physics() -> void:
	var probe := CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.0
	cs.shape = cap
	probe.add_child(cs)
	probe.collision_layer = 0
	probe.collision_mask = 1 | 2 | 8
	probe.visible = false
	add_child(probe)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x57E1
	for i in 6:
		var ang := rng.randf() * TAU
		var rad := rng.randf_range(30.0, 55.0)
		var at := Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
		var y := 40.0
		var hit := _ground_ray(Vector3(at.x, 500.0, at.z))
		if not hit.is_empty():
			y = (hit.position as Vector3).y
		# Start ON the ground and slide: contacts engage from the first
		# frame, paying the first-contact cost for each broadphase
		# neighbourhood probed.
		probe.global_position = Vector3(at.x, y + 0.6, at.z)
		for f in 10:
			probe.velocity.x = rng.randf_range(-3.0, 3.0)
			probe.velocity.z = rng.randf_range(-3.0, 3.0)
			probe.move_and_slide()
			await get_tree().physics_frame
	# Wanderer wake-sites: each villager's spawn spot is a place the
	# player can walk into and walkers will roam. Sliding the probe
	# (terrain + prop-bin + charfield mask) there pre-builds every
	# pair the arrival would otherwise build mid-game as a storm.
	var spots: Array[Vector3] = []
	for rec in placed:
		if rec.get("wanderer", false):
			spots.append((rec["node"] as Node3D).global_position)
	for at in spots:
		probe.global_position = at + Vector3(0.0, 0.3, 0.0)
		probe.velocity = Vector3.ZERO
		for f in 3:
			probe.move_and_slide()
			await get_tree().physics_frame
	probe.queue_free()
	if verbose:
		print("[tail] physics warm-up done")


## Ambient grass rustle: one voice per vegetation cluster — bright
## voices at the reeds, dry-soft voices in the open meadows (grass
## tufts + bushes), dark-soft under the grove canopies.
func _spawn_rustle(props_root: Node3D) -> void:
	var spots: Array = []
	for rec in placed:
		var k: String = rec.kind
		var p: Vector3 = rec.pos
		if k == "reeds":
			spots.append({"p": p + Vector3(0, 0.4, 0), "bright": true})
		elif k == "jabami_anime_tree-grass_v1.glb" or k == "bush_patch":
			# Only a share of tufts gets a voice (a voice per tuft
			# would be too many players).
			if _rng.randf() > 0.5:
				continue
			spots.append({"p": p + Vector3(0, 0.3, 0),
					"bright": false})
	if spots.is_empty():
		return
	var rustle := Node3D.new()
	rustle.set_script(RUSTLE_SCRIPT)
	rustle.wind_ref = _wind_node
	rustle.set("rustle_seed", seed_value + 8837)
	rustle.setup(spots)
	props_root.add_child(rustle)
	if verbose:
		print("[PropScatter] rustle: %d voices" % spots.size())


## Night dressing for the village: warm window glows on every placed
## house (window planes just outside each facade, so they never
## z-fight the real geometry) and torches standing by the wells.
## The kit registers in "night_lights" so DayNight lights it only
## after sunset.
func _spawn_village_night(props_root: Node3D) -> void:
	var windows: Array = []
	var torches: Array = []
	for rec in placed:
		if rec.get("wanderer", false) or rec.get("ship", false):
			continue
		var k: String = rec.kind
		if k.ends_with("house.glb") \
				or k.begins_with("low_poly_medieval_house"):
			# Descriptors carry the house's RAW (pre-scale) AABB: the
			# kit parents each glow to the house node, so the random
			# placement yaw and the solve scale are inherited
			# automatically and the panes always hug a real facade.
			windows.append({"node": rec.node, "ab": rec.aabb})
		elif k.ends_with("water_well.glb"):
			torches.append({"node": rec.node, "ab": rec.aabb})
	if windows.is_empty() and torches.is_empty():
		return
	var kit := Node3D.new()
	kit.set_script(VNL_SCRIPT)
	kit.setup(windows, torches, seed_value + 991)
	props_root.add_child(kit)
	if verbose:
		print("[PropScatter] village night: %d houses, %d wells"
				% [windows.size(), torches.size()])


## The dusk chorus: crickets chirping across the meadows, evening
## birds in the groves. Faded in/out by DayNight through the
## "night_lights" gate — silent at noon, alive at sunset.
func _spawn_ambience(props_root: Node3D) -> void:
	var crickets: Array[Vector3] = []
	var birds: Array[Vector3] = []
	for rec in placed:
		var k: String = rec.kind
		if k == "bush_patch" or k == "flower_patch" or k == "reeds":
			if crickets.size() < 20:
				crickets.append(rec.pos + Vector3(0, 0.3, 0))
		elif k.begins_with("jabami_anime_tree_v") or k == "maple_tree.glb":
			if birds.size() < 8 and _rng.randf() < 0.3:
				birds.append(rec.pos + Vector3(0, 1.0, 0))
	var amb := Node3D.new()
	amb.set_script(AMBIENCE_SCRIPT)
	amb.setup(crickets, birds, seed_value + 3313)
	props_root.add_child(amb)
	if verbose:
		print("[PropScatter] ambience: %d cricket spots, %d bird spots"
				% [crickets.size(), birds.size()])


## The wind field node reference (assigned in _spawn_wind).
var _wind_node: WindSway


## Ground height at xz (+dy), or `fallback` when the ray misses.
func _race_y(xz: Vector2, dy: float, fallback: float) -> float:
	var hit := _ground_ray(Vector3(xz.x, 500.0, xz.y))
	if hit.is_empty():
		return fallback
	return (hit.position as Vector3).y + dy


## The race course's waypoints, read from the REAL placed world:
## village start, castle flybys, grove canopy threading, both
## lighthouses, a big open-sea gate and the island's high point.
func _build_race_points() -> Array:
	var castle_a := Vector2.INF
	var castle_a_y := 20.0
	var castle_b := Vector2.INF
	var castle_b_y := 20.0
	var lights: Array[Vector2] = []
	var houses: Array[Vector2] = []
	var high_xz := Vector2.ZERO
	var high_y := -INF
	for rec in placed:
		var k: String = rec.kind
		var p: Vector3 = rec.pos
		if k.begins_with("old_castle"):
			if castle_a == Vector2.INF:
				castle_a = Vector2(p.x, p.z)
				castle_a_y = p.y + (rec.aabb as AABB).size.y * rec.scale
			else:
				castle_b = Vector2(p.x, p.z)
				castle_b_y = p.y + (rec.aabb as AABB).size.y * rec.scale
		elif rec.get("beacon", false):
			lights.append(Vector2(p.x, p.z))
		elif k.ends_with("house.glb") \
				or k.begins_with("low_poly_medieval_house"):
			houses.append(Vector2(p.x, p.z))
		elif rec.has("tops"):
			var top: float = (rec.tops as Array).max()
			if top > high_y:
				high_y = top
				high_xz = Vector2(p.x, p.z)
	if houses.is_empty():
		return []
	var village := Vector2.ZERO
	for h in houses:
		village += h
	village /= float(houses.size())
	_ensure_groves()
	var grove_a := Vector2(village.x + 60.0, village.y)
	var grove_b := Vector2(village.x - 60.0, village.y)
	if _groves.size() >= 2:
		grove_a = _groves[0].xz
		grove_b = _groves[1].xz
	var g1 := _ground_ray(Vector3(grove_a.x, 500.0, grove_a.y))
	var g2 := _ground_ray(Vector3(grove_b.x, 500.0, grove_b.y))
	var g1_y: float = (g1.position as Vector3).y \
			+ 4.0 if not g1.is_empty() else village.y + 10.0
	var g2_y: float = (g2.position as Vector3).y \
			+ 11.0 if not g2.is_empty() else village.y + 16.0
	# Sea gate: between the lighthouses (or any fallback bearing),
	# pushed out past the coast, high over the waves.
	var sea_xz: Vector2
	if lights.size() >= 2:
		sea_xz = ((lights[0] + lights[1]) * 0.5)
		if sea_xz.length() < 1.0:
			sea_xz = Vector2.RIGHT
		sea_xz = sea_xz.normalized() * (scatter_max_radius + 25.0)
	else:
		sea_xz = Vector2.RIGHT * (scatter_max_radius + 25.0)
	# High point: the tallest climb formation, else a castle tower.
	var high_gate := Vector3(high_xz.x, high_y + 3.0, high_xz.y) \
			if high_y > -INF \
			else Vector3(castle_b.x, castle_b_y + 8.0, castle_b.y)
	var pts: Array = [
		{"p": Vector3(village.x, _race_y(village, 6.0, 20.0), village.y),
				"r": 6.0},
		{"p": Vector3(castle_a.x, _race_y(castle_a, 8.0, 24.0), castle_a.y),
				"r": 6.5},
		{"p": Vector3(grove_a.x, g1_y, grove_a.y), "r": 4.5},
		{"p": Vector3(grove_b.x, g2_y, grove_b.y), "r": 5.0},
	]
	if lights.size() >= 1:
		var l1 := lights[0]
		pts.append({"p": Vector3(l1.x, _race_y(l1, 9.0, 18.0), l1.y),
				"r": 6.5})
	pts.append({"p": Vector3(sea_xz.x, sea_level + 12.0, sea_xz.y),
			"r": 8.0})
	if lights.size() >= 2:
		var l2 := lights[1]
		pts.append({"p": Vector3(l2.x, _race_y(l2, 9.0, 18.0), l2.y),
				"r": 6.5})
	pts.append({"p": high_gate, "r": 5.5})
	pts.append({"p": Vector3(village.x, _race_y(village + Vector2(12, 8),
			3.5, 16.0), village.y + 8.0), "r": 4.5})
	# FINISH: beside the start gate, same height — the course closes
	# visibly where it began.
	pts.append({"p": Vector3(village.x + 16.0,
			_race_y(village + Vector2(16, 0), 6.0, 20.0), village.y),
			"r": 6.0})
	return pts


## Spawn the race course (rings + timing + HUD). Rank thresholds are
## solved from the real path length at the player's cruise/boost
## speeds, so any island layout yields fair medals.
func _spawn_race(props_root: Node3D) -> void:
	var pts := _build_race_points()
	if pts.size() < 6:
		if verbose:
			print("[PropScatter] race: not enough landmarks, skipped")
		return
	# Path length through the waypoints.
	var len := 0.0
	for i in range(1, pts.size()):
		len += ((pts[i].p as Vector3) \
				- (pts[i - 1].p as Vector3)).length()
	# Cruise 16 m/s, boost 24; mediate for turns: gold ≈ 13 m/s avg
	# (+10% slack), silver ≈ 11, bronze ≈ 8.5.
	var gold := snappedf(len / 13.0 * 1.10, 1.0)
	var silver := snappedf(len / 11.0 * 1.10, 1.0)
	var bronze := snappedf(len / 8.5 * 1.10, 1.0)
	var course := Node3D.new()
	course.set_script(RACE_SCRIPT)
	course.setup(pts, [gold, silver, bronze])
	add_child(course)
	if verbose:
		print(("[PropScatter] race: %d rings, %.0f m - GOLD %.0fs / "
				+ "SILVER %.0fs / BRONZE %.0fs")
				% [pts.size(), len, gold, silver, bronze])


## The night-raid manager: at full night a squad of the placed
## warriors marches on the village and ransacks the houses unless the
## player (or a very long night of fireballs) stops them. Dawn calls
## the survivors home. Village centre = mean of the placed houses.
func _spawn_raid(props_root: Node3D) -> void:
	var houses: Array = []
	var radii: Array = []
	for rec in placed:
		if rec.get("wanderer", false) or rec.get("ship", false):
			continue
		var k: String = rec.kind
		if k.ends_with("house.glb") \
				or k.begins_with("low_poly_medieval_house"):
			houses.append(rec.node)
			radii.append(0.5 * maxf((rec.aabb as AABB).size.x,
					(rec.aabb as AABB).size.z) * (rec.scale as float))
	if houses.size() < 2:
		return
	# The raid targets the DENSEST cluster of houses (the real
	# village), not the island mean of every placed cottage.
	var village_c := _densest_cluster(houses, 60.0)
	var mgr := Node3D.new()
	mgr.set_script(RAID_SCRIPT)
	mgr.setup(village_c, houses, radii,
			_nearest_beach(Vector2(village_c.x, village_c.z)),
			seed_value + 7717)
	props_root.add_child(mgr)
	if verbose:
		print("[PropScatter] raid manager: %d houses, village at %s"
				% [houses.size(), village_c])


## Greedy densest-cluster finder: the position whose 60 m
## neighbourhood holds the most houses (ties broken by total inverse
## distance, i.e. tightness). O(n^2) over 16 houses is nothing.
func _densest_cluster(houses: Array, radius := 60.0) -> Vector3:
	var best_c := Vector3.ZERO
	var best_score := -1.0
	for a_rec in houses:
		# The raid path passes house NODES; the merchant passes raw
		# positions — accept both.
		var a: Vector3 = (a_rec as Node3D).global_position \
				if a_rec is Node3D else (a_rec as Vector3)
		var score := 0.0
		for b_rec in houses:
			var b: Vector3 = (b_rec as Node3D).global_position \
					if b_rec is Node3D else (b_rec as Vector3)
			var d: float = Vector2(a.x - b.x, a.z - b.z).length()
			if d <= radius:
				score += 1.0 + radius / (radius + d)
		var xz := Vector2(a.x, a.z)
		var hit := _ground_ray(Vector3(xz.x, 500.0, xz.y))
		var y := a.y if hit.is_empty() \
				else (hit.position as Vector3).y
		if score > best_score:
			best_score = score
			best_c = Vector3(xz.x, y, xz.y)
	return best_c


## The shore point nearest `from` (a recorded wet/dry band position),
## grounded on real terrain — the war band's landing beach.
func _nearest_beach(from: Vector2) -> Vector3:
	_shore_probe()
	var best_xz := from
	var best_d := INF
	for s in _shore:
		var p: Vector2 = s.p
		var d: float = p.distance_to(from)
		if d < best_d:
			best_d = d
			best_xz = p
	var hit := _ground_ray(Vector3(best_xz.x, 500.0, best_xz.y))
	var y := sea_level + 0.4 if hit.is_empty() \
			else (hit.position as Vector3).y
	return Vector3(best_xz.x, y, best_xz.y)


## The flagship: hand the placed sailable ship its ride parameters
## (sea level, hull-bottom offset, solved scale and the shared swell
## clock) so it bobs on the exact same water as the moored fleet and
## the shader surface.
func _spawn_sailboat(_props_root: Node3D) -> void:
	for rec in placed:
		if rec.get("sailable", false):
			# The wrapper already lives in the tree (added at placement
			# with the fleet); only the ride parameters are missing.
			var sb: Node = rec.node
			# The fleet parks in the shallows by design; the flagship
			# needs real water under her keel — the aground guard would
			# strand her at her own berth otherwise. Probe outward for
			# the nearest spot with honest depth and re-berth there.
			var ship: Node3D = rec.node
			var org := ship.position
			var deep := _deep_berth(Vector2(org.x, org.z))
			if deep != Vector2.INF:
				ship.position = Vector3(deep.x, org.y, deep.y)
			sb.call("setup", sea_level, (rec.aabb as AABB).position.y,
					rec.scale, Callable(self, "_swell_y"))
			if verbose:
				print("[PropScatter] flagship: sailable longship at %s"
						% [str((rec.node as Node3D).global_position)])
			return


## Deepest nearby berth for the flagship: expanding rings around the
## fleet parking spot, keeping the deepest seabed found. The shelf is
## barely-submerged near shore, so this walks a ring or two out to
## sea; Vector2.INF means no floor found at all (she stays put).
func _deep_berth(from: Vector2) -> Vector2:
	var best := Vector2.INF
	var best_y := -INF
	for r: float in [12.0, 24.0, 36.0, 50.0, 70.0, 95.0, 125.0, 160.0, 200.0, 240.0]:
		for i in range(12):
			var a := TAU * float(i) / 8.0
			var p := from + Vector2(cos(a), sin(a)) * r
			var hit := _ground_ray(Vector3(p.x, 500.0, p.y))
			if hit.is_empty():
				continue
			var y: float = (hit.position as Vector3).y
			if y < best_y:
				best_y = y
				best = p
	return best


## The regatta course: buoys hugging the real shoreline. This map's
## shelf is a barely-submerged sandbank (measured: bottom ~0.28 m
## under the surface near the coast), so each mark parks at the
## DEEPEST point found by probing outward along its bearing — where
## the flagship (draft 0.20) can actually round it. The start mark
## parks beside the flagship. Buoys are 55+ m apart along the coast;
## a too-close trailing mark is dropped so the loop closes visibly.
func _build_boat_race_points() -> Array:
	# The collision pass adds prop shapes DEFERRED — within the setup
	# frame the physics space holds only terrain, and a bearing probe
	# can't see the castle wall / bridge it would strand a buoy inside
	# (measured: one mark parked under a PropBin top at +11.5 m).
	# Waiting one physics frame lets every bearing ray see the real
	# prop geometry, exactly like the chest placement.
	await get_tree().physics_frame
	var pts: Array = []
	if _shore.size() < 24:
		return pts
	# The flagship's berth (the start mark sits near it).
	var ship_xz := Vector2(0, 260)
	for rec in placed:
		if rec.get("sailable", false):
			var sp: Vector3 = (rec.node as Node3D).position
			ship_xz = Vector2(sp.x, sp.z)
			break
	# The buoy band: for every 3rd shoreline sample, probe OUTWARD
	# (seaward — the shore record's normal points INLAND, so negate
	# it) and keep the deepest shelf point within 6-26 m offshore.
	var band: Array[Vector2] = []
	for j in range(0, _shore.size(), 3):
		var s: Dictionary = _shore[j]
		var dir2: Vector2 = -((s.n as Vector2).normalized())
		var best_y := INF
		var best_xz := Vector2.INF
		for off in [6.0, 10.0, 14.0, 18.0, 24.0]:
			var bxz: Vector2 = (s.p as Vector2) + dir2 * off
			var hit := _ground_ray(Vector3(bxz.x, 500.0, bxz.y))
			if hit.is_empty():
				continue
			var y: float = (hit.position as Vector3).y
			if y < best_y:
				best_y = y
				best_xz = bxz
		if best_xz == Vector2.INF or best_y > sea_level - 0.20:
			continue  # no sailable shelf along this bearing
		band.append(best_xz)
	if band.size() < 8:
		return pts
	# Start from the band member nearest the flagship, then march the
	# coastal circuit taking spread marks. _shore is angular order, so
	# the band IS the coast in order. The start mark keeps >= 15 m off
	# the ship's berth: its probe ran before the flagship's hull
	# collider registered, and a buoy parked over the hull reads as
	# dry ground to any later ray.
	var start_i := -1
	var best_d := INF
	for i in band.size():
		var d := band[i].distance_to(ship_xz)
		if d < 15.0:
			continue
		if d < best_d:
			best_d = d
			start_i = i
	if start_i < 0:
		# Degenerate coast (everything hugging the berth): fall back to
		# the nearest member whatever the clearance.
		for i in band.size():
			var d2 := band[i].distance_to(ship_xz)
			if d2 < best_d:
				best_d = d2
				start_i = i
	pts.append(Vector3(band[start_i].x, sea_level + 0.1,
			band[start_i].y))
	var last := band[start_i]
	var idx := start_i
	for k in band.size():
		idx = (idx + 1) % band.size()
		if band[idx].distance_to(last) >= 55.0:
			pts.append(Vector3(band[idx].x, sea_level + 0.1,
					band[idx].y))
		last = band[idx]
	while pts.size() > 2 and Vector2(pts[pts.size() - 1].x,
			pts[pts.size() - 1].z).distance_to(Vector2(pts[0].x,
			pts[0].z)) < 40.0:
		pts.pop_back()
	return pts


## Spawn the regatta (buoys + timing + HUD). Rank thresholds are
## solved from the true course length at rowing speeds with turn
## losses: gold ≈ 4.2 m/s average, silver ≈ 3.4, bronze ≈ 2.6.
func _spawn_boat_race(props_root: Node3D) -> void:
	var pts: Array = await _build_boat_race_points()
	if pts.size() < 5:
		if verbose:
			print("[PropScatter] regatta: not enough sailable coast, skipped")
		return
	var len := 0.0
	for i in range(1, pts.size()):
		len += ((pts[i] as Vector3) \
				- (pts[i - 1] as Vector3)).length()
	var gold := snappedf(len / 4.2, 5.0)
	var silver := snappedf(len / 3.4, 5.0)
	var bronze := snappedf(len / 2.6, 5.0)
	var race := Node3D.new()
	race.set_script(SAIL_RACE_SCRIPT)
	race.setup(pts, [gold, silver, bronze], Callable(self, "_swell_y"))
	props_root.add_child(race)
	if verbose:
		print(("[PropScatter] regatta: %d marks, %.0f m - GOLD %.0fs / "
				+ "SILVER %.0fs / BRONZE %.0fs")
				% [pts.size(), len, gold, silver, bronze])
	# Free-sail lap tracker: full circumnavigations around the course
	# centroid, timed and saved like the regatta best.
	var c := Vector3.ZERO
	for p in pts:
		c += p as Vector3
	var lap := Node3D.new()
	lap.set_script(SAIL_LAP_SCRIPT)
	lap.setup(c / float(pts.size()))
	props_root.add_child(lap)


## --- Treasure chests ---------------------------------------------------------

## Lootable chests on the island's high points: one per castle rooftop
## (raycast down onto the real mesh roof), one per lighthouse gallery,
## and one on each climb formation's highest standable top. Opened
## chests persist across sessions (user://chests.cfg), so the island
## slowly fills with trophies of past conquests.
func _spawn_chests(props_root: Node3D) -> void:
	# CRITICAL: the collision pass adds every prop shape DEFERRED —
	# within the setup frame the physics space still holds only the
	# terrain (measured: 625/625 rays at a lighthouse hit the beach,
	# one frame later the same rays find the hull top). Waiting one
	# physics frame lets every rooftop/gallery/step ray see the real
	# prop geometry.
	await get_tree().physics_frame
	var n := 0
	var placed_before := 0
	var spots: Array[String] = []
	for rec in placed:
		var kind: String = rec.kind
		var pos: Vector3 = rec.pos
		var aabb: AABB = rec.aabb
		var s: float = rec.scale
		var world_h := aabb.size.y * s
		if kind.begins_with("old_castle"):
				# Castles solve to 30-40 m: probe a 5x5 fan across the
				# footprint — the highest hit is a rooftop or turret
				# crown (mesh collision makes it walkable).
				var foot := maxf(aabb.size.x, aabb.size.z) * s * 0.35
				var best := Vector3.INF
				var best_y := -INF
				var best_any := Vector3.INF
				var best_any_y := -INF
				for gx in [-1.0, -0.5, 0.0, 0.5, 1.0]:
					for gz in [-1.0, -0.5, 0.0, 0.5, 1.0]:
						var off := Vector2(gx, gz) * foot
						var ch := _ground_ray(Vector3(
								pos.x + off.x,
								pos.y + world_h * 1.15,
								pos.z + off.y))
						if ch.is_empty():
							continue
						var hy := (ch.position as Vector3).y
						var nrm: Vector3 = ch.get("normal",
								Vector3.UP)
						if hy > best_any_y:
							best_any_y = hy
							best_any = Vector3(
									pos.x + off.x, hy,
									pos.z + off.y)
						# Chests belong on FLAT, walkable roof:
						# a turret FLANK (steep normal) reads as
						# buried in the slope from a foot away.
						if nrm.y < 0.72:
							continue
						if hy > best_y:
							best_y = hy
							best = Vector3(pos.x + off.x, hy,
									pos.z + off.y)
				if best == Vector3.INF:
					best = best_any
					best_y = best_any_y
				if best == Vector3.INF:
					continue
				n += _place_chest(props_root, best, "castle")
				if n > placed_before:
					spots.append("castle roof %.0f m"
							% (best_y - pos.y))
				placed_before = n
		elif bool(rec.get("beacon", false)):
			# Lighthouse: the mega-mesh got a convex HULL collider —
			# there is no real balcony mesh, and rays from mid-height
			# slip PAST the hull and land on the beach far below
			# (measured -6 m). Probe from ABOVE the whole silhouette
			# instead: the first hit is the walkable hull top (the
			# "invisible extra floor" the player already lands on).
			var landed := false
			# The tower is massively OFFSET from the model pivot (a
			# leaning tower on a wide rock base — measured: the hull
			# top sits 12-18 m sideways of `pos`). Grid-scan the FULL
			# neighbourhood from high above; the highest hit above
			# the beach band is the walkable hull top.
			var step := 1.5
			var span := 18.0
			var offs: Array[float] = []
			var o := -span
			for _i in int(span * 2.0 / step) + 1:
				offs.append(o)
				o += step
			var best := Vector3.INF
			var best_y := -INF
			for dx in offs:
				if landed:
					break
				for dz in offs:
					var lh := _ground_ray(Vector3(
							pos.x + dx, pos.y + 80.0,
							pos.z + dz))
					if lh.is_empty():
						continue
					var hp := lh.position as Vector3
					# Above the beach band: a shore hit is
					# not a beacon treasure (measured -6 m).
					if hp.y >= pos.y + world_h * 0.15 \
							and hp.y > best_y:
						best_y = hp.y
						best = Vector3(pos.x + dx,
								hp.y, pos.z + dz)
			if best != Vector3.INF:
				n += _place_chest(props_root, best, "lighthouse")
				if n > placed_before:
					spots.append("lighthouse top %.0f m"
							% (best_y - pos.y))
					placed_before = n
					landed = true
		elif kind.begins_with("climb_"):
			var tops: Array = rec.get("tops", [])
			var pts: Array = rec.get("pts", [])
			if tops.is_empty() or pts.size() != tops.size():
				continue
			# Highest CONFIRMING step: tree crowns are leaves
			# (no collision) — walk down the recorded tops until
			# a ray proves real standable geometry, so every
			# formation gets its chest.
			var order: Array[int] = []
			for t in tops.size():
				order.append(t)
			order.sort_custom(func(a: int, b: int) -> bool:
				return (tops[a] as float) > (tops[b] as float))
			for t in order:
				var tp := pts[t] as Vector2
				n += _place_chest(props_root,
						Vector3(tp.x, tops[t], tp.y), "climb")
				if n > placed_before:
					spots.append("climb top %.0f m"
							% ((tops[t] as float) - pos.y))
					placed_before = n
					break
	if n > 0 and verbose:
		print("[PropScatter] treasure chests: %d placed (%s)"
				% [n, ", ".join(spots)])
	# Both spawners' placed totals persist here once the run completes,
	# so the title's "12 of 46 chests plundered" line survives map
	# changes; opened ids already live in chests.cfg.
	_chests_placed += n


## One chest at a world spot, standing on the surface. A confirming
## raycast (the spot must be real, standable geometry within reach of
## the estimate) keeps chests out of thin air when a record's numbers
## drift from the actual mesh.
func _place_chest(props_root: Node3D, at: Vector3, tag: String) -> int:
	var confirm := _ground_ray(Vector3(at.x, at.y + 2.0, at.z))
	var surface := at.y
	if not confirm.is_empty():
		var cy := (confirm.position as Vector3).y
		if absf(cy - at.y) > 1.5:
			return 0  # the spot isn't real: skip rather than float
		surface = cy
		var cn: Vector3 = confirm.get("normal", Vector3.UP)
		if cn.y < 0.35:
			return 0  # a sheer wall is not a shelf
	surface += 0.04  # sit ON the surface, never z-fighting it
	var chest := Node3D.new()
	chest.set_script(CHEST_SCRIPT)
	var id := "chest_%s_%d_%d" % [tag, int(at.x * 10.0),
			int(at.z * 10.0)]
	chest.call("setup", id, surface)
	chest.position = Vector3(at.x, surface, at.z)
	chest.rotation.y = _rng.randf() * TAU
	props_root.add_child(chest)
	_taken.append({"xz": Vector2(at.x, at.z), "r": 1.2})
	return 1


## The sea hoard: chests hidden in OPEN water far offshore, half-buried
## in the seabed like wreck salvage. This map's sea is a uniform shallow
## shelf (measured: the bottom never sits more than ~0.31 m below the
## surface anywhere), so "only reachable by sailing" comes from the
## chest itself: a sunken chest opens ONLY for a nearly-stopped hull
## almost directly overhead — a swimmer standing on the lid can not
## open it, and the bubble glint answers only to a sailing hull. Each
## spot must prove itself by raycast: submerged bottom (0.15–0.45 m
## under the surface, so the half-buried lid rides at the waterline),
## no dry land within 60 m (open sea, not the beach), and no prop
## within 12 m. Seeded, kept apart, marked on no map.
const SEA_HOARD_COUNT := 6

func _spawn_sea_hoard(props_root: Node3D) -> void:
	await get_tree().physics_frame  # prop shapes register deferred
	var sea := sea_level
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 7777
	var taken: Array[Vector2] = []
	var n := 0
	# Ring bands at 100-150 m offshore — the measured deep band. The
	# deepest-bearing pass first: place the first pass at the deepest
	# point per bearing, the second at half the offset.
	for pass_i in 4:
		for si in _shore.size():
			if n >= SEA_HOARD_COUNT:
				break
			var s: Variant = _shore[si]
			if pass_i == 1 and (si % 2) == 0:
				continue  # later passes: alternate bearings only
			if pass_i == 2 and (si % 3) != 0:
				continue
			if pass_i == 3 and (si % 4) != 0:
				continue
			var sdir: Vector2 = (s.n as Vector2).normalized() * -1.0
			var off: float = [100.0, 50.0, 75.0, 125.0][pass_i]
			# Nudge along the coast so chests don't share a bearing.
			var perp := Vector2(-sdir.y, sdir.x)
			var q: Vector2 = (s.p as Vector2) + sdir * off \
					+ perp * rng.randf_range(-14.0, 14.0)
			var ok := true
			for t in taken:
				if t.distance_to(q) < 50.0:
					ok = false
					break
			if not ok:
				continue
			var hit := _ground_ray(Vector3(q.x, 500.0, q.y))
			if hit.is_empty():
				continue
			var bottom := (hit.position as Vector3).y
			# Submerged bottom: the chest half-buries with its lid at
			# the waterline. Dry seabed (bottom above the surface) is
			# land — reject. The measured shelf never exceeds ~0.31 m
			# deep, so the window hugs that band.
			var depth := sea - bottom
			if depth < 0.12 or depth > 0.33:
				continue
			# Open water: no dry land within ~36 m (2-3x farther out
			# than the regatta marks or any shore prop). A 16-direction
			# fan (dense enough that an islet can't slip between beams).
			var near_dry := false
			for a in 16:
				var ang := TAU * float(a) / 16.0
				var probe := q + Vector2(cos(ang), sin(ang)) * 36.0
				var ph := _ground_ray(Vector3(probe.x, 500.0, probe.y))
				if not ph.is_empty() \
						and (ph.position as Vector3).y > sea + 0.4:
					near_dry = true
					break
			if near_dry:
				continue
			# A prop within 12 m would break the "open water" fiction.
			var near_prop := false
			for rec in placed:
				var pp: Vector3 = rec.pos
				if Vector2(pp.x - q.x, pp.z - q.y).length() < 12.0:
					near_prop = true
					break
			if near_prop:
				continue
			var chest := Node3D.new()
			chest.set_script(CHEST_SCRIPT)
			var id := "sea_%d_%d" % [int(q.x * 10.0), int(q.y * 10.0)]
			chest.call("setup_sunken", id, bottom + 0.04)
			chest.call("set_waterline", sea_level)
			# Wreck look: sunk INTO the sand (a bit over half the 0.55 m
			# body buried) and knocked slightly off level, like a chest
			# that fell off a sunk ship long ago.
			chest.position = Vector3(q.x, bottom - 0.22, q.y)
			chest.rotation = Vector3(
					rng.randf_range(-0.16, 0.16), rng.randf() * TAU,
					rng.randf_range(-0.16, 0.16))
			props_root.add_child(chest)
			_taken.append({"xz": q, "r": 1.2})
			taken.append(q)
			n += 1
	if n > 0 and verbose:
		print("[PropScatter] sea hoard: %d chests in open water" % n)
	_chests_placed += n


## --- The dive site ---------------------------------------------------------
## The sea is a uniform ankle-deep shelf (measured: the terrain bottom
## never sits more than ~0.31 m below the surface), so the swim/dive
## stack had no deep water to live in and the sea hoard read as
## unreachable. The dive site fixes the WORLD, not the code: a sunken
## wreck platform far offshore in the bottomless zone with its own
## collider floor — the swim probe finds REAL depth over it, swimming
## and diving arm, and the sunken chests on its deck open to a DIVER
## at the lid (that path already exists in TreasureChest: the
## swim-and-dive loot loop). A beacon pillar marks the site from the
## surface; the serpents that guard sunken chests will circle the
## wreck, so the dive has its risk too.

const WRECK_DECK_DEPTH := 5.5      # deck below the surface (m)
const WRECK_SIZE := 14.0           # platform square (m)
const WRECK_CHESTS := 3

func _spawn_dive_site(props_root: Node3D) -> void:
	await get_tree().physics_frame  # prop shapes register deferred
	var sea := sea_level
	# Find the site: an offshore bearing whose ground ray finds NO
	# seabed within 600 m — the bottomless zone past the shelf.
	var site := Vector2.INF
	for si in _shore.size():
		var s: Variant = _shore[(si * 5) % _shore.size()]
		var d: Vector2 = ((s.n as Vector2).normalized() * -1.0)
		var q: Vector2 = (s.p as Vector2) + d * 80.0
		var hit := _ground_ray(Vector3(q.x, 500.0, q.y))
		if hit.is_empty():
			site = q
			break
	if site == Vector2.INF:
		if verbose:
			print("[PropScatter] dive site: no deep water found, skipped")
		return
	var deck_y := sea - WRECK_DECK_DEPTH
	# --- the wreck platform (the new "seabed" the probe finds) ------
	var wreck := StaticBody3D.new()
	wreck.name = "DiveWreck"
	wreck.collision_layer = 1      # world — the swim probe reads it
	wreck.collision_mask = 0
	var wmesh := MeshInstance3D.new()
	var wb := BoxMesh.new()
	wb.size = Vector3(WRECK_SIZE, 0.7, WRECK_SIZE)
	wmesh.mesh = wb
	wmesh.position.y = -0.35
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.23, 0.16, 0.10)
	wmat.roughness = 0.95
	wmesh.material_override = wmat
	wreck.add_child(wmesh)
	var wshape := CollisionShape3D.new()
	var wbox := BoxShape3D.new()
	wbox.size = Vector3(WRECK_SIZE, 0.7, WRECK_SIZE)
	wshape.shape = wbox
	wshape.position.y = -0.35
	wreck.add_child(wshape)
	# Deck dressing: broken ribs (tilted pillars) so it reads as a
	# wreck, not a raft.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 991
	for k in 7:
		var rib := MeshInstance3D.new()
		var rb := BoxMesh.new()
		rb.size = Vector3(0.4, rng.randf_range(2.0, 4.5), 0.6)
		rib.mesh = rb
		rib.position = Vector3(
				rng.randf_range(-WRECK_SIZE * 0.42, WRECK_SIZE * 0.42),
				rb.size.y * 0.5 - 0.2,
				rng.randf_range(-WRECK_SIZE * 0.42, WRECK_SIZE * 0.42))
		rib.rotation = Vector3(rng.randf_range(-0.5, 0.5),
				rng.randf() * TAU, rng.randf_range(-0.5, 0.5))
		rib.material_override = wmat
		wreck.add_child(rib)
	# Surface beacon: the one allowed glow — a slim pillar from the
	# broken mast down to the deck, so the site is findable from a
	# sailing hull the way the hoard's depth markers are.
	var mast := MeshInstance3D.new()
	var mcyl := CylinderMesh.new()
	mcyl.top_radius = 0.22
	mcyl.bottom_radius = 0.5
	mcyl.height = WRECK_DECK_DEPTH
	mcyl.radial_segments = 8
	mcyl.rings = 1
	mast.mesh = mcyl
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mm.albedo_color = Color(0.5, 0.8, 1.0, 0.14)
	mm.cull_mode = BaseMaterial3D.CULL_DISABLED
	mast.material_override = mm
	mast.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mast.position.y = WRECK_DECK_DEPTH * 0.5 + 0.35
	wreck.add_child(mast)
	wreck.position = Vector3(site.x, deck_y, site.y)
	props_root.add_child(wreck)
	# --- the sunken chests on the deck ------------------------------
	var placed_n := 0
	for k in WRECK_CHESTS:
		var chest := Node3D.new()
		chest.set_script(CHEST_SCRIPT)
		var a := TAU * float(k) / float(WRECK_CHESTS) + 0.6
		var off := Vector3(cos(a), 0.0, sin(a)) * (WRECK_SIZE * 0.28)
		var id := "wreck_%d_%d" % [int(site.x * 10.0), k]
		chest.call("setup_sunken", id, deck_y + 0.04)
		chest.call("set_waterline", sea_level)
		chest.position = off
		chest.rotation = Vector3(rng.randf_range(-0.12, 0.12),
				rng.randf() * TAU, rng.randf_range(-0.12, 0.12))
		wreck.add_child(chest)
		_chests_placed += 1
		placed_n += 1
	# Keep other scatters clear of the site.
	_taken.append({"xz": site, "r": WRECK_SIZE * 0.7})
	if verbose:
		print("[PropScatter] dive site: wreck at %s — %d m down, %d chests"
				% [site, WRECK_DECK_DEPTH, placed_n])


## The wandering trader: a viking with a pack who strolls nowhere but
## sells — the gold sink for the plunder. Parks near the village's
## densest house cluster; 1/2/3 buy his wares (fireball upgrade, swim
## charm, hoard map) once the customer is close.
const MERCHANT_SCRIPT := preload("res://Player/WanderingMerchant.gd")
const QUESTBOARD_SCRIPT := preload("res://Player/QuestBoard.gd")
const ELDER_SCRIPT := preload("res://Player/VillageElder.gd")

## The elder and his board: the quest board (a plain Node — it owns
## progress, persistence and the scroll HUD) spawns first, then the
## elder a few paces off, who reads the board's QUESTS to build his
## counsel panel and pays out its claims. Same village hub as the
## merchant: the densest house cluster.
func _spawn_elder(props_root: Node3D) -> void:
	var houses: Array[Vector3] = []
	for rec in placed:
		if rec.kind.contains("house"):
			houses.append(rec.pos)
	if houses.is_empty():
		return
	var center := _densest_cluster(houses, 60.0)
	var board := QUESTBOARD_SCRIPT.new()
	board.name = "QuestBoard"
	props_root.add_child(board)
	var elder := ELDER_SCRIPT.new()
	elder.name = "VillageElder"
	var glb: PackedScene = load("res://imports/viking_lowpoly.glb")
	if glb != null:
		elder.add_child(glb.instantiate())
	var spot := center + Vector3(3.4, 0.0, 2.4)
	var hit := _ground_ray(Vector3(spot.x, 500.0, spot.z))
	var y := spot.y
	if not hit.is_empty():
		y = (hit.position as Vector3).y
	elder.position = Vector3(spot.x, y, spot.z)
	props_root.add_child(elder)
	if verbose:
		print("[PropScatter] elder at %s (board live)" % elder.position)

func _spawn_merchant(props_root: Node3D) -> void:
	var houses: Array[Vector3] = []
	for rec in placed:
		if rec.kind.contains("house"):
			houses.append(rec.pos)
	if houses.is_empty():
		return
	var center := _densest_cluster(houses, 60.0)
	var m := MERCHANT_SCRIPT.new()
	m.name = "WanderingMerchant"
	var glb: PackedScene = load("res://imports/viking_lowpoly.glb")
	if glb != null:
		var inst := glb.instantiate()
		m.add_child(inst)
		# The wanderers' scale: measure and match it so he reads
		# human next to the hero.
		m.scale = Vector3.ONE * 1.0
	# Ground him at the village on the real surface.
	var hit := _ground_ray(Vector3(center.x, 500.0, center.z))
	var y := center.y
	if not hit.is_empty():
		y = (hit.position as Vector3).y
	m.position = Vector3(center.x, y, center.z)
	props_root.add_child(m)
	if verbose:
		print("[PropScatter] merchant at %s" % m.position)


## The deepest sea-hoard chest carries THE HORN OF THE NORTH-SEA —
## the relic chase. The chest opens exactly like the others; this one
## just launches the golden horn flight and the banner when it does.
func _mark_relic_chest() -> void:
	var best: Node = null
	var best_depth := -1.0
	for c in get_tree().get_nodes_in_group("sunken_chest"):
		var n3 := c as Node3D
		if n3 == null:
			continue
		var d := sea_level - n3.global_position.y
		if d > best_depth:
			best_depth = d
			best = c
	if best != null:
		best.call("mark_relic")
		if verbose:
			print("[PropScatter] relic hoard chest marked (%.2f m down)"
					% best_depth)


## One guardian per hoard chest: a sea serpent circles its chest just
## under the surface and makes the dive a risk — two bites and the
## hero is dragged under and back to his spawn. Fireballs drive the
## beast off (a hull-top defense, or a desperate underwater shot).
const SERPENT_SCRIPT := preload("res://Player/SeaSerpent.gd")

func _spawn_serpents() -> void:
	var n := 0
	for c in get_tree().get_nodes_in_group("sunken_chest"):
		var chest := c as Node3D
		if chest == null:
			continue
		var s := SERPENT_SCRIPT.new()
		s.call("setup", chest)
		add_child(s)
		n += 1
	if verbose:
		print("[PropScatter] sea serpents: %d guardians" % n)


## One island-wide butterfly colony: the stops are the flower patches'
## bloom heads, so the butterflies flutter between the flowers.
func _spawn_butterflies(props_root: Node3D) -> void:
	var heads := PackedVector3Array()
	for rec in placed:
		if rec.kind != "flower_patch":
			continue
		var p: Vector3 = rec.pos
		# Bloom head height: the patches' tallest flower is ~0.26 m.
		heads.append(Vector3(p.x, p.y + 0.3, p.z))
	if heads.size() < 2:
		return
	var colony := Node3D.new()
	colony.set_script(BUTTERFLY_SCRIPT)
	colony.set("colony_seed", seed_value + 4241)
	colony.setup(heads, 10)
	props_root.add_child(colony)
	colony.global_position = Vector3.ZERO
	if verbose:
		print("[PropScatter] butterflies: %d on %d patches"
				% [mini(10, heads.size()), heads.size()])


## Perches one flock of birds in each grove's canopy: perch points are
## sampled from the grove's own tree tops (plus the grove centre), so
## the birds sit in THIS grove's trees and scatter through THIS
## grove's air.
func _spawn_birds(props_root: Node3D) -> void:
	_ensure_groves()
	for i in _groves.size():
		var g: Dictionary = _groves[i]
		var gc: Vector2 = g.xz
		var perches := PackedVector3Array()
		# The grove centre itself is always a perch (it is guaranteed
		# dry, flat land with trees around it).
		var chit := _ground_ray(Vector3(gc.x, 500.0, gc.y))
		if not chit.is_empty():
			perches.append(Vector3(gc.x,
					chit.position.y + 5.5, gc.y))
		for rec in placed:
			var k: String = rec.kind
			if not (k.begins_with("jabami_anime_tree_v")
					or k == "maple_tree.glb"):
				continue
			var p: Vector3 = rec.pos
			if Vector2(p.x, p.z).distance_to(gc) > (g.r as float) + 2.0:
				continue
			perches.append(Vector3(p.x,
					p.y + (rec.aabb.size.y * rec.scale) + 0.15, p.z))
		if perches.size() < 2:
			continue
		var flock := Node3D.new()
		flock.set_script(BIRDS_SCRIPT)
		flock.set("flock_seed", seed_value + i * 104729)
		flock.set_perches(perches)
		# Position BEFORE add_child: the flock's _ready converts perch
		# points to local space using global_position, which is only
		# correct once the transform is set.
		flock.position = Vector3(gc.x, chit.position.y + 5.5, gc.y)
		props_root.add_child(flock)
	if verbose:
		print("[PropScatter] birds: %d flocks" % _groves.size())


## One wind field for the whole island: every tree (and grass tuft)
## registered here leans downwind — gentle breeze at rest, gusts when
## a player swoops past, downwash punches through during dives.
func _spawn_wind(_props_root: Node3D) -> void:
	var wind := Node3D.new()
	wind.set_script(WIND_SCRIPT)
	add_child(wind)
	_wind_node = wind as WindSway
	var idx := 0
	for rec in placed:
		if not (rec.get("trunk", false) or rec.get("no_collision", false)
				or rec.kind == "bush_patch"):
			continue
		var kind: String = rec.kind
		if not (kind.begins_with("jabami") or kind == "maple_tree.glb"
				or kind == "bush_patch" or kind == "flower_patch"
				or kind == "reeds"):
			continue
		var n: Node3D = rec.node
		var top: float = n.global_position.y \
				+ (rec.aabb.size.y * rec.scale)
		wind.call("register_tree", n, top, idx)
		idx += 1
	if verbose:
		print("[PropScatter] wind: %d swaying trees" % idx)


## Little tree clusters: THICKET_COUNT small copse centres are drawn
## on flat dry land (clear of the groves, each other and everything
## already placed), then each is filled with 3–6 SAPLINGS — one
## shared model per clump at 18–34% of full tree size, jumbled into
## a tight irregular clump like volunteers sprouting around a seed
## tree. Same trunk-only collision as the big trees, so the little
## woods are solid and shootable; they register in `placed` with
## trunk=true so the wind pass sweeps them in automatically.
func _place_thickets(props_root: Node3D) -> void:
	_thick_rng.seed = seed_value + 771
	var packed: Array[PackedScene] = []
	for path in THICKET_MODELS:
		var ps := load(path) as PackedScene
		if ps != null:
			packed.append(ps)
	if packed.is_empty():
		return
	var built := 0
	for t in THICKET_COUNT:
		var centre := Vector2.INF
		for attempt in 160:
			var ang := _thick_rng.randf() * TAU
			var rad := _thick_rng.randf_range(scatter_min_radius,
					scatter_max_radius - THICKET_RADIUS)
			var xz := Vector2(cos(ang), sin(ang)) * rad
			var hit := _ground_ray(Vector3(xz.x, 500.0, xz.y))
			if hit.is_empty() or hit.position.y < sea_level + 0.5:
				continue
			var normal: Vector3 = hit.get("normal", Vector3.UP)
			if rad_to_deg(normal.angle_to(Vector3.UP)) > 10.0:
				continue
			var clear := true
			for g in _groves:
				if xz.distance_to(g.xz) < (g.r as float) \
						+ THICKET_RADIUS + 4.0:
					clear = false
					break
			if not clear:
				continue
			if _too_close(xz, 12.0, THICKET_RADIUS):
				continue
			centre = xz
			break
		if centre == Vector2.INF:
			continue
		_thickets.append({"xz": centre, "r": THICKET_RADIUS})
		built += 1
		# Fill the clump: one model per thicket, a handful of saplings.
		var ps: PackedScene = packed[_thick_rng.randi_range(0,
				packed.size() - 1)]
		var maple := not ps.resource_path.contains("jabami")
		# Full grown size of this model (the scatter table's target):
		# saplings take a fraction of it.
		var grown := 11.0 if maple else 9.5
		var n := _thick_rng.randi_range(4, 7)
		for i in n:
			# A few sample tries per slot: a clump on awkward terrain
			# (a bank, a pond edge) still fills from whatever part of
			# its disc plants, instead of thinning to a lonely pair.
			var prop: Node3D = null
			var aabb := AABB()
			var s := 0.0
			var xz := Vector2.ZERO
			var hit := {}
			for try_i in 4:
				var sa := _thick_rng.randf() * TAU
				var sr := _thick_rng.randf() * THICKET_RADIUS * 0.8
				xz = centre + Vector2(cos(sa), sin(sa)) * sr
				hit = _ground_ray(Vector3(xz.x, 500.0, xz.y))
				if hit.is_empty() \
						or (hit.position.y as float) < sea_level + 0.2:
					continue
				var normal: Vector3 = hit.get("normal", Vector3.UP)
				if rad_to_deg(normal.angle_to(Vector3.UP)) > 14.0:
					continue
				var cand := ps.instantiate() as Node3D
				aabb = _prop_aabb(cand)
				# Target height in metres (a fraction of the grown
				# tree), then SOLVE the scale against the model's raw
				# AABB — the tree GLBs are authored in huge units, so
				# the scale must be solved like every other rule does,
				# never set directly (setting it made 500 m giants).
				var target_h := grown * _thick_rng.randf_range(0.18, 0.34)
				s = target_h / maxf(aabb.size.y, 0.001)
				if s <= 0.0 or aabb.size.y <= 0.001:
					cand.free()
					continue
				var r_self := 0.5 * maxf(aabb.size.x, aabb.size.z) * s
				# Tight clump: saplings pack at a fraction of the grown
				# trees' spacing — that is what makes a thicket read as
				# a little copse instead of scattered young trees.
				# Blocking is TRUNK-width against bigger neighbours (a
				# sapling sprouting under a grown tree's canopy is
				# exactly what a thicket edge looks like), full-width
				# against fellow saplings so clump mates never merge
				# into one blob.
				var blocked := false
				for tk in _taken:
					var tr: float = tk.r
					var need := 1.35 + r_self * 0.35 \
							+ (tr if tr < 2.5 else 1.0)
					if xz.distance_to(tk.xz as Vector2) < need:
						blocked = true
						break
				if blocked:
					cand.free()
					continue
				prop = cand
				break
			if prop == null:
				continue
			var r_fin := 0.5 * maxf(aabb.size.x, aabb.size.z) * s
			prop.scale = Vector3.ONE * s
			prop.rotation.y = _thick_rng.randf() * TAU
			prop.position = Vector3(xz.x,
					(hit.position.y as float) - aabb.position.y * s, xz.y)
			props_root.add_child(prop)
			var body := _bin_body(collision_layer, prop.global_position)
			_add_trunk(body, aabb, prop)
			placed.append({"kind": ps.resource_path.get_file(),
					"node": prop, "pos": prop.position, "aabb": aabb,
					"ship": false, "scale": s, "r": r_fin,
					"trunk": true, "no_collision": false,
					"breakable": false})
			# Claim the spot so later saplings in this and other clumps
			# space against it (half footprint: clump mates sit close).
			_taken.append({"xz": xz, "r": r_fin * 0.5})
		# One extra draw per thicket: varies nothing (the stream is
		# private), but mirrors the seed-tree-then-saplings story so a
		# future tweak per clump has a stable slot.
		_thick_rng.randf()
	if verbose:
		print("[PropScatter] thickets: %d clusters" % built)


## --- Natural climbing spots ---------------------------------------------


## Scatter stacked-rock cairns, fallen climbing trees and hillside
## stone ledges across the island (replaces the removed jumping
## platforms). Each formation is a staircase whose consecutive step
## TOPS rise at most CLIMB_MAX_STEP — reachable with the player's
## standing jump — so a climb never dead-ends, and every top is a
## lookout (or a fireball perch). Steps are grounded INDIVIDUALLY on
## the real terrain, so formations follow the ground instead of
## floating or burying. Placement records carry the measured step
## tops ("tops") for the verification harness.
func _place_climb_spots(props_root: Node3D) -> void:
	var built := 0
	var wants := {"cairn": CLIMB_CAIRNS, "tree": CLIMB_TREES,
			"ledge": CLIMB_LEDGES}
	for kind in wants:
		for i in int(wants[kind]):
			if _place_one_climb(props_root, kind):
				built += 1
	if verbose:
		print("[PropScatter] climb spots: %d formations" % built)
		print("[climb-dbg] %s" % str(_climb_dbg))

## TEMP diagnostics: rejection reasons per climbing kind.
var _climb_dbg := {}


## One attempt loop for a single climbing formation of `kind`.
func _place_one_climb(props_root: Node3D, kind: String) -> bool:
	var dbg := {"close": 0, "noground": 0, "sea": 0, "slope": 0,
			"ok": 0}
	# Same dict object referenced for the summary print: mutated in
	# place during the loop, so it always holds the final counts.
	_climb_dbg[kind] = dbg
	for attempt in 120:
		var ang := _rng.randf() * TAU
		var rad := _rng.randf_range(scatter_min_radius + 8.0,
				scatter_max_radius - 8.0)
		var xz := Vector2(cos(ang) * rad, sin(ang) * rad)
		if _too_close(xz, CLIMB_SPACING, 2.5):
			dbg["close"] += 1
			continue
		var hit := _ground_ray(Vector3(xz.x, 500.0, xz.y))
		if hit.is_empty():
			dbg["noground"] += 1
			continue
		var base: float = (hit.position as Vector3).y
		if base < sea_level + 0.6 or base < min_land_height:
			dbg["sea"] += 1
			continue
		var normal: Vector3 = hit.get("normal", Vector3.UP)
		if rad_to_deg(normal.angle_to(Vector3.UP)) > 12.0:
			dbg["slope"] += 1
			continue
		dbg["ok"] += 1
		var root := Node3D.new()
		root.name = "ClimbSpot"
		var tops: Array[float] = []
		var pts: Array[Vector2] = []
		var yaw := _rng.randf() * TAU
		match kind:
			"cairn":
				_build_climb_cairn(root, xz, base, tops, pts)
			"tree":
				_build_climb_tree(root, xz, base, yaw, tops, pts)
			"ledge":
				_build_climb_ledge(root, xz, base, yaw, tops, pts)
		if tops.size() < 3:
			root.free()
			continue
		# Root stays AT THE ORIGIN: the builders place every mesh in
		# WORLD coordinates (so each step can be grounded against the
		# real terrain individually); reparenting under props_root at
		# identity keeps those world values valid. Moving the root would
		# offset the whole formation twice.
		props_root.add_child(root)
		_taken.append({"xz": xz, "r": 3.0})
		placed.append({"kind": "climb_" + kind, "node": root,
				"pos": Vector3(xz.x, base, xz.y),
				"aabb": AABB(Vector3(-3.5, 0, -3.5),
				Vector3(7, 9, 7)), "tops": tops, "pts": pts,
				"ship": false, "scale": 1.0, "r": 3.0,
				"trunk": false, "no_collision": true,
				"breakable": false})
		return true
	return false


## One boulder step: a low-poly tapered drum whose top face is the
## standable surface, at world `wxz`, top exactly `top_y`. Mesh and
## collision share the exact top height — what you see is what you
## stand on. Sinks into the terrain when the ground is higher.
func _climb_rock(parent: Node3D, mat: StandardMaterial3D, wxz: Vector2,
		top_y: float, radius: float) -> void:
	var height := radius * _rng.randf_range(1.7, 2.2)
	var bottom := top_y - height
	var hit := _ground_ray(Vector3(wxz.x, 500.0, wxz.y))
	if not hit.is_empty():
		# Sink into rising ground, but never above the standable top.
		bottom = minf(bottom, (hit.position as Vector3).y - 0.3)
		bottom = minf(bottom, top_y - 0.25)
		height = top_y - bottom
	var mesh := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius * 1.3
	cm.height = height
	cm.radial_segments = 9
	mesh.mesh = cm
	mesh.material_override = mat
	mesh.position = Vector3(wxz.x, (top_y + bottom) * 0.5, wxz.y)
	mesh.rotation.y = _rng.randf() * TAU
	parent.add_child(mesh)
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height
	_add_shaped(_bin_body(collision_layer,
			Vector3(wxz.x, bottom, wxz.y)), cyl,
			Transform3D(Basis.IDENTITY,
			Vector3(wxz.x, (top_y + bottom) * 0.5, wxz.y)))


## Stacked-rock cairn: three boulders spiralling upward — step, ring
## and capstone — each top CLIMB_STEP above the last, clamped to
## CLIMB_MAX_STEP against the local terrain.
func _build_climb_cairn(parent: Node3D, xz: Vector2, base: float,
		tops: Array[float], tps: Array[Vector2]) -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.47, 0.46, 0.43).darkened(
			_rng.randf_range(0.0, 0.12))
	stone.roughness = 1.0
	var radii: Array[float] = [0.0, _rng.randf_range(1.5, 1.9),
			_rng.randf_range(2.8, 3.2)]
	var sizes: Array[float] = [1.25, 1.05, 0.9]
	var prev := INF
	for st in 3:
		var a := _rng.randf() * TAU
		var wxz := xz + Vector2(cos(a), sin(a)) * radii[st]
		var g := base
		var hit := _ground_ray(Vector3(wxz.x, 500.0, wxz.y))
		if not hit.is_empty():
			g = (hit.position as Vector3).y
		var top: float = g + CLIMB_STEP * float(st + 1)
		if prev != INF:
			top = minf(top, prev + CLIMB_MAX_STEP)
		_climb_rock(parent, stone, wxz, top, sizes[st])
		tps.append(wxz)
		tops.append(top)
		prev = top


## A big fallen tree laid along `yaw`: the trunk is a series of
## overlapping lying cylinder segments whose crest tops rise by
## CLIMB_STEP per segment — run up the trunk like a ramp of steps —
## ending in a leafy crown lookout. The root collar at the base is
## the first foothold.
func _build_climb_tree(parent: Node3D, xz: Vector2, base: float,
		yaw: float, tops: Array[float], tps: Array[Vector2]) -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.40, 0.29, 0.18).darkened(
			_rng.randf_range(0.0, 0.12))
	wood.roughness = 1.0
	var r := _rng.randf_range(0.5, 0.68)
	var dir := Vector2(cos(yaw), sin(yaw))
	# Root collar: a low wide drum at the base — step one.
	_climb_rock(parent, wood, xz, base + 0.4, r * 1.5)
	tps.append(xz)
	tops.append(base + 0.4)
	# Lay the cylinder along `yaw`: Z-rotation tips +Y into +X, then a
	# yaw of -yaw aims it at dir=(cos yaw, sin yaw) — rotating (1,0,0)
	# about UP by -yaw lands on (cos yaw, 0, sin yaw).
	var lay := Basis(Vector3.UP, -yaw) * Basis(Vector3(0, 0, 1),
			-PI * 0.5)
	var seg_h := 2.6
	var prev := base + 0.4
	for i in 4:
		# End-to-end, NOT overlapping: overlapping lying cylinders
		# pinch the space above each crest — a player standing on one
		# segment spawns inside the next and gets ejected by
		# depenetration (caught by the jump-sim harness). Touching
		# segments read as one continuous log with clean step faces.
		var d := 1.0 + float(i) * seg_h
		var wxz := xz + dir * d
		var g := base
		var hit := _ground_ray(Vector3(wxz.x, 500.0, wxz.y))
		if not hit.is_empty():
			g = (hit.position as Vector3).y
		var top: float = minf(g + CLIMB_STEP * float(i + 1),
				prev + CLIMB_MAX_STEP)
		# The crest (visible top of the lying trunk) is the standable
		# line: the cylinder centre sits one radius below it.
		var centre := top - r
		var cyl := CylinderShape3D.new()
		cyl.radius = r
		cyl.height = seg_h
		var xf := Transform3D(lay, Vector3(wxz.x, centre, wxz.y))
		_add_shaped(_bin_body(collision_layer,
				Vector3(wxz.x, centre, wxz.y)), cyl, xf)
		var mesh := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = r
		cm.bottom_radius = r
		cm.height = seg_h
		cm.radial_segments = 9
		mesh.mesh = cm
		mesh.material_override = wood
		mesh.transform = xf
		parent.add_child(mesh)
		tps.append(wxz)
		tops.append(top)
		prev = top
	# Crown: a leaf blob whose top is the final lookout.
	var tip_xz := xz + dir * (1.0 + 4.0 * seg_h + 0.6)
	var g2 := base
	var hit2 := _ground_ray(Vector3(tip_xz.x, 500.0, tip_xz.y))
	if not hit2.is_empty():
		g2 = (hit2.position as Vector3).y
	var crown_top: float = minf(g2 + CLIMB_STEP * 5.0,
			prev + CLIMB_MAX_STEP)
	var crown_c := crown_top - 0.55
	var crown := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.15
	sm.height = 1.1
	sm.radial_segments = 10
	sm.rings = 6
	crown.mesh = sm
	var leaf := StandardMaterial3D.new()
	leaf.albedo_color = Color(0.30, 0.44, 0.20)
	leaf.roughness = 1.0
	crown.material_override = leaf
	crown.position = Vector3(tip_xz.x, crown_c, tip_xz.y)
	parent.add_child(crown)
	var cshape := CylinderShape3D.new()
	cshape.radius = 0.85
	cshape.height = crown_top - (crown_c - 0.55)
	_add_shaped(_bin_body(collision_layer,
			Vector3(tip_xz.x, crown_c - 0.55, tip_xz.y)), cshape,
			Transform3D(Basis.IDENTITY, Vector3(tip_xz.x,
			(crown_top + crown_c - 0.55) * 0.5, tip_xz.y)))
	tps.append(tip_xz)
	tops.append(crown_top)


## Hillside ledge staircase: 4–6 flat stone slabs climbing in a
## zig-zag, each top CLIMB_STEP above the last (clamped to the max
## rise), hugging the real terrain so they read as natural rock
## shelves rather than placed blocks.
func _build_climb_ledge(parent: Node3D, xz: Vector2, base: float,
		yaw: float, tops: Array[float], tps: Array[Vector2]) -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.52, 0.50, 0.46).darkened(
			_rng.randf_range(0.0, 0.1))
	stone.roughness = 1.0
	var n := _rng.randi_range(4, 6)
	var dir := Vector2(cos(yaw), sin(yaw))
	var side := Vector2(-dir.y, dir.x)
	var zig := 1.0
	var prev := INF
	for i in n:
		var d := 1.3 + float(i) * 1.6
		var off := dir * d + side * (0.8 * zig)
		zig = -zig
		var wxz := xz + off
		var g := base
		var hit := _ground_ray(Vector3(wxz.x, 500.0, wxz.y))
		if not hit.is_empty():
			g = (hit.position as Vector3).y
		var top: float = g + CLIMB_STEP * float(i + 1)
		if prev != INF:
			top = minf(top, prev + CLIMB_MAX_STEP)
			top = maxf(top, prev + 0.35)
		# Slab: a stone block sunk 0.6 into the ground, top face = the
		# walk surface. Mesh and collision share one small yaw (the
		# top stays flat in world space either way). On steep hillsides
		# the terrain itself can rise past the step top — the slab is
		# clamped to a stub so BoxShape never gets a negative size (the
		# hill IS the walkable step there).
		var h := maxf(top - (g - 0.6), 0.3)
		var slab_yaw := _rng.randf_range(-0.4, 0.4)
		var basis := Basis(Vector3.UP, slab_yaw)
		var mesh := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.7, h, 1.4)
		mesh.mesh = bm
		mesh.material_override = stone
		mesh.transform = Transform3D(basis, Vector3(wxz.x,
				(top + g - 0.6) * 0.5, wxz.y))
		parent.add_child(mesh)
		var shape := BoxShape3D.new()
		shape.size = Vector3(1.7, h, 1.4)
		_add_shaped(_bin_body(collision_layer,
				Vector3(wxz.x, g - 0.6, wxz.y)), shape,
				Transform3D(basis, Vector3(wxz.x,
				(top + g - 0.6) * 0.5, wxz.y)))
		tps.append(wxz)
		tops.append(top)
		prev = top


## One firefly swarm per grove, spawned after all props (so the grove
## table is final). Deterministic: each grove's swarm is identical
## every run.
func _spawn_fireflies(props_root: Node3D) -> void:
	_ensure_groves()
	for i in _groves.size():
		var g: Dictionary = _groves[i]
		var gc: Vector2 = g.xz
		var hit := _ground_ray(Vector3(gc.x, 500.0, gc.y))
		if hit.is_empty():
			continue
		var swarm := Node3D.new()
		swarm.set_script(FIREFLY_SCRIPT)
		swarm.set("swarm_seed", seed_value + i * 7919)
		props_root.add_child(swarm)
		swarm.position = Vector3(gc.x,
				hit.position.y + 0.1, gc.y)


## Mesh collider for a plain prop: the REAL geometry as the shape
## (concave trimesh, hull for the very heavy models), shared per model
## via the cache. The old full-AABB box covered courtyards, chimneys
## and arches with solid air — this reads the actual surface instead.
## Adds `shape` to `body` as a child CollisionShape3D. `prop_xf` is
## the transform the shape's model-space coordinates need — since the
## collision bins are shared, top-level bodies, each prop's world
## transform rides on the shape node instead of on a per-prop body.
static func _add_shaped(body: StaticBody3D, shape: Shape3D,
		prop_xf: Transform3D) -> void:
	var cs := CollisionShape3D.new()
	cs.transform = prop_xf
	cs.shape = shape
	body.add_child(cs)


func _add_prop_mesh_shape(body: StaticBody3D, prop: Node3D) -> void:
	_add_shaped(body, _shape_for_prop(prop), prop.global_transform)


## Capsule collider helper for wanderers: a vertical capsule sized to
## the prop's AABB and resting on the AABB's bottom. Unlike the props'
## flat boxes, a capsule's rounded bottom rides OVER slopes and small
## steps instead of catching on them and levering the character into
## the ground (that was the knee-deep bug).
func _add_capsule(body: PhysicsBody3D, aabb: AABB) -> void:
	var cap := CapsuleShape3D.new()
	var height := maxf(aabb.size.y, 0.5)
	cap.height = height
	cap.radius = clampf(minf(aabb.size.x, aabb.size.z) * 0.5,
			0.15, height * 0.45)
	var cs := CollisionShape3D.new()
	cs.shape = cap
	cs.position = Vector3(aabb.get_center().x,
			aabb.position.y + height * 0.5, aabb.get_center().z)
	body.add_child(cs)


## The ocean: a shader-animated water surface. No collision — you can
## dive into it (the sea no longer kills; nothing does).
var _ocean: MeshInstance3D
var _ocean_mat: ShaderMaterial
## The shared swell clock: drives BOTH the shader's vertex swell (via
## the swell_t uniform) and the ships' bobbing (via _swell_y), so
## hulls stay glued to the animated surface under them.
var _swell_t := 0.0


func _add_water_plane() -> void:
	_ocean = MeshInstance3D.new()
	_ocean.name = "SeaPlane"
	var plane := PlaneMesh.new()
	# The ocean must outlive the island: cover the whole terrain at the
	# new scale, plus horizon margin. Subdivided so the vertex swell
	# can bend it.
	plane.size = Vector2(OCEAN_SIZE, OCEAN_SIZE)
	plane.subdivide_width = 96
	plane.subdivide_depth = 96
	_ocean.mesh = plane
	_ocean_mat = ShaderMaterial.new()
	_ocean_mat.shader = OCEAN_SHADER
	_ocean_mat.set_shader_parameter("swell_t", 0.0)
	_ocean_mat.set_shader_parameter("wave_height", SWELL_HEIGHT)
	_ocean_mat.set_shader_parameter("wave_period", SWELL_PERIOD)
	_ocean_mat.set_shader_parameter("wave_crests", SWELL_CRESTS)
	_ocean_mat.set_shader_parameter("ocean_size", OCEAN_SIZE)
	_ocean.material_override = _ocean_mat
	_ocean.position = Vector3(0, sea_level, 0)
	add_child(_ocean)


func _process(delta: float) -> void:
	if _ocean == null or _ocean_mat == null:
		return
	# The swell advances on ONE clock shared by the shader (the sheet
	# heaves, the normals shimmer, caustics dance) and the ships (they
	# ride the same formula on the CPU).
	_swell_t += delta
	_ocean_mat.set_shader_parameter("swell_t", _swell_t)
	for rec in placed:
		if rec.get("ship", false) and not rec.get("sailable", false):
			var ship := rec.node as Node3D
			var p := ship.position
			ship.position.y = sea_level - 0.15 \
					- (rec.aabb.position.y * rec.scale) \
					+ _swell_y(p.x, p.z)


## Ocean surface height at a world point (rest surface = sea_level).
func _swell_y(x: float, z: float) -> float:
	var w := TAU / SWELL_PERIOD
	var k := TAU * SWELL_CRESTS / OCEAN_SIZE
	return SWELL_HEIGHT * (sin(k * x + w * _swell_t)
			+ sin(k * (x * 0.7 + z) - w * _swell_t * 0.8)) * 0.5


## Y of the sea plane reference: a little UNDER the visible surface.
## No longer a death plane (sea death is disabled); kept in sync for
## future water gameplay — swimming, boats, fishing. All
## MovementControllers get water_y from this.
func sea_surface_y() -> float:
	# The visible sea plane sits AT sea_level (OceanWater mesh, mean
	# of the swell). An old death-plane-era offset put this 0.25 m
	# BELOW the surface, so the hero's swim gate, submersion tint,
	# breath and entry splashes all ran under the water you can see —
	# a hair under the plane keeps floats just beneath the crests.
	return sea_level - 0.02


## Tries to place one instance of `rule`; records it or counts a skip.
func _place_one(props_root: Node3D, packed: PackedScene, rule: PropRule) -> void:
	var tries := rule.attempts if rule.attempts >= 0 else attempts_per_prop
	var r_min := rule.min_radius if rule.min_radius >= 0.0 \
			else scatter_min_radius
	var r_max := rule.max_radius if rule.max_radius >= 0.0 \
			else scatter_max_radius
	# Grove trees cluster: most samples land around a shared grove
	# centre with a density falloff, the rest stay island loners.
	var groves_ok := rule.grove_share > 0.0
	if groves_ok:
		_ensure_groves()
	var chosen := {}
	var shore_sample := false
	var coast_sample := false
	var corner_sample := false
	var rec_ship := false
	var used_corner := -1
	if rule.wants_shore:
		_shore_probe()
		if _shore.is_empty():
			return
		shore_sample = true
	elif rule.wants_coast or rule.wants_corner:
		_shore_probe()
		if _shore.is_empty():
			return
		if rule.wants_corner:
			_corner_probe()
			if _corners.is_empty():
				return
			corner_sample = true
		else:
			coast_sample = true
	for attempt in tries:
		var xz := Vector2.ZERO
		var anchor := Vector2.INF
		var grove_now := false
		if rule.near_kind != "":
			# Anchor placement: ring the chosen prop (a house) with
			# clutter, just outside its own footprint.
			var a := _anchor_of(rule.near_kind)
			if not a.is_empty():
				var gap: float = a.r + rule.size * 0.5
				var ang := _rng.randf() * TAU
				xz = a.xz + Vector2(cos(ang), sin(ang)) \
						* _rng.randf_range(gap + 0.6, gap + 5.0)
				anchor = a.xz
		if shore_sample:
			# Shoreline placement: pick a recorded shoreline point and
			# step a little inland so the reed tuft sits ON land.
			var s: Dictionary = _shore[_rng.randi_range(0, _shore.size() - 1)]
			var sp: Vector2 = s.p
			var inland: Vector2 = s.n * _rng.randf_range(0.3, 0.9)
			xz = sp + inland
		elif corner_sample and not _corner_free.is_empty():
			# Corner placement: cycle the unclaimed map corners. The
			# tip is the quadrant's farthest dry point (found once by
			# the sweep); each attempt jitters the inland step and a
			# small lateral slide so the flat-ground checks have
			# several shots at each corner's bluff.
			var ci := attempt % _corner_free.size()
			var c: Dictionary = _corners[_corner_free[ci]]
			var cdir: Vector2 = c.dir
			var side := Vector2(-cdir.y, cdir.x)
			# A wide corner band: the tip area is crowded in this dense
			# world, so the tower hunts along the last stretch of coast
			# (inland 6-18 m, ±22 m along the shoreline) rather than a
			# tight disc, and settles for 22 m clearance instead of a
			# village-scale gap.
			xz = (c.tip as Vector2) - cdir * _rng.randf_range(6.0, 18.0) \
					+ side * _rng.randf_range(-22.0, 22.0)
			used_corner = _corner_free[ci]
		elif coast_sample:
			# Coastal placement (corner fallback): pick a shoreline
			# point and step WELL inland — the lighthouse stands on
			# dry ground above the waterline, overlooking its coast.
			var s: Dictionary = _shore[_rng.randi_range(0, _shore.size() - 1)]
			xz = (s.p as Vector2) + (s.n as Vector2) \
					* _rng.randf_range(6.0, 14.0)
		elif anchor == Vector2.INF:
			var in_grove: bool = groves_ok and not _groves.is_empty() \
					and (rule.grove_share >= 1.0
					or _rng.randf() < rule.grove_share)
			if in_grove:
				# Least-loaded grove first (ties broken by the roll):
				# all woods fill evenly instead of one saturating.
				var gi := 0
				for k in range(1, _groves.size()):
					if _groves[k].n < _groves[gi].n:
						gi = k
				var gr: Dictionary = _groves[gi]
				var gc: Vector2 = gr.xz
				var ga := _rng.randf() * TAU
				var gr_r: float = gr.r
				xz = gc + Vector2(cos(ga), sin(ga)) \
						* (gr_r * pow(_rng.randf(), GROVE_FALLOFF))
				grove_now = true
				chosen = gr
			else:
				var angle := _rng.randf() * TAU
				var radius := _rng.randf_range(r_min, r_max)
				xz = Vector2(cos(angle), sin(angle)) * radius
		var hit := _ground_ray(Vector3(xz.x, 500.0, xz.y))
		if hit.is_empty():
			continue
		var ground_y: float = hit.position.y
		if rule.wants_water:
			# Floating: deep water is preferred, but after the fallback
			# budget a shallow bay is accepted (beached longship beats no
			# longship). Ships ride at the surface either way.
			var deep_ok := ground_y < sea_level - 1.0
			var shallow_ok := rule.shallow_fallback_after >= 0 \
					and attempt >= rule.shallow_fallback_after \
					and ground_y < sea_level - 0.02
			if not deep_ok and not shallow_ok:
				continue
		else:
			# Island only: above sea level AND above the min height.
			if ground_y < min_land_height \
					or ground_y < sea_level + 0.2:
				continue
			var normal: Vector3 = hit.get("normal", Vector3.UP)
			if rad_to_deg(normal.angle_to(Vector3.UP)) > rule.max_slope_deg:
				continue
			if rule.max_slope_deg <= 8.0 and not rule.trunk_collision \
					and rule.sink_frac < 0.08:
				# Buildings need a FLAT PATCH, not just a level centre
				# (deep-sunk landmarks like the castles are exempt —
				# their skirt buries terrain variation by design):
				# probe the ground around the footprint and require it
				# to stay near the centre height. A 7-degree centre
				# slope can still end at a dome or a step within a few
				# metres, and a flat-bottomed cottage would visibly
				# hover over the drop.
				var patch := true
				var probe_d: float = rule.size * 0.75
				# Big footprints need a scaled tolerance: a 40 m castle
				# on real terrain never stays within a fixed ±0.6 m at
				# 30 m out — 1.2% of the probe distance per metre of
				# footprint keeps it honest.
				var tol: float = 0.6 + 0.012 * probe_d
				for off in [Vector2(1, 0), Vector2(-1, 0),
						Vector2(0, 1), Vector2(0, -1)]:
					var ph := _ground_ray(Vector3(
							xz.x + off.x * probe_d, 500.0,
							xz.y + off.y * probe_d))
					if ph.is_empty() \
							or absf(ph.position.y - ground_y) > tol:
						patch = false
						break
				if not patch:
					continue
			if rule.trunk_collision:
				# Trees want a flat forest floor: the patch a trunk
				# stands on must not dome or dip within arm's reach.
				var flat := true
				for off in [Vector2(1.4, 0.0), Vector2(0.0, 1.4)]:
					var ph := _ground_ray(Vector3(xz.x + off.x, 500.0,
							xz.y + off.y))
					if ph.is_empty() \
							or absf(ph.position.y - ground_y) > 0.6:
						flat = false
						break
				if not flat:
					continue
		# sit the visual child so its LOWEST point sits on the ground
		# (that is the body's contact point — the capsule's rounded
		# bottom rides the terrain).
		# Build the node (wanderers wrap the model in a CharacterBody3D)
		# but only add it to the tree AFTER placement is fully decided,
		# so a wanderer's _ready captures its true home position.
		var prop: Node3D
		if packed == null:
			# Procedural vegetation/dressing (grove_fill plants, bushes,
			# flowers, reeds): built from primitives at placement time.
			prop = _build_grove_prop(rule.scene_path)
			if prop == null:
				continue
			if rule.scene_path == "flower_patch":
				# Pickable: FlowerPatch registers the patch in the
				# "flower_patch" group so wandering vikings can find
				# and pluck from it (blooms hide + regrow).
				prop.set_script(FLOWER_PATCH_SCRIPT)
		elif rule.as_wanderer:
			var wb := CharacterBody3D.new()
			wb.set_script(WANDERER_SCRIPT)
			# The animated glb child stays: it IS the viking's visible,
			# walk-animated body. Its collider is the capsule below —
			# a mesh collider cannot follow bones on a moving
			# skeleton, so a character is the one place a capsule is
			# the honest shape.
			wb.add_child(packed.instantiate())
			prop = wb
		elif rule.breakable:
			# Breakable barrel: BarrelProp builds its own box body and
			# handles smash/respawn (skips the generic StaticBody path).
			var bp := Node3D.new()
			bp.set_script(BARREL_SCRIPT)
			bp.add_child(packed.instantiate())
			prop = bp
		elif rule.solid_interior:
			# Hollow house: HouseProp swaps the carved mesh and builds
			# the compound (door-aware) collision in its _ready.
			var hp := Node3D.new()
			hp.set_script(HOUSE_SCRIPT)
			hp.add_child(packed.instantiate())
			prop = hp
		else:
			prop = packed.instantiate()
		var aabb := _prop_aabb(prop)
		var source_size: float = maxf(aabb.size.x, aabb.size.z) \
				if rule.by_length else aabb.size.y
		if source_size <= 0.001:
			prop.free()
			continue
		var s := rule.size / source_size
		prop.scale = Vector3.ONE * s
		if rule.as_wanderer:
			# Physics bodies must stay at scale 1: a scaled capsule is a
			# SCALED SHAPE on a moving body — the server's slow path for
			# every contact query (part of the measured ~40 ms wanderer
			# cost). The visual child carries the scale instead; the
			# capsule in the collision pass is sized from the pre-scaled
			# AABB.
			prop.scale = Vector3.ONE
			for c in prop.get_children():
				(c as Node3D).scale = Vector3.ONE * s
		# Spacing is surface-to-surface: the candidate's footprint
		# radius (measured from its real AABB) plus every placed prop's
		# radius.
		var r_self := 0.5 * maxf(aabb.size.x, aabb.size.z) * s
		if rule.rect_claim:
			# Landmarks: claim the half-diagonal so nothing can slot
			# into the corner gap a disc under-covers.
			r_self = 0.5 * s * Vector2(aabb.size.x, aabb.size.z).length()
		if grove_now:
			# In a forest, trunks pack by TRUNK distance — canopies are
			# allowed (expected) to overlap. Keep a small clearance so
			# the spacing check still feels the rule's `spacing`.
			r_self = maxf(aabb.size.y * s * 0.06, 0.5)
		var spacing := rule.spacing * (GROVE_SPACING_SCALE if grove_now \
				else 1.0)
		if _too_close(xz, spacing, r_self, anchor):
			prop.free()
			continue
		# The flagship: the first ship to survive placement converts
		# into the sailable Sailboat wrapper (own moving hull body +
		# ride). Conversion happens here — after every rejection path —
		# so a failed attempt can never burn the one flagship budget.
		var made_sailable := false
		if rule.sailable and _sailable_left > 0:
			var sb := Node3D.new()
			sb.set_script(SAIL_SCRIPT)
			sb.add_child(prop)
			prop = sb
			made_sailable = true
			_sailable_left -= 1
		prop.rotation.y = _rng.randf() * TAU
		if rule.wants_water:
			# Ride the swell at the water surface, hull slightly submerged.
			prop.position = Vector3(xz.x, sea_level - 0.15 \
					- aabb.position.y * s, xz.y)
			rec_ship = true
		else:
			# Sit the prop's lowest point exactly on the ground — except
			# houses sink slightly, so the interior floor slab sits flush
			# with the terrain and every doorway is step-straight-in.
			var sink := 0.0
			if rule.solid_interior:
				sink = HOUSE_SINK_FRAC * aabb.size.y * s
			elif rule.sink_frac > 0.0:
				sink = rule.sink_frac * aabb.size.y * s
			elif rule.scene_path == "fallen_log":
				# Logs lie on the ground: sink a third of the trunk height
				# so the round body reads as settled into the forest floor
				# (and never rocks on a flat bottom edge).
				sink = 0.35 * aabb.size.y * s
			elif rule.scene_path == "reeds":
				# Reeds root INTO the soil: bury the base slightly so the
				# tuft never floats on a pebble.
				sink = 0.08 * aabb.size.y * s
			prop.position = Vector3(xz.x,
					ground_y - aabb.position.y * s - sink, xz.y)
		if rule.as_wanderer:
			prop.set("walk_speed", _rng.randf_range(1.3, 2.0))
			prop.set("wander_radius", _rng.randf_range(14.0, 24.0))
			prop.set("water_level", sea_level)
			# Drop them in a hand-width above the surface: flush-on-bumpy
			# placement let the capsule overlap a pebble and grind in
			# depenetration forever (measured part of the lag). A short
			# fall grounds everyone cleanly.
			prop.position.y += 0.35
		props_root.add_child(prop)
		# Bushes grow food: berries or herbs ripen on ~2/3 of them. A
		# PRIVATE rng keyed on the bush's position keeps the shared
		# placement stream untouched (no downstream reshuffle) and the
		# layout deterministic.
		if rule.scene_path == "bush_patch" \
				and hash(xz) % 1000 < 660:
			var fg := Node3D.new()
			fg.set_script(FORAGE_SCRIPT)
			prop.add_child(fg)
			var frng := RandomNumberGenerator.new()
			frng.seed = hash(xz)
			var fkind := "berries" if frng.randf() < 0.6 else "herbs"
			fg.call("setup", aabb.size.y * s, frng.randi(), fkind)
		if grove_now and not chosen.is_empty():
			chosen["n"] = (chosen.get("n", 0) as int) + 1
		placed.append({"kind": rule.scene_path.get_file(),
				"node": prop, "pos": prop.position, "aabb": aabb,
				"wanderer": rule.as_wanderer, "ship": rec_ship,
				"scale": s, "r": r_self,
				"trunk": rule.trunk_collision,
				"no_collision": rule.no_collision,
				"breakable": rule.breakable,
				"mesh": rule.mesh_collision,
				"beacon": rule.scene_path.ends_with("old_lighthouse.glb"),
				"sailable": made_sailable})
		# Claim the spot: every later prop must clear this footprint.
		# (Without this append the spacing ledger stays empty and props
		# pile into each other — trees inside castle walls, houses
		# glued to castle towers.)
		_taken.append({"xz": xz, "r": r_self})
		if used_corner >= 0:
			_corner_free.erase(used_corner)
		return
	skipped += 1


## 2D spacing check against every placed prop: the gap between the
## candidate's surface and each placed surface must exceed `spacing`.
## `anchor` (anchor placement) relaxes the check against that one
## placed prop: clutter may sit right up against its house.
func _too_close(xz: Vector2, spacing: float, r_self: float,
		anchor := Vector2.INF) -> bool:
	if xz.length() < KEEP_OUT_RADIUS + r_self:
		return true
	for t in _taken:
		var need: float = spacing + r_self + t.r
		if anchor != Vector2.INF and t.xz.distance_to(anchor) < 0.01:
			need = r_self + t.r + 0.4  # the anchor itself: touching is fine
		if xz.distance_to(t.xz) < need:
			return true
	return false


## A random already-placed prop of `kind` (for anchor placement) as
## {xz, r}, or an empty Dictionary when none exists yet.
func _anchor_of(kind: String) -> Dictionary:
	var cands: Array[Dictionary] = []
	for rec in placed:
		if rec.kind == kind:
			var p: Vector3 = rec.pos
			cands.append({"xz": Vector2(p.x, p.z), "r": rec.r})
	if cands.is_empty():
		return {}
	return cands[_rng.randi_range(0, cands.size() - 1)]


## Finds the island's four outer corners: one radial sweep over 24
## directions records each quadrant's farthest dry point. Determin
## istic — no RNG draws, so placement streams are untouched. Used by
## corner-placement rules (the lighthouses).
func _corner_probe() -> void:
	if not _corners.is_empty():
		return
	var quads: Array[Dictionary] = [{}, {}, {}, {}]  # NE SE SW NW
	for i in 24:
		var ang := TAU * float(i) / 24.0
		var dir := Vector2(cos(ang), sin(ang))
		var far := 0.0
		var fy := 0.0
		for r in range(60, 340, 2):
			var xz := dir * float(r)
			var hit := _ground_ray(Vector3(xz.x, 500.0, xz.y))
			if hit.is_empty() or hit.position.y < sea_level:
				break
			far = float(r)
			fy = hit.position.y
		if far <= 0.0:
			continue
		var q := 0 if dir.x >= 0.0 and dir.y <= 0.0 else \
				(1 if dir.x >= 0.0 and dir.y > 0.0 else \
				(2 if dir.x < 0.0 and dir.y > 0.0 else 3))
		if not quads[q].has("r") or far > quads[q].r:
			quads[q] = {"dir": dir, "tip": dir * far, "y": fy,
					"r": far}
	for qq in quads:
		if not qq.is_empty():
			_corners.append(qq)
			_corner_free.append(_corners.size() - 1)
	if verbose:
		var rs: Array = []
		for c in _corners:
			rs.append(c.r)
		print("[PropScatter] corners: %d (r=%s)" % [_corners.size(),
				str(rs)])


## Samples the island's shoreline: radially raycast outward, record
## the last dry point before the waterline plus the inward normal.
## Used by shore-placement rules (reeds).
func _shore_probe() -> void:
	if not _shore.is_empty():
		return
	for i in 128:
		var ang := TAU * float(i) / 128.0
		var dir := Vector2(cos(ang), sin(ang))
		var last_dry := Vector2.INF
		for ri in range(40, 310, 2):
			var r := float(ri)
			var xz := dir * r
			var hit := _ground_ray(Vector3(xz.x, 500.0, xz.y))
			if hit.is_empty() or hit.position.y < sea_level:
				if last_dry != Vector2.INF:
					_shore.append({"p": last_dry, "n": -dir})
					break
				continue
			last_dry = xz


## Builds a procedural grove-floor prop by kind name:
## "mushroom_cluster" — 2–4 toadstools (stem + cap, four palettes);
## "fallen_log" — a tipped-over trunk with stubby branch snags.
func _build_grove_prop(kind: String) -> Node3D:
	var root := Node3D.new()
	if kind == "mushroom_cluster":
		var n := _rng.randi_range(2, 4)
		var palette: Array[Color] = [Color(0.78, 0.16, 0.12),
				Color(0.86, 0.62, 0.30), Color(0.90, 0.88, 0.80),
				Color(0.45, 0.24, 0.50)]
		var base := palette[_rng.randi_range(0, palette.size() - 1)]
		for i in n:
			var m := Node3D.new()
			var h := _rng.randf_range(0.10, 0.26)
			var stem := MeshInstance3D.new()
			var sm := CylinderMesh.new()
			sm.top_radius = h * 0.10
			sm.bottom_radius = h * 0.13
			sm.height = h
			stem.mesh = sm
			var stem_mat := StandardMaterial3D.new()
			stem_mat.albedo_color = Color(0.92, 0.88, 0.78)
			stem.material_override = stem_mat
			stem.position.y = h * 0.5
			m.add_child(stem)
			var cap := MeshInstance3D.new()
			var cm := SphereMesh.new()
			cm.radius = h * (0.55 if _rng.randf() < 0.25 else 0.42)
			cm.height = cm.radius * 1.1
			cm.radial_segments = 10
			cm.rings = 6
			cap.mesh = cm
			var cap_mat := StandardMaterial3D.new()
			cap_mat.albedo_color = base.lightened(
					_rng.randf_range(-0.06, 0.10))
			cap.material_override = cap_mat
			cap.position.y = h
			m.add_child(cap)
			m.position = Vector3(_rng.randf_range(-0.25, 0.25), 0.0,
					_rng.randf_range(-0.25, 0.25))
			m.rotation.y = _rng.randf() * TAU
			root.add_child(m)
	elif kind == "fallen_log":
		var log := MeshInstance3D.new()
		var lm := CylinderMesh.new()
		var ln := _rng.randf_range(0.55, 1.0)
		lm.top_radius = ln * 0.85
		lm.bottom_radius = ln
		lm.height = _rng.randf_range(2.4, 4.0)
		log.mesh = lm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.42, 0.30, 0.19).darkened(
				_rng.randf_range(0.0, 0.15))
		mat.roughness = 1.0
		log.material_override = mat
		# Lay the cylinder on its side: local +Z along the length.
		log.rotation = Vector3(TAU * 0.25, 0.0, 0.0)
		root.add_child(log)
		for i in _rng.randi_range(2, 4):
			var snag := MeshInstance3D.new()
			var sm := CylinderMesh.new()
			sm.top_radius = ln * 0.12
			sm.bottom_radius = ln * 0.16
			sm.height = _rng.randf_range(0.22, 0.5)
			snag.mesh = sm
			snag.material_override = mat
			var ang := _rng.randf() * TAU
			snag.position = Vector3(cos(ang) * ln * 0.7,
					ln * 0.3 + sm.height * 0.4, sin(ang) * ln * 0.7)
			snag.rotation.z = _rng.randf_range(0.5, 1.1) \
					* (1.0 if cos(ang) >= 0.0 else -1.0)
			root.add_child(snag)
		# The root sits at the log's centre; placement measures the
		# AABB and grounds on its LOWEST point, so keep the pivot level
		# with the cylinder's centre.
		log.position.y = 0.0
	elif kind == "bush_patch":
		# 3-5 leaf spheres clumped around a woody base.
		var leaf := Color(0.24, 0.44, 0.18)
		var matb := StandardMaterial3D.new()
		matb.albedo_color = leaf.lightened(_rng.randf_range(-0.05, 0.12))
		matb.roughness = 1.0
		for i in _rng.randi_range(3, 5):
			var blob := MeshInstance3D.new()
			var bm := SphereMesh.new()
			var br := _rng.randf_range(0.18, 0.34)
			bm.radius = br
			bm.height = br * 1.7
			bm.radial_segments = 9
			bm.rings = 5
			blob.mesh = bm
			blob.material_override = matb
			blob.position = Vector3(_rng.randf_range(-0.3, 0.3),
					br * 0.85, _rng.randf_range(-0.3, 0.3))
			root.add_child(blob)
	elif kind == "flower_patch":
		# 5-8 tiny blooms: thin stems with bright caps, mixed colors.
		var petals: Array[Color] = [Color(0.95, 0.75, 0.25),
				Color(0.9, 0.3, 0.35), Color(0.85, 0.85, 0.95),
				Color(0.75, 0.4, 0.85)]
		for i in _rng.randi_range(5, 8):
			var bloom := Node3D.new()
			var fh := _rng.randf_range(0.12, 0.26)
			var stem := MeshInstance3D.new()
			var sm := CylinderMesh.new()
			sm.top_radius = 0.008
			sm.bottom_radius = 0.011
			sm.height = fh
			stem.mesh = sm
			var smat := StandardMaterial3D.new()
			smat.albedo_color = Color(0.3, 0.5, 0.22)
			stem.material_override = smat
			stem.position.y = fh * 0.5
			bloom.add_child(stem)
			var head := MeshInstance3D.new()
			var hm := SphereMesh.new()
			hm.radius = fh * 0.22
			hm.height = fh * 0.4
			hm.radial_segments = 7
			hm.rings = 4
			head.mesh = hm
			var hmat := StandardMaterial3D.new()
			hmat.albedo_color = petals[_rng.randi_range(0,
					petals.size() - 1)]
			head.material_override = hmat
			head.position.y = fh
			bloom.add_child(head)
			bloom.position = Vector3(_rng.randf_range(-0.35, 0.35), 0.0,
					_rng.randf_range(-0.35, 0.35))
			bloom.rotation.y = _rng.randf() * TAU
			root.add_child(bloom)
	elif kind == "reeds":
		# A shoreline tuft: 5-9 tall thin stalks with seed heads,
		# fanned out around the base.
		var reed_mat := StandardMaterial3D.new()
		reed_mat.albedo_color = Color(0.55, 0.55, 0.30).lightened(
				_rng.randf_range(-0.08, 0.1))
		for i in _rng.randi_range(5, 9):
			var stalk := MeshInstance3D.new()
			var rm := CylinderMesh.new()
			var rh := _rng.randf_range(0.5, 1.0)
			rm.top_radius = 0.012
			rm.bottom_radius = 0.02
			rm.height = rh
			stalk.mesh = rm
			stalk.material_override = reed_mat
			var ang := _rng.randf() * TAU
			var lean := _rng.randf_range(0.1, 0.45)
			stalk.position = Vector3(cos(ang) * 0.06, rh * 0.5,
					sin(ang) * 0.06)
			stalk.rotation = Vector3(sin(ang) * lean, 0.0,
					-cos(ang) * lean)
			root.add_child(stalk)
			if _rng.randf() < 0.5:
				var head := MeshInstance3D.new()
				var hm := CylinderMesh.new()
				hm.top_radius = 0.005
				hm.bottom_radius = 0.018
				hm.height = rh * 0.18
				head.mesh = hm
				head.material_override = reed_mat
				head.position = stalk.position + Vector3(0, rh * 0.55, 0)
				root.add_child(head)
	else:
		root.free()
		return null
	return root


## Draws the shared mini-forest centres (once): flat dry land, clear of
## the village and each other, so every tree rule clusters around the
## same few woods instead of eight separate ones. Grove-floor rules
## funnel through here too, so they never see an empty grove table.
func _ensure_groves() -> void:
	if _groves_done:
		return
	_groves_done = true
	for g in GROVE_COUNT:
		for attempt in 220:
			var ang := _rng.randf() * TAU
			var rad := _rng.randf_range(scatter_min_radius + GROVE_RADIUS,
					scatter_max_radius - GROVE_RADIUS)
			var xz := Vector2(cos(ang), sin(ang)) * rad
			var hit := _ground_ray(Vector3(xz.x, 500.0, xz.y))
			if hit.is_empty():
				continue
			if hit.position.y < sea_level + 0.5:
				continue
			var normal: Vector3 = hit.get("normal", Vector3.UP)
			if rad_to_deg(normal.angle_to(Vector3.UP)) > 12.0:
				continue
			var clear := true
			for t in _taken:
				if t.r >= 2.0 and xz.distance_to(t.xz) < 30.0 + t.r:
					clear = false
					break
			if not clear:
				continue
			var clash := false
			for gr in _groves:
				if xz.distance_to(gr.xz) < GROVE_MIN_GAP:
					clash = true
					break
			if clash:
				continue
			_groves.append({"xz": xz, "r": GROVE_RADIUS, "n": 0})
			break


## Downward ray to the terrain (and anything else on the layer).
func _ground_ray(from: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(from,
			Vector3(from.x, from.y - 1200.0, from.z), collision_layer)
	return space.intersect_ray(params)


## Combined AABB of every mesh under `prop`, in prop-local space.
## Uses LOCAL transforms only — props are measured before entering the
## tree, where global transforms are invalid.
##
## Skinned meshes are special-cased: their vertex positions live in
## skeleton space, so the mesh AABB is the raw bind blob (for the
## lowpoly warrior it measured a 0.9 m crouch blob for a ~1.9 m figure
## — the knee-deep grounding bug). Where a skeleton exists, skinned
## meshes are measured by the skeleton's GLOBAL REST pose bounds
## instead: the true size of the posed figure.
func _prop_aabb(prop: Node3D) -> AABB:
	return _aabb_under(prop, Transform3D.IDENTITY)


func _aabb_under(n: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	for c in n.get_children():
		var c3d := c as Node3D
		var cxf := xf * (c3d.transform if c3d != null \
				else Transform3D.IDENTITY)
		var sk := c as Skeleton3D
		if sk != null and sk.get_bone_count() > 0:
			var sb := _skeleton_rest_aabb(sk)
			if sb.size != Vector3.ZERO:
				var wb: AABB = cxf * sb
				out = wb if first else out.merge(wb)
				first = false
			continue  # skinned meshes are covered by the skeleton bounds
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null and not _is_skinned(mi):
			var b: AABB = cxf * mi.mesh.get_aabb()
			out = b if first else out.merge(b)
			first = false
		var sub := _aabb_under(c, cxf)
		if sub.size != Vector3.ZERO:
			out = sub if first else out.merge(sub)
			first = false
	return out


## True when the mesh is deformed by a skeleton (its own AABB is then
## meaningless for placement).
func _is_skinned(mi: MeshInstance3D) -> bool:
	if mi.skin != null:
		return true
	if mi.skeleton == NodePath(""):
		return false
	return mi.get_node_or_null(mi.skeleton) is Skeleton3D


## World-aligned AABB of a skeleton's GLOBAL REST pose: every joint
## origin, padded by a small fraction of the height so the head top and
## foot soles (which sit beyond the joints) are included.
func _skeleton_rest_aabb(sk: Skeleton3D) -> AABB:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for i in sk.get_bone_count():
		var p: Vector3 = sk.get_bone_global_rest(i).origin
		lo = lo.min(p)
		hi = hi.max(p)
	if lo.x == INF:
		return AABB()
	var box := AABB(lo, hi - lo)
	return box.grow(box.size.y * 0.05)


## Keeps every MovementController's water_y reference on the visible
## sea surface (future water gameplay reads it from here; nothing
## kills on it anymore).
func _sync_death_plane() -> void:
	for p in get_tree().get_nodes_in_group("player"):
		if p is MovementController:
			p.water_y = sea_surface_y()


## Stone-bridge collision planes (raw model units, measured from the
## GLB): deck slab + guard rails. The node carries the scale.
const BRIDGE_LEN := 1.460113
const BRIDGE_DECK_TOP := 0.066144
const BRIDGE_DECK_BOT := -0.418896
const BRIDGE_HALF_W := 0.5
const BRIDGE_RAIL_TOP := 0.208312
const BRIDGE_RAIL_IN := 0.4298
const BRIDGE_RAIL_OUT := 0.5477


## Downward ground ray at radius `r` along `dir` (channel sweep helper).
func _dir_ray(dir: Vector2, r: float) -> Dictionary:
	var xz := dir * r
	return _ground_ray(Vector3(xz.x, 500.0, xz.y))


## Bridge rules place differently: find genuine water channels (short
## inland runs where the ground dips below sea level), then span each
## one — the deck is TILTED flush with each bank's own plateau and the
## abutment ends are buried into both banks so nothing floats.
func _place_bridges(props_root: Node3D, packed: PackedScene,
		rule: PropRule) -> void:
	var built := 0
	var used: Array[Vector2] = []
	# Highest banks first: the deck clamps to bank height, so the most
	# bridgeable channels should win the limited count.
	var chans := _find_channels()
	if verbose:
		print("[PropScatter] bridge channels found: %d" % chans.size())
	chans.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.bank_y > b.bank_y)
	for ch in chans:
		if built >= rule.count:
			break
		var clear := true
		for p in used:
			if p.distance_to(ch.center) < 70.0:
				clear = false
				break
		if not clear:
			continue
		var prop := packed.instantiate() as Node3D
		var aabb := _prop_aabb(prop)
		# +9 model-overhang total: ~4.5 m of each end buried in the bank.
		var s: float = clampf((ch.span + 9.0) / maxf(aabb.size.x, 0.001),
				2.0, 12.0)
		var r_self := 0.5 * aabb.size.x * s
		if _too_close(ch.center, rule.spacing, r_self):
			prop.free()
			continue
		prop.scale = Vector3.ONE * s
		# Local +X must lie along the channel direction, and the whole
		# bridge is TILTED so each end sits flush with ITS OWN bank — a
		# level deck at the higher bank left an unclimbable step on the
		# lower side.
		var yaw := atan2(-ch.dir.y, ch.dir.x)
		var deck_a: float = maxf(ch.ya + 0.06, sea_level + 0.30)
		var deck_b: float = maxf(ch.yb + 0.06, sea_level + 0.30)
		var pitch: float = atan2(deck_b - deck_a, ch.span)
		# Yaw about world UP, then pitch about the bridge's own local
		# Z (so the ramp runs along the crossing, not the world axis).
		prop.basis = Basis(Vector3.UP, yaw) \
				* Basis(Vector3.BACK, pitch) \
				* Basis.from_scale(Vector3.ONE * s)
		# Mesh centre: the tips are NOT symmetric about the water
		# centre when the two burial depths differ.
		var mesh_ctr: Vector2 = ch.dir * (ch.tip_a_r + ch.tip_b_r) * 0.5
		prop.position = Vector3(mesh_ctr.x,
				(deck_a + deck_b) * 0.5 - BRIDGE_DECK_TOP * s, mesh_ctr.y)
		props_root.add_child(prop)
		_add_bridge_collision(prop)
		_taken.append({"xz": ch.center, "r": r_self})
		placed.append({"kind": rule.scene_path.get_file(), "node": prop,
				"pos": prop.position, "aabb": aabb, "ship": false,
				"custom": true, "scale": s, "r": r_self})
		used.append(ch.center)
		built += 1## Sweeps 64 radials; each short under-water run becomes a candidate
## bridge site. This terrain's ponds are steep-sided dishes, so the
## needed burial per side is MEASURED, not assumed: walk outward from
## each water edge until the ground forms a real bank plateau (above
## the waterline and STAYS there for 3 m). Sites needing more than 10
## m of burial per side are dishes or mudflats — rejected.
func _find_channels() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in 96:
		var ang := TAU * float(i) / 96.0
		var dir := Vector2(cos(ang), sin(ang))
		var run_start := -1.0
		for ri in range(40, 300, 2):
			var r := float(ri)
			var xz := dir * r
			var hit := _ground_ray(Vector3(xz.x, 500.0, xz.y))
			var wet: bool = not hit.is_empty() \
					and hit.position.y < sea_level - 0.05
			if wet and run_start < 0.0:
				run_start = r
			elif not wet and run_start >= 0.0:
				var run_len := r - run_start
				if run_len >= 5.0 and run_len <= 40.0:
					var site := _measure_channel(dir, run_start, r,
							run_len)
					if not site.is_empty():
						out.append(site)
				run_start = -1.0
	return out


## Measures one channel: how far out each bank's plateau starts, the
## plateau heights, and the walk-up approaches beyond them. Returns a
## placement record, or an empty Dictionary when either side never
## plateaus (a dish) or the approaches are wet (a swamp crossing).
func _measure_channel(dir: Vector2, edge_a: float, edge_b: float,
		run_len: float) -> Dictionary:
	var ba := _plateau_dist(dir, edge_a, -1.0)
	var bb := _plateau_dist(dir, edge_b, 1.0)
	if ba.d < 0.0 or bb.d < 0.0:
		return {}
	if run_len + ba.d + bb.d > 36.0:
		return {}
	# Walk-up ground beyond each plateau must be real dry land at
	# THREE distances — this pond-riddled island hides more water
	# behind mudflat shoulders; 6 and 11 m fit inside them, 16 m
	# usually does not.
	for dist in [6.0, 11.0, 16.0]:
		var app_a := _dir_ray(dir, edge_a - ba.d - dist)
		var app_b := _dir_ray(dir, edge_b + bb.d + dist)
		if app_a.is_empty() or app_a.position.y < sea_level + 0.5 \
				or app_b.is_empty() or app_b.position.y < sea_level + 0.5:
			return {}
	return {"center": dir * (edge_a + edge_b) * 0.5, "dir": dir,
			"span": run_len + ba.d + bb.d,
			"bank_y": maxf(ba.y, bb.y),
			"tip_a_r": edge_a - ba.d, "tip_b_r": edge_b + bb.d,
			"ya": ba.y, "yb": bb.y}


## Walks outward from a water edge in 1 m steps (up to 12 m) until the
## terrain has been above the waterline for 3 consecutive steps. That
## is where a bridge tip can grip. Returns {d: burial, y: plateau
## height}, or d = -1 when no plateau forms (dish / mudflat).
func _plateau_dist(dir: Vector2, edge_r: float, outward: float) -> Dictionary:
	var run := 0
	var last_y := -INF
	for step in range(1, 13):
		var hit := _dir_ray(dir, edge_r + outward * float(step))
		if hit.is_empty():
			return {"d": -1.0, "y": 0.0}
		last_y = hit.position.y
		if hit.position.y >= sea_level + 0.35:
			run += 1
			if run >= 3:
				return {"d": float(step) - 2.0, "y": last_y}
		else:
			run = 0
	return {"d": -1.0, "y": last_y}


## Bridge compound collider: the stone arch's REAL mesh as a concave
## trimesh (per-model cached). Deck, rails and the arch underside are
## all the actual geometry — no slab approximation to catch a hoof on.
func _add_bridge_collision(prop: Node3D) -> void:
	var body := _bin_body(collision_layer, prop.global_position)
	_add_shaped(body, _shape_for_prop(prop, "::bridge"),
			prop.global_transform)


## Trimesh collider for landmark props (castles, hollow houses): the
## actual mesh geometry as a concave shape. Landing on a castle
## touches the real roofline; the courtyard is walkable; there is no
## invisible box floor at the tallest turret.
func _add_mesh_shape(body: StaticBody3D, prop: Node3D) -> void:
	_add_shaped(body, _shape_for_prop(prop), prop.global_transform)


## Face collection + cached shape build for the EVERYTHING-MESH rule.
## Gathering the faces first lets the builder pick the honest shape:
## small models get a true concave trimesh (mesh == collision exactly),
## models past MAX_TRIMESH_FACES get a convex hull of the same mesh.
## Shapes are cached per model path — 200 maples upload their collider
## triangles once.
static func _mesh_faces_under(n: Node, xf: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for c in n.get_children():
		var c3d := c as Node3D
		var cxf := xf * (c3d.transform if c3d != null \
				else Transform3D.IDENTITY)
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null:
			var mf := mi.mesh.get_faces()
			for i in mf.size():
				out.append(cxf * mf[i])
		out.append_array(_mesh_faces_under(c, cxf))
	return out


## Static entry for other collider owners (BarrelProp, HouseProp): the
## best mesh-derived shape for the meshes under `n`, cached per model.
## Key = wrapper script (when any) + the child models' own paths —
## barrel RULES share one script but pack different GLBs, so the
## wrapper's (empty) path alone would smear one shape across them all.
static func mesh_shape_for(n: Node) -> Shape3D:
	return _shape_for_prop(n as Node3D)


## Cache key for a prop: wrapper script (when any) + the child models'
## own paths. No real model path (randomized procedural flora) means
## an empty key — the shape is built fresh per instance, never shared.
static func _prop_key(n: Node3D, suffix := "") -> String:
	var model_paths := []
	_collect_model_paths(n, model_paths)
	if model_paths.is_empty():
		if n.get_script() != null:
			return str((n.get_script() as Script).resource_path) + suffix
		return ""
	if n.get_script() != null:
		model_paths.append((n.get_script() as Script).resource_path)
	model_paths.sort()
	return ":".join(PackedStringArray(model_paths)) + suffix


## Cache-first shape for any prop node. Cache hits skip the face
## gather entirely — that is what keeps 500-prop boot fast.
static func _shape_for_prop(n: Node3D, suffix := "") -> Shape3D:
	var key := _prop_key(n, suffix)
	if key != "":
		var cached: Shape3D = _shape_cache.get(key, null)
		if cached != null:
			return cached
	return _get_shape(_mesh_faces_under(n, Transform3D.IDENTITY), key)


## Every distinct glb/scene path under `n` (the model files that
## determine the geometry).
static func _collect_model_paths(n: Node, out: Array) -> void:
	var p := (n as Node3D).scene_file_path if n is Node3D else ""
	if p != "" and not out.has(p):
		out.append(p)
	for c in n.get_children():
		_collect_model_paths(c, out)


## Builds (or fetches from the cache) the best mesh-derived shape for
## `faces`, keyed on `key`. Concave trimesh under the face budget,
## convex hull above it.
static func _get_shape(faces: PackedVector3Array, key: String) -> Shape3D:
	if key != "":
		var cached: Shape3D = _shape_cache.get(key, null)
		if cached != null:
			return cached
	var shape: Shape3D
	if faces.size() / 3 <= MAX_TRIMESH_FACES:
		var tri := ConcavePolygonShape3D.new()
		tri.set_faces(faces)
		tri.backface_collision = true
		shape = tri
	else:
		# Hull path: the raw point cloud can hold millions of
		# vertices, and the hull builder chokes on that. Stride-
		# sample down to a bounded cloud first — a hull only needs
		# the extreme points, and density is what matters for
		# finding them.
		var pts := faces
		const HULL_CAP := 60000
		if pts.size() > HULL_CAP:
			var k := int(pts.size() / float(HULL_CAP)) + 1
			var slim := PackedVector3Array()
			slim.resize(pts.size() / k + 2)
			var j := 0
			for i in range(0, pts.size(), k):
				slim[j] = pts[i]
				j += 1
			slim.resize(j)
			pts = slim
		var hull := ConvexPolygonShape3D.new()
		hull.points = pts
		shape = hull
	if key != "":
		_shape_cache[key] = shape
	return shape


## Trunk collider for trees: a CONCAVE MESH of the trunk band (faces
## in the bottom 40% of height) — the trunk blocks walking and
## fireballs, the canopy stays fly-through for flight. Band shapes are
## cached per model, so whole forests share one physics upload.
func _add_trunk(body: PhysicsBody3D, aabb: AABB,
		prop: Node3D = null) -> void:
	var prop_xf := Transform3D.IDENTITY
	if prop != null:
		prop_xf = prop.global_transform
	# No source mesh (procedural stems, bushes): keep the cheap
	# cylinder — there is nothing to take a trunk band from.
	if prop == null:
		_add_trunk_fallback(body, aabb, prop_xf)
		return
	var key := _prop_key(prop, "::trunk")
	if key != "":
		var cached: Shape3D = _shape_cache.get(key, null)
		if cached != null:
			_add_shaped(body, cached, prop_xf)
			return
	var faces := _mesh_faces_under(prop, Transform3D.IDENTITY)
	if faces.is_empty():
		_add_trunk_fallback(body, aabb, prop_xf)
		return
	var lo: float = aabb.position.y
	var cut := lo + aabb.size.y * 0.4
	var band := PackedVector3Array()
	for i in range(0, faces.size(), 3):
		var cy := (faces[i].y + faces[i + 1].y + faces[i + 2].y) / 3.0
		if cy <= cut:
			band.append(faces[i])
			band.append(faces[i + 1])
			band.append(faces[i + 2])
	if band.size() < 9:
		_add_trunk_fallback(body, aabb, prop_xf)
		return
	_add_shaped(body, _get_shape(band, key), prop_xf)


## Cylinder fallback for trunk collision, placed in the coordinate
## space `xf` (the prop's world transform when its mesh failed us).
func _add_trunk_fallback(body: PhysicsBody3D, aabb: AABB,
		xf: Transform3D) -> void:
	var cyl := CylinderShape3D.new()
	cyl.height = aabb.size.y * 0.4
	cyl.radius = maxf(aabb.size.y * 0.035, 0.15)
	_add_shaped(body, cyl, xf * Transform3D(Basis.IDENTITY,
			Vector3(aabb.get_center().x,
			aabb.position.y + cyl.height * 0.5,
			aabb.get_center().z)))
