extends Node3D
class_name WaterSplash
## Sea-death splash: everything a water entry needs, built at runtime —
## no scene or asset dependencies. Spawned by MovementController at the
## exact point the player crossed the water surface.
##
## Anatomy of the splash:
## - a crown of water petals that rises, spreads and collapses
## - a foam disc that lingers where the body went under
## - ballistic droplets thrown upward that fall back and vanish
## - an expanding surface ripple ring
## - a brief blue light pulse (colored by the death flash)
## - a procedural splash sound, pitched/louder with entry speed
##
## The node frees itself when the last effect finishes.

const SAMPLE_RATE := 22050

## Base loudness of the splash sound.
@export var splash_db := -6.0
## How many water petals form the crown.
@export var crown_petals := 9
## How many ballistic droplets are thrown.
@export var droplet_count := 16
## Total lifetime of the effect (s).
@export var life := 1.4

var _strength := 1.0  # 0.4 shallow .. 2.0 terminal-velocity plunge
var _age := 0.0
var _crown: MeshInstance3D
var _crown_mat: StandardMaterial3D
var _foam: MeshInstance3D
var _foam_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _light: OmniLight3D
## Droplet records: { node: MeshInstance3D, vel: Vector3 }.
var _droplets: Array = []
var _sound: AudioStreamPlayer3D


## Configure and start. `entry_speed` is the speed the player hit the
## water with (m/s); `flash` colors the light pulse.
func setup(entry_speed: float, flash := Color(0.35, 0.65, 0.95)) -> void:
	_strength = clampf(entry_speed / 20.0, 0.4, 2.0)
	# One uniform scale drives the whole anatomy: light range scales
	# with the node, meshes and droplet arcs multiply with it.
	scale = Vector3.ONE * (0.7 + 0.3 * _strength)
	if _light != null:
		_light.light_color = flash.lightened(0.3)
	if _sound != null:
		_sound.volume_db = splash_db + 5.0 * (_strength - 0.4)
		# Big splashes sound deep, shallow ones bright.
		_sound.pitch_scale = clampf(1.3 - 0.3 * _strength, 0.7, 1.3)
		_sound.stream = _make_stream(_strength)
		_sound.play()


func _ready() -> void:
	var foam_color := Color(0.85, 0.95, 1.0)

	# Crown: a ring of stretched water petals.
	_crown = MeshInstance3D.new()
	var crown_mesh := SphereMesh.new()
	crown_mesh.radius = 0.62
	crown_mesh.height = 1.9
	crown_mesh.radial_segments = 14
	crown_mesh.rings = 8
	_crown.mesh = crown_mesh
	_crown_mat = StandardMaterial3D.new()
	_crown_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_crown_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_crown_mat.albedo_color = Color(0.72, 0.89, 1.0, 0.55)
	_crown_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_crown.material_override = _crown_mat
	add_child(_crown)
	# Petal ring: several stretched spheres fanned outward.
	for i in crown_petals:
		var petal := MeshInstance3D.new()
		var pm := SphereMesh.new()
		pm.radius = 0.16
		pm.height = 0.85
		pm.radial_segments = 8
		pm.rings = 4
		petal.mesh = pm
		petal.material_override = _crown_mat
		var a := TAU * float(i) / float(crown_petals)
		petal.position = Vector3(cos(a) * 0.5, 0.1, sin(a) * 0.5)
		petal.rotation.x = 0.55  # lean outward
		petal.rotation.y = -a  # ...away from the center
		_crown.add_child(petal)

	# Foam: the disc that stays where the body went under.
	_foam = MeshInstance3D.new()
	var foam_mesh := SphereMesh.new()
	foam_mesh.radius = 0.75
	foam_mesh.height = 0.28
	foam_mesh.radial_segments = 16
	foam_mesh.rings = 6
	_foam.mesh = foam_mesh
	_foam_mat = StandardMaterial3D.new()
	_foam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_foam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_foam_mat.albedo_color = Color(foam_color.r, foam_color.g, foam_color.b,
			0.5)
	_foam.material_override = _foam_mat
	add_child(_foam)

	# Ripple ring: expanding surface circle.
	_ring = MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.68
	ring_mesh.outer_radius = 0.8
	_ring.mesh = ring_mesh
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.albedo_color = Color(foam_color.r, foam_color.g, foam_color.b,
			0.4)
	_ring.material_override = _ring_mat
	_ring.position.y = 0.04
	add_child(_ring)

	# Light pulse: colored by the death flash, gone in 0.6 s.
	_light = OmniLight3D.new()
	_light.omni_range = 7.0
	_light.light_energy = 1.6
	add_child(_light)

	# Droplets: unshaded water beads with real ballistics.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(global_position)
	for i in droplet_count:
		var drop := MeshInstance3D.new()
		var dm := SphereMesh.new()
		var r := rng.randf_range(0.05, 0.12)
		dm.radius = r
		dm.height = r * 2.0
		dm.radial_segments = 8
		dm.rings = 4
		drop.mesh = dm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.8, 0.92, 1.0, 0.8)
		drop.material_override = mat
		add_child(drop)
		var a := rng.randf() * TAU
		var rad := rng.randf_range(0.1, 0.45)
		drop.position = Vector3(cos(a) * rad, rng.randf_range(0.0, 0.2),
				sin(a) * rad)
		var vel := Vector3(cos(a) * rng.randf_range(0.8, 2.6),
				rng.randf_range(2.5, 5.5), sin(a) * rng.randf_range(0.8, 2.6))
		_droplets.append({"node": drop, "vel": vel})

	_sound = AudioStreamPlayer3D.new()
	_sound.name = "SplashSound"
	_sound.max_distance = 80.0
	_sound.bus = "Master"
	add_child(_sound)


func _physics_process(delta: float) -> void:
	_age += delta

	# Crown: rises and spreads to the apex (~0.3 s), then collapses.
	var ct := clampf(_age / 0.55, 0.0, 1.0)
	if _crown != null:
		_crown.position.y = sin(ct * PI) * 0.95
		_crown.scale = Vector3.ONE * lerpf(0.55, 1.2, ct)
		_crown_mat.albedo_color.a = 0.55 * (1.0 - ct * ct)
		if ct >= 1.0:
			_crown.visible = false

	# Foam: spreads and fades over 0.9 s.
	if _foam != null:
		var ft := clampf(_age / 0.9, 0.0, 1.0)
		_foam.scale = Vector3.ONE * lerpf(0.5, 1.7, ft)
		_foam_mat.albedo_color.a = 0.5 * (1.0 - ft)
		if ft >= 1.0:
			_foam.visible = false

	# Ripple: expands outward, thinning, over ~1 s.
	if _ring != null:
		var rt := clampf(_age / 1.05, 0.0, 1.0)
		_ring.scale = Vector3(lerpf(0.4, 2.6, rt), 1.0, lerpf(0.4, 2.6, rt))
		_ring_mat.albedo_color.a = 0.4 * (1.0 - rt)
		if rt >= 1.0:
			_ring.visible = false

	# Light pulse.
	if _light != null:
		_light.light_energy = 1.6 * maxf(0.0, 1.0 - _age / 0.6)
		if _age >= 0.6:
			_light.visible = false

	# Droplets: gravity, then gone under the surface (local y < 0).
	for i in range(_droplets.size() - 1, -1, -1):
		var d: Dictionary = _droplets[i]
		var node: MeshInstance3D = d.node
		var vel: Vector3 = d.vel
		vel.y -= 14.0 * delta
		d.vel = vel
		node.position += vel * delta
		if node.position.y < 0.0:
			node.queue_free()
			_droplets.remove_at(i)

	if _age >= life:
		queue_free()


## --- Procedural splash sound --------------------------------------------


## Layers: a low body-entry whumph (220->70 Hz sweep), a bright noise
## burst that settles into fizz, and a tail of random droplet plinks.
## Rebuilt per splash (rare event, cheap) so entry speed shapes it.
static func _make_stream(strength: float) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260915
	var length := int(0.9 * SAMPLE_RATE)
	var data := PackedFloat32Array()
	data.resize(length)
	var lp := 0.0
	var phase := 0.0
	for i in length:
		var u := float(i) / float(length)
		var v := 0.0
		# Body-entry whumph: quick downward sine sweep.
		if u < 0.18:
			var tu := u / 0.18
			phase += TAU * (220.0 - 150.0 * tu) / float(SAMPLE_RATE)
			v += sin(phase) * 0.75 * exp(-16.0 * tu)
		# Spray burst: noise through a closing low-pass (bright splash
		# settling into water fizz).
		var bright := exp(-7.0 * u)
		lp = lerpf(lp, rng.randf_range(-1.0, 1.0), 0.05 + 0.4 * bright)
		v += lp * 0.75 * exp(-6.0 * u)
		# Droplet plinks in the tail.
		if u > 0.25 and u < 0.85 and rng.randf() < 0.0016:
			var plink_len := int(0.035 * SAMPLE_RATE)
			var freq := rng.randf_range(900.0, 2100.0)
			var amp := rng.randf_range(0.05, 0.14)
			for k in plink_len:
				var idx := i + k
				if idx >= length:
					break
				var ku := float(k) / float(plink_len)
				data[idx] += sin(TAU * freq * float(k) / float(SAMPLE_RATE)) \
						* amp * (1.0 - ku) * (1.0 - ku)
		data[i] += v
	# Strength shapes the mix before packing.
	var out := PackedFloat32Array()
	out.resize(length)
	for i in length:
		out[i] = clampf(data[i] * (0.8 + 0.3 * strength), -1.0, 1.0)
	return _to_stream(out)


static func _to_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2,
				int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = bytes
	return wav
