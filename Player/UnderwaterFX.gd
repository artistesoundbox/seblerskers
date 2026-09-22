class_name UnderwaterFX
extends CanvasLayer
## The underwater mood, in three layers:
##   1. MUFFLE — a master-bus low-pass plus a gentle master-volume dip
##      so the surface world (wind, oars, birds) reads as "above the
##      water" while the camera is submerged.
##   2. TONE — a low, slow-breathing underwater hum that fades in with
##      submersion (procedural loop, built once).
##   3. SHAFTS — glinting god-ray columns that hang from the surface
##      around the camera, tops pinned at the waterline, shimmering
##      with per-shaft phase. Deeper water = more visible shafts.
## A fast sea entry punches the muffle (kept from the previous pass).
##
## Spawned by MovementController at boot; fed each physics frame.

## Steady muffle cutoff (Hz) while the camera is under the surface.
@export var steady_cutoff := 900.0
## Full-open cutoff — effectively no filter.
@export var open_cutoff := 19500.0
## Deepest dive cutoff (Hz) right after a terminal-velocity entry.
@export var punch_cutoff := 260.0
## How fast the punch recovers (fraction/s of the way back).
@export var recover_rate := 1.6
## Steady tint alpha while submerged.
@export var steady_tint := 0.22
## Extra tint on a fast entry (scaled by entry speed).
@export var punch_tint := 0.30
## Master-bus volume dip (dB) while fully submerged — the surface
## world reads as "above the water".
@export var submerged_bus_db := -7.0
## Peak loudness of the underwater tone (dB, negative = quiet).
@export var tone_db := -16.0
## Radius the shaft rig follows the camera with (m).
@export var shaft_radius := 14.0
## How many shafts form the rig.
@export var shaft_count := 7

## Headless-verifiable state.
var muffle_on := false
var cutoff_hz := open_cutoff
var tint_alpha := 0.0
var punch := 0.0
## Tone loudness 0..1 (fades with submersion), tone player live flag.
var tone_level := 0.0
var tone_playing := false
## Shafts visible flag + the last glint value (moves over time —
## the harness proves the shimmer).
var shafts_visible := false
var last_glint := 0.0

var _rect: ColorRect
var _filter: AudioEffectLowPassFilter
var _filter_idx := -1
var _punch_decay := 1.4
## Bus volume bookkeeping (only touch the bus we borrowed).
var _bus_normal_db := 0.0
var _bus_dipped := false
## The low underwater tone.
var _tone: AudioStreamPlayer
## God-ray shafts: one node per shaft + shared material.
var _rig: Node3D
var _shaft_mats: Array = []
var _shaft_phase: Array = []
var _rig_seed := 0.7


func _ready() -> void:
	layer = 90
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.color = Color(0.09, 0.30, 0.42, 0.0)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)
	# One low-pass on the master bus, added once and enabled/disabled
	# — every sound in the game (wind, oars, footsteps, music) shares
	# the underwater muffle the same way ears do.
	_filter = AudioEffectLowPassFilter.new()
	AudioServer.add_bus_effect(0, _filter)
	_filter_idx = AudioServer.get_bus_effect_count(0) - 1
	AudioServer.set_bus_effect_enabled(0, _filter_idx, false)
	_bus_normal_db = AudioServer.get_bus_volume_db(0)
	# The low underwater tone: a seamless procedural loop (slow
	# sub-bass swell + a fifth above, faint). Fades with submersion.
	_tone = AudioStreamPlayer.new()
	_tone.stream = _make_tone_stream()
	_tone.volume_db = -60.0
	_tone.bus = "Master"
	_tone.autoplay = true
	add_child(_tone)
	_build_shafts()


func _exit_tree() -> void:
	if _filter_idx >= 0:
		AudioServer.remove_bus_effect(0, _filter_idx)
		_filter_idx = -1
	if _bus_dipped:
		AudioServer.set_bus_volume_db(0, _bus_normal_db)


func _build_shafts() -> void:
	_rig = Node3D.new()
	_rig.name = "GodRayRig"
	add_child(_rig)
	for i in shaft_count:
		var m := MeshInstance3D.new()
		var pm := PrismMesh.new()
		pm.left_to_right = 0.5
		pm.size = Vector3(0.55, 26.0, 0.55)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.albedo_color = Color(0.75, 0.92, 1.0, 0.0)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.emission_enabled = true
		mat.emission = Color(0.65, 0.85, 1.0)
		mat.emission_energy_multiplier = 0.6
		mat.vertex_color_use_as_albedo = true
		mat.no_depth_test = false
		m.mesh = pm
		m.material_override = mat
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.rotation.y = randf() * TAU
		m.rotation.z = randf_range(-0.10, 0.10)
		_rig.add_child(m)
		_shaft_mats.append(mat)
		_shaft_phase.append(randf() * TAU)


## The low underwater tone: a seamless 8 s loop — a 55 Hz sub swell
## breathing at 1/8 Hz plus its fifth, shaped so the loop joins
## silently. Pure synthesis, no assets.
func _make_tone_stream() -> AudioStreamWAV:
	var rate := 11025
	var length := 8 * rate
	var data := PackedFloat32Array()
	data.resize(length)
	for i in length:
		var t := float(i) / rate
		var breath := 0.5 + 0.5 * sin(TAU * t / 8.0)
		# The fifth above gets its own slower breath and slight detune
		# so the chord shimmers instead of sitting still.
		var v := (0.8 * sin(TAU * 55.0 * t) * (0.35 + 0.65 * breath)
				+ 0.5 * sin(TAU * 82.5 * t + 0.7 * sin(TAU * t / 8.0))
				* (0.25 + 0.75 * (0.5 + 0.5 * sin(TAU * t / 8.0 + PI / 3.0))))
		data[i] = clampf(v * 0.28, -1.0, 1.0)
	var bytes := PackedByteArray()
	bytes.resize(data.size() * 2)
	for i in data.size():
		bytes.encode_s16(i * 2,
				int(clampf(data[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	return wav


## A fast sea entry: punch the muffle harder the faster the hit.
func trigger_punch(entry_speed: float) -> void:
	punch = clampf(entry_speed / 14.0, 0.0, 1.0)


func update(delta: float, submerged: bool, tint_boost := 0.0,
		water_y := -0.75, cam_pos := Vector3.INF) -> void:
	punch = maxf(0.0, punch - punch * _punch_decay * delta)
	# The filter rides: open above water, steady below, punched deep
	# right after a hard entry — recovering toward the steady level.
	var target := open_cutoff
	if submerged:
		target = steady_cutoff * (1.0 - 0.55 * punch)
		if punch > 0.2:
			target = lerpf(target, punch_cutoff, 0.35)
	cutoff_hz = lerpf(cutoff_hz, target, minf(1.0, (recover_rate + 3.0) * delta))
	muffle_on = cutoff_hz < open_cutoff * 0.75
	AudioServer.set_bus_effect_enabled(0, _filter_idx, muffle_on)
	_filter.cutoff_hz = cutoff_hz
	# Surface world volume dip (only while submerged).
	if submerged and not _bus_dipped:
		AudioServer.set_bus_volume_db(0, _bus_normal_db + submerged_bus_db)
		_bus_dipped = true
	elif not submerged and _bus_dipped:
		AudioServer.set_bus_volume_db(0, _bus_normal_db)
		_bus_dipped = false
	# Tint: steady underwater wash + the punch flash + an optional
	# boost while the camera is DEEP (dive physics).
	var tint_target := (steady_tint + punch_tint * punch + tint_boost) \
			if submerged else 0.0
	tint_alpha = lerpf(tint_alpha, tint_target,
			minf(1.0, (recover_rate + 2.0) * delta))
	_rect.color.a = tint_alpha
	_update_tone(delta, submerged)
	_update_shafts(delta, submerged, water_y, cam_pos)


## The tone fades with submersion; headless-verifiable via tone_level.
## tone_playing reports the voice's INTENT (stream ready + audible
## level) — the dummy audio driver headless runs never raises
## AudioStreamPlayer.playing, so the transport flag is unusable there.
func _update_tone(delta: float, submerged: bool) -> void:
	var target := 1.0 if submerged else 0.0
	tone_level = move_toward(tone_level, target, delta / 0.9)
	tone_playing = _tone != null and _tone.stream != null \
			and tone_level > 0.01
	if _tone != null:
		_tone.volume_db = lerpf(-60.0, tone_db, tone_level)


## The shaft rig trails the camera; each shaft's alpha glints on its
## own slow phase, and the whole rig fades with submersion + depth.
func _update_shafts(delta: float, submerged: bool, water_y: float,
		cam_pos: Vector3) -> void:
	if _rig == null:
		return
	# Rig follows the camera (x/z only — the tops pin to the surface).
	_rig.global_position = Vector3(cam_pos.x, water_y, cam_pos.z)
	_rig.visible = submerged
	shafts_visible = _rig.visible
	if not _rig.visible:
		return
	var t := Time.get_ticks_msec() / 1000.0
	var glint0 := 0.0
	for i in _shaft_mats.size():
		var mat: StandardMaterial3D = _shaft_mats[i]
		var ph: float = _shaft_phase[i]
		# Glint: a slow sine with a sharper crest — reads as light
		# catching the column, not a flat pulsing.
		var glint := pow(0.5 + 0.5 * sin(t * 0.9 + ph), 2.2)
		var drift := sin(t * 0.23 + ph * 1.7)
		mat.albedo_color.a = (0.10 + 0.16 * glint) \
				* (0.55 + 0.45 * maxf(0.0, drift))
		if i == 0:
			glint0 = glint
	last_glint = glint0
