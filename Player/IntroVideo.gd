extends CanvasLayer
## The intro cinematic: plays the game's opening video full-screen before
## the title menu appears (Boot.gd spawns this first and awaits `finished`).
## A Skip button sits bottom-center; any key, click or gamepad button skips.
## The hero is frozen while it plays (the title keeps him frozen after),
## the mouse is freed for the button, and the island loads invisibly
## behind the video — the cinematics mask the world's boot cost.
##
## The source is imports/gameintrovideo.mov, transcoded to Ogg Theora
## (gameintrovideo.ogv) because that is the only container Godot decodes.

signal finished

const VIDEO := "res://imports/seblerskers_intro.ogv"
const INK := Color(0.98, 0.94, 0.82)      # the game's parchment tone
const FADE_OUT_S := 0.45

var _player: VideoStreamPlayer
var _skip: Button
var _bg: ColorRect
var _done := false


func _ready() -> void:
	layer = 120
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_freeze_hero(true)

	# Black backdrop behind the video (and during its fade-out).
	_bg = ColorRect.new()
	_bg.color = Color.BLACK
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	# The video, stretched edge to edge (480x272 is ~16:9; the window is
	# 16:9-ish, so the stretch is imperceptible).
	_player = VideoStreamPlayer.new()
	_player.stream = load(VIDEO)
	_player.expand = true
	# The video's own score rides hot — ducked so it sits like a
	# soundtrack, not a wall of sound (user: the opening war audio is
	# too loud).
	_player.volume_db = -8.0
	_player.set_anchors_preset(Control.PRESET_FULL_RECT)
	_player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_player)
	_player.finished.connect(_finish)

	# Skip, bottom center.
	_skip = Button.new()
	_skip.text = "Skip"
	_skip.add_theme_font_size_override("font_size", 22)
	_skip.add_theme_color_override("font_color", INK)
	_skip.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	_skip.add_theme_color_override("font_focus_color", Color(1, 1, 0.9))
	_skip.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_skip.offset_left = -80.0
	_skip.offset_right = 80.0
	_skip.offset_top = -66.0
	_skip.offset_bottom = -28.0
	_skip.pressed.connect(_finish)
	add_child(_skip)
	_skip.grab_focus()

	if _player.stream == null:
		# Missing/unimportable video: never trap the player on black.
		_finish.call_deferred()
	else:
		_player.play()


## Any key or gamepad button also skips (the button is the visible affordance).
func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed:
		_finish()
		return
	var btn := event as InputEventJoypadButton
	if btn != null and btn.pressed:
		_finish()
		return
	var mouse := event as InputEventMouseButton
	if mouse != null and mouse.pressed and not _skip.get_global_rect().has_point(
			_skip.get_global_mouse_position()):
		_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	_player.stop()
	_skip.visible = false
	finished.emit()
	# Dissolve the layer's CHILDREN (a CanvasLayer has no modulate of
	# its own), then free.
	var tw := create_tween()
	for child in [_bg, _player]:
		tw.parallel().tween_property(child, "modulate:a", 0.0, FADE_OUT_S)
	tw.tween_callback(queue_free)


## The hero stands down while the cinematic runs; the title menu (which
## spawns right after) keeps him frozen until Set Sail.
func _freeze_hero(frozen: bool) -> void:
	var players := get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		players[0].set("menu_frozen", frozen)
