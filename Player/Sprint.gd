extends Node
## Sprint trigger: on the ground it switches the character into the run
## animation (with the FOV kick); while flying it boosts the fly speed.

@export var controller_path := NodePath("../")
@onready var controller: MovementController = get_node(controller_path)

@export var head_path := NodePath("../Head")
@onready var cam: Camera3D = get_node(head_path).cam

## Speed multiplier of the ground run vs. normal walk speed.
@export var ground_run_multiplier := 1.6
## Speed multiplier while flying and holding sprint.
@export var fly_boost := 1.5
@export var fov_multiplier := 1.08
@onready var normal_speed: float = controller.walk_speed
@onready var normal_fov: float = cam.fov

var _sprinting := false


# Called every physics tick. 'delta' is constant
func _physics_process(delta: float) -> void:
	_sprinting = can_sprint()
	controller.sprinting = _sprinting

	if controller.sailing and controller._sail_host != null:
		# Sailing: the trigger boosts the hull's rowing speed (the
		# same treatment as the flight boost).
		(controller._sail_host as Node).call("set_boost", _sprinting)
		controller.sprint_boost = 1.0  # unused aboard
	elif controller.flying:
		controller.sprint_boost = fly_boost if _sprinting else 1.0
	else:
		controller._speed = sprint_speed() if _sprinting else normal_speed

	if _sprinting:
		cam.set_fov(lerpf(cam.fov, normal_fov * fov_multiplier, delta * 8))
	else:
		cam.set_fov(lerpf(cam.fov, normal_fov, delta * 8))


func sprint_speed() -> float:
	return normal_speed * ground_run_multiplier


func can_sprint() -> bool:
	if not Input.is_action_pressed("sprint"):
		return false
	if controller.flying:
		return true
	# Sailing: the trigger means a rowing boost while pulling forward.
	if controller.sailing:
		return Input.get_action_strength("move_forward") >= 0.5
	return (controller.is_on_floor()
			and not controller.crouching
			and (controller.input_axis.x >= 0.5
				or Input.get_action_strength("move_forward") >= 0.5))
