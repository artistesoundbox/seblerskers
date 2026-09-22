extends Node3D
class_name ForageProp
## Gatherable food on the bushes: ripe berry clusters or herb sprigs
## sit on the leaf blobs. The player gathers them (G / pad Back) —
## the cluster pops with a pluck sound and floating pickup text, the
## bush stays bare for a while, then the fruit regrows. PropScatter
## seeds each bush via seed_bush(); the controller finds ripe spots
## through the "forage" group.

## Seconds until the fruit regrows (randomized around this).
@export var regrow_time := 40.0
## Ripe cluster idle pulse amplitude.
@export var ripe_pulse := 0.045

var kind := "berries"  # "berries" | "herbs"
var ripe := true

var _spots: Array[Node3D] = []
var _regrow := 0.0
var _t := 0.0
var _rng := RandomNumberGenerator.new()

const SR := 22050
static var _pop_cache: AudioStreamWAV


## Called by PropScatter right after set_script(): picks the fruit,
## seeds the RNG deterministically, builds the geometry. (Not done in
## _ready because the bush's measured world height arrives from
## placement.)
func setup(height: float, rng_seed: int, p_kind: String) -> void:
	kind = p_kind
	_rng.seed = rng_seed
	_build(height)


func _ready() -> void:
	add_to_group("forage")


func _build(height: float) -> void:
	if kind == "berries":
		_build_berries(height)
	else:
		_build_herbs(height)


## Berry clusters: 4-6 dark-red spheres clumped on the bush's upper
## half, facing out from the centre.
func _build_berries(height: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.10, 0.14)
	mat.roughness = 0.35
	mat.emission_enabled = true
	mat.emission = Color(0.35, 0.02, 0.05)
	mat.emission_energy_multiplier = 0.35
	for i in _rng.randi_range(4, 6):
		var ang := TAU * float(i) / 5.0 + _rng.randf_range(-0.4, 0.4)
		var spot := Node3D.new()
		spot.position = Vector3(cos(ang) * 0.30,
				height * _rng.randf_range(0.42, 0.72),
				sin(ang) * 0.30)
		add_child(spot)
		for k in _rng.randi_range(2, 3):
			var berry := MeshInstance3D.new()
			var bm := SphereMesh.new()
			bm.radius = _rng.randf_range(0.05, 0.075)
			bm.height = bm.radius * 2.0
			bm.radial_segments = 8
			bm.rings = 5
			berry.mesh = bm
			berry.material_override = mat
			berry.position = Vector3(_rng.randf_range(-0.06, 0.06),
					_rng.randf_range(-0.05, 0.05),
					_rng.randf_range(-0.06, 0.06))
			spot.add_child(berry)
		_spots.append(spot)


## Herb sprigs: 3-5 slim green stalks with leaf blades poking up.
func _build_herbs(height: float) -> void:
	var stalk_mat := StandardMaterial3D.new()
	stalk_mat.albedo_color = Color(0.35, 0.55, 0.22)
	var leaf_mat := StandardMaterial3D.new()
	leaf_mat.albedo_color = Color(0.55, 0.72, 0.3)
	for i in _rng.randi_range(3, 5):
		var ang := TAU * float(i) / 4.0 + _rng.randf_range(-0.5, 0.5)
		var spot := Node3D.new()
		spot.position = Vector3(cos(ang) * 0.26,
				height * _rng.randf_range(0.35, 0.6),
				sin(ang) * 0.26)
		add_child(spot)
		for k in _rng.randi_range(2, 3):
			var stalk := MeshInstance3D.new()
			var sm := CylinderMesh.new()
			sm.top_radius = 0.008
			sm.bottom_radius = 0.012
			sm.height = _rng.randf_range(0.18, 0.3)
			stalk.mesh = sm
			stalk.material_override = stalk_mat
			stalk.position.y = sm.height * 0.5
			stalk.rotation.z = _rng.randf_range(-0.25, 0.25)
			spot.add_child(stalk)
			var blade := MeshInstance3D.new()
			var pm := PlaneMesh.new()
			pm.size = Vector2(0.05, 0.11)
			blade.mesh = pm
			blade.material_override = leaf_mat
			blade.position.y = sm.height
			blade.rotation.x = -TAU * 0.25
			blade.rotation.y = _rng.randf() * TAU
			spot.add_child(blade)
		_spots.append(spot)


## How many ripe spots remain (0 = fully harvested).
func ripe_count() -> int:
	if not ripe:
		return 0
	return _spots.size()


## Human name for the prompt and the pickup text.
func display_name() -> String:
	return "juiceberries" if kind == "berries" else "wild herbs"


## Food value of one harvest (the player's counter gains this).
func food_value() -> int:
	return _rng.randi_range(3, 6) if kind == "berries" \
			else _rng.randi_range(2, 4)


## Gather: hides the cluster, pops FX + sound, starts the regrow clock.
## Returns {type, name, food} or {} when already bare.
func harvest() -> Dictionary:
	if not ripe:
		return {}
	ripe = false
	for s in _spots:
		s.visible = false
	_regrow = regrow_time * _rng.randf_range(0.85, 1.2)
	_pop_fx()
	return {"type": kind, "name": display_name(),
			"food": food_value()}


## Regrow + idle pulse.
func _process(delta: float) -> void:
	_t += delta
	if not ripe:
		_regrow -= delta
		if _regrow <= 0.0:
			ripe = true
			for s in _spots:
				s.visible = true
				s.scale = Vector3.ONE * 0.2
				var tw := s.create_tween()
				tw.tween_property(s, "scale", Vector3.ONE, 0.5) \
						.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	else:
		# Slow ripe shimmer so bushes with fruit read at a glance.
		var pulse := 1.0 + sin(_t * 1.8) * ripe_pulse
		for s in _spots:
			s.scale = Vector3.ONE * pulse


## Harvest FX: pluck sound + floating pickup text at the bush.
func _pop_fx() -> void:
	var host := get_tree().current_scene
	if host == null:
		return
	var voice := AudioStreamPlayer3D.new()
	voice.stream = _pop_stream()
	voice.pitch_scale = _rng.randf_range(0.9, 1.2)
	voice.volume_db = -6.0
	voice.max_distance = 30.0
	host.add_child(voice)
	voice.global_position = global_position + Vector3(0, 0.6, 0)
	voice.play()
	host.get_tree().create_timer(1.0).timeout.connect(voice.queue_free)
	var lbl := Label3D.new()
	lbl.text = "+ %s" % display_name()
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.pixel_size = 0.004
	lbl.font_size = 40
	lbl.outline_size = 8
	lbl.modulate = Color(1.0, 0.75, 0.35) if kind == "berries" \
			else Color(0.6, 0.9, 0.4)
	host.add_child(lbl)
	lbl.global_position = global_position + Vector3(0, 1.1, 0)
	var tw := lbl.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lbl, "position:y",
			lbl.position.y + 1.2, 1.2)
	tw.tween_property(lbl, "modulate:a", 0.0, 1.2)
	tw.chain().tween_callback(lbl.queue_free)


## Pluck: a quick sine plick with a soft noise tick.
static func _pop_stream() -> AudioStreamWAV:
	if _pop_cache != null:
		return _pop_cache
	var samples := PackedFloat32Array()
	samples.resize(int(0.12 * SR))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x9057
	for i in samples.size():
		var t := float(i) / SR
		var v := sin(TAU * (620.0 + 500.0 * t) * t) * exp(-t * 38.0) * 0.6
		v += rng.randf_range(-1.0, 1.0) * exp(-t * 90.0) * 0.25
		samples[i] = clampf(v, -1.0, 1.0)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	wav.data = bytes
	_pop_cache = wav
	return wav
