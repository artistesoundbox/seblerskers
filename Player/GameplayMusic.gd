class_name GameplayMusic
extends Node
## The island's melody: `imports/ingameaudio1.mp3` looping under
## gameplay — while the player owns control (walking, flying, sailing).
## Etiquette, mirroring the viking drone:
##   - title screen owns the game (menu_frozen): silent
##   - paused (PauseMenu): silent
##   - ending moment: faded out for the drone's swell
## The player calls begin() the instant Set Sail returns control
## (Title._finish_overlay / L_Main's direct-boot path both land there),
## so the track only ever plays inside real play.

const TRACK_PATH := "res://imports/ingameaudio1.mp3"
const PLAY_DB := -10.0   # present but under the SFX bed
const FADE_S := 1.6

var _player: AudioStreamPlayer
var _wanted := false
var _fading_out := false


func _ready() -> void:
	add_to_group("gameplay_music")
	_player = AudioStreamPlayer.new()
	var stream: AudioStream = load(TRACK_PATH)
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	_player.stream = stream
	_player.volume_db = -60.0
	add_child(_player)
	# A begin() that arrived before we were ready (cold-boot race)
	# is honored now.
	if _wanted:
		begin()


## Control has handed to the player: bring the track up. Safe to call
## before the node is ready (cold-boot ordering): the wish is latched
## and honored the moment _ready builds the player.
func begin() -> void:
	_wanted = true
	_fading_out = false
	if _player == null:
		return
	if not _player.playing:
		_player.play()
	var tw := create_tween()
	tw.tween_property(_player, "volume_db", PLAY_DB, FADE_S) \
			.set_ease(Tween.EASE_IN_OUT)


## The title/pause/ending owns the game: sink to silence (kept
## playing at -60 so the loop position survives a brief pause-menu dip
## and returns exactly where it left off).
func hush() -> void:
	_wanted = false
	if _player == null or not _player.playing:
		return
	_fading_out = false
	var tw := create_tween()
	tw.tween_property(_player, "volume_db", -60.0, FADE_S) \
			.set_ease(Tween.EASE_IN_OUT)


## The ending moment: slower, gentler fade — the score hands the
## stage to the drone's swell.
func fade_for_ending() -> void:
	_wanted = false
	if _player == null or not _player.playing:
		return
	_fading_out = true
	var tw := create_tween()
	tw.tween_property(_player, "volume_db", -60.0, 3.5) \
			.set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		if _fading_out:
			_fading_out = false
			_player.stop())


func is_audible() -> bool:
	return _wanted and _player != null and _player.playing \
			and _player.volume_db > -55.0


## Spawned once on the tree ROOT (survives scene changes); safe to call
## from any boot path. Returns the live node.
static func ensure(root: Node) -> Node:
	if root == null:
		return null
	for n in root.get_children():
		if n.is_in_group("gameplay_music"):
			return n
	var m := Node.new()
	m.set_script(load("res://Player/GameplayMusic.gd"))
	# During scene setup the root rejects immediate children — defer
	# then (the latched _wanted in begin() covers the gap).
	if root.is_node_ready():
		root.add_child(m)
	else:
		root.add_child.call_deferred(m)
	return m
