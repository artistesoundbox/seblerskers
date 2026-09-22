class_name FlightAudio
extends Node3D
## Bird-flight sound: a continuous procedural wind bed that swells with
## airspeed (climbs roar, glides hiss, dives scream) and wing-beat sounds
## synced to the fly clip's actual playback phase — the whoosh swells so
## its peak lands mid-downstroke at any flap tempo, and a faint
## double-thump marks the upstroke. Glide and dive clips beat silent.
##
## Everything routes through a master "FlightAir" bus carrying a
## high-pass and a low-pass filter: gliding strips the low rumble so the
## wind reads crisp and thin, a dive slams a slipstream low-pass over the
## whole flight mix, and pulling out sweeps the muffle open with an
## ears-pop pressure release (a non-spatial one-shot — it happens in
## your ears, not in the world).
##
## No audio assets needed: the wind texture, whooshes, thump and pop are
## synthesized at startup. Drop real AudioStreams into the export slots
## to replace them with recorded sounds.

## Optional wind loop override (should loop seamlessly).
@export var wind_stream: AudioStream
## Optional flap whoosh variations (picked randomly per beat).
@export var flap_streams: Array[AudioStream] = []

## Airspeed (m/s) where the wind starts rising out of silence.
@export var wind_min_speed := 3.0
## Airspeed (m/s) where the wind reaches full loudness and pitch.
@export var wind_full_speed := 30.0
## Wind loudness at full airspeed.
@export var wind_db := -4.0
## Wind level while gliding at the reference sink speed — steep glides
## rush at this floor, shallow floats stay near glide_wind_min_level.
## The floor scales with sink speed between the two.
@export_range(0.0, 1.0) var glide_wind_level := 0.45
## Wind floor for a shallow float (near-zero sink) while gliding.
@export_range(0.0, 1.0) var glide_wind_min_level := 0.25
## Sink speed (downward m/s) at which the glide floor reaches
## glide_wind_level.
@export var glide_wind_sink_speed := 14.0
## How fast the wind volume eases towards its target (1/s).
@export var wind_fade_rate := 4.0
## Wind playback pitch at idle vs full airspeed (dives scream up).
@export var wind_pitch_min := 0.85
@export var wind_pitch_max := 1.4
## Base loudness of one wing-beat whoosh.
@export var flap_base_db := -14.0
## Extra whoosh loudness at high airspeed (harder beats carry more air).
@export var flap_speed_db_gain := 6.0
## Random pitch variation per whoosh.
@export var flap_pitch_variance := 0.08
## Whoosh voice pool size (overlapping beats don't cut each other off).
@export var flap_voice_count := 3
## Base loudness of the faint upstroke double-thump.
@export var thump_base_db := -24.0
## Beat-loop fraction where the double-thump fires (mid-upstroke rise;
## the downstroke sweep runs 0.25..0.75 of the loop).
@export var thump_upstroke_frac := 0.9
## Random pitch variation per double-thump.
@export var thump_pitch_variance := 0.06
## Double-thump voice pool size.
@export var thump_voice_count := 2
## Optional double-thump override (single variation).
@export var thump_stream: AudioStream
## --- Wing-flare landing burst -----------------------------------------
## Whooshes in the landing flare burst — the rapid soft wing beats as
## the wings spread to brake for touchdown. 0 disables the burst.
@export var flare_whooshes := 6
## Loudness offset of flare whooshes vs. normal beat whooshes (dB):
## the flare reads as soft air brakes, not full wing beats, whatever
## the fall speed.
@export var flare_db_offset := -7.0
## Total span of the burst (s); the whooshes quicken within it.
@export var flare_duration := 0.55
## Minimum time between flare bursts (s).
@export var flare_cooldown := 1.0
## --- Master air bus (dive muffle / glide crispness / ears pop) ---------
## Low-pass cutoff (Hz) the flight mix muffles to during a dive.
@export var dive_muffle_cutoff := 750.0
## High-pass cutoff (Hz) that strips the low rumble while gliding, so
## the wind reads crisp and thin.
@export var glide_highpass := 320.0
## How fast the muffle closes over the mix when a dive starts (1/s).
@export var muffle_speed := 10.0
## How fast the muffle sweeps back open on pull-out (1/s) — the ears-pop.
@export var pop_speed := 5.0
## Loudness of the ears-pop pressure release.
@export var pop_db := -8.0
## Optional ears-pop override (non-spatial one-shot).
@export var pop_stream: AudioStream
## Maximum distance (m) at which the flight sounds remain audible.
@export var max_distance := 45.0
## Engine Doppler tracking on all flight voices (wind + whooshes).
@export var doppler_enabled := true
## How fast the swoop bend eases back to neutral (1/s).
@export var swoop_bend_decay := 2.5
## Sharpest swoop bend, in fractions of an octave (0.25 = pitch x1.19
## into and x0.84 out of the swoop, like a flyby pass).
@export var swoop_bend_octaves := 0.25
## Camera-to-bird closing speed (m/s) for the full swoop bend.
@export var swoop_ref_speed := 12.0
## Closing speed above which a swoop registers (m/s).
@export var swoop_onset_speed := 1.4

const SYNTH_SAMPLE_RATE := 22050
## Wind player node name (tests read its state directly).
const WIND_NODE := "Wind"
## Name of the master flight-air bus all flight voices route through.
const AIR_BUS := "FlightAir"
## Effect slots on the air bus (order they are added in _setup_air_bus).
const EFFECT_HP := 0
const EFFECT_LP := 1
## Low-pass considered "open" (transparent) at this cutoff.
const OPEN_CUTOFF := 20000.0
## High-pass considered transparent at this cutoff.
const OPEN_HIGHPASS := 20.0

## Smoothed wind level 0..1 (follows the speed mapping); useful for tests.
var wind_level := 0.0
## Incremented on every flap whoosh; useful for tests/debugging.
var play_count := 0
## Incremented on every upstroke double-thump; useful for tests/debugging.
var thump_count := 0
## Volume of the most recent whoosh / thump (debugging/tests).
var last_whoosh_db := 0.0
var last_thump_db := 0.0
## Live air-bus filter state (debugging/tests): current low-pass and
## high-pass cutoffs in Hz, and how many ears-pops have fired.
var air_cutoff := OPEN_CUTOFF
var air_highpass := OPEN_HIGHPASS
var pop_count := 0
## Current swoop-bend strength 0..1 and its direction (+1 = the camera
## is closing on the bird, pitch bends up; -1 = receding, bends down).
## Useful for tests/debugging.
var swoop_bend := 0.0
var swoop_bend_dir := 1.0

var _wind: AudioStreamPlayer3D
var _flap_voices: Array[AudioStreamPlayer3D] = []
var _next_voice := 0
var _flap_pool: Array[AudioStream] = []
var _thump_voices: Array[AudioStreamPlayer3D] = []
var _thump_next := 0
var _thump_pool: Array[AudioStream] = []
var _air_bus_idx := -1
var _lp_effect: AudioEffectLowPassFilter
var _hp_effect: AudioEffectHighPassFilter
var _pop_player: AudioStreamPlayer
## Diving state of the previous tick, for the pull-out edge detection.
var _was_diving := false
## Flight state of the previous tick, for the landing-flare edge.
var _was_flying := false
## Landing-flare burst state: elapsed time, whooshes left, the next
## trigger time inside the burst, and the inter-burst cooldown.
var _flare_t := 0.0
var _flare_left := 0
var _flare_next := 0.0
var _flare_cd := 0.0
## Number of flare bursts fired this session (diagnostics/tests).
var flare_count := 0
## Last beat-loop fraction read from the fly clip (phase-crossing
## detection); -1 = waiting for the first reading.
var _last_frac := -1.0
## Peak time of the whoosh envelope within its own sample (it swells to
## a peak ~54% into its 0.26 s), used to offset the trigger so the peak
## lands mid-downstroke at the current flap tempo.
const WHOOSH_PEAK_SEC := 0.14
## Camera and bird positions of the previous physics tick, for the
## swoop-bend velocity estimate (position-based, so teleports count).
var _cam_prev := Vector3.ZERO
var _bird_prev := Vector3.ZERO
var _pos_seen := false

@onready var controller: MovementController = get_parent()
@onready var model: PlayerModel = controller.get_node(controller.model_path)
@onready var head: PlayerHead = controller.get_node(controller.head_path)


func _ready() -> void:
	_setup_air_bus()
	_wind = AudioStreamPlayer3D.new()
	_wind.name = WIND_NODE
	# The wind follows the bird — it is the sound OF the bird.
	_wind.max_distance = max_distance
	_wind.bus = AIR_BUS
	_apply_doppler(_wind)
	add_child(_wind)
	for i in flap_voice_count:
		var p := AudioStreamPlayer3D.new()
		p.name = "Flap%d" % i
		p.max_distance = max_distance
		_apply_doppler(p)
		add_child(p)
		_flap_voices.append(p)
	for i in thump_voice_count:
		var t := AudioStreamPlayer3D.new()
		t.name = "Thump%d" % i
		t.max_distance = max_distance
		t.bus = AIR_BUS
		_apply_doppler(t)
		add_child(t)
		_thump_voices.append(t)
	_pop_player = AudioStreamPlayer.new()
	_pop_player.name = "EarPop"
	# The ears-pop is a body sensation: deliberately non-spatial, routed
	# through the air bus so it starts muffled and clarifies as it plays.
	_pop_player.bus = AIR_BUS
	_pop_player.volume_db = pop_db
	_pop_player.stream = pop_stream if pop_stream != null \
			else _make_pop_stream()
	add_child(_pop_player)
	for i in flap_voice_count:
		_flap_voices[i].bus = AIR_BUS
	_build_streams()


## Engine Doppler: the audio server compares the listener's (camera)
## velocity against this player's and shifts the pitch accordingly.
## Requires doppler/use_pitch_scale in the project settings to bend
## pitch rather than only volume.
func _apply_doppler(p: AudioStreamPlayer3D) -> void:
	p.doppler_tracking = (AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
			if doppler_enabled
			else AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED)


## Fills the pools: uses the exported overrides when present, otherwise
## synthesizes the looping wind texture and three whoosh variations.
func _build_streams() -> void:
	_wind.stream = wind_stream if wind_stream != null else _make_wind_stream()
	if flap_streams.is_empty():
		for i in 3:
			_flap_pool.append(_make_whoosh_stream())
	else:
		_flap_pool.assign(flap_streams)
	_thump_pool.append(thump_stream if thump_stream != null
			else _make_thump_stream())


func _physics_process(delta: float) -> void:
	_update_swoop_bend(delta)
	_update_wind(delta)
	_check_flap_beats()
	_update_air_bus(delta)
	_tick_flare(delta)
	_update_flight_edge()


## --- Master air bus ----------------------------------------------------


## Creates the FlightAir bus (shared if several players exist) with a
## high-pass and a low-pass filter, and grabs live references to both
## so _update_air_bus can animate their cutoffs every physics tick.
func _setup_air_bus() -> void:
	_air_bus_idx = AudioServer.get_bus_index(AIR_BUS)
	if _air_bus_idx == -1:
		AudioServer.add_bus()
		_air_bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_air_bus_idx, AIR_BUS)
		AudioServer.set_bus_send(_air_bus_idx, "Master")
		var hp := AudioEffectHighPassFilter.new()
		hp.cutoff_hz = air_highpass
		AudioServer.add_bus_effect(_air_bus_idx, hp)
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = air_cutoff
		AudioServer.add_bus_effect(_air_bus_idx, lp)
	_hp_effect = AudioServer.get_bus_effect(_air_bus_idx, EFFECT_HP) \
			as AudioEffectHighPassFilter
	_lp_effect = AudioServer.get_bus_effect(_air_bus_idx, EFFECT_LP) \
			as AudioEffectLowPassFilter


## Air-bus state machine: a dive closes the low-pass over the whole
## flight mix (the slipstream presses on your ears), gliding raises the
## high-pass to strip the rumble (crisp thin air), and the pull-out
## edge sweeps everything back open with an ears-pop.
func _update_air_bus(delta: float) -> void:
	var target_cut := OPEN_CUTOFF
	var target_hp := OPEN_HIGHPASS
	if controller.flying:
		if controller.diving:
			target_cut = dive_muffle_cutoff
		elif not controller.wing_flapping:
			target_hp = glide_highpass
	# Pull-out edge: the pressure releases with a pop — but only if the
	# muffle had actually engaged (no pop for one-frame dive glitches).
	if _was_diving and not controller.diving and air_cutoff < 8000.0:
		_play_ear_pop()
	_was_diving = controller.diving
	# Into the muffle strains fast; out of it releases like a pressure pop.
	var cut_rate := muffle_speed if target_cut < air_cutoff else pop_speed
	var hp_rate := muffle_speed if target_hp > air_highpass else pop_speed
	air_cutoff = lerpf(air_cutoff, target_cut,
			1.0 - exp(-cut_rate * delta))
	air_highpass = lerpf(air_highpass, target_hp,
			1.0 - exp(-hp_rate * delta))
	if _lp_effect != null:
		_lp_effect.cutoff_hz = air_cutoff
	if _hp_effect != null:
		_hp_effect.cutoff_hz = air_highpass


## Fires the ears-pop pressure release. Non-spatial on purpose: routed
## through the air bus, so it plays muffled and clarifies as the
## low-pass opens — the sensation of ears unplugging.
func _play_ear_pop() -> void:
	if _pop_player == null:
		return
	if _pop_player.playing:
		_pop_player.stop()
	_pop_player.play()
	pop_count += 1


## Wind bed: volume and pitch follow the flight speed mapping. On the
## ground (or hovering at a crawl) the wind stops entirely.
func _update_wind(delta: float) -> void:
	var speed := controller.velocity.length()
	var target := 0.0
	if controller.flying:
		target = clampf(
				(speed - wind_min_speed) / (wind_full_speed - wind_min_speed),
				0.0, 1.0)
		# Wings spread and not beating = gliding: the spread wings scoop
		# air, and the deeper the sink the harder they bite it — the
		# floor ramps from the shallow-float minimum up to the full
		# glide level at the reference sink speed.
		if not controller.diving and not controller.wing_flapping:
			var sink := maxf(0.0, -controller.velocity.y)
			var floor_level := lerpf(glide_wind_min_level, glide_wind_level,
					clampf(sink / glide_wind_sink_speed, 0.0, 1.0))
			target = maxf(target, floor_level)
	wind_level = lerpf(wind_level, target,
			1.0 - exp(-wind_fade_rate * delta))
	if wind_level < 0.002:
		if _wind.playing:
			_wind.stop()
		return
	# Loudness: silence floor -> full wind_db at wind_level 1, set before
	# (re)starting so a restart never pops at full volume.
	_wind.volume_db = lerpf(-60.0, wind_db, wind_level)
	if not _wind.playing:
		_wind.play()
	# Pitch rises with airspeed so dives audibly scream past the ears,
	# then the swoop bend adds the flyby shift on top.
	var base_pitch := lerpf(wind_pitch_min, wind_pitch_max,
			clampf((speed - wind_min_speed) / (wind_full_speed - wind_min_speed),
					0.0, 1.0))
	_wind.pitch_scale = clampf(base_pitch * bend_mult(), 0.05, 8.0)


## Swoop bend: engine Doppler can barely fire here because the camera
## rig is parented to the bird — their true relative velocity is ~zero
## in steady flight. But a real swoop whips the camera around anyway
## (follow-camera lag + shoulder boom), so the camera's own velocity
## becomes the flyby: its closing rate along the bird-camera axis bends
## the wind and whooshes up on approach and down on recession.
func _update_swoop_bend(delta: float) -> void:
	if head == null or head.cam == null or not controller.flying:
		swoop_bend *= exp(-swoop_bend_decay * delta)
		_pos_seen = false
		return
	var cam_pos: Vector3 = head.cam.global_position
	var bird_pos := controller.global_position
	if not _pos_seen:
		_cam_prev = cam_pos
		_bird_prev = bird_pos
		_pos_seen = true
		return
	# Position-based velocities: teleports and physics both count.
	var dt := maxf(delta, 0.0001)
	var cam_vel: Vector3 = (cam_pos - _cam_prev) / dt
	var bird_vel: Vector3 = (bird_pos - _bird_prev) / dt
	_cam_prev = cam_pos
	_bird_prev = bird_pos
	var rel := bird_pos - cam_pos
	var closing := 0.0
	if rel.length() > 0.1:
		# + = the camera (listener) is closing on the bird (source).
		closing = (cam_vel - bird_vel).dot(rel.normalized())
	var strength := clampf(absf(closing) / swoop_ref_speed, 0.0, 1.0)
	if strength > swoop_onset_speed / swoop_ref_speed:
		swoop_bend_dir = signf(closing)
		swoop_bend = maxf(swoop_bend * exp(-swoop_bend_decay * delta),
				strength)
	else:
		swoop_bend *= exp(-swoop_bend_decay * delta)


## Current swoop-bend pitch multiplier (1.0 = neutral).
func bend_mult() -> float:
	return pow(2.0, swoop_bend_dir * swoop_bend_octaves * swoop_bend)


## Beat-phase triggers, read from the fly clip's actual playback. One
## beat per loop, so loop fractions are wing-cycle fractions: the wing
## tops out at 0.25, sweeps down through 0.5, bottoms at 0.75 and rises
## through the wrap. The whoosh fires early enough that its swell PEAKS
## mid-downstroke at the current flap tempo; a faint double-thump marks
## the upstroke. Glide and dive never register here — the wings are
## spread or folded, not beating.
func _check_flap_beats() -> void:
	var on_beat_clip := controller.flying and not controller.diving \
			and model.anim.current_animation == model.ANIM_FLY
	if not on_beat_clip:
		_last_frac = -1.0
		return
	var flap: Animation = model.anim.get_animation(model.ANIM_FLY)
	var frac := fposmod(model.anim.current_animation_position / flap.length,
			1.0)
	if _last_frac < 0.0:
		_last_frac = frac
		return
	# The whoosh's envelope peaks WHOOSH_PEAK_SEC into its playback; in
	# beat-loop fractions that is peak_sec x speed_scale. Fire that much
	# BEFORE the mid-downstroke point so the peak lands there at any
	# tempo (clamped to the loop start when the tempo outruns it).
	var fire_frac := clampf(0.5 - WHOOSH_PEAK_SEC * model.anim.speed_scale,
			0.0, 0.49)
	if _crossed(fire_frac, frac):
		_on_flap()
	if _crossed(thump_upstroke_frac, frac):
		_on_thump()
	_last_frac = frac


## True when the beat loop passed fraction `t` between the previous and
## current readings (wrap-safe).
func _crossed(t: float, cur: float) -> bool:
	if cur >= _last_frac:
		return _last_frac < t and t <= cur
	return t > _last_frac or t <= cur


## --- Wing-flare landing burst ------------------------------------------


## Touchdown edge: flight ending while standing on the floor is a
## landing — spread the wings and flare. A mid-air toggle-off falls and
## lands WITHOUT flight, so it never flares, and cancelling a takeoff
## (still rising, still on the floor) doesn't either.
func _update_flight_edge() -> void:
	if _was_flying and not controller.flying and controller.is_on_floor() \
				and controller.velocity.y <= 0.5 and _flare_cd <= 0.0 \
				and flare_whooshes > 0:
		_start_flare()
	_was_flying = controller.flying


## Schedules the burst: soft whooshes that quicken towards the end,
## like wings beating faster as the bird bleeds off the last of its
## speed into the ground.
func _start_flare() -> void:
	_flare_left = flare_whooshes
	_flare_t = 0.0
	_flare_next = 0.0
	_flare_cd = flare_cooldown
	flare_count += 1


func _tick_flare(delta: float) -> void:
	_flare_cd = maxf(0.0, _flare_cd - delta)
	if _flare_left <= 0:
		return
	_flare_t += delta
	while _flare_left > 0 and _flare_t >= _flare_next:
		# Soft whooshes, deliberately independent of the (falling)
		# airspeed so the burst never spikes loud on a fast descent.
		_on_flap(flare_db_offset)
		_flare_left -= 1
		var done := float(flare_whooshes - _flare_left) / float(flare_whooshes)
		_flare_next = flare_duration * pow(done, 0.7)


## Fires one whoosh, louder and slightly sharper the faster the bird
## moves (harder wing strokes bite more air). `db_offset` shifts the
## loudness (the landing flare fires these soft).
func _on_flap(db_offset := 0.0) -> void:
	if _flap_voices.is_empty() or _flap_pool.is_empty():
		return
	var speed := controller.velocity.length()
	var db := flap_base_db + flap_speed_db_gain * clampf(
			(speed - wind_min_speed) / (wind_full_speed - wind_min_speed),
			0.0, 1.0) + db_offset
	var pitch := 1.0 + randf_range(-flap_pitch_variance, flap_pitch_variance)
	var p := _flap_voices[_next_voice]
	_next_voice = (_next_voice + 1) % _flap_voices.size()
	play_count += 1
	# Chest height: the wing-beat noise radiates from the body, which the
	# voice follows because these players are NOT world-fixed.
	p.global_position = controller.global_position + Vector3.UP * 1.2
	p.stream = _flap_pool.pick_random()
	p.volume_db = db
	p.pitch_scale = clampf(pitch * bend_mult(), 0.05, 8.0)
	last_whoosh_db = p.volume_db
	p.play()


## Fires the faint upstroke double-thump: two soft low pulses, like the
## wing bones flexing as the wings reset for the next beat. Rides the
## same swoop bend and Doppler as the whooshes.
func _on_thump() -> void:
	if _thump_voices.is_empty() or _thump_pool.is_empty():
		return
	var t := _thump_voices[_thump_next]
	_thump_next = (_thump_next + 1) % _thump_voices.size()
	thump_count += 1
	t.global_position = controller.global_position + Vector3.UP * 1.2
	t.stream = _thump_pool[0]
	t.volume_db = thump_base_db
	t.pitch_scale = clampf(maxf(0.1, 1.0 + randf_range(
			-thump_pitch_variance, thump_pitch_variance)) * bend_mult(),
			0.05, 8.0)
	last_thump_db = t.volume_db
	t.play()


## --- Procedural sound synthesis (used when no streams are assigned) ----


## A 2-second seamless wind loop: two low-passed noise layers (deep rumble
## + airy body) with slow gust LFOs whose periods divide the loop length,
## then an overlap-add crossfade at the seam so it can loop forever
## without a tick.
func _make_wind_stream() -> AudioStreamWAV:
	var length := int(2.0 * SYNTH_SAMPLE_RATE)
	var fade := int(0.1 * SYNTH_SAMPLE_RATE)
	var raw := PackedFloat32Array()
	raw.resize(length + fade)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var lp_rumble := 0.0
	var lp_body := 0.0
	for i in raw.size():
		var n := rng.randf_range(-1.0, 1.0)
		lp_rumble = lerpf(lp_rumble, n, 0.02)
		lp_body = lerpf(lp_body, n, 0.08)
		var t := float(i) / SYNTH_SAMPLE_RATE
		# Gusts: 1.333 s and 0.333 s periods, both divide the 2 s loop.
		var gust := 0.72 + 0.18 * sin(TAU * 1.5 * t + 1.3) \
				+ 0.10 * sin(TAU * 3.0 * t)
		raw[i] = clampf((lp_rumble * 2.6 + lp_body * 1.4) * gust, -1.0, 1.0)
	var data := PackedFloat32Array()
	data.resize(length)
	for i in length:
		if i < fade:
			# Blend the overhang tail into the loop head (equal-power-ish).
			var w := float(i) / float(fade)
			data[i] = raw[i] * w + raw[length + i] * (1.0 - w)
		else:
			data[i] = raw[i]
	var wav := _to_stream(data)
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = length
	return wav


## A ~260 ms wing-beat whoosh: band-passed noise (the difference of two
## low-pass layers) under a skewed swell envelope — air piling up on the
## downstroke, then slipping away. Three variations with different filter
## settings are generated so consecutive beats don't sound cloned.
func _make_whoosh_stream() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var length := int(0.26 * SYNTH_SAMPLE_RATE)
	var data := PackedFloat32Array()
	data.resize(length)
	var lp_hi := 0.0
	var lp_lo := 0.0
	var hi_coef := rng.randf_range(0.10, 0.16)
	var lo_coef := rng.randf_range(0.035, 0.055)
	var skew := rng.randf_range(0.75, 1.0)
	for i in length:
		var u := float(i) / float(length)
		var n := rng.randf_range(-1.0, 1.0)
		lp_hi = lerpf(lp_hi, n, hi_coef)
		lp_lo = lerpf(lp_lo, n, lo_coef)
		var band := lp_hi - lp_lo  # cheap band-pass
		var env := pow(sin(PI * pow(u, skew)), 2.0)
		data[i] = clampf(band * 2.4 * env, -1.0, 1.0)
	return _to_stream(data)


## The upstroke double-thump: two soft low pulses 70 ms apart (the wing
## bones flexing at the top of the stroke and the wings resetting). Pure
## decaying sines around 70 Hz with a gentle pitch drop per pulse.
func _make_thump_stream() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var length := int(0.2 * SYNTH_SAMPLE_RATE)
	var data := PackedFloat32Array()
	data.resize(length)
	var gap := int(0.07 * SYNTH_SAMPLE_RATE)
	var pulse_len := int(0.09 * SYNTH_SAMPLE_RATE)
	for pulse in 2:
		var start := pulse * gap
		var f0 := 72.0 + rng.randf_range(-6.0, 6.0)
		var phase := 0.0
		for i in pulse_len:
			var idx := start + i
			if idx >= length:
				break
			var u := float(i) / float(pulse_len)
			var env := exp(-7.0 * u) * (1.0 - u * 0.3)
			var f := f0 * (1.0 - 0.25 * u)  # pitch drops through the pulse
			phase += TAU * f / SYNTH_SAMPLE_RATE
			data[idx] += clampf(sin(phase) * 0.6 * env, -1.0, 1.0)
	return _to_stream(data)


## The ears-pop pressure release: a low thump with sagging pitch (the
## pressure dropping) plus a short noise tick (the plug coming free).
## ~160 ms, deliberately soft.
func _make_pop_stream() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var length := int(0.16 * SYNTH_SAMPLE_RATE)
	var data := PackedFloat32Array()
	data.resize(length)
	var phase := 0.0
	for i in length:
		var u := float(i) / float(length)
		var v := 0.0
		if u < 0.38:
			var tu := u / 0.38
			phase += TAU * (110.0 - 60.0 * tu) / SYNTH_SAMPLE_RATE
			v += sin(phase) * 0.55 * exp(-5.0 * tu)
		if u >= 0.30 and u < 0.50:
			var ru := (u - 0.30) / 0.20
			v += rng.randf_range(-1.0, 1.0) * 0.25 * sin(PI * ru)
		data[i] = clampf(v, -1.0, 1.0)
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
