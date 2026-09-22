extends Node3D
## The evening chorus: crickets chirping from the meadow vegetation
## and a few evening birds in the groves. PropScatter hands in the
## world-space voice spots; every voice is a cheap looping 3D player
## (procedural chirp streams, one shared per kind). DayNight drives
## the loudness through `dusk_crickets()` — the chorus fades in as the
## sun drops through the dusk hours and fades back out in deep night.
## Noon: completely silent, zero active voices.

## Crickets chirping per spot (kept modest: 3D voices are cheap but
## not free, and 20 spots already fills a meadow with song).
const CRICKET_VOICES_PER := 2
## Bird-voice ceiling (each spot gets one player).
const BIRD_VOICE_CAP := 8
## How often a cricket re-triggers its chirp phrase (s, random band).
const CRICKET_PERIOD_MIN := 0.35
const CRICKET_PERIOD_MAX := 1.4
## How often an evening bird calls (s, random band).
const BIRD_PERIOD_MIN := 2.5
const BIRD_PERIOD_MAX := 7.0

const SR := 22050

## Procedural chirp streams, shared by every voice of that kind.
static var _cricket_cache: AudioStreamWAV
static var _evening_bird_cache: AudioStreamWAV

var _crickets: Array = []
var _birds: Array = []
## From DayNight (found through the tree): chorus loudness 0..1.
var _ctrl: DayNight = null
var _level := 0.0
var _rng := RandomNumberGenerator.new()
var _t := 0.0


func setup(crickets: Array[Vector3], birds: Array[Vector3],
		rng_seed: int) -> void:
	_rng.seed = rng_seed
	for p in crickets:
		for v in CRICKET_VOICES_PER:
			_add_voice(_crickets, p + Vector3(
					_rng.randf_range(-2.0, 2.0), 0.0,
					_rng.randf_range(-2.0, 2.0)),
					_cricket_stream(),
					_rng.randf_range(0.9, 1.25),
					_rng.randf_range(CRICKET_PERIOD_MIN, CRICKET_PERIOD_MAX),
					-8.0)
	for p in birds:
		if _birds.size() >= BIRD_VOICE_CAP:
			break
		_add_voice(_birds, p, _evening_bird_stream(),
				_rng.randf_range(0.85, 1.2),
				_rng.randf_range(BIRD_PERIOD_MIN, BIRD_PERIOD_MAX),
				-7.0)


func _add_voice(pool: Array, at: Vector3, stream: AudioStream,
		pitch: float, period: float, db: float) -> void:
	var pl := AudioStreamPlayer3D.new()
	pl.stream = stream
	pl.pitch_scale = pitch
	pl.volume_db = db
	pl.max_distance = 45.0
	pl.position = at
	pl.set_meta("period", period)
	pl.set_meta("next", _rng.randf_range(0.0, period))
	pl.set_meta("base_db", db)
	pl.set_meta("base_pitch", pitch)
	add_child(pl)
	pool.append(pl)


func _ready() -> void:
	# The clock lives under L_Main/Lighting; find it through the tree.
	for n in get_tree().get_nodes_in_group("daynight"):
		_ctrl = n as DayNight
		break
	if _ctrl == null:
		# Fallback: walk up from props_root.
		var n := self
		while n != null and _ctrl == null:
			for c in n.get_children():
				if c is DayNight:
					_ctrl = c
			n = n.get_parent()
	if _ctrl == null:
		push_warning("DuskAmbience: no DayNight found; staying silent")


func _process(delta: float) -> void:
	_t += delta
	var want := 0.0
	if _ctrl != null:
		want = _ctrl.dusk_crickets()
	# Smooth toward the target so the fade never steps.
	_level = move_toward(_level, want, delta * 0.7)
	if _level <= 0.001:
		for pool in [_crickets, _birds]:
			for v in pool:
				if (v as AudioStreamPlayer3D).playing:
					(v as AudioStreamPlayer3D).stop()
		return
	for pool in [_crickets, _birds]:
		for v in pool:
			var pl := v as AudioStreamPlayer3D
			var period: float = pl.get_meta("period")
			var next: float = pl.get_meta("next") - delta
			if next <= 0.0 and not pl.playing:
				pl.volume_db = (pl.get_meta("base_db") as float) \
						+ linear_to_db(maxf(_level, 0.01))
				# Per-phrase pitch jitter, always around the voice's own
				# base (never drifts session-long).
				pl.pitch_scale = (pl.get_meta("base_pitch") as float) \
						+ _rng.randf_range(-0.03, 0.03)
				pl.play()
				next = _rng.randf_range(period * 0.6, period * 1.6)
			pl.set_meta("next", next)


## One cricket chirp: a burst of 4 rapid pulses (~430 Hz carrier,
## amplitude-modulated by a 95 Hz flutter — the stridulating wing),
## quiet tail. Loopable but voiced in short phrases.
static func _cricket_stream() -> AudioStreamWAV:
	if _cricket_cache != null:
		return _cricket_cache
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260916
	var length := int(0.55 * SR)
	var data := PackedFloat32Array()
	data.resize(length)
	var phase := 0.0
	for i in length:
		var u := float(i) / float(SR)
		# 4 pulses in the first 0.32 s, then silence (the phrase gap
		# lives between triggers, not inside the sample).
		var env := 0.0
		if u < 0.32:
			var pu := fposmod(u, 0.08)
			var pi := int(u / 0.08)
			var pulse_env := sin(PI * pu / 0.08)
			env = pow(pulse_env, 1.6) * (1.0 - float(pi) * 0.18)
		phase += TAU * 430.0 / float(SR)
		var carrier := sin(phase)
		var flutter := 0.5 + 0.5 * sin(TAU * 95.0 * u)
		data[i] = carrier * env * flutter * 0.6
	_cricket_cache = _to_stream(data)
	return _cricket_cache


## One evening-bird call: a soft two-note descending whistle
## (1600 -> 1150 Hz), airy with a little breath noise.
static func _evening_bird_stream() -> AudioStreamWAV:
	if _evening_bird_cache != null:
		return _evening_bird_cache
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260917
	var length := int(0.7 * SR)
	var data := PackedFloat32Array()
	data.resize(length)
	var phase := 0.0
	for i in length:
		var u := float(i) / float(SR)
		var freq := 1600.0
		var env := 0.0
		if u < 0.22:
			# First note: quick swell, gentle fall.
			freq = 1600.0 - 180.0 * (u / 0.22)
			env = sin(PI * u / 0.22)
		elif u >= 0.34 and u < 0.62:
			# Second note: lower, longer.
			var nu := (u - 0.34) / 0.28
			freq = 1150.0 - 240.0 * nu
			env = sin(PI * nu)
		phase += TAU * freq / float(SR)
		var v := sin(phase) * env * 0.42
		# A touch of breath: filtered noise behind the tone.
		v += rng.randf_range(-1.0, 1.0) * env * 0.03
		data[i] = v
	_evening_bird_cache = _to_stream(data)
	return _evening_bird_cache


static func _to_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2,
				int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	wav.data = bytes
	return wav
