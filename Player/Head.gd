class_name PlayerHead
extends Node3D
## Third/first person camera head: mouse + right-stick look, over-the-shoulder
## offset, and smooth zoom via mouse wheel or holding the right-stick
## click (R3) and pushing the stick up/down.
##
## (User report: the D-pad used to zoom into first person and players
## got stranded there — the D-pad no longer touches the camera at all.
## D-pad up/down now toggles the elder's scroll instead, QuestBoard.)
##
## Follow-camera behavior: while the character moves (and you are not actively
## free-looking), the camera eases in behind the body's back. Free-looking with
## the stick or mouse decouples the camera at once; release it and it swings
## back behind. Backpedaling (moving towards the camera) keeps the camera put.
##
## The desired world yaw lives in rot.y; because this head is a child of the
## rotating body, its LOCAL yaw is rot.y minus the body's current yaw.

@export var cam_path := NodePath("SpringArm3D/Camera3D")
@onready var cam: Camera3D = get_node(cam_path)
@onready var arm: SpringArm3D = $SpringArm3D

## Lateral offset of the camera boom in meters (positive = over the right
## shoulder). Fades out automatically when zooming into first person.
@export var shoulder_offset := 0.65
## Helm (sailing) boom: while the hero sits at the flagship's tiller the
## controller parks the camera at this raised behind-back offset so the
## bow and the water ahead stay in view while steering. 0 disables.
@export var helm_boom := 0.0
## Height the helm boom rides above the seat (local Y, meters).
@export var helm_height := 0.0
## Eye height for the helm FIRST-PERSON view (the held C / Y tiller
## eyes): the arm parks this far ABOVE the head node, so the tiller
## view looks over the bow from raised eyes, not deck level.
@export var helm_eye_height := 1.05
## Follow ease toward the hull heading while sailing (rad/s blend
## rate). Deliberately slower than the walk follow so the view lags
## behind the hull through turns and swings back lazily after free
## look — the cinematic chase.
@export var helm_follow_speed := 2.2
## Speed surge 0..1 fed by the controller while sailing (hull speed
## against the boost ceiling). Swells the helm lag and handheld drift
## so boosting at the tiller feels wilder than a lazy cruise.
var helm_surge := 0.0
## Tiller resistance pull-back 0..1 (controller feeds the boat's
## eased rudder-drag load): during hard turns at speed the helm
## camera leans back a touch against the rudder — the stick
## fighting the water. Pure render layer, silent at the eyes.
var helm_pull := 0.0
## Helm-EYES: while seated and this is true (the controller sets it
## while the camera toggle is HELD), the camera leans into the
## helmsman's eyes — first-person at the tiller — and glides back to
## the raised helm boom on release.
var helm_eyes := false
## Eye height for the OAR BENCH first-person view (the C — take an
## oar seat): parked this far ABOVE the head node, RAISED higher than
## the tiller eyes so the view looks over the bow, the oar entries
## and the crew from the bench. Tunable from the editor.
@export var oar_eye_height := 1.55
## OAR BENCH: while true (the controller sets it whenever the rider
## has taken an oar with the C toggle) the camera LIVES at the rowing
## bench — the raised rower's-eyes view. The helm boom and the
## underway tiller-eyes are parked while this is on: the camera rides
## the seat, not the hull's motion.
var oar_mode := false
var _helm_stash := 0.0
## Helm underway camera: while seated and the hull has way on (the
## controller raises this with hull speed) the camera leans into the
## helmsman's eyes — the same first-person tiller view as holding the
## camera toggle. At rest the helm boom rules again.
var helm_underway := 0.0
## Swim camera lift (user request): while the hero swims, the camera
## rides this much HIGHER above the default head height, looking
## slightly down at him — so he reads IN the water (submerged to the
## chest, wake breaking around him) instead of perched on top of it.
## Controller sets `swim_lift` 0..1; this is the raised height (m).
@export var swim_cam_lift := 1.1
## 0..1, driven by the controller while the swim clip owns the body.
var swim_lift := 0.0
## Stroke-synced dip state (fed by the boat's oar strokes): time since
## the last pull, its side, its effort, and a count (for verification).
var _stroke_t := 99.0
var _stroke_side := 0.0
var _stroke_effort := 0.0
var stroke_dips := 0
## Camera distance range for zooming.
@export var zoom_min := 0.0  # fully zoomed in = first person
@export var zoom_max := 6.0
@export var zoom_start := 4.0
## Distance change per mouse-wheel notch.
@export var zoom_step := 0.5
## Zoom speed (m/s) for D-pad and right-stick zooming.
@export var zoom_stick_speed := 3.0
## How fast the boom eases towards the zoom target (1/s).
@export var zoom_smooth_speed := 10.0
## How fast the camera swings back behind the body while moving (1/s).
@export var follow_speed := 5.0
## The character is hidden when the camera is closer than this (first person).
@export var first_person_hide_threshold := 0.5
## Model node to hide in first person.
@export var model_path := NodePath("../Model")

@export var mouse_sensitivity := 2.0  # divided by 1000 in _ready
@export var joystick_sensitivity := 2.8  # radians per second at full stick deflection
@export var joystick_power := 1.6  # > 1.0 gives finer control near stick center
@export var invert_y := false
@export var y_limit := 85.0  # pitch limit in degrees
## If true the character always turns with the camera. If false, the body only
## turns while the character is actually moving (follow-camera orbit style).
@export var body_yaw_follows_camera := false

var rot := Vector3()
## Yaw currently applied to the body (kept in sync by sync_body_yaw).
var _body_yaw := 0.0
var _zoom_target: float
## Last third-person zoom target, restored by the camera toggle.
var _tp_zoom := 4.0
## The user's configured third-person follow behavior.
var _tp_follow := false
## Set by the controller: is the character currently moving on the ground?
var _body_moving := false
## Set by the controller: is the character moving towards the camera?
var _body_backpedaling := false
## Free look input happened this frame?
var _free_looking := false
## Seconds of free-look grace after mouse movement.
var _free_look_timer := 0.0

@onready var _model: Node3D = get_node_or_null(model_path)


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	mouse_sensitivity = mouse_sensitivity / 1000
	y_limit = deg_to_rad(y_limit)
	_body_yaw = get_owner().rotation.y
	_zoom_target = zoom_start
	_tp_zoom = zoom_start
	_tp_follow = body_yaw_follows_camera
	arm.spring_length = _zoom_target


# Called when there is an input event
func _input(event: InputEvent) -> void:
	# Mouse look (only if the mouse is captured).
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_camera(event.relative * mouse_sensitivity)
		# Recent mouse movement counts as free-looking too, so the camera
		# does not yank back behind the body mid-look.
		_free_look_timer = 0.4

	# Mouse wheel zoom: wheel up = closer, wheel down = further away.
	# In first person, wheeling out pops back to third person.
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_target = clampf(_zoom_target - zoom_step, zoom_min, zoom_max)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if is_first_person():
				_toggle_camera_mode()
			else:
				_zoom_target = clampf(_zoom_target + zoom_step, zoom_min, zoom_max)

	# Y / gamepad Y: swap between first and third person.
	if event.is_action_pressed("toggle_camera"):
		_toggle_camera_mode()


func is_first_person() -> bool:
	return _zoom_target <= 0.01 or helm_eyes or oar_mode


func _toggle_camera_mode() -> void:
	if is_first_person():
		_zoom_target = _tp_zoom
	else:
		_tp_zoom = _zoom_target
		_zoom_target = zoom_min


# Called every physics tick; right-stick look and zoom are analog.
func _physics_process(delta: float) -> void:
	_stroke_t += delta
	var stick := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	_free_look_timer = maxf(0.0, _free_look_timer - delta)
	_free_looking = stick.length_squared() > 0.0 or _free_look_timer > 0.0
	if _free_looking:
		# Curve the deflection for finer control near the stick center.
		var scaled := Vector2(
				signf(stick.x) * pow(absf(stick.x), joystick_power),
				signf(stick.y) * pow(absf(stick.y), joystick_power))
		if Input.is_action_pressed("zoom_modifier"):
			# Right-stick zoom: hold R3, push the stick up/down; the
			# horizontal axis still turns the camera.
			_zoom_target = clampf(_zoom_target + scaled.y * zoom_stick_speed * delta,
					zoom_min, zoom_max)
			rotate_camera(Vector2(scaled.x * joystick_sensitivity * delta, 0.0))
		else:
			rotate_camera(scaled * joystick_sensitivity * delta)

	# Follow camera: swing back behind the body's back while it moves,
	# unless the player is actively looking around or backpedaling.
	if not body_yaw_follows_camera and _body_moving and not _free_looking \
			and not _body_backpedaling:
		# At the helm the chase is deliberately slower: the view lags
		# behind the hull's heading through turns and eases back lazily
		# after free look — the cinematic sail. With way on the lag
		# swells: the faster the hull pulls, the more the view trails
		# (full boost chases at roughly half the calm rate).
		var fs := (helm_follow_speed if helm_boom > 0.0 else follow_speed)
		fs *= (1.0 - 0.5 * clampf(helm_surge, 0.0, 1.0))
		rot.y = lerp_angle(rot.y, _body_yaw, minf(1.0, fs * delta))

	rotation.x = rot.x
	rotation.y = rot.y - _body_yaw
	# Cinematic helm drift: a slow handheld sway layered on the boom
	# camera. Applied FRESH each frame after the look state is resolved
	# (never fed back into rot), so it cannot accumulate or fight the
	# follow. Disabled at the eyes — first person stays steady.
	if (helm_boom > 0.0 or oar_mode) and not helm_eyes \
			and helm_underway <= 0.12:
		var t := Time.get_ticks_msec() / 1000.0
		# The handheld sway swells with hull speed (controller feeds
		# helm_surge): boosting runs the sway nearly 3x wider and adds
		# a fast tremor — the flame-in-the-wind feel at full surge.
		var surge := clampf(helm_surge, 0.0, 1.0)
		rotation.y += 0.045 * (1.0 + 1.8 * surge) * sin(t * 0.31 + 1.3)
		rotation.x += 0.02 * (1.0 + 1.8 * surge) * sin(t * 0.23)
		rotation.y += 0.012 * surge * sin(t * 2.1)
		rotation.x += 0.008 * surge * sin(t * 1.7 + 0.9)
		# Tiller resistance pull-back: hard rudder at speed leans the
		# view back against the turn (the load already eases to zero
		# as the rudder centers, so this fades with the effort).
		rotation.x += 0.03 * clampf(helm_pull, 0.0, 1.0)
		# Stroke-synced dip-and-swell: each oar pull dips the view
		# gently — fast settle, slow swell back up — with a lean toward
		# the pulling oar. Pure render layer, exactly like the drift:
		# it never feeds back into rot, and it's off at the eyes.
		if _stroke_t < 1.2:
			var attack := clampf(_stroke_t / 0.12, 0.0, 1.0)
			var decay := exp(-maxf(_stroke_t - 0.12, 0.0) / 0.35)
			# Effort floors at half depth so the idle beat (oars dragging
			# at zero throttle) still breathes with the rhythm.
			var pulse := attack * decay * (0.5 + 0.5 * _stroke_effort)
			rotation.x -= 0.010 * pulse
			rotation.z -= 0.006 * _stroke_side * pulse

	_update_arm(delta)


func _update_arm(delta: float) -> void:
	# OAR BENCH override: while the rider has taken an oar, the camera
	# is the raised rower's-eyes view — the "C — take an oar"
	# position. First person at the bench, model hidden, no helm boom,
	# no underway tilt: the seat owns the view, whatever the hull is
	# doing. Stroke-synced dips still breathe the frame (see
	# helm_stroke / the dip block below).
	if oar_mode:
		if _helm_stash == 0.0 and _zoom_target > 0.01:
			_helm_stash = _tp_zoom
		_zoom_target = zoom_min
		arm.spring_length = lerpf(arm.spring_length, zoom_min,
				minf(1.0, zoom_smooth_speed * delta))
		arm.position = arm.position.lerp(
				Vector3(0.0, oar_eye_height, 0.0),
				minf(1.0, zoom_smooth_speed * delta))
		if _model:
			_model.visible = false
		return
	# Helm override: while sailing, the camera is fully scripted —
	# the raised behind-back boom at rest, the tiller eyes (the same
	# view as the C hold) underway, or the tiller eyes when the toggle
	# is held. Zoom controls are idled; freed on landing.
	if helm_boom > 0.0:
		if helm_eyes:
			# --- Held toggle: the tiller eyes (interrupts everything) -
			if _helm_stash == 0.0 and _zoom_target > 0.01:
				_helm_stash = _tp_zoom
			_zoom_target = zoom_min
			arm.spring_length = lerpf(arm.spring_length, zoom_min,
					minf(1.0, zoom_smooth_speed * delta))
			arm.position = arm.position.lerp(
					Vector3(0.0, helm_eye_height, 0.0),
					minf(1.0, zoom_smooth_speed * delta))
			if _model:
				_model.visible = false
			return
		if helm_underway > 0.12:
			# --- Underway: the tiller eyes --------------------------------
			# Hull moving: the camera leans into the helmsman's eyes —
			# first-person at the raised tiller, the same view as
			# holding the camera toggle — so the bow and the water
			# ahead fill the frame while she has way on.
			if _helm_stash == 0.0 and _zoom_target > 0.01:
				_helm_stash = _tp_zoom
			_zoom_target = zoom_min
			arm.spring_length = lerpf(arm.spring_length, zoom_min,
					minf(1.0, zoom_smooth_speed * delta))
			arm.position = arm.position.lerp(
					Vector3(0.0, helm_eye_height, 0.0),
					minf(1.0, zoom_smooth_speed * delta))
			if _model:
				_model.visible = false
			return
		if _helm_stash > 0.0:
			# Leaving the eyes: restore zoom + the model.
			_zoom_target = _helm_stash
			_helm_stash = 0.0
			if _model:
				_model.visible = true
		arm.spring_length = lerpf(arm.spring_length, helm_boom,
				minf(1.0, zoom_smooth_speed * delta))
		arm.position = arm.position.lerp(
				Vector3(0.0, helm_height, 0.0),
				minf(1.0, zoom_smooth_speed * delta))
		if _model:
			_model.visible = true
		return
	helm_underway = 0.0
	if _helm_stash > 0.0:
		# Left a scripted seat without an explicit restore (defensive
		# one-shot): give the stashed third-person zoom back here too,
		# or the walk camera stays stuck in first person.
		_zoom_target = _helm_stash
		_helm_stash = 0.0
	# The swim lift: while swimming the arm rides up (and the boom
	# eases there), so the hero reads IN the water, not on it.
	arm.position = arm.position.lerp(
			Vector3(0.0, swim_lift * swim_cam_lift, 0.0),
			minf(1.0, zoom_smooth_speed * delta))
	arm.spring_length = lerpf(arm.spring_length, _zoom_target,
			minf(1.0, zoom_smooth_speed * delta))
	# Fade the shoulder offset out as the camera moves into first person.
	arm.position.x = shoulder_offset * clampf(arm.spring_length, 0.0, 1.0)
	# Hide the character when the camera is basically inside the head.
	if _model:
		_model.visible = arm.spring_length > first_person_hide_threshold
	# FPS-style look (body turns with the camera) whenever the camera is
	# effectively at the head, no matter how it got there.
	body_yaw_follows_camera = _tp_follow or arm.spring_length <= first_person_hide_threshold


func rotate_camera(look: Vector2) -> void:
	# Horizontal look (world-space yaw).
	rot.y -= look.x
	# Vertical look.
	var pitch_delta := look.y * (-1.0 if invert_y else 1.0)
	rot.x = clampf(rot.x - pitch_delta, -y_limit, y_limit)

	if body_yaw_follows_camera:
		sync_body_yaw(rot.y)


## Called by the controller: reports the body's current motion state so the
## camera knows when to swing back behind.
func set_body_moving(moving: bool, backpedaling := false) -> void:
	_body_moving = moving
	_body_backpedaling = backpedaling


## True while the player is actively looking around (stick held or recent
## mouse motion); the controller suppresses body auto-turning during this.
func is_free_looking() -> bool:
	return _free_looking


## Called by the controller whenever the body's yaw changed, so the camera
## keeps its world yaw stable while following.
func sync_body_yaw(yaw: float) -> void:
	_body_yaw = yaw
	get_owner().rotation.y = yaw
	rotation.y = rot.y - _body_yaw


## One rowing stroke, forwarded by the controller while sailing: the
## helm camera dips with the pull and leans toward the oar (render
## layer only — see the drift block in _physics_process).
func helm_stroke(side: int, effort: float) -> void:
	# The stroke dip breathes at the TILLER boom and at the OAR BENCH
	# (your own stroke dips the rower's view); silent at the eyes.
	if (helm_boom > 0.0 or oar_mode) and not helm_eyes:
		_stroke_t = 0.0
		_stroke_side = float(side)
		_stroke_effort = clampf(effort, 0.0, 1.0)
		stroke_dips += 1


## Leaving a scripted seat (oar bench / tiller eyes) for the WALK
## camera: restore the stashed third-person zoom and unhide the hero.
## (User report: deboarding while in the C view left the character in
## first person — the oar view had parked zoom at 0 and nobody handed
## the stash back.)
func restore_third_person() -> void:
	oar_mode = false
	if _helm_stash > 0.0:
		_zoom_target = _helm_stash
		_helm_stash = 0.0
	if _model:
		_model.visible = true


## Dismount/reset: drop every helm override at once AND return the
## camera to third person (the deboard/rescue path calls this once).
func clear_helm() -> void:
	helm_boom = 0.0
	helm_height = 0.0
	helm_eyes = false
	helm_underway = 0.0
	helm_pull = 0.0
	helm_surge = 0.0
	oar_mode = false
	restore_third_person()
