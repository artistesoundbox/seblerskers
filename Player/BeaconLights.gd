class_name BeaconLights
extends Node
## One lighthouse's night-light kit: the warm lamp in the lamp room and
## the long rotating beam. Created by PropScatter next to the model;
## registers in the "night_lights" group so DayNight fades it in after
## sunset and out again at dawn. Owns the pulse and the spin (they were
## tweens before — folded here so the night gate can scale both).

var _lamp: OmniLight3D
var _beam: SpotLight3D
var _spinner: Node3D
var _gate := 0.0
var _t := 0.0
## Phase offset so two lighthouses never flash in sync.
var _seed_phase := 0.0

const LAMP_MAX := 3.0
const LAMP_MIN := 0.6
const BEAM_MAX := 7.0
const PULSE_HZ := 1.0 / 5.2  # 2.6 s down + 2.6 s up (shipped rhythm)
const SPIN_PERIOD := 9.0


func setup(lamp: OmniLight3D, beam: SpotLight3D,
		spinner: Node3D, seed_phase: float) -> void:
	_lamp = lamp
	_beam = beam
	_spinner = spinner
	_seed_phase = seed_phase


func _ready() -> void:
	add_to_group("night_lights")
	set_process(false)
	_apply_gate()


func on_night_register(_ctrl: Node) -> void:
	pass  # DayNight broadcasts registration; nothing to do per-beacon.


func on_night_gate(g: float) -> void:
	_gate = clampf(g, 0.0, 1.0)
	_apply_gate()


func _apply_gate() -> void:
	var active := _gate > 0.001
	set_process(active)
	if _lamp != null:
		_lamp.visible = active
	if _beam != null:
		_beam.visible = active


func _process(delta: float) -> void:
	_t += delta
	# Lamp pulse: sine breathing between LAMP_MIN and LAMP_MAX, scaled
	# by the night gate so it dims out through dawn.
	var pulse := 0.5 + 0.5 * sin((_t + _seed_phase) * TAU * PULSE_HZ)
	if _lamp != null:
		_lamp.light_energy = lerpf(LAMP_MIN, LAMP_MAX, pulse) * _gate
	# Beam spins a full revolution per period; its energy follows the
	# lamp loosely so the sweep reads alive.
	if _spinner != null:
		_spinner.rotation.y = fposmod(
				(_t + _seed_phase) * TAU / SPIN_PERIOD, TAU)
	if _beam != null:
		_beam.light_energy = BEAM_MAX * (0.75 + 0.25 * pulse) * _gate
