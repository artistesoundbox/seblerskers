extends Node3D
## A breakable barrel/village prop. Attached by PropScatter to the
## barrel-kind rules instead of the generic StaticBody path.
##
## Shot with a fireball (direct hit or caught in the blast radius):
## the barrel SPLINTERS — procedural wood chunks skid outward with a
## crack-thock sound and a sawdust puff — goes invisible and intangible
## (dead barrels never block anything), then respawns after a delay so
## the village restocks itself.
##
## Barrels also chain: a smashed barrel ignites neighbours within
## `chain_radius` a beat later, so the barrel pile pops piece by piece.

## Physics layer for the barrel body (world — fireballs hit it).
@export var body_layer := 1
## Seconds before a smashed barrel reappears.
@export var respawn_delay := 25.0
## Random extra respawn delay so clusters don't pop back in sync.
## Kept wide: each respawn is a static-body teleport into the world,
## which briefly (a few tenths of a second) churns the broadphase —
## spreading the waves keeps those hiccups short and far apart.
@export var respawn_jitter := 18.0
## A smashed barrel sets fire to neighbours within this distance.
@export var chain_radius := 3.0
## Wood chunks thrown per smash.
@export var debris_count := 8
## Loudness of the splinter crack.
@export var smash_db := -2.0

var alive := true

var _aabb := AABB()
var _rng := RandomNumberGenerator.new()

static var _crack_cache: AudioStreamWAV
const SR := 22050

## Dead barrels become scorched husks: the MESH is charred (shared
## material swap) while the collider stays exactly where it was.
## In a world this big, disabling a collider or teleporting a static
## body storms the physics broadphase for ~1 s (37 ms frames,
## measured; reproducible in the bare engine) — a material swap is
## free. A husk reads as "burnt out" and stays solid until it
## restocks, which is honest: it looks solid because it is.
static var _husk_mat: StandardMaterial3D

var _meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	_rng.randomize()
	add_to_group("barrel")
	_aabb = _mesh_aabb(self, Transform3D.IDENTITY)
	for m in _collect_meshes(self):
		_meshes.append(m)
	# NOTE: no own StaticBody. The barrel's collider is a shape in
	# PropScatter's regional collision bin, added once at scatter
	# time and NEVER changed: die/respawn only swap the mesh
	# materials (scorched husk <-> fresh). Toggling or re-inserting
	# a static body here storms the broadphase for up to a second
	# (measured) — so the barrel is physically immortal, visually
	# dead. A husk blocking fireballs reads honestly: charred wood
	# is still solid.


## Fireball blast reached this barrel (same entry point as the
## vikings). The barrel chars into a husk — no collider changes, no
## teleports, nothing the physics broadphase could storm over.
func die() -> void:
	if not alive:
		return
	alive = false
	_scorch(true)
	_smash_fx()
	smash_neighbours()


## Char / restore every mesh under this barrel. The husk material is
## shared and built once; clearing the override returns each mesh to
## its own materials.
func _scorch(dead: bool) -> void:
	if dead:
		if _husk_mat == null:
			_husk_mat = StandardMaterial3D.new()
			_husk_mat.albedo_color = Color(0.16, 0.13, 0.11)
			_husk_mat.roughness = 1.0
		for m in _meshes:
			if is_instance_valid(m):
				m.material_override = _husk_mat
	else:
		for m in _meshes:
			if is_instance_valid(m):
				m.material_override = null


func _collect_meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c as MeshInstance3D)
		out.append_array(_collect_meshes(c))
	return out


## Chains the blast outward: neighbours pop after a short beat so the
## pile crackles instead of vanishing at once.
func smash_neighbours() -> void:
	for b in get_tree().get_nodes_in_group("barrel"):
		if b == self:
			continue
		var n := b as Node3D
		if n == null or (b as Node).get("alive") != true:
			continue
		if n.global_position.distance_to(global_position) > chain_radius:
			continue
		var wait := get_tree().create_timer(_rng.randf_range(0.15, 0.4))
		wait.timeout.connect(n.call.bind("die"))


func _smash_fx() -> void:
	# FX are world-fixed (under the scene root): the barrel may be
	# respawned/moved later without dragging its debris along.
	var host := Node3D.new()
	host.name = "BarrelSmash"
	get_tree().current_scene.add_child(host)
	var top: float = to_global(_aabb.position).y
	var ctr: Vector3 = to_global(_aabb.get_center())
	var s: float = _aabb.size.y
	var wood: Array[Color] = [Color(0.55, 0.38, 0.22),
			Color(0.46, 0.31, 0.18), Color(0.64, 0.47, 0.28)]
	for i in debris_count:
		var chunk := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(_rng.randf_range(0.10, 0.26),
				_rng.randf_range(0.06, 0.16), _rng.randf_range(0.10, 0.24))
		chunk.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = wood[i % wood.size()]
		chunk.material_override = mat
		var from := ctr + Vector3(_rng.randf_range(-0.3, 0.3),
				_rng.randf_range(-0.2, 0.4), _rng.randf_range(-0.3, 0.3))
		chunk.position = from
		host.add_child(chunk)
		# Ballistic skid: accelerating out+down to the ground beside
		# the barrel, tumbling, then shrinking away.
		var flight := _rng.randf_range(0.45, 0.8)
		var land := from + Vector3(_rng.randf_range(-1.0, 1.0), 0.0,
				_rng.randf_range(-1.0, 1.0)).normalized() \
				* _rng.randf_range(1.0, 2.4)
		land.y = top + bm.size.y * 0.5
		var tw := chunk.create_tween()
		tw.set_parallel(true)
		tw.tween_property(chunk, "position", land, flight) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(chunk, "rotation",
				chunk.rotation + Vector3(_rng.randf_range(-7.0, 7.0),
						_rng.randf_range(-7.0, 7.0),
						_rng.randf_range(-7.0, 7.0)), flight)
		tw.chain().tween_property(chunk, "scale",
				Vector3.ONE * 0.05, 0.25)
	# Sawdust puff: two expanding beige clouds.
	for i in 2:
		var puff := MeshInstance3D.new()
		var pm := SphereMesh.new()
		pm.radius = s * 0.3
		pm.height = s * 0.6
		pm.radial_segments = 10
		pm.rings = 6
		puff.mesh = pm
		var pmat := StandardMaterial3D.new()
		pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pmat.albedo_color = Color(0.78, 0.66, 0.48, 0.55)
		puff.material_override = pmat
		puff.position = ctr + Vector3(_rng.randf_range(-0.3, 0.3),
				_rng.randf_range(0.0, 0.35), _rng.randf_range(-0.3, 0.3))
		host.add_child(puff)
		var pt := puff.create_tween()
		pt.set_parallel(true)
		pt.tween_property(puff, "scale", Vector3.ONE * 2.6, 0.7)
		pt.tween_property(pmat, "albedo_color:a", 0.0, 0.7)
	# Splinter crack: sharp crack impulses + a low wood thock.
	var voice := AudioStreamPlayer3D.new()
	voice.stream = _crack_stream()
	voice.pitch_scale = _rng.randf_range(0.85, 1.2)
	voice.volume_db = smash_db
	voice.max_distance = 60.0
	host.add_child(voice)
	voice.play()
	var sweep := get_tree().create_timer(1.8)
	sweep.timeout.connect(host.queue_free)
	# Restock.
	var back := get_tree().create_timer(respawn_delay
			+ _rng.randf() * respawn_jitter)
	back.timeout.connect(_respawn)


func _respawn() -> void:
	alive = true
	_scorch(false)


static func _crack_stream() -> AudioStreamWAV:
	if _crack_cache != null:
		return _crack_cache
	var samples := PackedFloat32Array()
	samples.resize(int(0.5 * SR))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x51a5
	var delays: Array[float] = [0.0, 0.028, 0.061]
	var freqs: Array[float] = [920.0, 1350.0, 640.0]
	var gains: Array[float] = [0.5, 0.4, 0.45]
	for i in samples.size():
		var t := float(i) / SR
		var v := rng.randf_range(-1.0, 1.0) * exp(-t * 9.0) * 0.55
		for k in 3:
			var dt := t - delays[k]
			if dt >= 0.0:
				v += sin(TAU * freqs[k] * dt) * exp(-dt * 90.0) * gains[k]
		if t < 0.3:
			v += sin(TAU * 175.0 * t) * exp(-t * 18.0) * 0.35
		samples[i] = clampf(v, -1.0, 1.0)
	_crack_cache = _to_stream(samples)
	return _crack_cache


static func _to_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	wav.data = bytes
	return wav


## Combined AABB of every mesh under `n`, in n-local space (barrels are
## rigid models — no skeleton special-casing needed).
func _mesh_aabb(n: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	for c in n.get_children():
		var c3d := c as Node3D
		var cxf := xf * (c3d.transform if c3d != null \
				else Transform3D.IDENTITY)
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null:
			var b: AABB = cxf * mi.mesh.get_aabb()
			out = b if first else out.merge(b)
			first = false
		var sub := _mesh_aabb(c, cxf)
		if sub.size != Vector3.ZERO:
			out = sub if first else out.merge(sub)
			first = false
	return out
