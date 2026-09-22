class_name DayNight
extends Node3D
## The island's day-night cycle: one Phase drives everything, so
## lighting, sky, fog, fireflies and the lighthouse beacons always
## agree. Phase 0 = dawn, 0.25 = noon, 0.5 = dusk, 0.75 = deep night.
## The sun rides a tilted orbit; the moon rises exactly opposite it and
## lights the night. Palettes keyframe through the day (dawn and dusk
## are warm low-sun twins); the Fireflies swarms and the lighthouse
## lamps + spinning beams (group "night_lights") wake only after
## sunset, fading in as the sun drops below the horizon.
##
## Attach under L_Main's "Lighting" node, next to the sun. The moon is
## created at runtime so the scene file keeps a single light.

## Full day length in real seconds (8-minute day by default). Exported
## so playtests can freeze or accelerate the clock.
@export_range(10.0, 3600.0) var day_length := 480.0
## Starting phase: 0.52 = late golden hour — roughly half a minute of
## warm daylight after boot, then the sun slides to the horizon and
## the fireflies and beacons wake.
@export_range(0.0, 1.0) var phase := 0.52
## While true the clock never advances (playtests, screenshots).
@export var paused := false

signal phase_changed(phase: float)

## Key phases for every palette table: dawn, noon, dusk, night.
const KEY_PHASES: Array[float] = [0.0, 0.25, 0.5, 0.75]

const SUN_COLORS := {
	0.0: Color(1.0, 0.52, 0.26),   # dawn: deep ember
	0.25: Color(1.0, 0.97, 0.88),  # noon: near-white
	0.5: Color(1.0, 0.62, 0.32),   # dusk: the shipped amber
	0.75: Color(0.55, 0.65, 0.95), # night: moonlight
}
const SUN_ENERGY := {
	0.0: 0.55,
	0.25: 1.25,
	0.5: 1.15,
	0.75: 0.5,
}
const SHADOW_BLUR := {
	0.0: 1.6,
	0.25: 1.0,
	0.5: 1.6,
	0.75: 2.0,
}
const SKY_TOP := {
	0.0: Color(0.35, 0.34, 0.55),
	0.25: Color(0.24, 0.46, 0.82),
	0.5: Color(0.18, 0.24, 0.45),  # shipped dusk navy
	0.75: Color(0.045, 0.055, 0.14),
}
const SKY_HORIZON := {
	0.0: Color(0.98, 0.62, 0.38),
	0.25: Color(0.68, 0.80, 0.95),
	0.5: Color(0.91, 0.60, 0.37),  # shipped amber
	0.75: Color(0.10, 0.12, 0.26),
}
const GROUND_HORIZON := {
	0.0: Color(0.90, 0.55, 0.34),
	0.25: Color(0.55, 0.62, 0.68),
	0.5: Color(0.86, 0.53, 0.33),  # shipped value
	0.75: Color(0.06, 0.07, 0.16),
}
const FOG_LIGHT := {
	0.0: Color(0.90, 0.58, 0.40),
	0.25: Color(0.82, 0.88, 0.95),
	0.5: Color(0.86, 0.59, 0.42),  # shipped value
	0.75: Color(0.13, 0.16, 0.30),
}
const FOG_DENSITY := {
	0.0: 0.00042,
	0.25: 0.00016,
	0.5: 0.00028,                  # shipped value
	0.75: 0.00038,
}
## Sun elevation (deg) at each key phase. Night: well below horizon.
const SUN_ELEV := {
	0.0: 8.0,
	0.25: 62.0,
	0.5: 30.0,   # the shipped dusk angle
	0.75: -38.0,
}

## Below this elevation (deg) the night gates start opening.
const SUNSET_ELEV := 6.0
## Night gates are fully open by this elevation (deg) — the fade lags
## the geometric horizon so dusk stays moody for a few real minutes.
const NIGHT_OPEN_ELEV := -6.0
## Gate fade speed (fraction per second): full sunset transition in
## ~2.5 s of real time once the sun crosses the gate.
const GATE_SPEED := 0.4

var _sun: DirectionalLight3D
var _moon: DirectionalLight3D
var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _gates := 0.0  # 0 = day, 1 = full night
## Clock hold: the world build (scatter + physics warm-up) eats real
## seconds, so time stays frozen until PropScatter reports the world
## playable — the player always gets the full starting golden hour.
var _setup_hold := true
## Failsafe: if the scatter never reports (script error, removed node),
## the clock self-releases after this many real seconds.
const HOLD_TIMEOUT_SEC := 120.0
var _hold_deadline_msec := 0


func _ready() -> void:
	_hold_deadline_msec = Time.get_ticks_msec() + \
			int(HOLD_TIMEOUT_SEC * 1000.0)
	add_to_group("daynight")
	_sun = get_node_or_null("../DirectionalLight3D") as DirectionalLight3D
	if _sun == null:
		push_error("DayNight: no sibling DirectionalLight3D found")
		return
	# The moon: a cold-blue second key that rides the opposite side of
	# the orbit and carries the night. Created here so the scene keeps
	# a single authored light.
	_moon = DirectionalLight3D.new()
	_moon.name = "MoonLight"
	_moon.light_color = Color(0.62, 0.72, 1.0)
	_moon.shadow_enabled = true
	_moon.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_moon.directional_shadow_max_distance = 3000.0
	_moon.shadow_blur = 2.0
	add_child(_moon)

	var we := get_node_or_null("../WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		_env = we.environment
		if _env.sky != null:
			_sky_mat = _env.sky.sky_material as ProceduralSkyMaterial
	# Register any already-present night-light kit. Beacons and
	# fireflies spawn later (during the scatter), but _apply() re-broadcasts
	# the gate every frame so late spawners pick it up immediately.
	get_tree().call_group("night_lights", "on_night_register", self)
	_apply(0.0)


func _process(delta: float) -> void:
	if _setup_hold:
		var sc := get_node_or_null("../../PropScatter")
		if sc != null and sc.get("setup_done") != true \
				and Time.get_ticks_msec() < _hold_deadline_msec:
			_apply(0.0)  # keep lighting consistent while time is held
			return
		_setup_hold = false
	var prev := phase
	if not paused:
		phase = fposmod(phase + delta / day_length, 1.0)
	if int(prev * 4.0) != int(phase * 4.0):
		phase_changed.emit(phase)
	_apply(delta)


func set_phase(p: float) -> void:
	## Jump the clock (playtests, debugging).
	phase = fposmod(p, 1.0)
	_apply(0.0)


func night_gate() -> float:
	## Current night factor: 0 = full day, 1 = full night. Fireflies
	## and beacons scale themselves by this every frame.
	return _gates


func sun_elevation() -> float:
	## Current sun elevation in degrees (negative = below horizon).
	return _sun_elev_for(phase)


func _apply(delta: float) -> void:
	if _sun == null:
		return
	var sun_elev := _sun_elev_for(phase)

	# ---- orbit ---------------------------------------------------------
	_orbit(_sun, phase, 24.0)
	_sun.visible = sun_elev > -12.0
	# The moon rides the opposite side of the orbit; its output ramps
	# with its own height so it rises dark and brightens overhead.
	_orbit(_moon, fposmod(phase + 0.5, 1.0), 30.0)
	_moon.light_energy = clampf(remap(_moon_elev(), -6.0, 22.0,
			0.0, 0.5), 0.0, 0.5)
	_moon.visible = _moon.light_energy > 0.01

	# ---- palette keyframing --------------------------------------------
	var seg := _segment(phase)
	_sun.light_color = _col(SUN_COLORS, seg)
	_sun.light_energy = _val(SUN_ENERGY, seg)
	_sun.shadow_blur = _val(SHADOW_BLUR, seg)
	if _env != null:
		_env.fog_light_color = _col(FOG_LIGHT, seg)
		_env.fog_density = _val(FOG_DENSITY, seg)
		# Sun-scatter through the mist only while the sun is low.
		var amber := clampf(remap(sun_elev, -8.0, 20.0, 1.0, 0.0),
				0.0, 1.0)
		_env.fog_sun_scatter = lerpf(0.06, 0.34, amber)
		if _sky_mat != null:
			_sky_mat.sky_top_color = _col(SKY_TOP, seg)
			_sky_mat.sky_horizon_color = _col(SKY_HORIZON, seg)
			_sky_mat.ground_horizon_color = _col(GROUND_HORIZON, seg)
			# At night the ground melts toward the sky so terrain
			# edges vanish into the dark instead of rimming.
			_sky_mat.ground_bottom_color = \
					_col(GROUND_HORIZON, seg).darkened(0.55)

	# ---- night gates -----------------------------------------------------
	var target := 0.0
	if sun_elev <= NIGHT_OPEN_ELEV:
		target = 1.0
	elif sun_elev < SUNSET_ELEV:
		target = remap(sun_elev, NIGHT_OPEN_ELEV, SUNSET_ELEV, 1.0, 0.0)
	_gates = move_toward(_gates, target, maxf(delta, 0.0) * GATE_SPEED)
	get_tree().call_group("night_lights", "on_night_gate", _gates)


func dusk_crickets() -> float:
	## Loudness factor for the evening chorus: crickets and
	## twilight birds wake in the dusk hours (sun below ~20 deg and
	## falling), quiet right down through deep night — the deep-dark
	## island belongs to the wind and the waves.
	var el := _sun_elev_for(phase)
	if el > 20.0:
		return 0.0
	if el > 2.0:
		return remap(el, 2.0, 20.0, 1.0, 0.0)
	if el > -14.0:
		return 1.0
	return clampf(remap(el, -26.0, -14.0, 0.0, 1.0), 0.0, 1.0)


## Elevation from the phase (through the SUN_ELEV keyframes, so the
## shipped dusk angle is preserved), azimuth sweeping once per day,
## plus a fixed tilt so shadows never fall along a world axis.
func _orbit(light: DirectionalLight3D, p: float, tilt: float) -> void:
	var el := _sun_elev_for(p)
	var az := TAU * p + deg_to_rad(tilt)
	light.rotation = Vector3.ZERO
	light.rotate_y(az)
	# Pitch about local X: positive angle lifts the light direction
	# (its -Z) above the horizon, negative drops it below.
	light.rotate_object_local(Vector3(1, 0, 0), deg_to_rad(el))


func _moon_elev() -> float:
	if _moon == null:
		return -90.0
	return rad_to_deg(asin(clampf(
			-_moon.global_transform.basis.z.normalized().y, -1.0, 1.0)))


func _sun_elev_for(p: float) -> float:
	var seg := _segment(p)
	return lerpf(SUN_ELEV[seg[0]], SUN_ELEV[seg[1]], seg[2])


## Palette interpolation over one segment: [phase_a, phase_b, t].
func _col(table: Dictionary, seg: Array) -> Color:
	var a: Color = table[seg[0]]
	var b: Color = table[seg[1]]
	return a.lerp(b, seg[2])


func _val(table: Dictionary, seg: Array) -> float:
	var a: float = table[seg[0]]
	var b: float = table[seg[1]]
	return lerpf(a, b, seg[2])


## Which palette segment does phase p live in? Handles the night->dawn
## wrap (0.75 .. 1.0 runs from the night key to the dawn key).
func _segment(p: float) -> Array:
	var keys := KEY_PHASES
	var i1 := 1
	while i1 < keys.size() and keys[i1] < p:
		i1 += 1
	var p0: float = keys[i1 - 1]
	var p1: float = keys[i1 % keys.size()]
	var span := p1 - p0
	if span <= 0.0:
		span += 1.0
	return [p0, p1, clampf((p - p0) / span, 0.0, 1.0)]
