class_name NewIslands
extends Node3D
## Three outpost islands across the sea, expanding the sandbox beyond
## the home island. Each is a procedural terrain mesh (seeded, so
## chest ids stay stable across sessions): a sandy shelf rising to a
## grassy crown with rocky slopes, baked into the same chunked trimesh
## collision the home terrain uses (layer 1 — the player, fireballs
## and the flagship all stand on it). The far island hosts a small
## viking camp — mast, banner, fire ring, supply crates — and every
## island carries lootable chests placed through the game's own chest
## pipeline (persisted ids, confirming raycasts, the real placed
## total), so the deeds and the title ledger count them honestly.
##
## Placed far enough out that the sea hoard's 100-150 m ring and the
## sailing race stay clear. Spawned by L_Main beside PropScatter.

const MAX_TRIMESH_FACES := 120000
const GRID := 1.5  # terrain vertex spacing (m)

const ISLAND_DEFS := [
	{"center": Vector2(265.0, -150.0), "r": 54.0, "peak": 17.0,
	 "lobes": 3.0, "phase": 0.7, "camp": true},
	{"center": Vector2(-310.0, 130.0), "r": 50.0, "peak": 12.0,
	 "lobes": 4.0, "phase": 2.1, "camp": false},
	{"center": Vector2(130.0, 340.0), "r": 45.0, "peak": 9.0,
	 "lobes": 2.0, "phase": 4.4, "camp": false},
]

const SAND := Color(0.76, 0.68, 0.5)
const GRASS := Color(0.36, 0.5, 0.27)
const ROCK := Color(0.42, 0.4, 0.37)
const SEA_LEVEL := -0.5

var setup_done := false
var _sea := SEA_LEVEL
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group("new_islands")
	_build.call_deferred()


## Island height at a world XZ: a smooth cone shaped by radial lobes
## plus two octaves of seeded noise, clamped to zero past the shore.
func _height(def: Dictionary, xz: Vector2) -> float:
	var c: Vector2 = def["center"]
	var r: float = def["r"]
	var d := xz.distance_to(c)
	if d >= r:
		return -2.0  # below the shelf: disappears under the sea
	var t := 1.0 - d / r
	var ang := (xz - c).angle()
	var lobe: float = 0.8 + 0.18 * sin(ang * float(def["lobes"])
			+ float(def["phase"]))
	var n: float = 1.0 + 0.16 * sin(xz.x * 0.11 + xz.y * 0.07) \
			+ 0.1 * sin(xz.x * 0.23 - xz.y * 0.17)
	var h: float = float(def["peak"]) * t * t * (3.0 - 2.0 * t) \
			* lobe * n
	return h - 2.0  # shelf sits 2 m under the surface at the shore


func _build() -> void:
	_rng.seed = 20260920
	# The home scatter owns the authoritative sea level.
	var scatter := _find_scatter(get_tree().root)
	if scatter != null:
		_sea = float(scatter.get("sea_level"))
	var t0 := Time.get_ticks_usec()
	for def in ISLAND_DEFS:
		_build_island(def)
	# Collision: the same grouped chunked trimesh the home terrain
	# uses (player layer 1 + character boxes), computed once the mesh
	# nodes are in the tree so world transforms bake in.
	await get_tree().physics_frame
	var r := TerrainWorld.bake_collision_grouped(self, 1,
			MAX_TRIMESH_FACES, false)
	print("[NewIslands] %d islands, %d tris, %d cells  (%d ms)"
			% [ISLAND_DEFS.size(), int(r["tris"]), int(r["shapes"]),
			(Time.get_ticks_usec() - t0) / 1000])
	await get_tree().physics_frame  # shapes register deferred
	_dress()
	_report_placed()


func _build_island(def: Dictionary) -> void:
	var c: Vector2 = def["center"]
	var r: float = def["r"]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := int(r * 2.0 / GRID)
	var heights := {}
	for gx in n + 1:
		for gz in n + 1:
			var xz := c + Vector2(-r + gx * GRID, -r + gz * GRID)
			heights[Vector2i(gx, gz)] = _height(def, xz)
	for gx in n:
		for gz in n:
			var h00 := heights[Vector2i(gx, gz)] as float
			var h10 := heights[Vector2i(gx + 1, gz)] as float
			var h01 := heights[Vector2i(gx, gz + 1)] as float
			var h11 := heights[Vector2i(gx + 1, gz + 1)] as float
			var xz := c + Vector2(-r + gx * GRID, -r + gz * GRID)
			_quad(st, xz, h00, h10, h01, h11)
	st.generate_normals()
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mi.material_override = mat
	add_child(mi)


## One grid quad, split along the shorter diagonal, each vertex
## colored by height band (sand shelf, grass crown, rock steeps).
func _quad(st: SurfaceTool, xz: Vector2, h00: float, h10: float,
		h01: float, h11: float) -> void:
	var p00 := Vector3(xz.x, h00, xz.y)
	var p10 := Vector3(xz.x + GRID, h10, xz.y)
	var p01 := Vector3(xz.x, h01, xz.y + GRID)
	var p11 := Vector3(xz.x + GRID, h11, xz.y + GRID)
	_tri(st, p00, p10, p11)
	_tri(st, p00, p11, p01)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	for p in [a, b, c]:
		st.set_color(_band(p))
		st.add_vertex(p)


func _band(p: Vector3) -> Color:
	if p.y < _sea + 0.7:
		return SAND
	if p.y > 9.0:
		return ROCK
	return GRASS.lerp(SAND, clampf((3.5 - p.y) / 3.0, 0.0, 1.0)) \
			.lerp(ROCK, clampf((p.y - 6.0) / 3.0, 0.0, 1.0))


## --- Dressing: camp, chests -------------------------------------------------

func _dress() -> void:
	var props := Node3D.new()
	props.name = "Dressing"
	add_child(props)
	var defs := ISLAND_DEFS
	for i in defs.size():
		var def := defs[i] as Dictionary
		var c: Vector2 = def["center"]
		var r: float = def["r"]
		# The crown: highest point near the centre.
		var top := Vector3(c.x, _height(def, c), c.y)
		if bool(def["camp"]):
			_build_camp(props, top)
			# The chest stands clear of the mast and crates (a
			# confirm ray over the mast would otherwise seat the
			# chest on the masthead).
			var ang := _rng.randf() * TAU
			var cxz := c + Vector2(sin(ang), cos(ang)) * 4.0
			_place_outpost_chest(props, i,
					Vector3(cxz.x, _height(def, cxz), cxz.y), "crown")
		else:
			_place_outpost_chest(props, i, top, "crown")
		# A beach shelf chest on each island.
		var bang := _rng.randf() * TAU
		var bxz := c + Vector2(sin(bang), cos(bang)) * r * 0.55
		var bh := _height(def, bxz)
		if bh > _sea + 0.6:
			_place_outpost_chest(props, i,
					Vector3(bxz.x, bh, bxz.y), "shore")
	setup_done = true
	print("[NewIslands] dressed: camps + chests placed")


## A viking camp on the far island's crown: banner mast, fire ring,
## supply crates. Pure primitives — no model needed.
func _build_camp(parent: Node3D, at: Vector3) -> void:
	var camp := Node3D.new()
	camp.position = at
	parent.add_child(camp)
	# Mast + banner
	var mast := MeshInstance3D.new()
	var msh := CylinderMesh.new()
	msh.top_radius = 0.07
	msh.bottom_radius = 0.1
	msh.height = 6.0
	mast.mesh = msh
	mast.position.y = 3.0
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.36, 0.26, 0.16)
	wood.roughness = 1.0
	mast.material_override = wood
	camp.add_child(mast)
	var flag := MeshInstance3D.new()
	var fsh := BoxMesh.new()
	fsh.size = Vector3(1.9, 1.1, 0.05)
	flag.mesh = fsh
	flag.position = Vector3(0.95, 5.2, 0.0)
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color(0.55, 0.14, 0.1)
	flag.material_override = cloth
	camp.add_child(flag)
	# Fire ring: stones + glowing embers
	for k in 7:
		var a := TAU * float(k) / 7.0
		var stone := MeshInstance3D.new()
		var ssh := SphereMesh.new()
		ssh.radius = 0.22
		ssh.height = 0.34
		stone.mesh = ssh
		stone.position = Vector3(sin(a) * 0.9, 0.12, cos(a) * 0.9)
		var sm := StandardMaterial3D.new()
		sm.albedo_color = Color(0.3, 0.29, 0.27)
		stone.material_override = sm
		camp.add_child(stone)
	var ember := MeshInstance3D.new()
	var esh := SphereMesh.new()
	esh.radius = 0.3
	esh.height = 0.4
	ember.mesh = esh
	ember.position.y = 0.18
	var em := StandardMaterial3D.new()
	em.albedo_color = Color(0.9, 0.45, 0.1)
	em.emission_enabled = true
	em.emission = Color(0.9, 0.4, 0.08)
	em.emission_energy_multiplier = 1.6
	ember.material_override = em
	camp.add_child(ember)
	# Supply crates
	for off in [Vector3(1.6, 0.35, 0.9), Vector3(2.0, 0.35, 1.4),
			Vector3(1.8, 0.95, 1.15)]:
		var crate := MeshInstance3D.new()
		var csh := BoxMesh.new()
		csh.size = Vector3(0.7, 0.7, 0.7)
		crate.mesh = csh
		crate.position = off
		crate.rotation.y = _rng.randf() * TAU
		var cm := StandardMaterial3D.new()
		cm.albedo_color = Color(0.45, 0.33, 0.19)
		crate.material_override = cm
		camp.add_child(crate)


## One chest through the game's own pipeline: raycast-confirmed spot,
## stable id ("outpost_<i>_<tag>"), the scatter's keep-out list, and
## the shared TreasureChest save path — deeds and the title count it.
func _place_outpost_chest(parent: Node3D, i: int, at: Vector3,
		tag: String) -> void:
	var space := get_world_3d().direct_space_state
	var from := Vector3(at.x, at.y + 40.0, at.z)
	var params := PhysicsRayQueryParameters3D.create(from,
			Vector3(from.x, from.y - 120.0, from.z), 1)
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return
	var surface := (hit.position as Vector3).y
	var nrm: Vector3 = hit.get("normal", Vector3.UP)
	if nrm.y < 0.5 or surface < _sea + 0.4:
		return  # a sheer slope or a wet spot is no shelf
	surface += 0.04
	var chest := Node3D.new()
	chest.set_script(load("res://Player/TreasureChest.gd"))
	chest.call("setup", "outpost_%d_%s" % [i, tag], surface)
	chest.position = Vector3(at.x, surface, at.z)
	chest.rotation.y = _rng.randf() * TAU
	parent.add_child(chest)
	print("[NewIslands] chest outpost_%d_%s at %.1f m" % [i, tag,
			surface])


## Honest chest accounting: before the scatter's tail writes the
## placed total, join our count into its own counter (same frame
## window, no file race). If the scatter already finished, do the
## max-merge ourselves.
func _report_placed() -> void:
	var mine := 0
	for ch in get_children():
		for d in ch.get_children():
			if (d as Node).get_script() != null \
					and ((d as Node).get_script() as Script) \
					.resource_path.ends_with("TreasureChest.gd"):
				mine += 1
	var scatter := _find_scatter(get_tree().root)
	if scatter != null and not bool(scatter.get("setup_done")):
		scatter.set("_chests_placed",
				int(scatter.get("_chests_placed")) + mine)
		return
	var cfg := ConfigFile.new()
	cfg.load("user://chests.cfg")
	cfg.set_value("progress", "placed",
			maxi(int(cfg.get_value("progress", "placed", 0)), mine))
	cfg.save("user://chests.cfg")


func _find_scatter(n: Node) -> Node:
	var s := n.get_script() as Script
	if s != null and s.resource_path.ends_with("PropScatter.gd"):
		return n
	for c in n.get_children():
		var r := _find_scatter(c)
		if r != null:
			return r
	return null
