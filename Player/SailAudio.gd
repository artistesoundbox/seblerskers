class_name SailAudio
extends Node3D
## The flagship's water voice: a hull-cutting wash loop that swells
## with way on (level AND pitch follow speed, so a sprint surges) and
## oar-dip plinks fired on the PLAYER's real stroke events — the same
## events that drive the crew's oars and the splash bursts, so sound,
## foam and animation all beat together.
##
## All procedural (no assets): the wash is a seamless 2 s loop of
## filtered noise layers with LFO periods that divide the loop and an
## overlap-add crossfade at the seam; the plink is a pitch-dropping
## droplet ping over a small noise splash, in three variations so
## consecutive dips don't sound cloned.
##
## Deliberately self-contained (no Sailboat class reference — it
## preloads nothing back, but consistency with Sailboat/Chest style).

## Wash loop level at rest and at full cruise (dB). Live-tuned:
## the full mix read hot in playtesting — pulled down 6 dB.
const WASH_DB_IDLE := -52.0
const WASH_DB_CRUISE := -14.0
## Pitch scale range of the wash across the speed band.
const WASH_PITCH_LO := 0.85
const WASH_PITCH_HI := 1.35
## Cruise speed (m/s) the wash curves are tuned against (matches the
## boat's MAX_SPEED; boosting past it simply pushes the curve over).
const CRUISE_SPEED := 5.5

## The wash loop (3D: it lives on the hull, Doppler on for swoop-bys).
var _wash: AudioStreamPlayer3D
## Round-robin plink players (2, so overlapping strokes never cut).
var _plinks: Array[AudioStreamPlayer3D] = []
var _plink_active := 0
## Headless-verifiable counter (one per stroke plink fired).
var plink_count := 0
## Volume (dB) of the most recent plink — headless-verifiable loudness.
var last_plink_db := -80.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 404
	_wash = AudioStreamPlayer3D.new()
	_wash.stream = _make_wash_stream()
	_wash.volume_db = WASH_DB_IDLE
	_wash.unit_size = 18.0
	_wash.max_db = 0.0
	# Doppler: sailing past the camera pitch-bends the wash, exactly
	# like the flight wind players.
	_wash.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_IDLE_STEP
	add_child(_wash)
	_wash.play()
	var plink_streams: Array = [
		_make_plink_stream(0.0), _make_plink_stream(0.33),
		_make_plink_stream(0.66)]
	for i in 2:
		var p := AudioStreamPlayer3D.new()
		p.stream = plink_streams[i % plink_streams.size()]
		p.volume_db = -14.0
		p.unit_size = 14.0
		p.max_db = 3.0
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_IDLE_STEP
		add_child(p)
		_plinks.append(p)


## Called by the boat every physics frame with the hull's speed.
## Drives the wash level and pitch; silence at rest, surge at boost.
func update(speed: float) -> void:
	if _wash == null:
		return
	var ratio := clampf(speed / CRUISE_SPEED, 0.0, 1.6)
	if ratio < 0.03:
		_wash.volume_db = WASH_DB_IDLE  # parked: the dock creak owns it
	else:
		# Perceptual curve: quiet until there is way on, then a strong
		# rise (power of 0.6 keeps slow rowing subtle).
		var t := pow(ratio, 0.6)
		_wash.volume_db = lerpf(WASH_DB_IDLE, WASH_DB_CRUISE, t)
	# Faster hull = brighter, higher rush.
	_wash.pitch_scale = lerpf(WASH_PITCH_LO, WASH_PITCH_HI,
			clampf(ratio, 0.0, 1.0))


## One oar-dip plink (0..1 strength = rowing effort). Fired from the
## boat's _oar_stroke (the same event as the crew sweep + foam burst).
func plink(strength: float) -> void:
	plink_count += 1
	_plink_active = (_plink_active + 1) % _plinks.size()
	var p := _plinks[_plink_active]
	# Rotate through all three variation streams round-robin too.
	var idx := plink_count % 3
	p.stream = _plink_variation(idx)
	var vdb := -26.0 + 9.0 * clampf(strength, 0.0, 1.0)
	p.volume_db = vdb
	last_plink_db = vdb
	p.pitch_scale = 0.92 + 0.22 * _rng.randf()
	p.play()


## Accessor for tests: the live wash level in dB.
func wash_db() -> float:
	return _wash.volume_db if _wash != null else -80.0


func wash_pitch() -> float:
	return _wash.pitch_scale if _wash != null else 0.0


## --- synthesis -------------------------------------------------------------

## A 2-second seamless wash loop: deep hull-lap rumble + brighter
## rushing-hiss, under slow swell LFOs whose periods divide the loop
## length, crossfaded at the seam (FlightAudio's wind recipe).
func _make_wash_stream() -> AudioStreamWAV:
	var rate := 22050
	var length := int(2.0 * rate)
	var fade := int(0.1 * rate)
	var raw := PackedFloat32Array()
	raw.resize(length + fade)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var lp_lap := 0.0
	var lp_hiss := 0.0
	for i in raw.size():
		var n := rng.randf_range(-1.0, 1.0)
		# Deep lap layer (hull displacement) + rushing hiss layer.
		lp_lap = lerpf(lp_lap, n, 0.015)
		lp_hiss = lerpf(lp_hiss, n, 0.11)
		var t := float(i) / rate
		# Swell periods 1.0 s and 2.0 s — both divide the 2 s loop.
		var swell := 0.78 + 0.14 * sin(TAU * t + 0.7) \
				+ 0.08 * sin(TAU * 0.5 * t + 2.1)
		raw[i] = clampf((lp_lap * 3.1 + lp_hiss * 1.05) * swell, -1.0, 1.0)
	var data := PackedFloat32Array()
	data.resize(length)
	for i in length:
		if i < fade:
			var w := float(i) / float(fade)
			data[i] = raw[i] * w + raw[length + i] * (1.0 - w)
		else:
			data[i] = raw[i]
	var wav := _to_stream(data, rate)
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = length
	return wav


## A ~240 ms oar plink: a pitch-dropping droplet ping (the "plink")
## over a tiny filtered-noise splash. `shift` detunes each variation.
func _make_plink_stream(shift: float) -> AudioStreamWAV:
	return _plink_body(shift)


func _plink_variation(idx: int) -> AudioStreamWAV:
	# Built lazily per index and cached by pitch offset table.
	var shifts := [0.0, 0.33, 0.66]
	return _plink_body(shifts[idx % shifts.size()])


func _plink_body(shift: float) -> AudioStreamWAV:
	var rate := 22050
	var length := int(0.24 * rate)
	var data := PackedFloat32Array()
	data.resize(length)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(1000.0 + shift * 100.0)
	var f0 := 2100.0 * (1.0 + shift)
	var phase := 0.0
	var lp := 0.0
	for i in length:
		var t := float(i) / rate
		# Droplet: frequency slides DOWN (f0 -> 55% over the ping),
		# sharp attack, ~70 ms exponential decay.
		var f := f0 * (1.0 - 0.45 * minf(t / 0.12, 1.0))
		phase += TAU * f / rate
		var ping_env := exp(-38.0 * t)
		var ping := sin(phase) * ping_env * 0.5
		# Splash: small low-passed noise burst under the ping.
		var n := rng.randf_range(-1.0, 1.0)
		lp = lerpf(lp, n, 0.22)
		var splash_env := exp(-22.0 * maxf(t - 0.02, 0.0)) \
				* minf(t / 0.015, 1.0)
		var splash := lp * 2.2 * splash_env * 0.35
		data[i] = clampf(ping + splash, -1.0, 1.0)
	return _to_stream(data, rate)


func _to_stream(data: PackedFloat32Array, rate: int) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(data.size() * 2)
	for i in data.size():
		bytes.encode_s16(i * 2, int(clampf(data[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	return wav
