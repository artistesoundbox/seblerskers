extends Node3D

#-----------------SCENE--SCRIPT------------------#
#    Close your game faster by clicking 'Esc'    #
#   Change mouse mode by clicking 'Shift + F1'   #
#------------------------------------------------#

@export var fast_close := true


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# Outpost islands across the sea: seeded terrain, real trimesh
	# collision, camps and outpost chests. Spawned first so their
	# collision exists while PropScatter's tail still counts chests.
	var isles := Node3D.new()
	isles.set_script(load("res://Player/NewIslands.gd"))
	add_child(isles)
	# The pause menu replaces the template's Esc-quits-everything:
	# Esc / Start freezes the world and offers Resume or Quit, with
	# the choice spelled out instead of a silent kill. Spawned FIRST
	# so it exists on every boot path (it stays inert while the title
	# screen owns the game).
	var pm := CanvasLayer.new()
	pm.set_script(load("res://Player/PauseMenu.gd"))
	add_child(pm)
	# Touch controls for phones/tablets (web + mobile builds): built
	# only when the device reports a touchscreen, so desktops never
	# see them. Also shifts the elder's scroll HUD clear of the pills.
	if load("res://Player/TouchControls.gd").call("wanted"):
		var tc := CanvasLayer.new()
		tc.set_script(load("res://Player/TouchControls.gd"))
		add_child(tc)
	# Title overlay active (a real game launch): leave the mouse to the
	# menu, let its camera take over, and let the drone's title level
	# stand until the handover ducks it to ambient.
	var boot := get_node_or_null("/root/Boot")
	if boot != null and boot.get("want_menu") == true:
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# The title's drone carries in: duck it to the island's ambient
	# bed. Launched straight into the island (no title)? Start it here
	# directly at ambient.
	var drones := get_tree().get_nodes_in_group("music_drone")
	if drones.is_empty():
		var drone := Node.new()
		drone.set_script(load("res://Player/VikingDrone.gd"))
		drone.set("start_ambient", true)
		get_tree().root.add_child.call_deferred(drone)
	else:
		drones[0].call("to_ambient")
	# Direct island boot: the in-game track plays from the first step.
	var music: Node = load("res://Player/GameplayMusic.gd").ensure(
			get_tree().root)
	if music != null:
		music.call("begin")
	
	if !OS.is_debug_build():
		fast_close = false
	
	if fast_close:
		print("** Fast Close enabled in the 'L_Main.gd' script **")
		print("** 'Esc' / Start pauses the game (no more instant quit) **")
		print("** 'Shift + F1' to release mouse **")
	
	set_process_input(fast_close)


func _input(event: InputEvent) -> void:
	# Esc no longer quits (the old template fast-close silently ended
	# the whole game — player-reported "ends the game somehow although
	# it doesn't say"). The PauseMenu owns Esc now: pause/resume.
	pass
	
	if event.is_action_pressed("change_mouse_input"):
		match Input.get_mouse_mode():
			Input.MOUSE_MODE_CAPTURED:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			Input.MOUSE_MODE_VISIBLE:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# Capture mouse if clicked on the game, needed for HTML5
# Called when an InputEvent hasn't been consumed by _input() or any GUI item
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT && event.pressed:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
