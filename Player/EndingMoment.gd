class_name EndingMoment
extends CanvasLayer
## The saga's final goal, made real: the moment the Horn is recovered,
## every chest is emptied and both races carry a medal, the game
## gathers itself into a short cinematic — letterbox bars, a slow
## orbit around the hero standing where the saga closed, the viking
## drone swelling back up, and the credits rolling over the living
## island. Any key, click or gamepad button lets it go.
##
## Plays once per saga: user://ending.cfg records it, Restart Saga
## wipes the file through the ledger's SAVE_FILES (so a fresh saga
## can earn it again), and an Undo Restart brings the memory back.
## Spawned on demand by the QuestBoard's poll.

const ENDING_PATH := "user://ending.cfg"

const BAR_TIME := 0.9
const TITLE_TIME := 4.0
const SCROLL_TIME := 46.0
const MIN_SHOW := 3.0  # no accidental instant skips

const GOLD := Color(1.0, 0.82, 0.35)
const PARCHMENT := Color(0.93, 0.88, 0.78)
const DIM := Color(0.72, 0.66, 0.55)

var _hero: Node3D
var _head_cam: Camera3D
var _cam: Camera3D
var _orbit_a := 0.0
var _orbit_r := 16.0
var _orbit_h := 10.0
var _bars_top: ColorRect
var _bars_bot: ColorRect
var _title: Label
var _scroller: VBoxContainer
var _shown_t := 0.0
var _finishing := false
var _hud_was: Array = []


static func was_shown() -> bool:
	var cf := ConfigFile.new()
	if cf.load(ENDING_PATH) != OK:
		return false
	return bool(cf.get_value("ending", "shown", false))


static func mark_shown() -> void:
	var cf := ConfigFile.new()
	cf.set_value("ending", "shown", true)
	cf.save(ENDING_PATH)


func _ready() -> void:
	if was_shown():
		queue_free()
		return
	layer = 80
	_build()
	_take_stage()
	mark_shown()
	var drone := get_tree().get_first_node_in_group("music_drone")
	if drone != null and drone.has_method("swell_in"):
		drone.call("swell_in")
	# The in-game track yields the stage to the drone's swell.
	var music := get_tree().get_first_node_in_group("gameplay_music")
	if music != null and music.has_method("fade_for_ending"):
		music.call("fade_for_ending")


func _build() -> void:
	_bars_top = ColorRect.new()
	_bars_top.color = Color.BLACK
	_bars_top.anchor_left = 0.0
	_bars_top.anchor_right = 1.0
	_bars_top.anchor_top = 0.0
	_bars_top.anchor_bottom = 0.0
	_bars_top.offset_bottom = 0.0
	add_child(_bars_top)
	_bars_bot = ColorRect.new()
	_bars_bot.color = Color.BLACK
	_bars_bot.anchor_left = 0.0
	_bars_bot.anchor_right = 1.0
	_bars_bot.anchor_top = 1.0
	_bars_bot.anchor_bottom = 1.0
	_bars_bot.offset_top = 0.0
	add_child(_bars_bot)

	_title = Label.new()
	_title.text = "THE SAGA IS TOLD"
	_title.add_theme_font_size_override("font_size", 52)
	_title.add_theme_color_override("font_color", GOLD)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_title.anchor_left = 0.0
	_title.anchor_right = 1.0
	_title.offset_top = 140.0
	_title.offset_bottom = 210.0
	_title.modulate.a = 0.0
	add_child(_title)

	_scroller = VBoxContainer.new()
	_scroller.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroller.alignment = BoxContainer.ALIGNMENT_END
	_scroller.add_theme_constant_override("separation", 10)
	add_child(_scroller)
	_add_credit("SEBLERSKERS", 46, GOLD)
	_add_credit("the north-sea saga of one winged warrior", 22, DIM)
	_add_credit("", 12, DIM)
	_add_credit("the Horn recovered from the deepest hoard", 24, PARCHMENT)
	_add_credit("every chest on the island emptied", 24, PARCHMENT)
	_add_credit("a medal from the sky course", 24, PARCHMENT)
	_add_credit("a medal from the coastal regatta", 24, PARCHMENT)
	_add_credit("", 12, DIM)
	_add_credit("the village stood through the night raids", 22, DIM)
	_add_credit("the elder's errands, all answered", 22, DIM)
	_add_credit("", 12, DIM)
	_add_credit("the island keeps its sagas", 22, DIM)
	_add_credit("— and its sagas keep their island —", 22, DIM)
	_add_credit("", 12, DIM)
	_add_credit("MANTECA STUDIOS", 30, GOLD)
	# Start the scroll parked below the screen; the tween carries it up.
	_scroller.reset_size()
	await get_tree().process_frame
	_scroller.position.y = get_viewport().get_visible_rect().size.y

	var tw := create_tween()
	tw.tween_property(_bars_top, "offset_bottom", 90.0, BAR_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(_bars_bot, "offset_top", -90.0, BAR_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_title, "modulate:a", 1.0, 1.2)
	tw.tween_interval(TITLE_TIME)
	tw.tween_property(_title, "modulate:a", 0.0, 1.5)
	tw.tween_callback(_start_scroll)


func _add_credit(txt: String, size: int, col: Color) -> void:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.modulate.a = 0.0
	_scroller.add_child(l)


func _start_scroll() -> void:
	var tw := create_tween()
	tw.set_parallel(true)
	for c in _scroller.get_children():
		var l := c as Label
		tw.tween_property(l, "modulate:a", 1.0, 1.0)
	var travel := _scroller.size.y + 220.0
	tw.tween_property(_scroller, "position:y", -travel, SCROLL_TIME) \
		.set_trans(Tween.TRANS_LINEAR)
	tw.chain().tween_callback(_finish)


## The stage: freeze the hero, hide the HUD chrome, take the camera
## into a slow orbit around him.
func _take_stage() -> void:
	for p in get_tree().get_nodes_in_group("player"):
		_hero = p as Node3D
		_hero.set("menu_frozen", true)
		break
	for qb in get_tree().get_nodes_in_group("quest_board"):
		var hud: CanvasLayer = qb.get("_hud")
		if hud != null:
			_hud_was.append(hud)
			hud.visible = false
	if _hero != null:
		var head = _hero.get("head")
		if head != null:
			_head_cam = head.get("cam") as Camera3D
		_cam = Camera3D.new()
		_cam.fov = 55.0
		_cam.current = true
		add_child(_cam)
		_place_cam()


func _place_cam() -> void:
	if _hero == null or _cam == null:
		return
	var t := _hero.global_position
	_cam.global_position = t + Vector3(
		sin(_orbit_a) * _orbit_r, _orbit_h, cos(_orbit_a) * _orbit_r)
	_cam.look_at(t + Vector3(0.0, 2.0, 0.0))


func _physics_process(delta: float) -> void:
	_shown_t += delta
	_orbit_a += delta * 0.045
	_place_cam()


func _unhandled_input(event: InputEvent) -> void:
	if _finishing or _shown_t < MIN_SHOW:
		return
	var press := false
	if event is InputEventKey:
		press = event.is_pressed()
	elif event is InputEventMouseButton:
		press = event.is_pressed()
	elif event is InputEventJoypadButton:
		press = event.is_pressed()
	elif event is InputEventJoypadMotion:
		press = event.axis_value > 0.6
	if press:
		_finish()


func _finish() -> void:
	if _finishing:
		return
	_finishing = true
	var tw := create_tween()
	tw.tween_property(_bars_top, "modulate:a", 0.0, 1.2)
	tw.parallel().tween_property(_bars_bot, "modulate:a", 0.0, 1.2)
	tw.parallel().tween_property(_title, "modulate:a", 0.0, 1.2)
	tw.parallel().tween_property(_scroller, "modulate:a", 0.0, 1.2)
	tw.tween_callback(_release)


## Hand the stage back: camera to the hero's head, control restored,
## HUD chrome visible again, then self-destruct.
func _release() -> void:
	if _head_cam != null:
		_head_cam.current = true
	if _hero != null:
		_hero.set("menu_frozen", false)
	for hud in _hud_was:
		(hud as CanvasLayer).visible = true
	queue_free()
