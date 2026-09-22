extends Node3D
## A flock of birds perched in one grove's canopy. While perched they
## flick and fidget on their branches; when a FLYING player swoops
## through the canopy layer near them they scatter — burst outward
## away from the intruder, chirping — then glide a wide arc and drift
## back to their perches. Fireball blasts scare them the same way
## (the explosion calls scare_from_blast through the "birds" group).
##
## All geometry is procedural (body, beak, tail), the chirps are
## synthesized WAV (two-note tweet, per-bird pitch), and each flock is
## cheap: ~7 birds, one shared look, no lights.

## Birds in the flock.
@export var bird_count := 7
## Horizontal distance at which a swooping player flushes the flock (m).
@export var react_radius := 10.0
## Player speed that counts as a threatening swoop (m/s) — a slow
## hover through the canopy does not scare them.
@export var react_speed := 8.0
## Vertical band around the birds where a flyby counts (m).
@export var canopy_band := 4.0
## Scatter burst speed (m/s), per-bird randomized around this.
@export var scatter_speed := 10.0
## Seconds on the wing before drifting back to the perch.
@export var return_delay := 6.0
## Blast radius that scares every bird (m) — slightly larger than the
## fireball's own blast so the flock reacts to near misses.
@export var blast_scare_radius := 14.0
## Chirp loudness.
@export var chirp_db := -6.0
## Deterministic flock personality (set from PropScatter).
@export var flock_seed := 0

const SR := 22050
static var _chirp_cache: AudioStreamWAV

## One bird: procedural mesh, perch, voice and flight state.
class Bird:
	var root: Node3D
	var perch: Vector3  # local to the flock
	var voice: AudioStreamPlayer3D
	var state := 0  # 0 perched, 1 scattered, 2 returning
	var dir := Vector3.ZERO
	var speed := 0.0
	var wait := 0.0
	var chirps := 0
	var chirp_t := 0.0

var _birds: Array[Bird] = []
var _rng := RandomNumberGenerator.new()
var _perches: PackedVector3Array
var _t := 0.0


## PropScatter hands in world-space perch points (canopy tops) before
## the flock enters the tree.
func set_perches(world_points: PackedVector3Array) -> void:
	_perches = world_points


func _ready() -> void:
	_rng.seed = flock_seed
	add_to_group("birds")
	var n := mini(bird_count, _perches.size())
	for i in n:
		var b := Bird.new()
		b.root = _build_bird()
		b.perch = _perches[i] - global_position
		b.root.position = b.perch
		b.voice = AudioStreamPlayer3D.new()
		b.voice.stream = _chirp_stream()
		b.voice.pitch_scale = _rng.randf_range(0.85, 1.3)
		b.voice.volume_db = chirp_db
		b.voice.max_distance = 70.0
		b.root.add_child(b.voice)
		add_child(b.root)
		_birds.append(b)


## A fireball blast nearby: the whole flock flushes instantly, away
## from the impact (called via the "birds" group).
func scare_from_blast(at: Vector3) -> void:
	for b in _birds:
		if b.state == 0:
			_flush(b, (b.root.global_position - at).normalized(), 1.35)
			b.chirps = 2 + _rng.randi_range(0, 2)


## Diagnostics: how many birds are off their perch right now.
func airborne_count() -> int:
	var n := 0
	for b in _birds:
		if b.state != 0:
			n += 1
	return n


## Diagnostics: true while any bird is mid-chirp.
func chirping() -> bool:
	for b in _birds:
		if b.voice.playing:
			return true
	return false


func _process(delta: float) -> void:
	_t += delta
	# The threat: any player swooping through the canopy layer.
	var threat: MovementController = null
	for p in get_tree().get_nodes_in_group("player"):
		var mc := p as MovementController
		if mc == null or not mc.flying:
			continue
		if mc.velocity.length() < react_speed:
			continue
		threat = mc
		break
	for b in _birds:
		match b.state:
			0:
				_perched_tick(b, delta, threat)
			1:
				_flight_tick(b, delta, false)
			2:
				_flight_tick(b, delta, true)


## Perched: fidget gently; flush when a swoop passes through the band.
func _perched_tick(b: Bird, delta: float, threat: MovementController) -> void:
	# Fidget: a tiny idle rock on the branch.
	b.root.rotation.z = sin(_t * (2.0 + b.perch.x * 0.31) + b.perch.z) * 0.05
	if threat == null:
		return
	var bp := b.root.global_position
	var tp := threat.global_position
	if absf(tp.y - bp.y) > canopy_band:
		return
	if Vector2(tp.x - bp.x, tp.z - bp.z).length() > react_radius:
		return
	var away := bp - tp
	away.y = 0.0
	var dir := away.normalized() if away.length() > 0.01 \
			else Vector3.FORWARD
	dir += Vector3(0, _rng.randf_range(0.45, 0.8), 0)
	_flush(b, dir.normalized(), 1.0)
	b.chirps = 2 + _rng.randi_range(0, 2)


func _flush(b: Bird, dir: Vector3, boost: float) -> void:
	b.state = 1
	b.dir = dir
	b.speed = scatter_speed * boost * _rng.randf_range(0.85, 1.2)
	b.wait = 0.0
	b.chirp_t = 0.0
	# Face the escape heading.
	if dir.length() > 0.01:
		b.root.basis = Basis.looking_at(dir, Vector3.UP)


## Airborne: burst outward, bleed speed, glide, then drift home.
func _flight_tick(b: Bird, delta: float, returning: bool) -> void:
	# Chirp while flying: short bursts of 2-4 notes.
	if b.chirps > 0:
		b.chirp_t -= delta
		if b.chirp_t <= 0.0:
			b.voice.play()
			b.chirps -= 1
			b.chirp_t = _rng.randf_range(0.25, 0.8)
	if returning:
		var target := global_position + b.perch
		var to := target - b.root.global_position
		var step := to.normalized() * minf(5.0 * delta, to.length())
		b.root.global_position += step
		if to.length() > 0.01:
			b.root.basis = Basis.looking_at(to.normalized(), Vector3.UP)
		if to.length() < 0.25:
			b.state = 0
			b.root.position = b.perch
			b.root.basis = Basis.IDENTITY
		return
	b.root.global_position += b.dir * b.speed * delta
	# Drag bleeds the burst; the heading eases toward level glide.
	b.speed = maxf(b.speed - 6.5 * delta, 2.2)
	b.dir.y = move_toward(b.dir.y, -0.12, 0.6 * delta)
	b.root.basis = Basis.looking_at(b.dir.normalized(), Vector3.UP)
	b.wait += delta
	if b.wait >= return_delay and b.speed <= 2.5:
		b.state = 2

## Procedural bird: dark round body, orange beak, angled tail.
func _build_bird() -> Node3D:
	var root := Node3D.new()
	var body := MeshInstance3D.new()
	var bm := SphereMesh.new()
	bm.radius = 0.09
	bm.height = 0.18
	bm.radial_segments = 10
	bm.rings = 6
	body.mesh = bm
	body.scale = Vector3(1.0, 0.85, 1.45)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.15, 0.18)
	body.material_override = mat
	root.add_child(body)
	var beak := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = 0.022
	cm.height = 0.09
	beak.mesh = cm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.92, 0.55, 0.12)
	beak.material_override = bmat
	beak.rotation.x = TAU * 0.25  # point +Z (the bird's forward)
	beak.position = Vector3(0, 0.01, 0.15)
	root.add_child(beak)
	var tail := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.06, 0.02, 0.16)
	tail.mesh = tm
	tail.material_override = mat
	tail.position = Vector3(0, 0.02, -0.16)
	tail.rotation.x = -0.35
	root.add_child(tail)
	return root


## Synthesized two-note tweet: descending FM sweeps with a fast
## attack/decay envelope (one cached stream, per-bird pitch variance).
static func _chirp_stream() -> AudioStreamWAV:
	if _chirp_cache != null:
		return _chirp_cache
	var samples := PackedFloat32Array()
	samples.resize(int(0.34 * SR))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xB12D
	for i in samples.size():
		var t := float(i) / SR
		var v := 0.0
		# Two notes: 60 ms at t=0, 70 ms at t=0.16 s.
		for k in 2:
			var t0 := 0.0 if k == 0 else 0.16
			var dur := 0.06 if k == 0 else 0.07
			var dt := t - t0
			if dt >= 0.0 and dt < dur:
				var ph := dt / dur
				var f := 3200.0 - 1100.0 * ph  # descending sweep
				var env := sin(PI * ph)
				v += sin(TAU * f * dt + sin(TAU * 42.0 * dt) * 0.7) * env
		v += rng.randf_range(-1.0, 1.0) * 0.015  # breath
		samples[i] = clampf(v * 0.6, -1.0, 1.0)
	_chirp_cache = _to_stream(samples)
	return _chirp_cache


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
