extends Node
## Boot hook (autoload): when the game is launched normally — a windowed
## run, not a headless harness — it spawns the title overlay over the
## real island. Headless runs spawn nothing: harnesses keep exercising
## the raw world exactly as before, with no menu and no input noise.
## The island (main scene) consults Boot.want_menu to decide whether it
## should wait for the menu (skip its own drone start, release the mouse
## to the menu) or run headless-style (own drone, captured mouse).

var want_menu := false


func _enter_tree() -> void:
	# Headless = automated harness run: no menu, no mouse juggling.
	if DisplayServer.get_name() == "headless":
		return
	want_menu = true
	# The overlay is added deferred so the island scene is already
	# becoming current when Title asks for its systems.
	call_deferred("_spawn_title")


func _spawn_title() -> void:
	# The intro cinematic plays first (skippable); the title menu spawns
	# the moment it ends or is skipped. The island loads invisibly
	# underneath — the video masks the world's boot cost.
	var intro := CanvasLayer.new()
	intro.set_script(load("res://Player/IntroVideo.gd"))
	get_tree().root.add_child(intro)
	await intro.finished

	var packed: PackedScene = load("res://Levels/Title/Title.tscn")
	if packed == null:
		return
	var overlay := packed.instantiate()
	overlay.set("as_overlay", true)
	get_tree().root.add_child(overlay)
