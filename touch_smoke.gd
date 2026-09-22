extends SceneTree

## TouchControls smoke test: instantiate the layer headless and make
## sure _build() runs clean (buttons created, HUD shift applied).

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== touch smoke ==")
	var fails := 0
	var tc: Node = load("res://Player/TouchControls.gd").new()
	root.add_child(tc)
	await process_frame
	await process_frame
	var buttons := 0
	for c in tc.get_children():
		if c is Button:
			buttons += 1
	print("buttons built: ", buttons)
	if buttons != 6:
		fails += 1
		print("FAIL expected 6 buttons")
	if float(load("res://Player/QuestBoard.gd").hud_y) != 64.0:
		fails += 1
		print("FAIL hud_y not applied")
	# Synthetic action round-trip: press + release jump.
	var ev := InputEventAction.new()
	ev.action = "jump"
	ev.pressed = true
	Input.parse_input_event(ev)
	await process_frame
	print("jump pressed: ", Input.is_action_pressed("jump"))
	if not Input.is_action_pressed("jump"):
		fails += 1
		print("FAIL synthetic jump not registered")
	print("RESULT fails=%d" % fails)
	quit(1 if fails > 0 else 0)
