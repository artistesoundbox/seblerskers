class_name FootstepAudio
extends Node3D
## 3D footstep and landing sounds driven by FootstepFX's animation
## footfall signals — so audio plays in rhythm with the stride-matched
## walk/run cycle exactly where the dust puffs spawn.
##
## If no streams are assigned, short footstep crunches and a low landing
## thud are synthesized procedurally at startup (no assets needed); drop
## real AudioStreams into the export slots to replace them.

## Optional step sound variations (picked randomly per step).
@export var step_streams: Array[AudioStream] = []
## Optional landing sound override.
@export var land_stream: AudioStream

## Base loudness of a normal step.
@export var step_db := -19.0
## Volume offset applied while crouching (quieter, tighter scuff).
@export var crouch_volume_offset_db := -8.0
## Extra loudness for sprint stomps / hard plant steps.
@export var sprint_extra_db := 2.0
## Base loudness of a landing (harder falls play louder).
@export var land_db := -14.0
## Random pitch variation per step, +/- this fraction: breaks up the
## machine-gun repetition of a single looped sample.
@export var pitch_variance := 0.12
## Voice pool size; voices are reused round-robin so fast stride-matched
## steps and landings can overlap without cutting each other off.
@export var voice_count := 6
## Maximum distance (m) at which footsteps remain audible.
@export var max_distance := 30.0

const SYNTH_SAMPLE_RATE := 22050

## Incremented on every voice play; useful for tests/debugging.
var play_count := 0

var _voices: Array[AudioStreamPlayer3D] = []
var _next_voice := 0
var _step_pool: Array[AudioStream] = []
var _land: AudioStream

@onready var controller: MovementController = get_parent()
@onready var fx: FootstepFX = get_node_or_null(^"../FootstepFX")


func _ready() -> void:
	for i in voice_count:
		var p := AudioStreamPlayer3D.new()
		p.name = "Voice%d" % i
		# World-fixed: the voice stays where the foot hit the ground
		# instead of being dragged along by the moving player.
		p.top_level = true
		p.max_distance = max_distance
		add_child(p)
		_voices.append(p)
	_build_streams()
	if fx == null:
		push_warning("FootstepAudio: no FootstepFX sibling; audio disabled.")
		set_physics_process(false)
		return
	fx.stepped.connect(_on_stepped)
	fx.landed.connect(_on_landed)


## Fills the pools: uses the exported overrides when present, otherwise
## synthesizes three step variations and a landing thud.
func _build_streams() -> void:
	if step_streams.is_empty():
		for i in 3:
			_step_pool.append(_make_step_stream())
	else:
		_step_pool.assign(step_streams)
	_land = land_stream if land_stream != null else _make_land_stream()


func _on_stepped(pos: Vector3, strength: float, crouched: bool) -> void:
	var db := step_db
	var pitch := 1.0 + randf_range(-pitch_variance, pitch_variance)
	if crouched:
		db += crouch_volume_offset_db
		pitch *= 1.08  # lighter, quicker scuff
	elif strength >= 0.85:
		db += sprint_extra_db  # hard plant = sprint stomp
		pitch *= 0.96
	_play(_step_pool.pick_random(), pos, db, pitch)


func _on_landed(pos: Vector3, impact: float) -> void:
	# impact runs 0.3 (soft) .. 1.0 (hard 12 m/s fall).
	var db := land_db + 4.0 * (impact - 0.5)
	var pitch := 1.0 - 0.08 * (1.0 - impact) + randf_range(
			-pitch_variance, pitch_variance)
	_play(_land, pos, db, pitch)


func _play(stream: AudioStream, pos: Vector3, db: float, pitch: float) -> void:
	if stream == null or _voices.is_empty():
		return
	var p := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	play_count += 1
	p.global_position = pos + Vector3.UP * 0.1
	p.stream = stream
	p.volume_db = db
	p.pitch_scale = maxf(0.1, pitch)
	p.play()


## --- Procedural sound synthesis (used when no streams are assigned) ----


## A ~90 ms footstep crunch: low-passed noise burst with a soft low thump,
## exponentially decayed. Three variations are generated with different
## filter and thump parameters so steps alternate naturally.
func _make_step_stream() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var length := int(0.09 * SYNTH_SAMPLE_RATE)
	var data := PackedFloat32Array()
	data.resize(length)
	var lp := 0.0
	var crunch := rng.randf_range(0.35, 0.5)
	var thump_hz := rng.randf_range(85.0, 110.0)
	var thump_mix := rng.randf_range(0.45, 0.7)
	for i in length:
		var t := float(i) / SYNTH_SAMPLE_RATE
		var decay := exp(-t * 55.0)
		lp = lerpf(lp, rng.randf_range(-1.0, 1.0), crunch)
		var thump := sin(TAU * thump_hz * t) * thump_mix \
				* exp(-t * 90.0)
		data[i] = clampf((lp * 1.4 + thump) * decay, -1.0, 1.0) * 0.8
	return _to_stream(data)


## A ~350 ms landing thud: deep pitch-swept sine body plus a dirt-scatter
## noise tail, much heavier than a step.
func _make_land_stream() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var length := int(0.35 * SYNTH_SAMPLE_RATE)
	var data := PackedFloat32Array()
	data.resize(length)
	var lp := 0.0
	for i in length:
		var t := float(i) / SYNTH_SAMPLE_RATE
		var decay := exp(-t * 16.0)
		# Falling pitch: the "weight settling" thud.
		var f := 95.0 - 45.0 * clampf(t / 0.2, 0.0, 1.0)
		var thump := sin(TAU * f * t) * 0.95 * exp(-t * 22.0)
		lp = lerpf(lp, rng.randf_range(-1.0, 1.0), 0.22)
		data[i] = clampf((thump + lp * 1.1 * decay) , -1.0, 1.0) * 0.9
	return _to_stream(data)


## Packs float samples into a 16-bit mono AudioStreamWAV.
func _to_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2,
				int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SYNTH_SAMPLE_RATE
	wav.stereo = false
	wav.data = bytes
	return wav
