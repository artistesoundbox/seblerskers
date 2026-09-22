extends Node3D
## The viking house, set up for gameplay. Attached to every house
## instance by PropScatter (replacing the generic box-collider path).
##
## What it does:
## 1. Swaps the GLB's mesh for the CARVED variant (Tools/carve_house.gd
##    cut three walk-through doorways: north long wall and both curved
##    ends — the south doorway was already part of the model). The
##    original wall material survives the carve.
## 2. Builds a door-aware COMPOUND collider instead of one solid box:
##    wall segments with real gaps at every doorway, lintels above the
##    doors, an interior floor slab (so you stand inside, not in the
##    mud) and a roof slab (so you can't fall through from above and
##    fireballs detonate on the roof).
## 3. Adds a warm hearth light inside, gently flickering.
##
## Collision plane coordinates are stored as fractions of the mesh's
## own AABB, so they follow any future re-carve or re-export scale.

const CARVED := preload("res://a_viking_house_carved.res")

## Vertical fractions of the model height (0 = AABB bottom):
## wall collision tops out here (roof overhang above stays soft).
const WALL_TOP := 0.75
## Doorway head height (matches the carve volumes: 0.62..0.15 abs
## => top at 0.35 of height).
const DOOR_TOP := 0.35
## Interior floor slab.
const FLOOR_BOT := 0.03
const FLOOR_TOP := 0.075
## Roof slab.
const ROOF_BOT := 0.913
const ROOF_TOP := 0.964

## Wall skin planes as fractions of the AABB (measured from the GLB):
## long walls run along X at |z| ~= 0.4055..0.4667, end walls along Z
## at |x| ~= 0.848..0.8815.
const ZW_IN0 := 0.1232
const ZW_IN1 := 0.8716
const ZW_OUT0 := 0.0665
const ZW_OUT1 := 0.9335
const XW_IN0 := 0.0700
const XW_IN1 := 0.9178
const XW_OUT0 := 0.0471
const XW_OUT1 := 0.9350
## Door half-widths as fractions (south/north doors: x = 0.5 +/- 0.0459;
## end doors: z = 0.5 +/- 0.0635).
const DOOR_X_HALF := 0.0459
const DOOR_Z_HALF := 0.0635

## Physics layer for the house body (PropScatter passes its own).
@export var body_layer := 1
## Warm interior light.
@export var hearth := true

var _body: StaticBody3D
var _hearth: OmniLight3D
var _hearth_energy := 1.1
var _flicker_t := 0.0

func _ready() -> void:
	var mi := _find_mesh_instance(self)
	if mi != null:
		mi.mesh = CARVED
	_build_body()
	if hearth:
		_add_hearth()

## Absolute model-space Y of the interior floor's top surface.
## PropScatter uses it to sink the house so the floor sits flush with
## the terrain (you step straight in through any door).
func floor_top_model_y() -> float:
	var aabb := CARVED.get_aabb()
	return aabb.position.y + FLOOR_TOP * aabb.size.y

func _build_body() -> void:
	_body = StaticBody3D.new()
	_body.name = "HouseBody"
	_body.collision_layer = body_layer
	_body.collision_mask = 0
	add_child(_body)
	# Mesh collision: the carved mesh (doorways cut through it) as a
	# concave trimesh — walls, roof and floor slabs are the real
	# geometry, doorways walk-through exactly where they were cut.
	# A backface_collision trimesh is solid from both sides, so the
	# interior is as solid as the outside. Cache key on the script
	# path: every hollow house shares one shape build.
	var cs := CollisionShape3D.new()
	cs.shape = PropScatter.mesh_shape_for(self)
	_body.add_child(cs)
	# (The old 14-box wall/door approximation is gone: the carved
	# mesh IS the collision now, doorways included — the boxes used
	# to sit on top of the mesh and re-seal the walk-through doors.)

func _add_hearth() -> void:
	var aabb := CARVED.get_aabb()
	_hearth = OmniLight3D.new()
	_hearth.name = "Hearth"
	_hearth.light_color = Color(1.0, 0.62, 0.30)
	_hearth.light_energy = _hearth_energy
	_hearth.omni_range = aabb.size.y * 0.55
	_hearth.shadow_enabled = false
	_hearth.position = Vector3(aabb.get_center().x,
			aabb.position.y + 0.22 * aabb.size.y, aabb.get_center().z)
	add_child(_hearth)

func _process(delta: float) -> void:
	if _hearth == null:
		return
	# Cheap two-sine flicker: fire-like, no noise texture needed.
	_flicker_t += delta
	_hearth.light_energy = _hearth_energy * (0.92 + 0.05
			* sin(_flicker_t * 9.0) + 0.03 * sin(_flicker_t * 3.7 + 1.3))

func _find_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var r := _find_mesh_instance(c)
		if r != null:
			return r
	return null
