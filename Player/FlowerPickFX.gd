extends Node3D
## Flower-pick FX: petals burst up in a quick fountain while the
## picker's arm reaches down (a one-shot procedural reach-pick-reach
## blend on the arm bones/pivots) — the moment of plucking pops a
## soft pluck-chirp, 3D positioned at the picked flower. Independent
## of the picker node, so nothing about the wanderer's gait machinery
## is touched.
class_name FlowerPickFX

const SR := 22050
static var _pluck_cache: AudioStreamWAV


## Full sequence at `patch`'s bloom position; auto-frees.
## (Instantiation goes through load()+set_script: a script cannot
## reference its own class_name — that breaks the whole compile.)
static func play(host: Node, picker: Node3D, at: Vector3, kind: int) -> void:
	if host == null:
		host = picker  # any in-tree node works (FX is self-positioning)
	if host == null:
		return
	var fx: Node3D = load("res://Player/FlowerPickFX.gd").new()
	host.add_child(fx)
	fx.call("_setup", picker, at, kind)


func _setup(picker: Node3D, at: Vector3, kind: int) -> void:
	# Petal fountain (independent node at the bloom's spot).
	var petals := Node3D.new()
	add_child(petals)
	petals.global_position = at
	var base := Color(0.9, 0.32, 0.42) if kind == 0 \
			else Color(0.55, 0.4, 0.85)
	_spawn_petals(petals, base)
	# Reach + pluck chirp.
	_start_reach(picker)
	var pluck := AudioStreamPlayer3D.new()
	pluck.stream = _pluck_stream()
	pluck.pitch_scale = randf_range(0.92, 1.15)
	pluck.volume_db = -8.0
	pluck.max_distance = 34.0
	add_child(pluck)
	pluck.global_position = at
	pluck.play()
	get_tree().create_timer(1.2).timeout.connect(pluck.queue_free)
	get_tree().create_timer(2.6).timeout.connect(queue_free)


func _spawn_petals(parent: Node3D, base: Color) -> void:
	for i in 7:
		var pm := SphereMesh.new()
		pm.radius = randf_range(0.025, 0.045)
		pm.height = pm.radius * 0.7
		pm.radial_segments = 6
		pm.rings = 4
		var p := MeshInstance3D.new()
		p.mesh = pm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = base.lightened(randf_range(-0.1, 0.25))
		mat.emission_enabled = true
		mat.emission = base * 0.35
		mat.emission_energy_multiplier = 0.5
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		p.material_override = mat
		var ang := randf() * TAU
		var r := randf_range(0.05, 0.2)
		p.position = Vector3(cos(ang) * r, randf_range(0.0, 0.1),
				sin(ang) * r)
		parent.add_child(p)
		var vx := cos(ang) * randf_range(0.25, 0.8)
		var vz := sin(ang) * randf_range(0.25, 0.8)
		var vy := randf_range(1.0, 1.7)
		var tw := p.create_tween()
		tw.set_parallel(true)
		tw.tween_property(p, "position",
				p.position + Vector3(vx * 0.55, -0.28, vz * 0.55), 0.85) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(p, "rotation",
				Vector3(randf() * TAU, randf() * TAU, randf() * TAU), 0.85)
		tw.tween_property(p, "transparency", 1.0, 0.85) \
				.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)


## The picker crouches toward the bloom: a one-shot, hand-driven pose
## pulse on their arm machinery — works on both gait tiers (skeleton
## bone poses, rigid pivots). The wanderer's per-frame gait keeps
## rewriting those same bones, so the pose decays on its own; we just
## push it hard once and let the walk animation reclaim it.
func _start_reach(picker: Node3D) -> void:
	if picker == null:
		return
	var sk: Skeleton3D = null
	for n in picker.find_children("*", "Skeleton3D", true, false):
		sk = n
		break
	if sk != null:
		_reach_skeleton(sk)
		return
	var pivot: Node3D = null
	for n in picker.find_children("LegPivot*", "Node3D", true, false):
		pivot = n
		break
	if pivot != null:
		_reach_rigid(pivot)


func _reach_skeleton(sk: Skeleton3D) -> void:
	for i in sk.get_bone_count():
		var bn := sk.get_bone_name(i).to_lower()
		if not (bn.contains("arm") or bn.contains("hand")):
			continue
		var rest := sk.get_bone_pose_rotation(i)
		var fwd := -sk.global_transform.basis.z
		var sgn := 1.0
		if (sk.global_transform.basis * Vector3(1, 0, 0)) \
				.dot(fwd) < 0.0:
			sgn = -1.0
		sk.set_bone_pose_rotation(i, rest * Quaternion(
				Vector3(1, 0, 0), sgn * deg_to_rad(60.0)))
		sk.force_update_all_bone_transforms()


func _reach_rigid(pivot: Node3D) -> void:
	# Tilt the whole arm pivot forward-down briefly; the walk gait
	# overwrites the basis next frame, so this reads as a quick reach.
	pivot.rotation = pivot.rotation \
			+ Vector3(deg_to_rad(55.0), 0.0, 0.0)


## Soft two-note "plick" — same family as the berry pluck but airier.
static func _pluck_stream() -> AudioStreamWAV:
	if _pluck_cache != null:
		return _pluck_cache
	var samples := PackedFloat32Array()
	samples.resize(int(0.16 * SR))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xF100
	for i in samples.size():
		var t := float(i) / SR
		var v := sin(TAU * (740.0 - 260.0 * t) * t) * exp(-t * 30.0) * 0.5
		v += sin(TAU * 1480.0 * t) * exp(-t * 55.0) * 0.22
		v += rng.randf_range(-1.0, 1.0) * exp(-t * 80.0) * 0.12
		samples[i] = clampf(v, -1.0, 1.0)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	wav.data = bytes
	_pluck_cache = wav
	return wav
