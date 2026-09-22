class_name PauseMenu
extends CanvasLayer
## The island's pause menu. Esc (keyboard) or Start (gamepad) opens
## it: the world freezes, the mouse is released, and the player gets
## Resume / Quit choices — instead of the old template behavior
## (Esc silently killed the whole game, player-reported "ends the
## game somehow although it doesn't say").
##
## Spawned by L_Main at boot. It stays inert while the title screen
## owns the game (the hero reports menu_frozen), so the title's own
## Esc-to-skip keeps working; once the hero is live, Esc belongs to
## the pause menu.

const PAUSE_ACTIONS := ["ui_cancel", "start_button"]

var _open := false
var _dim: ColorRect
var _box: VBoxContainer
var _resume_btn: Button
var _title_btn: Button
var _quit_btn: Button
var _hint: Label
## Guards a double-spawn while the title overlay is being re-added.
var _title_respawning := false


func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_start_action()
	_build()
	_hide_menu()


## The gamepad Start button: register the action if the project
## doesn't define one, so the pause menu works on controller even
## though the original template never mapped Start.
func _ensure_start_action() -> void:
	if InputMap.has_action("start_button"):
		return
	InputMap.add_action("start_button")
	var ev := InputEventJoypadButton.new()
	ev.button_index = JOY_BUTTON_START
	InputMap.action_add_event("start_button", ev)


func _build() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0.03, 0.04, 0.06, 0.62)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	_box = VBoxContainer.new()
	_box.set_anchors_preset(Control.PRESET_CENTER)
	_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_box.grow_vertical = Control.GROW_DIRECTION_BOTH
	_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_box.add_theme_constant_override("separation", 14)
	_dim.add_child(_box)

	var title := Label.new()
	title.text = "SEBLERSKERS"
	title.add_theme_font_size_override("font_size", 42)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(title)

	var sub := Label.new()
	sub.text = "— paused —"
	sub.add_theme_font_size_override("font_size", 20)
	sub.add_theme_color_override("font_color", Color(0.8, 0.72, 0.55))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(sub)

	_resume_btn = _mk_button("Resume  (Esc / B)")
	_resume_btn.pressed.connect(_close)
	_box.add_child(_resume_btn)

	_title_btn = _mk_button("Quit to Title")
	_title_btn.pressed.connect(_quit_to_title)
	_box.add_child(_title_btn)

	_quit_btn = _mk_button("Quit to Desktop")
	_quit_btn.pressed.connect(func() -> void: get_tree().quit())
	_box.add_child(_quit_btn)

	_hint = Label.new()
	_hint.text = "Esc or Start pauses • B or Esc resumes • fly safe"
	_hint.add_theme_font_size_override("font_size", 14)
	_hint.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(_hint)


func _mk_button(txt: String) -> Button:
	var b := Button.new()
	b.text = txt
	b.custom_minimum_size = Vector2(280.0, 44.0)
	b.add_theme_font_size_override("font_size", 20)
	return b

## The hero is found lazily through the "player" group (the controller
## registers itself there) — robust to boot order.
func _hero_busy() -> bool:
	var hero := get_tree().get_first_node_in_group("player")
	if hero == null:
		return true
	# The title screen owns the game until Set Sail.
	return bool(hero.get("menu_frozen"))


func _unhandled_input(event: InputEvent) -> void:
	# Gamepad Start always works (no Esc on a pad); Esc toggles too.
	# While the title owns the game, Esc is left unhandled so the
	# title's own skip handler keeps working.
	if not _open and _hero_busy():
		return
	for a in PAUSE_ACTIONS:
		if event.is_action_pressed(a):
			if _open:
				_close()
			else:
				_try_open()
			get_viewport().set_input_as_handled()
			return


func _try_open() -> void:
	if _hero_busy():
		return
	_open = true
	get_tree().paused = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	# The track steps aside while the menu owns the game.
	var music := get_tree().get_first_node_in_group("gameplay_music")
	if music != null:
		music.call("hush")
	_show_menu()


func _close() -> void:
	_open = false
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# Back to play: the track resumes where it left off.
	var music := get_tree().get_first_node_in_group("gameplay_music")
	if music != null:
		music.call("begin")
	_hide_menu()


## Back to the title over the LIVING island — no scene reload, no
## intro replay. The world keeps its state (weather, time of day),
## the hero freezes under the menu, and the save summary reads the
## freshest plunder: loot-then-quit shows updated numbers immediately.
func _quit_to_title() -> void:
	if _title_respawning:
		return
	_title_respawning = true
	_open = false
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_hide_menu()
	# The viking drone swells back up under the menu (title mood); the
	# in-game track steps aside for it.
	var drone := get_tree().get_first_node_in_group("music_drone")
	if drone != null:
		drone.call("swell_in")
	var music := get_tree().get_first_node_in_group("gameplay_music")
	if music != null:
		music.call("hush")
	# Same overlay chain as Boot — minus the intro, which the player
	# has already seen this session.
	var packed: PackedScene = load("res://Levels/Title/Title.tscn")
	if packed == null:
		return
	var overlay := packed.instantiate()
	overlay.set("as_overlay", true)
	get_tree().root.add_child.call_deferred(overlay)


func _show_menu() -> void:
	_dim.visible = true
	_resume_btn.grab_focus()


func _hide_menu() -> void:
	_dim.visible = false
