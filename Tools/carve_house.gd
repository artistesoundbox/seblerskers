extends SceneTree
## One-shot tool: carves three walk-through doorways into the viking
## house GLB's single indexed mesh by REMOVING every triangle inside
## each door volume (the shell is double-walled and the door volumes
## pierce both skins plus the roof overhang above, so the cut opens
## clean rectangular holes with sharp edges).
##
## The existing south doorway is left untouched. Output:
## res://a_viking_house_carved.res (ArrayMesh, original material kept).
##
## Run:
##   Godot --headless --path . --script Tools/carve_house.gd

const SRC := "res://a_viking_house.glb"
const DST := "res://a_viking_house_carved.res"

## Door volumes in MODEL-LOCAL space (the GLB instance sits at identity,
## so model space == prop-local space). Widen generously past the wall
## skins so both layers are cut, but stay inside the wall runs.
const DOORS := [
	# North long wall: centred on x=0, through z=-0.54..-0.30.
	{"a": Vector3(-0.16, -0.62, -0.60), "b": Vector3(0.16, -0.15, -0.24)},
	# East end wall: through x=+0.78..+1.00.
	{"a": Vector3(0.75, -0.62, -0.13), "b": Vector3(1.02, -0.15, 0.13)},
	# West end wall: mirrored.
	{"a": Vector3(-1.02, -0.62, -0.13), "b": Vector3(-0.75, -0.15, 0.13)},
]

var _log: FileAccess

func _mark(s: String) -> void:
	if _log != null:
		_log.store_line(s)
		_log.flush()

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_log = FileAccess.open("res://.freebuff/carve_log.txt", FileAccess.WRITE)
	_mark("A: started")
	var packed: PackedScene = load(SRC)
	if packed == null:
		push_error("cannot load %s" % SRC)
		quit(1)
		return
	var inst: Node3D = packed.instantiate()
	var mis := inst.find_children("*", "MeshInstance3D", true, false)
	if mis.is_empty():
		push_error("no MeshInstance3D in %s" % SRC)
		quit(1)
		return
	var mi := mis[0] as MeshInstance3D
	var src := mi.mesh
	var arr := src.surface_get_arrays(0)
	_mark("B: mesh grabbed")
	var verts := arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
	_mark("B1: verts %d" % verts.size())
	var idx := arr[Mesh.ARRAY_INDEX] as PackedInt32Array
	_mark("B2: idx %d" % idx.size())
	var uv := arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array
	_mark("B3: uv %d" % uv.size())
	var norm := arr[Mesh.ARRAY_NORMAL] as PackedVector3Array
	_mark("B4: norm %d" % norm.size())
	# NOTE: do NOT read ARRAY_TANGENT here — this Godot build hangs on
	# that cast in headless script mode. Tangents are skipped; the house
	# material has no normal map, so lighting is unaffected.
	# Drop every triangle whose three corners all sit inside a door
	# volume. Triangles crossing the volume edge stay and form the
	# cut's rim.
	var keep := PackedInt32Array()
	var dropped := 0
	var tri_count := idx.size() / 3
	_mark("C: tris %d" % tri_count)
	for t in range(0, idx.size(), 3):
		var v0 := verts[idx[t]]
		var v1 := verts[idx[t + 1]]
		var v2 := verts[idx[t + 2]]
		if _in_any(v0, v1, v2):
			dropped += 1
			continue
		keep.append(idx[t])
		keep.append(idx[t + 1])
		keep.append(idx[t + 2])
		if (t / 3) % 2000 == 0:
			_mark("  ..t %d" % (t / 3))
	_mark("D: dropped %d, keeping %d" % [dropped, keep.size() / 3])
	var out := ArrayMesh.new()
	var out_arr := []
	out_arr.resize(Mesh.ARRAY_MAX)
	out_arr[Mesh.ARRAY_VERTEX] = verts
	out_arr[Mesh.ARRAY_INDEX] = keep
	if not norm.is_empty():
		out_arr[Mesh.ARRAY_NORMAL] = norm
	if not uv.is_empty():
		out_arr[Mesh.ARRAY_TEX_UV] = uv
	var mat := src.surface_get_material(0)
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out_arr)
	if mat != null:
		out.surface_set_material(0, mat)
	_mark("E: mesh built")
	var err := ResourceSaver.save(out, DST)
	_mark("F: save returned %d" % err)
	if err != OK:
		push_error("save failed: %s" % err)
		quit(1)
		return
	_mark("G: saved")
	inst.free()
	_log.close()
	quit(0)

func _in_any(a: Vector3, b: Vector3, c: Vector3) -> bool:
	for d_v in DOORS:
		var d: Dictionary = d_v
		if _box_has(d["a"], d["b"], a) and _box_has(d["a"], d["b"], b) \
				and _box_has(d["a"], d["b"], c):
			return true
	return false

func _box_has(lo: Vector3, hi: Vector3, p: Vector3) -> bool:
	return p.x >= lo.x and p.x <= hi.x and p.y >= lo.y and p.y <= hi.y \
			and p.z >= lo.z and p.z <= hi.z
