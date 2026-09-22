extends Node3D
## Superman landing: the ground SHATTERS under a hard touchdown. Same
## recipe family as the barrel smash (BarrelProp._smash_fx) — procedural
## debris chunks, puffs and a synthesized crack — but earth-flavoured:
## soil/stone chunks burst outward in a low cone, a dark crack ring
## splinters across the ground, a shockwave of dust rolls outward and a
## deep crack-thud punctuates the impact. Everything is world-fixed
## (under the scene root) so nothing drags along with the player, and
## the whole effect auto-frees. Scaled by the landing `strength`
## (0.3..1.0 from FootstepFX's fall-speed impact).
class_name LandingCrack

const SR := 22050
## Effect lifetime (s) before the host cleans itself up.
const LIFETIME := 2.4

static var _crack_cache: AudioStreamWAV

## Debris chunks ejected per point of strength.
@export var debris_count := 12
## Loudness of the crack-thud at full strength.
@export var crack_db := -8.5


## Entry point: builds the effect at `at` (a ground contact point) and
## walks away — no references kept, it frees itself.
static func play(host: Node, at: Vector3, strength: float) -> void:
	if host == null:
		return
	var fx: Node3D = load("res://Player/LandingCrack.gd").new()
	fx.name = "LandingCrack"
	host.add_child(fx)
	fx.call("_setup", at, strength)


func _setup(at: Vector3, strength: float) -> void:
	global_position = at
	# Ground orientation: the crack ring lies ON the surface, so probe
	# the normal below the impact point (flat fallback everywhere else).
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
			at + Vector3.UP * 1.5, at + Vector3.DOWN * 3.0, 1)
	var hit := space.intersect_ray(q)
	var n := Vector3.UP
	if not hit.is_empty():
		n = hit.get("normal", Vector3.UP)
	var basis := Basis()
	if n.angle_to(Vector3.UP) > 0.01:
		basis = Basis(Quaternion(Vector3.UP, n))
	global_transform = Transform3D(basis, at)
	_ground_ring(strength)
	_shockwave_dust(strength)
	_debris(strength)
	_crack_sound(strength)
	get_tree().create_timer(LIFETIME).timeout.connect(queue_free)


## The "pavement cracked" flash: a dark disc, a splintering ring of
## radial shards and an expanding pressure ring, all flat on the
## ground, flashing bright then fading.
func _ground_ring(strength: float) -> void:
	var ring_scale := 0.9 + 1.6 * strength
	var flash := StandardMaterial3D.new()
	flash.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flash.albedo_color = Color(0.09, 0.07, 0.05, 0.62)
	# Dark disc: the ground "gives way" under the feet.
	var disc := MeshInstance3D.new()
	var dm := CylinderMesh.new()
	dm.top_radius = 0.55 * ring_scale
	dm.bottom_radius = 0.55 * ring_scale
	dm.height = 0.02
	disc.mesh = dm
	disc.material_override = flash
	disc.position = Vector3(0, 0.03, 0)
	add_child(disc)
	# Radial crack shards: jagged thin boxes splaying outward.
	var shards := 6 + int(strength * 4.0)
	for i in shards:
		var ang := TAU * float(i) / float(shards) + randf_range(-0.2, 0.2)
		var shard := MeshInstance3D.new()
		var bm := BoxMesh.new()
		var ln := randf_range(0.4, 1.1) * ring_scale
		bm.size = Vector3(randf_range(0.05, 0.12), 0.02, ln)
		shard.mesh = bm
		shard.material_override = flash
		var mid := ln * 0.5 + 0.35 * ring_scale
		shard.position = Vector3(cos(ang) * mid, 0.035, sin(ang) * mid)
		shard.rotation.y = -ang
		add_child(shard)
		# Shards lunge outward as the ground splits, then fade.
		var out := Vector3(cos(ang), 0.0, sin(ang)) * 0.55 * ring_scale
		var tw := shard.create_tween()
		tw.set_parallel(true)
		tw.tween_property(shard, "position",
				shard.position + out, 0.28) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(flash, "albedo_color:a", 0.0, 0.6)
	# Expanding pressure ring (the shockwave's edge).
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.42
	tm.outer_radius = 0.5
	ring.mesh = tm
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.albedo_color = Color(0.85, 0.8, 0.7, 0.4)
	ring.material_override = rmat
	ring.position = Vector3(0, 0.06, 0)
	ring.scale = Vector3.ONE * 0.4
	add_child(ring)
	var rt := ring.create_tween()
	rt.set_parallel(true)
	rt.tween_property(ring, "scale", Vector3.ONE * 2.4 * ring_scale, 0.45) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	rt.tween_property(rmat, "albedo_color:a", 0.0, 0.45)


## Shockwave: earth-toned dust puffs arranged in a circle rolling
## outward from the impact, like the pavement blowing off its dust.
func _shockwave_dust(strength: float) -> void:
	var puffs := 7
	var radius := 0.45
	var spread := 0.9 + 1.5 * strength
	for i in puffs:
		var ang := TAU * float(i) / float(puffs) + randf_range(-0.15, 0.15)
		var puff := MeshInstance3D.new()
		var pm := SphereMesh.new()
		pm.radius = randf_range(0.16, 0.26)
		pm.height = pm.radius * 1.6
		pm.radial_segments = 9
		pm.rings = 5
		puff.mesh = pm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.62, 0.53, 0.38,
				randf_range(0.4, 0.55))
		puff.material_override = mat
		puff.position = Vector3(cos(ang) * radius,
				pm.radius * 0.5, sin(ang) * radius)
		add_child(puff)
		var pt := puff.create_tween()
		pt.set_parallel(true)
		pt.tween_property(puff, "position",
				puff.position + Vector3(cos(ang) * spread,
						randf_range(0.2, 0.7), sin(ang) * spread),
				randf_range(0.45, 0.75)) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		pt.tween_property(puff, "scale", Vector3.ONE * 2.2, 0.7)
		pt.tween_property(mat, "albedo_color:a", 0.0, 0.7)


## Stone/soil chunks burst outward in a low cone and skid to rest
## beside the crater — the barrel-smash ballistic skid, grounded.
func _debris(strength: float) -> void:
	var earth: Array[Color] = [Color(0.42, 0.35, 0.26),
			Color(0.5, 0.44, 0.34), Color(0.3, 0.28, 0.26),
			Color(0.55, 0.5, 0.42)]
	var count := int(debris_count * (0.5 + strength * 0.7))
	for i in count:
		var chunk := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(randf_range(0.06, 0.2),
				randf_range(0.05, 0.14), randf_range(0.06, 0.18))
		chunk.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = earth[i % earth.size()]
		chunk.material_override = mat
		var ang := randf() * TAU
		var from := Vector3(cos(ang) * randf_range(0.0, 0.3),
				randf_range(0.05, 0.2), sin(ang) * randf_range(0.0, 0.3))
		chunk.position = from
		add_child(chunk)
		# Low ballistic cone: out and slightly up, landing radially out.
		var flight := randf_range(0.4, 0.75)
		var dist := randf_range(0.8, 2.1) * (0.55 + strength * 0.6)
		var land := Vector3(cos(ang) * dist, bm.size.y * 0.5,
				sin(ang) * dist)
		var tw := chunk.create_tween()
		tw.set_parallel(true)
		tw.tween_property(chunk, "position", land, flight) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(chunk, "rotation",
				chunk.rotation + Vector3(randf_range(-8.0, 8.0),
						randf_range(-8.0, 8.0), randf_range(-8.0, 8.0)),
				flight)
		tw.chain().tween_property(chunk, "scale",
				Vector3.ONE * 0.05, 0.3)


## Deep superman crack-thud: a pitch-swept ground thud, two sharp
## crack impulses and a low rumble tail. Cached like the barrel crack.
func _crack_sound(strength: float) -> void:
	var voice := AudioStreamPlayer3D.new()
	voice.stream = _crack_stream()
	voice.pitch_scale = randf_range(0.9, 1.1) * (1.15 - strength * 0.2)
	voice.volume_db = crack_db - 7.0 * (1.0 - strength)
	voice.max_distance = 80.0
	add_child(voice)
	voice.play()


static func _crack_stream() -> AudioStreamWAV:
	if _crack_cache != null:
		return _crack_cache
	var samples := PackedFloat32Array()
	samples.resize(int(1.0 * SR))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x3EA75
	for i in samples.size():
		var t := float(i) / SR
		var v := 0.0
		# Ground thud: 150 -> 50 Hz sweep, fast decay.
		if t < 0.35:
			var f := 150.0 - 100.0 * (t / 0.35)
			v += sin(TAU * (150.0 - 55.0 * t) * t) * exp(-t * 11.0) * 0.85
			v += sin(TAU * f * 0.5 * t) * exp(-t * 9.0) * 0.3
		# Two sharp crack impulses right at impact.
		for k in 2:
			var dt := t - 0.004 * k
			if dt >= 0.0 and dt < 0.06:
				v += rng.randf_range(-1.0, 1.0) * exp(-dt * 130.0) * 0.5
		# Stone ping decay.
		if t >= 0.0:
			v += sin(TAU * 1100.0 * t) * exp(-t * 60.0) * 0.18
		# Low rumble tail: two slow decaying sines.
		v += sin(TAU * 46.0 * t) * exp(-t * 4.5) * 0.28
		v += sin(TAU * 71.0 * t) * exp(-t * 5.5) * 0.2
		samples[i] = clampf(v, -1.0, 1.0)
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.data = bytes
	_crack_cache = wav
	return wav
