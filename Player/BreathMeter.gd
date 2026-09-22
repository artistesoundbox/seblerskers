class_name BreathMeter
extends CanvasLayer
## The diver's breath: a slim gauge at the bottom of the screen that
## only appears while the camera is under the surface. Drains left to
## right while diving, refills fast at the surface, and washes red as
## it nears empty — the warning to kick up before the sea pushes you
## up itself (the controller handles that; this is the readout).
##
## Spawned by MovementController at boot.

## Fill color when comfortably full.
const FULL_COLOR := Color(0.35, 0.8, 0.95)
## Fill color at empty.
const EMPTY_COLOR := Color(0.95, 0.3, 0.2)

var _bg: ColorRect
var _fill: ColorRect


func _ready() -> void:
	layer = 91
	_bg = ColorRect.new()
	_bg.color = Color(0.0, 0.0, 0.0, 0.4)
	_bg.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_bg.anchor_left = 0.5
	_bg.anchor_right = 0.5
	_bg.anchor_top = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left = -110.0
	_bg.offset_right = 110.0
	_bg.offset_top = -64.0
	_bg.offset_bottom = -57.0
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	_fill = ColorRect.new()
	_fill.position = Vector2(2, 2)
	_fill.size = Vector2(216, 5)
	_fill.color = FULL_COLOR
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.add_child(_fill)
	visible = false


## Render the current breath 0..1. `show` = camera is underwater.
func show_level(v: float, show: bool) -> void:
	visible = show
	if not show:
		return
	var f := clampf(v, 0.0, 1.0)
	_fill.color = EMPTY_COLOR.lerp(FULL_COLOR, f)
	_fill.size = Vector2(maxf(0.0, (_bg.size.x - 4.0) * f), 5.0)
