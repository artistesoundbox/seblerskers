class_name ControllerFeedback
extends Node
## Gamepad feel for the player: controller vibration (rumble) plus a subtle
## camera lean into strafing/motion. Attach as a child of the player root.

@export var controller_path := NodePath("..")
## Defaults to ../Head (the camera head with the SpringArm3D).
@export var head_path := NodePath("../Head")

@export var rumble_enabled := true
## Low-frequency motor strength for the "walk" pulse, 0..1.
@export var walk_rumble := 0.12
## Extra strength while sprinting.
@export var sprint_rumble := 0.2
@export var jump_rumble := 0.5
@export var land_rumble := 0.65
@export var attack_rumble := 0.85
## Strength of the burst when a dive-bomb strike begins.
@export var dive_rumble := 0.9
## Continuous shake strength while plunging in a dive (scales with speed).
@export var dive_shake := 0.45
## Tiller resistance while sailing: low-motor trill strength during
## hard turns at speed (the stick fighting back through the water),
## scaled by the boat's rudder-drag load.
@export var tiller_rumble := 0.28

@export var lean_enabled := true
## Max lean angle in degrees when strafing at full speed.
@export var lean_angle := 2.0
@export var lean_speed := 6.0
## Horizontal speed above which the character counts as sprinting
## (between the 4 m/s walk and the 1.6x run).
@export var sprint_speed_threshold := 5.2

@onready var controller: MovementController = get_node(controller_path)
@onready var head: PlayerHead = get_node(head_path)

var _lean := 0.0
var _was_on_floor := true
## Seconds left on the current one-shot rumble pulse.
var _pulse_time := 0.0
var _pulse_duration := 0.0
var _pulse_strength := 0.0


func _ready() -> void:
	controller.attacked.connect(_on_attacked)
	controller.dive_started.connect(_on_dive_started)
	if not Input.is_joy_known(0):
		set_physics_process(false)
		return
	Input.start_joy_vibration(0, 0.0, 0.0, 0.0)


## Re-arm rumble when a controller is plugged in mid-game.
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		if not is_physics_processing():
			set_physics_process(true)


func _physics_process(delta: float) -> void:
	_process_rumble(delta)
	_process_lean(delta)


func _process_rumble(delta: float) -> void:
	if not rumble_enabled:
		return
	var on_floor := controller.is_on_floor()
	# Landing: one short strong thump.
	if on_floor and not _was_on_floor and controller.velocity.y < -4.0:
		_pulse(land_rumble, 0.18)
	# Jump: one short kick.
	if not on_floor and _was_on_floor and controller.velocity.y > 4.0:
		_pulse(jump_rumble, 0.12)
	_was_on_floor = on_floor

	# Flight: soft humps while flapping (one per wing beat), a gentle
	# continuous hum while gliding, and a rising roar while dive-bombing.
	if controller.flying:
		if controller.diving:
			var plunge := clampf(-controller.velocity.y / 38.0, 0.0, 1.0)
			_rumble(dive_shake * plunge, dive_shake * plunge * 0.8)
			return
		if controller.wing_flapping:
			var flap_env: float = maxf(0.0, sin(Time.get_ticks_msec() / 1000.0 * 12.0))
			_rumble(0.2 * flap_env, 0.0)
		else:
			_rumble(0.08, 0.0)
		return

	# Sailing: the tiller pushes back through hard turns — a low fast
	# trill riding the rudder-drag load — plus a faint water-drag hum
	# while pulling at boost speed.
	if controller.sailing:
		var trill := tiller_trill_strength()
		if trill > 0.0:
			_rumble(trill, 0.0)
		else:
			var drag := 0.0
			if controller._sail_host != null:
				drag = clampf(((controller._sail_host.call("surge_amount") as float) - 0.66) / 0.34, 0.0, 1.0)
				_rumble(0.05 * drag, 0.0)
			else:
				_rumble(0.0, 0.0)
		return

	# Walking: gentle pulses in step with the walk cycle.
	var ground_speed := Vector2(controller.velocity.x, controller.velocity.z).length()
	if on_floor and ground_speed > 1.0:
		var strength := walk_rumble * clampf(ground_speed / controller.current_speed(), 0.0, 1.0)
		if ground_speed > sprint_speed_threshold:
			strength = sprint_rumble
		# Two soft humps per cycle => one per footstep.
		var envelope: float = maxf(0.0, sin(Time.get_ticks_msec() / 1000.0 * 10.1))
		_rumble(strength * envelope, 0.0)
	else:
		_rumble(0.0, 0.0)


func _process_lean(delta: float) -> void:
	if not lean_enabled:
		return
	# Lean into horizontal strafing, relative to the body.
	var aim: Basis = controller.global_transform.basis
	var local_vel := aim.inverse() * Vector3(controller.velocity.x, 0.0, controller.velocity.z)
	var target := deg_to_rad(lean_angle) * clampf(local_vel.x / controller.current_speed(), -1.0, 1.0)
	_lean = lerpf(_lean, target, minf(1.0, lean_speed * delta))
	head.rotation.z = _lean


## Tiller trill strength right now (0 = silent): the stick fighting
## back during hard turns, scaled by the eased rudder-drag load and
## shaped as a ~22 Hz beat so it reads as strain, not noise.
func tiller_trill_strength() -> float:
	if not controller.sailing or controller._sail_host == null:
		return 0.0
	var load: float = clampf(controller._sail_host.call("rudder_load"), 0.0, 1.0)
	if load <= 0.0:
		return 0.0
	var beat := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 1000.0 * TAU * 22.0)
	return tiller_rumble * load * (0.35 + 0.65 * beat)


## One-shot rumble that overrides the walking pulse for its duration.
func _pulse(strength: float, duration: float) -> void:
	_pulse_strength = strength
	_pulse_duration = duration
	_pulse_time = duration


func _on_attacked() -> void:
	_pulse(attack_rumble, 0.25)


## Dive-bomb: one strong burst as the wings fold, then the continuous
## plunge shake takes over from _process_rumble.
func _on_dive_started() -> void:
	_pulse(dive_rumble, 0.35)


func _rumble(low: float, high: float) -> void:
	if _pulse_time > 0.0:
		_pulse_time = maxf(0.0, _pulse_time - get_physics_process_delta_time())
		if _pulse_time > 0.0:
			low = maxf(low, _pulse_strength)
			high = maxf(high, _pulse_strength * 0.7)
		elif _pulse_duration > 0.0:
			# Pulse just ended: make sure motors stop.
			low = 0.0
			high = 0.0
			_pulse_duration = 0.0
	if rumble_enabled:
		Input.start_joy_vibration(0, clampf(low, 0.0, 1.0), clampf(high, 0.0, 1.0), 0.1)
