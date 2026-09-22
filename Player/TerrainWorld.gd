extends Node3D
class_name TerrainWorld
## Adds collision to an imported terrain GLB at runtime: walks every
## MeshInstance3D under this node, bakes each node's transform into its
## face data and builds ConcavePolygonShape3D (trimesh) collision for
## all of it on physics layer 1 ("Objects") — so the player, fireballs
## and anything else masking layer 1 can stand on, slide along and
## detonate against the whole landscape.
##
## Baking transforms into the vertices (instead of scaling collision
## shapes) keeps the physics shapes unscaled and unsquashed, which the
## solver likes far better. Runtime generation keeps the GLB untouched
## and survives re-imports; the cost is a one-time hitch while the
## shapes build.

## Physics layer the generated shapes land on.
@export_flags_3d_physics var collision_layer_override := 1
## Skip meshes with more triangles than this (a safety valve for
## accidentally dropped-in mega meshes).
@export var max_triangles := 2_000_000
## Print a per-mesh summary while building (diagnostics).
@export var verbose := false

## Terrain collision grid cell size (m). Queries against a small chunk
## cost a fraction of the same query against the whole-island shape —
## but the BODY COUNT matters too (the broadphase storms somewhere
## above ~630 static bodies, measured), so cells stay large enough to
## keep the chunk total well under that: ~480 chunks at 32 m.
const CHUNK_SIZE := 32.0

## --- Character heightfield (cheap ground for NPC walkers) ---------------
## A moving capsule against the terrain's CONCAVE (trimesh) shapes costs
## ~6-7 ms PER WALKING CHARACTER per physics frame on the stock physics
## server (measured: village frame cost scales 1:1 with the awake-walker
## count, cap 4 or 6 alike). NPC walkers therefore get an ANALYTIC
## ground: box prisms whose tops sample the baked terrain, on the
## DEDICATED layer 8 that only wanderer capsules mask. Boxes are the
## cheapest shape the solver knows, so a strolling villager costs a
## small fraction of the trimesh contact. The player, fireballs and
## everything else keep the full-detail trimesh on layer 1.
## Steep faces (cliff walls) are EXCLUDED: a plan-rasterized wall would
## become a tall column that teleports bodies to its top; without it a
## capsule pushed over a bluff just falls and the wanderer's sea/ground
## safety nets recover it.
const CHAR_LAYER := 8
## Heightfield grid cell (m): fine enough that adjacent tops differ by
## less than the capsule's snap length on walkable slopes.
const CHAR_CELL := 4.0
## Walkable band: nothing above this is character ground (rooftops are
## player-only domain), and the deep sea basin is excluded (the
## wanderers' own water safety net handles the shallows).
const CHAR_MAX_Y := 26.0
const CHAR_MIN_Y := -20.0
## Steep-face cutoff: faces steeper than ~50 deg never join the field.
const CHAR_MIN_UP_Y := 0.64
## Regional char-body span (m): matching the trimesh CHUNK_SIZE grid
## keeps the walker's neighbourhood bodies one-per-cell.
const CHAR_REGION := 32.0
## Diagnostics/tests: how many prism shapes the heightfield got.
var char_shapes := 0

## Number of collision shapes generated (diagnostics/tests).
var shape_count := 0
## Total triangles baked into collision (diagnostics/tests).
var triangle_count := 0


func _ready() -> void:
	# Fix scaled shapes BEFORE building anything else: the old template
	# arena cubes are 1x1x1 scenes scaled x3 at instance level, so every
	# platform collider was a SCALED shape — the measured ~40 ms/frame
	# contact cost for any awake body standing on them.
	var scene := get_tree().current_scene
	if scene == null:
		scene = get_parent()
	_descale_static_colliders(scene)
	_build_collision()


## Rebuilds every scaled static collider under `from` at scale 1: the
## body's global scale is folded into each shape's dimensions and the
## transforms are stripped to rotation+position. World geometry is
## unchanged — a 1x1x1 box scaled x3 IS a 3x3x3 box — but the physics
## server stops paying the scaled-shape tax on every contact query.
## Shapes are duplicated first: instanced scenes share sub_resources,
## and folding scale into a shared shape would corrupt every sibling.
func _descale_static_colliders(from: Node) -> void:
	var stack: Array[Node] = [from]
	var fixed := 0
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is StaticBody3D:
			fixed += _descale_body(n as StaticBody3D)
		for c in n.get_children():
			stack.append(c)
	if fixed > 0:
		print("[TerrainWorld] de-scaled %d scaled colliders" % fixed)


func _descale_body(body: StaticBody3D) -> int:
	var gt := body.global_transform
	var s := gt.basis.get_scale()
	if s.is_equal_approx(Vector3.ONE):
		return 0
	# Capture each shape's world transform BEFORE fixing the body.
	var shapes: Array = []
	for c in body.get_children():
		var cs := c as CollisionShape3D
		if cs != null and cs.shape != null:
			shapes.append([cs, cs.global_transform])
	if shapes.is_empty():
		return 0
	body.global_transform = Transform3D(gt.basis.orthonormalized(),
			gt.origin)
	var fixed := 0
	for e in shapes:
		var cs: CollisionShape3D = e[0]
		var cgt: Transform3D = e[1]
		var cs_s := cgt.basis.get_scale()
		cs.global_transform = Transform3D(
				cgt.basis.orthonormalized(), cgt.origin)
		# Duplicate BEFORE folding: instances share shape resources.
		cs.shape = cs.shape.duplicate()
		_fold_scale(cs.shape, cs_s)
		fixed += 1
	return fixed


func _fold_scale(shape: Shape3D, s: Vector3) -> void:
	var avg := (s.x + s.y + s.z) / 3.0
	if shape is BoxShape3D:
		(shape as BoxShape3D).size *= s
	elif shape is SphereShape3D:
		(shape as SphereShape3D).radius *= avg
	elif shape is CapsuleShape3D:
		var cap := shape as CapsuleShape3D
		cap.radius *= avg
		cap.height *= s.y
	elif shape is CylinderShape3D:
		var cyl := shape as CylinderShape3D
		cyl.radius *= avg
		cyl.height *= s.y
	elif shape is ConcavePolygonShape3D:
		# Trimesh: bake the scale into the face data (only safe for
		# non-shared shapes; callers duplicate first).
		var cps := shape as ConcavePolygonShape3D
		var xf := Transform3D(Basis.from_scale(s), Vector3.ZERO)
		var faces := cps.get_faces()
		for i in faces.size():
			faces[i] = xf * faces[i]
		cps.data = faces
	elif shape is ConvexPolygonShape3D:
		var xps := shape as ConvexPolygonShape3D
		var xf2 := Transform3D(Basis.from_scale(s), Vector3.ZERO)
		var pts := xps.points
		for i in pts.size():
			pts[i] = xf2 * pts[i]
		xps.points = pts


func _build_collision() -> void:
	# Grouped bake: ALL chunk shapes on ONE body — keeps the world's
	# total static-body count far below the measured broadphase storm
	# threshold while queries still only touch small cell BVHs.
	var r := bake_collision_grouped(self, collision_layer_override,
			max_triangles, verbose)
	shape_count = r["shapes"]
	triangle_count = r["tris"]
	char_shapes = r.get("char_shapes", 0)


## Shared trimesh baker: walks every MeshInstance3D under `root`, bakes
## each node's WORLD transform into its vertices and hosts all shapes on
## one body whose global transform is FORCED to identity. That last
## part matters: a body left at the node's scale (the terrain sits at
## x3 after the resize) makes every concave shape a SCALED shape — the
## physics server's slow path for contact queries (one awake character
## body cost ~40 ms per physics frame, measured, on any engine —
## GodotPhysics and Jolt alike). Identity body + baked vertices keeps
## every query on the fast path.
##
## The baked faces are then split into a horizontal GRID of chunk
## shapes: one giant 130k-triangle concave shape makes every capsule
## contact query traverse a huge BVH (~6 ms per moving character,
## measured) no matter where it stands; a cell-sized chunk costs
## fractions of that. Returns {"shapes": n, "tris": n}.
static func bake_collision_for(root: Node3D, collision_layer: int,
		max_triangles: int, verbose := false) -> Dictionary:
	var body := StaticBody3D.new()
	body.name = "BakedCollision"
	body.collision_layer = collision_layer
	body.collision_mask = 0
	# Counter-transform to IDENTITY in world space, whatever scale the
	# terrain node carries (must happen AFTER add_child — global
	# transforms need the node in the tree).
	root.add_child(body)
	body.global_transform = Transform3D.IDENTITY
	var tris := 0
	var all_faces := PackedVector3Array()
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	for node in meshes:
		var mi := node as MeshInstance3D
		var mesh := mi.mesh
		if mesh == null:
			continue
		var faces := mesh.get_faces()
		var count := faces.size() / 3
		if count == 0 or count > max_triangles:
			continue
		# Bake the mesh node's WORLD transform into the vertices so the
		# shapes live in world coordinates (matching the identity body).
		var xf := mi.global_transform
		if not xf.is_equal_approx(Transform3D.IDENTITY):
			for i in faces.size():
				faces[i] = xf * faces[i]
		all_faces.append_array(faces)
		tris += count
		if verbose:
			print("[Bake] %s: %d tris" % [mi.name, count])
	# Grid-bucket the triangles: cell chosen by triangle center, whole
	# triangles stay in one cell (a cell's floor may poke a little into
	# its neighbour — harmless for queries, which just get a slightly
	# generous floor there).
	var cells := {}
	for t in range(0, all_faces.size(), 3):
		var cx := int(floorf((all_faces[t].x + all_faces[t + 1].x
				+ all_faces[t + 2].x) / (3.0 * CHUNK_SIZE)))
		var cz := int(floorf((all_faces[t].z + all_faces[t + 1].z
				+ all_faces[t + 2].z) / (3.0 * CHUNK_SIZE)))
		var key := Vector2i(cx, cz)
		if not cells.has(key):
			cells[key] = PackedVector3Array()
		var chunk: PackedVector3Array = cells[key]
		chunk.append_array(all_faces.slice(t, t + 3))
		cells[key] = chunk
	var shapes := cells.size()
	for key in cells:
		var shape := ConcavePolygonShape3D.new()
		shape.data = cells[key]
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
	if verbose:
		print("[Bake] %d tris in %d %0.0f m cells"
				% [tris, shapes, CHUNK_SIZE])
	return {"shapes": shapes, "tris": tris}


## Binary-search helper for the broadphase storm threshold: instead of
## `count` StaticBody3D chunks, hosts all cell shapes on `groups`
## StaticBody3D bodies (shapes carry world-space cell offsets as node
## transforms; the shared body itself stays at identity). M4-verified:
## hundreds of shapes on ONE body behave identically to few bodies.
static func bake_grouped_for(root: Node3D, collision_layer: int,
		max_triangles: int, groups := 4, char_layer := 0) -> Dictionary:
	var faces := PackedVector3Array()
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	for node in meshes:
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var f := mi.mesh.get_faces()
		if f.size() / 3 > max_triangles:
			continue
		var xf := mi.global_transform
		if not xf.is_equal_approx(Transform3D.IDENTITY):
			for i in f.size():
				f[i] = xf * f[i]
		faces.append_array(f)
	var cells := {}
	for t in range(0, faces.size(), 3):
		var cx := int(floorf((faces[t].x + faces[t + 1].x
				+ faces[t + 2].x) / (3.0 * CHUNK_SIZE)))
		var cz := int(floorf((faces[t].z + faces[t + 1].z
				+ faces[t + 2].z) / (3.0 * CHUNK_SIZE)))
		var key := Vector2i(cx, cz)
		if not cells.has(key):
			cells[key] = PackedVector3Array()
		var chunk: PackedVector3Array = cells[key]
		chunk.append_array(faces.slice(t, t + 3))
		cells[key] = chunk
	var body := StaticBody3D.new()
	body.name = "BakedCollision"
	body.collision_layer = collision_layer
	body.collision_mask = 0
	root.add_child(body)
	body.global_transform = Transform3D.IDENTITY
	for key in cells:
		var shape := ConcavePolygonShape3D.new()
		shape.data = cells[key]
		var cs := CollisionShape3D.new()
		cs.shape = shape
		# The cell faces are already WORLD-space (transforms were baked
		# above and the body sits at identity), so the shape node stays
		# at identity — offsetting it by the cell origin would shift
		# every chunk across the map.
		body.add_child(cs)
	var shapes := cells.size()
	var char_count := 0
	var regions := {}
	if char_layer != 0:
		# Character heightfield: rasterize the same world-space faces
		# into box prisms on the NPC-only layer. Per cell the top is the
		# highest STEEP-EXCLUDED face centre inside it — centre sampling
		# never creates teleport columns, and on smooth ground the prism
		# top sits within a whisker of the visual surface.
		var tops := {}
		for t in range(0, faces.size(), 3):
			var a := faces[t]
			var b := faces[t + 1]
			var c := faces[t + 2]
			var cy := (a.y + b.y + c.y) / 3.0
			if cy > CHAR_MAX_Y or cy < CHAR_MIN_Y:
				continue
			var n := (b - a).cross(c - a)
			# Winding-agnostic: face winding may point the cross either
			# way (measured: Godot's get_faces() gave ALL floors a
			# downward cross here, zeroing the whole field). A floor-like
			# face is simply one whose PLANE is near-horizontal — take
			# the absolute up-share (terrain has no undersides).
			if n.length_squared() < 0.000001 \
					or absf(n.normalized().y) < CHAR_MIN_UP_Y:
				continue
			var key := Vector2i(
					int(floorf((a.x + b.x + c.x) / (3.0 * CHAR_CELL))),
					int(floorf((a.z + b.z + c.z) / (3.0 * CHAR_CELL))))
			tops[key] = maxf(tops.get(key, -INF), cy)
		# Regional char bodies: the whole field on ONE body made every
		# wanderer's first contact with a fresh 4 m cell pay a whole-field
		# pair cost (the once-per-second ~38 ms spike pattern). Splitting
		# the boxes over ~32 m regional bodies confines a new-cell pair to
		# the neighbourhood's body — the same trick the prop bins use.
		for key in tops:
			var rk := Vector2i(int(floorf(key.x * CHAR_CELL / CHAR_REGION)),
					int(floorf(key.y * CHAR_CELL / CHAR_REGION)))
			if not regions.has(rk):
				regions[rk] = []
			(regions[rk] as Array).append(key)
		for rk in regions:
			var hf := StaticBody3D.new()
			hf.name = "CharTerrain_%d_%d" % [rk.x, rk.y]
			hf.collision_layer = char_layer
			hf.collision_mask = 0
			root.add_child(hf)
			hf.global_transform = Transform3D.IDENTITY
			var half := CHAR_CELL * 0.5
			for key in regions[rk]:
				var h: float = tops[key]
				var box := BoxShape3D.new()
				box.size = Vector3(CHAR_CELL, h - CHAR_MIN_Y, CHAR_CELL)
				var cs := CollisionShape3D.new()
				cs.shape = box
				cs.position = Vector3(key.x * CHAR_CELL + half,
						(h + CHAR_MIN_Y) * 0.5, key.y * CHAR_CELL + half)
				hf.add_child(cs)
				char_count += 1
	return {"shapes": shapes, "tris": faces.size() / 3,
			"bodies": regions.size(), "char_shapes": char_count}


## Quadrant-grouped entry: 1 body, all chunk shapes as world-space
## children. Use when the world's static-body count is anywhere near
## the measured storm threshold (~630).
static func bake_collision_grouped(root: Node3D, collision_layer: int,
		max_triangles: int, verbose := false) -> Dictionary:
	var r := bake_grouped_for(root, collision_layer, max_triangles, 4,
			CHAR_LAYER)
	if verbose:
		print("[Bake] grouped: %d cells, %d tris, 1 body, %d char boxes"
				% [r["shapes"], r["tris"], r.get("char_shapes", 0)])
	return r
