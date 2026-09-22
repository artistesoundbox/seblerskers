extends Node3D
## A drifting swarm of fireflies for the mini forests. One swarm is
## spawned by PropScatter at each grove centre; the fireflies wander
## under the canopy with slow layered sine noise (no two pulses in
## sync), each blinking its own soft glow. Built from emissive
## billboards + one OmniLight — cheap enough to keep five swarms alive
## at all times, and the pixels are unshaded + additively blended so
## the swarm reads as lights (not dots) from far away.

## Fireflies per swarm.
@export var count := 22
## Horizontal wander radius around the grove centre (metres).
@export var roam_radius := 11.0
## Band the flies drift inside: [ground_offset, ground_offset + band]
## metres above the terrain — under the canopy, above the undergrowth.
@export var ground_offset := 0.5
@export var band := 2.2
## Blink tempo range (pulses per second) — per-fly random inside it.
@export var blink_min := 0.35
@export var blink_max := 0.9
## Peak brightness per fly (the OmniLight carries the neighbourhood glow).
## Night-tuned: fireflies are night creatures now — DayNight fades the
## whole swarm in after sunset, so each pulse must read against a dark
## sky (was 2.6 in the all-day era, 5.2 at permanent dusk).
@export var glow_energy := 5.2
## Seed so a grove's swarm is the same every run (set from PropScatter).
@export var swarm_seed := 0

var _flies: Array[Sprite3D] = []
var _rng := RandomNumberGenerator.new()
## Per-fly wander phases and speeds (layered sines, no allocations
## after _ready).
var _phase_a: PackedFloat32Array
var _phase_b: PackedFloat32Array
var _speed: PackedFloat32Array
var _blink_phase: PackedFloat32Array
var _blink_hz: PackedFloat32Array
var _base_y: PackedFloat32Array
var _t := 0.0
var _light: OmniLight3D
## Night gate from DayNight (0 = day, 1 = full night): the swarm dims
## and sleeps through daylight, wakes as the sun sets.
var _gate := 0.0


func _ready() -> void:
	_rng.seed = swarm_seed
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.disable_receive_shadows = true
	mat.albedo_color = Color(1.0, 1.0, 0.55, 1.0)
	# Radial glow dot: a soft round sprite built in code (no texture
	# asset needed) — bright core, quick falloff.
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var d := Vector2(x - size * 0.5, y - size * 0.5).length() \
					/ (size * 0.5)
			var a: float = clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	mat.albedo_texture = ImageTexture.create_from_image(img)

	_phase_a.resize(count)
	_phase_b.resize(count)
	_speed.resize(count)
	_blink_phase.resize(count)
	_blink_hz.resize(count)
	_base_y.resize(count)
	for i in count:
		var s := Sprite3D.new()
		s.material_override = mat  # shared; per-fly blink via modulate
		s.pixel_size = 0.028
		s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(s)
		_flies.append(s)
		_phase_a[i] = _rng.randf() * TAU
		_phase_b[i] = _rng.randf() * TAU
		_speed[i] = _rng.randf_range(0.5, 1.1)
		_blink_phase[i] = _rng.randf() * TAU
		_blink_hz[i] = _rng.randf_range(blink_min, blink_max)
		_base_y[i] = _rng.randf_range(ground_offset,
				ground_offset + band)
	# One warm light hovering mid-swarm: the fireflies' neighbourhood
	# glow (per-fly lights would be far too expensive).
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.95, 0.55)
	# Brighter + wider than the daytime tune so the swarm's neighbourhood
	# glow survives the lower dusk sun.
	_light.light_energy = 1.1
	_light.omni_range = 9.0
	_light.shadow_enabled = false
	_light.position = Vector3(0, ground_offset + band * 0.5, 0)
	add_child(_light)
	# Join the night-light kit: DayNight broadcasts the gate every
	# frame, so the swarm fades in as the sun crosses the horizon.
	add_to_group("night_lights")
	_apply_gate()

func on_night_register(_ctrl: Node) -> void:
	pass  # Late registration handled by the per-frame group broadcast.


func on_night_gate(g: float) -> void:
	_gate = clampf(g, 0.0, 1.0)
	_apply_gate()


func _apply_gate() -> void:
	var active := _gate > 0.001
	set_process(active)
	for s in _flies:
		s.visible = active
	if _light != null:
		_light.visible = active


func _process(delta: float) -> void:
	_t += delta
	var brightest := 0.0
	for i in _flies.size():
		var s := _flies[i]
		# Layered-sine wander: a slow loop around the grove plus a
		# smaller cross-drift — organic, never leaves the grove.
		var sa: float = _speed[i]
		var r: float = roam_radius * (0.45 + 0.55
				* absf(sin(_phase_a[i] * 0.5)))
		var px: float = cos(_phase_a[i]) * r
		var pz: float = sin(_phase_b[i]) * r
		var py: float = _base_y[i] + sin(_phase_b[i] * 1.7) * 0.4
		s.position = Vector3(px, py, pz)
		_phase_a[i] += delta * sa * 0.35
		_phase_b[i] -= delta * sa * 0.27
		# Independent blink: a squared sine pulse per fly.
		var blink := sin(_blink_phase[i])
		var glow: float = maxf(blink, 0.0)
		glow *= glow
		var e: float = glow * glow_energy * _gate
		s.modulate = Color(e, e, e * 0.8, clampf(glow * 1.6, 0.0, 1.0))
		brightest = maxf(brightest, glow)
		_blink_phase[i] += delta * TAU * _blink_hz[i]
	# The shared light breathes with the swarm's brightest moment,
	# scaled by the night gate so groves go fully dark at noon.
	if _light != null:
		_light.light_energy = (0.7 + brightest * 0.8) * _gate
