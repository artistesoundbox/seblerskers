extends Node3D
## Tall-grass rustle: looped procedural rustle voices placed among the
## reeds, meadow grass and grove undergrowth. Every voice loops a
## filtered-noise "leaves" bed whose loudness and brightness track the
## island's wind — calm = a faint hush, a swoop-gust = the grass roars.
## Reeds and dry meadow tufts sound brighter; grove undergrowth is
## darker and softer. Voices are cheap loops (no per-frame synthesis);
## only the volume/pitch are driven every frame.

## Wind field this system listens to (injected by PropScatter).
var wind_ref: WindSway
## Base loudness of a rustle voice at calm breeze (dB).
@export var calm_db := -34.0
## Loudness at full gust (dB).
@export var gust_db := -13.0
## Pitch rise with gust (semitone-ish, additive on playback pitch).
@export var gust_pitch := 0.35
## Update throttling: voices outside this range park at minimum.
@export var listen_radius := 75.0
## Deterministic voicing.
@export var rustle_seed := 0

const SR := 22050

var _voices: Array[Dictionary] = []
var _wind: WindSway
var _rng := RandomNumberGenerator.new()


## PropScatter hands in the rustle spots: {p: Vector3, bright: bool}.
func setup(spots: Array) -> void:
	_spots = spots

var _spots: Array = []


func _ready() -> void:
	_rng.seed = rustle_seed
	_wind = wind_ref
	var reed_stream := _rustle_stream(true)
	var soft_stream := _rustle_stream(false)
	for s in _spots:
		var at: Vector3 = s.p
		var bright: bool = s.bright
		var v := AudioStreamPlayer3D.new()
		v.stream = reed_stream if bright else soft_stream
		v.volume_db = calm_db
		v.pitch_scale = _rng.randf_range(0.92, 1.08)
		v.max_distance = 45.0
		v.unit_size = 6.0
		v.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		v.autoplay = true
		add_child(v)
		v.position = at
		_voices.append({"v": v, "pos": Vector2(at.x, at.z),
				"bright": bright})


func _process(_delta: float) -> void:
	if _wind == null or _voices.is_empty():
		return
	var gust: float = clampf(_wind.gust_level(), 0.0, 1.0)
	# Local gust boost: if the PLAYER is the gust source, voices near
	# the player get the full effect; far ones only the breeze share.
	var pxz := Vector2.INF
	var players := get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		var mc := players[0] as MovementController
		if mc != null:
			pxz = Vector2(mc.global_position.x, mc.global_position.z)
	# The wind field's gust is already locality-shaped for trees; the
	# audio mirrors that with a soft player-distance weight.
	var target_db: float = lerpf(calm_db, gust_db, gust)
	var target_pitch := 1.0 + gust * gust_pitch
	for rec in _voices:
		var v := rec.v as AudioStreamPlayer3D
		var w := 1.0
		if pxz != Vector2.INF and gust > 0.05:
			var d: float = (pxz - (rec.pos as Vector2)).length()
			# Full locality: a swoop on the far side of the island does
			# not roar through THIS meadow (far voices hold the calm
			# baseline; the breeze's own breathing still modulates it).
			w = clampf(1.0 - d / listen_radius, 0.0, 1.0)
		v.volume_db = lerpf(calm_db, target_db, w)
		v.pitch_scale = target_pitch * (1.12 if rec.bright else 0.94)


## One looped rustle bed: band-passed noise with a slow breathing
## undulation. The loop is made click-free by fading BOTH ends to
## silence over ~0.2 s — the bed breathes with a lull every cycle,
## which reads as wind anyway.
static func _rustle_stream(bright: bool) -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	var dur := 3.0
	samples.resize(int(dur * SR))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x72457 if bright else 0x5147
	var lp := 0.0
	var bp := 0.0
	var hp := 0.0
	# Cutoff-ish coefficients: bright reeds let more highs through.
	var k := 0.22 if bright else 0.10
	var fade := 0.2 * SR
	for i in samples.size():
		var t := float(i) / SR
		var n := rng.randf_range(-1.0, 1.0)
		# Two-pole low-pass + high-pass = band-passed leaf noise.
		lp += k * (n - lp)
		hp = lp - bp
		bp += k * 0.5 * (lp - bp)
		var v := hp * (2.4 if bright else 1.6)
		# Slow undulation (wind breathing through the tuft).
		v *= 0.75 + 0.25 * sin(TAU * 0.7 * t + 1.3)
		# Matched end fades: the loop wraps through silence, so the
		# seam can never click.
		var env := 1.0
		if i < fade:
			env = 0.5 - 0.5 * cos(PI * float(i) / fade)
		elif i >= samples.size() - fade:
			var j := float(samples.size() - 1 - i) / fade
			env = 0.5 - 0.5 * cos(PI * j)
		samples[i] = clampf(v * env * 0.8, -1.0, 1.0)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = samples.size()
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	wav.data = bytes
	return wav
