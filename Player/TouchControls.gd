extends CanvasLayer
class_name TouchControls
## On-screen touch controls for phones/tablets (web + mobile builds).
## Built ONLY when the device reports a touchscreen — real desktops and
## laptops never see a pixel of this.
##
## LEFT HALF  — virtual joystick: drag anywhere on the lower-left to
##              walk (the ring is just a hint; it recenters under the
##              thumb). Start the drag high on the screen and the same
##              thumb also pitches the camera — one thumb can sail and
##              peek around. Drag up = look up, the right stick's
##              convention.
## RIGHT HALF — drag to look around, exactly like the right stick.
## BUTTONS    — JUMP (boards the longship too), ATK, RUN (tap to
##              latch), SEAT (row bench / tiller swap aboard), plus two
##              small pills up top: the elder's scroll and pause.
##
## Everything is wired as SYNTHETIC input through Input.parse_input_event
## / Input.action_press, so the game's own code (MovementController,
## QuestBoard, PauseMenu, the mouse-riding scroll) needs no changes.
##
## Spawned by L_Main; nothing else has to know it exists.

const INK := Color(0.98, 0.94, 0.82, 0.9)
const RING_FILL := Color(1, 1, 1, 0.10)
const RING_EDGE := Color(1, 1, 1, 0.35)
const KNOB_FILL := Color(1, 1, 1, 0.30)
const BTN_BG := Color(0.07, 0.06, 0.05, 0.5)
const BTN_EDGE := Color(0.75, 0.6, 0.25, 0.7)

## Synthetic action names (they exist in the project's InputMap).
const BTN_JUMP := &"jump"
const BTN_ATTACK := &"attack"
const BTN_SPRINT := &"sprint"
const BTN_CROUCH := &"crouch"
const BTN_SCROLL := &"toggle_scroll"
const BTN_PAUSE := &"ui_cancel"

## Fraction of screen height a left-half thumb must stay under to walk
## (above it, the same drag also pitches the camera).
const LOOK_LINE := 0.45
## Look-stick gain: full deflection ≈ 0.55 of the stick axis range.
const LOOK_GAIN := 0.55
## How many screen-heights of right-thumb drag map to full look axis.
const LOOK_TRAVEL := 0.14

var _ring: Control
var _knob: Control
var _ring_home := Vector2.ZERO
var _ring_r := 60.0
var _joy_id := -1            # finger owning the joystick
var _joy_center := Vector2.ZERO
var _look_id := -1           # finger owning camera look
var _look_last := Vector2.ZERO
var _look_v := Vector2.ZERO  # synthetic stick value fed every frame
var _joy_walk := Vector2.ZERO
var _sprint_on := false
var _sprint_btn: Button


static func wanted() -> bool:
	return DisplayServer.is_touchscreen_available()


func _ready() -> void:
	layer = 98
	# QuestBoard's scroll + hint (and the gold counter that follows it)
	# shift down clear of the top pills on phones.
	QuestBoard.hud_y = 64.0
	_build()


func _build() -> void:
	var vp := get_viewport().get_visible_rect().size
	_ring_r = clampf(vp.x * 0.055, 44.0, 64.0)

	# --- the joystick hint ring (lower-left) ---------------------------
	_ring = Control.new()
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.size = Vector2.ONE * _ring_r * 2.0
	_ring.draw.connect(_draw_ring)
	add_child(_ring)
	_knob = Control.new()
	_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_knob.size = _ring.size
	_knob.draw.connect(_draw_knob)
	add_child(_knob)
	_ring_home = Vector2(22.0 + _ring_r, vp.y - 22.0 - _ring_r)
	_park_ring()

	# --- action buttons (bottom-right cluster) --------------------------
	_btn(BTN_JUMP, "JUMP", Vector2(-100, -104), 86)
	_btn(BTN_ATTACK, "ATK", Vector2(-202, -76), 72)
	_btn(BTN_SPRINT, "RUN", Vector2(-110, -198), 64)
	_btn(BTN_CROUCH, "SEAT", Vector2(-198, -206), 64)
	# --- top-right pills: elder's scroll + pause -------------------------
	_btn(BTN_SCROLL, "scroll", Vector2(-118, 8), 100, 38)
	_btn(BTN_PAUSE, "| |", Vector2(-58, 8), 44, 38)


func _btn(action: StringName, label: String, pos: Vector2,
		w: float, h := -1.0) -> Button:
	var b := Button.new()
	b.text = label
	b.add_theme_font_size_override("font_size",
			22 if label.length() > 3 else 17)
	b.add_theme_color_override("font_color", INK)
	var sb := StyleBoxFlat.new()
	sb.bg_color = BTN_BG
	sb.set_corner_radius_all(40)
	sb.set_border_width_all(2)
	sb.border_color = BTN_EDGE
	for st in ["normal", "hover", "focus"]:
		b.add_theme_stylebox_override(st, sb)
	var sbp: StyleBoxFlat = sb.duplicate()
	sbp.bg_color = Color(0.25, 0.2, 0.12, 0.7)
	b.add_theme_stylebox_override("pressed", sbp)
	var vp := get_viewport().get_visible_rect().size
	b.position = vp + pos
	b.size = Vector2(w, h if h > 0.0 else w)
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.button_down.connect(_btn_down.bind(action))
	b.button_up.connect(_btn_up.bind(action))
	add_child(b)
	if action == BTN_SPRINT:
		_sprint_btn = b
	return b


## SPRINT latches (tap once to jog, tap again to stop) — holding three
## fingers to run is not a thing on a phone.
func _btn_down(action: StringName) -> void:
	if action == BTN_SPRINT:
		_sprint_on = not _sprint_on
		_action(action, _sprint_on)
		if _sprint_btn != null:
			_sprint_btn.modulate = (Color(1.5, 1.35, 0.85)
					if _sprint_on else Color(1, 1, 1))
	else:
		_action(action, true)


func _btn_up(action: StringName) -> void:
	if action != BTN_SPRINT:
		_action(action, false)


func _action(action: StringName, on: bool) -> void:
	if not InputMap.has_action(action):
		return
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = on
	Input.parse_input_event(ev)


# --- touch routing -----------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_touch_start(t)
		else:
			_touch_end(t)
	elif event is InputEventScreenDrag:
		_touch_drag(event as InputEventScreenDrag)


func _touch_start(t: InputEventScreenTouch) -> void:
	var vp := get_viewport().get_visible_rect().size
	if t.position.x < vp.x * 0.5 and _joy_id < 0 \
			and t.position.y > vp.y * LOOK_LINE:
		# Lower-left: the walking thumb — anywhere works.
		_joy_id = t.index
		_joy_center = t.position
		_ring.position = _joy_center - _ring.size * 0.5
		_knob.position = _ring.position
	elif _look_id < 0:
		# Anywhere else: the looking thumb.
		_look_id = t.index
		_look_last = t.position


func _touch_end(t: InputEventScreenTouch) -> void:
	if t.index == _joy_id:
		_joy_id = -1
		_joy_walk = Vector2.ZERO
		_move_axis(Vector2.ZERO)
		_park_ring()
	elif t.index == _look_id:
		_look_id = -1


func _touch_drag(d: InputEventScreenDrag) -> void:
	if d.index == _joy_id:
		var raw := d.position - _joy_center
		var rel := raw.limit_length(_ring_r)
		_knob.position = _joy_center + rel - _knob.size * 0.5
		# Walk: forward = stick up = negative screen y.
		_joy_walk = Vector2(rel.x / _ring_r, -rel.y / _ring_r)
		_move_axis(_joy_walk)
		# A thumb that STARTS high on the screen also pitches the
		# camera with the same drag (drag up = look up, the right
		# stick's convention) — one-thumb sailing.
		var vp := get_viewport().get_visible_rect().size
		if _joy_center.y < vp.y * LOOK_LINE:
			_look_v.y = clampf(raw.y / _ring_r, -1.0, 1.0) * LOOK_GAIN
	elif d.index == _look_id:
		var vp := get_viewport().get_visible_rect().size
		# The drag since the last event becomes the stick deflection;
		# it decays to zero when the thumb holds still (in _process).
		_look_v.x = clampf((d.position.x - _look_last.x)
				/ (vp.y * LOOK_TRAVEL), -1.0, 1.0) * LOOK_GAIN
		_look_v.y = clampf((d.position.y - _look_last.y)
				/ (vp.y * LOOK_TRAVEL), -1.0, 1.0) * LOOK_GAIN
		_look_last = d.position


func _park_ring() -> void:
	_ring.position = _ring_home
	_knob.position = _ring_home


func _process(_delta: float) -> void:
	# The synthetic look stick decays to zero the moment no fresh drag
	# events arrive (thumb parked) — otherwise the camera would creep.
	_stick_look(_look_v)
	_look_v = _look_v.lerp(Vector2.ZERO, 0.5)


# --- synthetic input -----------------------------------------------------------

## Walk rides the real InputMap actions so touch and keys compose
## (touch forward + keyboard right = diagonal, same as two pads).
func _move_axis(v: Vector2) -> void:
	_axis_pair("move_right", "move_left", v.x)
	_axis_pair("move_back", "move_forward", v.y)


func _axis_pair(pos: StringName, neg: StringName, v: float) -> void:
	_axis_val(pos, maxf(v, 0.0))
	_axis_val(neg, maxf(-v, 0.0))


func _axis_val(action: StringName, v: float) -> void:
	if not InputMap.has_action(action):
		return
	if v <= 0.001:
		if Input.is_action_pressed(action):
			Input.action_release(action)
		return
	Input.action_press(action, v)


## Camera look through the RIGHT-STICK actions — the head's analog
## look path (power curve, pitch clamp, follow-camera grace) applies.
func _stick_look(v: Vector2) -> void:
	_axis_pair("look_right", "look_left", v.x)
	_axis_pair("look_down", "look_up", v.y)


# --- drawing -----------------------------------------------------------------

func _draw_ring() -> void:
	var c := Vector2.ONE * _ring_r
	_ring.draw_circle(c, _ring_r, RING_FILL)
	_ring.draw_arc(c, _ring_r, 0.0, TAU, 40, RING_EDGE, 2.0)


func _draw_knob() -> void:
	_knob.draw_circle(Vector2.ONE * _ring_r, _ring_r * 0.42, KNOB_FILL)
