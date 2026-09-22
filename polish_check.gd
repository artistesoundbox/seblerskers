extends SceneTree

## Post-polish verification for the four requested fixes:
##  1. dive site: a real deep-water wreck with sunken chests
##  2. oar-bench camera: the C toggle moves the camera to the bench
##     (raised rower's eyes) and back to the tiller rig
##  3. regatta readability: numbered marks, START banner, idle arrow
##  4. rings readability: numbered rings, START gate, light pillars
## Boots the real world headless, waits for the scatter, boards the
## hero, toggles the seats, and checks every marker exists.

var _fails := 0


func _check(name: String, ok: bool, detail := "") -> void:
	if ok:
		print("  ok   %s" % name)
	else:
		_fails += 1
		print("  FAIL %s %s" % [name, detail])


func _wait(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await physics_frame
		t += 1.0 / 60.0


func _find_by_script(node: Node, tail: String) -> Node:
	if node.get_script() != null \
			and str((node.get_script() as Script).resource_path).ends_with(tail):
		return node
	for c in node.get_children():
		var f := _find_by_script(c, tail)
		if f != null:
			return f
	return null


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== post-polish harness ==")
	var world: Node = (load("res://Levels/Main/L_Main.tscn") as PackedScene).instantiate()
	root.add_child(world)
	var scatter := _find_by_script(world, "PropScatter.gd")
	var guard := 0
	while (scatter == null or not bool(scatter.get("setup_done"))) \
			and guard < 2400:
		await physics_frame
		guard += 1
		if scatter == null:
			scatter = _find_by_script(world, "PropScatter.gd")
	_check("world placed", scatter != null and bool(scatter.get("setup_done")))
	if scatter == null:
		print("RESULT fails=%d" % _fails)
		quit(1)
		return
	await _wait(1.0)

	# --- 1. the dive site ------------------------------------------------
	var wreck := world.find_child("DiveWreck", true, false) as Node3D
	_check("dive wreck exists", wreck != null)
	var sea: float = scatter.get("sea_level")
	if wreck != null:
		var depth := sea - wreck.global_position.y
		_check("wreck sits deep", depth > 3.0, "depth=%.1f" % depth)
		var chests := 0
		for c in wreck.get_children():
			var cs := c.get_script() as Script
			if cs != null and cs.resource_path.ends_with("TreasureChest.gd"):
				chests += 1
		_check("wreck carries sunken chests", chests >= 1, "chests=%d" % chests)

	# --- 2. the regatta markers -------------------------------------------
	var race := _find_by_script(world, "SailRace.gd")
	_check("regatta live", race != null)
	if race != null:
		var buoys: Array = race.get("_buoys")
		_check("buoys built", buoys.size() >= 5, "n=%d" % buoys.size())
		var start_found := false
		var nums := 0
		for bd in buoys:
			var b: Node3D = bd.node
			for c in b.get_children():
				if c is Label3D:
					if (c as Label3D).text == "START":
						start_found = true
					else:
						nums += 1
		_check("START banner on mark 1", start_found)
		_check("numbers on the marks", nums >= buoys.size(), "n=%d" % nums)
		await _wait(0.5)
		var ptr: MeshInstance3D = race.get("_pointer")
		_check("idle arrow points at the start", ptr != null and ptr.visible)
		# The course FACTS, from the live world (the user asked: what is
		# the trajectory of the regatta race?). Marks in order with legs.
		var pts := PackedVector2Array()
		for bd in buoys:
			var bn: Node3D = bd.node
			pts.append(Vector2(bn.position.x, bn.position.z))
		var total := 0.0
		for i in pts.size():
			var nxt := pts[(i + 1) % pts.size()]
			total += pts[i].distance_to(nxt)
			print("   regatta mark %d at (%.0f, %.0f) — leg %.0f m"
					% [i + 1, pts[i].x, pts[i].y, pts[i].distance_to(nxt)])
		print("   regatta course: ~%.0f m around %d marks"
				% [total, pts.size()])

	# --- 3. the rings markers ---------------------------------------------
	var course := _find_by_script(world, "RaceCourse.gd")
	_check("rings course live", course != null)
	if course != null:
		var rings: Array = course.get("_rings")
		_check("rings built", rings.size() >= 3, "n=%d" % rings.size())
		var pillars := 0
		var start_found := false
		for r in rings:
			var ring: Node3D = r
			for c in ring.get_children():
				if c is MeshInstance3D and (c as MeshInstance3D).has_meta("pillar"):
					pillars += 1
				if c is Label3D and (c as Label3D).text == "START":
					start_found = true
		_check("rings carry light pillars", pillars == rings.size(),
				"p=%d of %d" % [pillars, rings.size()])
		_check("rings START label", start_found)
		await _wait(0.5)
		var ptr2: MeshInstance3D = course.get("_pointer")
		_check("ring idle arrow visible", ptr2 != null and ptr2.visible)

	# --- 4. the oar-bench camera ------------------------------------------
	var heroes := get_nodes_in_group("player")
	_check("hero found", not heroes.is_empty())
	if heroes.is_empty():
		print("RESULT fails=%d" % _fails)
		quit(1)
		return
	var hero: Node = heroes[0]
	var boat := get_first_node_in_group("sailboat") as Node3D
	_check("flagship present", boat != null)
	if boat != null:
		hero.global_position = boat.global_position + Vector3(3.0, 2.5, 0.0)
		hero.velocity = Vector3.ZERO
		await physics_frame
		hero.call("_sail_try_board")
		await _wait(1.0)
		_check("boarded", bool(hero.get("sailing")))
		if bool(hero.get("sailing")):
			var head: Node = hero.get("head")
			var arm: SpringArm3D = head.get("arm")
			# BOARDING DEFAULT (user request): the oar BENCH is where the
			# camera lives the moment you hop aboard; C swaps up to the
			# tiller. The old "command seat on board" is gone.
			_check("boarded at the oar bench", not bool(boat.get("_commander")))
			_check("bench default: oar cam on", bool(head.get("oar_mode")))
			_check("bench default: first person",
					float(arm.spring_length) < 0.35,
					"len=%.2f" % arm.spring_length)
			_check("bench default: raised eyes",
					absf(arm.position.y - float(head.get("oar_eye_height"))) < 0.2,
					"y=%.2f want=%.2f" % [arm.position.y,
					float(head.get("oar_eye_height"))])
			var mdl: Node3D = head.get("_model")
			_check("bench default: model hidden", mdl == null or not mdl.visible)
			# C — take the helm: up to the tiller rig.
			boat.call("set_commander", true)
			await _wait(0.5)
			_check("helm again: oar cam off", not bool(head.get("oar_mode")))
			_check("helm again: boom back",
					float(head.get("helm_boom")) > 0.0
					and absf(arm.spring_length - 4.2) < 0.5,
					"len=%.2f" % arm.spring_length)
			# And back DOWN to the bench: the round trip ("C toggle rides
			# the seat").
			boat.call("set_commander", false)
			await _wait(0.5)
			_check("bench again: oar cam on", bool(head.get("oar_mode")))
			# Boarding default itself: a FRESH board lands at the bench.
			boat.call("disembark")
			await _wait(0.5)
			hero.call("_sail_try_board")
			await _wait(0.5)
			_check("fresh board: oar bench default",
					bool(hero.get("sailing"))
					and not bool(boat.get("_commander")))
			_check("fresh board: oar cam on", bool(head.get("oar_mode")))
			# DEBOARD FROM THE C VIEW (user report): hopping off must
			# return the WALK camera to third person automatically —
			# not leave the hero stuck in the rower's first person.
			boat.call("disembark")
			await _wait(0.5)
			_check("deboard: walk camera not first person",
					not bool(head.call("is_first_person")))
			_check("deboard: third-person boom restored",
					float(arm.spring_length) > 2.0,
					"len=%.2f" % arm.spring_length)
			# The deboard above went through boat.disembark() directly
			# (the harness has no input actions), so the cooldown was
			# not armed by that path — verify the GATE itself: the timer
			# runs down and the board press path reads it.
			hero.set("_sail_board_rearm", 1.2)
			await _wait(0.3)
			var rearmed: float = float(hero.get("_sail_board_rearm"))
			_check("board cooldown gate runs down",
					rearmed > 0.5 and rearmed < 1.2, "t=%.2f" % rearmed)
			# ... and board again for the sail checks below.
			hero.call("_sail_try_board")
			await _wait(0.5)
			# THE SAIL BLOCKED THE VIEW (user report): while rowing, the
			# canvas must stay furred even at full boost; at the tiller
			# the same boost unrolls it.
			boat.set("_boost_amt", 1.0)
			for k in 6:
				boat.call("_update_sail", 0.05)
			var cloth: Node3D = boat.get("_sail_node")
			_check("rowing: sail stays furred",
					cloth == null or not bool(cloth.visible))
			boat.call("set_commander", true)
			await _wait(0.2)
			for k in 40:
				boat.call("_update_sail", 0.05)
			_check("at tiller: sail unfurls on boost",
					cloth != null and bool(cloth.visible))
			boat.set("_boost_amt", 0.0)

	# --- 5. ring triggers listen for the HERO (layer 2) -------------------
	var course2 := _find_by_script(world, "RaceCourse.gd")
	if course2 != null:
		var areas: Array = course2.get("_areas")
		var bad := 0
		for a in areas:
			if (a as Area3D).collision_mask != 2:
				bad += 1
		_check("ring triggers hear the player (mask 2)",
				bad == 0, "bad=%d of %d" % [bad, areas.size()])

	# --- 6. the elder's scroll hint -----------------------------------------
	var qboard := get_first_node_in_group("quest_board")
	_check("elder's scroll live", qboard != null)
	if qboard != null:
		var hint: Label = qboard.get("_hint")
		_check("toggle hint painted on the rolled bar",
				hint != null and hint.visible)
		# The new scroll.png art (324x406): text must sit inside the
		# MEASURED writing band — nine-patch margins clear the rolled
		# edges, the box insets clear the decorated bands (user report:
		# text too high, overlapping the margins).
		var sc: NinePatchRect = qboard.get("_scroll")
		_check("nine-patch margins match the new art",
				sc != null and float(sc.patch_margin_top) >= 90.0
				and float(sc.patch_margin_bottom) >= 80.0
				and float(sc.patch_margin_left) >= 90.0)
		var bx: Control = qboard.get("_box")
		_check("text sits inside the writing band",
				bx != null and float(bx.offset_top) >= 90.0
				and float(bx.offset_bottom) <= -110.0
				and float(bx.offset_left) >= 48.0
				and float(bx.offset_right) <= -48.0)
		# The gold status banner must center OUTSIDE the scroll's strip
		# (user report: the scroll overlapped the status text).
		var ann: Label = qboard.get("_announce")
		_check("status banner clears the scroll",
				ann != null and float(ann.offset_right) <= -396.0)
		qboard.call("_toggle_scroll")
		_check("scroll toggles open (no mouse needed)",
				bool(qboard.get("_scroll_open")))
		qboard.call("_toggle_scroll")
		_check("scroll toggles closed", not bool(qboard.get("_scroll_open")))

	# --- 7. the flagship's hull contact -------------------------------------
	var boat7 := get_first_node_in_group("sailboat") as Node3D
	if boat7 != null:
		var scl: float = boat7.get("_scl")
		var fwd3: Vector3 = boat7.global_transform.basis.z
		fwd3.y = 0.0
		fwd3 = fwd3.normalized()
		var wall := StaticBody3D.new()
		var wcs := CollisionShape3D.new()
		var wbox := BoxShape3D.new()
		wbox.size = Vector3(12.0, 10.0, 1.0)
		wcs.shape = wbox
		wall.add_child(wcs)
		wall.collision_layer = 1
		# Root child: position == world position (set BEFORE add_child;
		# global_position needs the tree).
		wall.position = boat7.global_position \
				+ fwd3 * (scl * 4.1 + 2.2)
		root.add_child(wall)
		await physics_frame
		await physics_frame
		var vin: Vector3 = fwd3 * 4.0
		boat7.set("_vel", vin)
		var vout: Vector3 = boat7.call("_hull_contact_slide", 1.0 / 60.0)
		_check("hull contact: blocked head-on",
				vout.dot(fwd3) < 1.0, "dot=%.2f" % vout.dot(fwd3))
		_check("hull contact: slides along the wall",
				vout.length() > 1.5, "len=%.2f" % vout.length())
		wall.queue_free()

	# --- 8. the swim camera lift ------------------------------------------
	# Over the flagship's offshore berth (deep water): the swim state
	# must arm and the camera must ride up — the raised, slightly
	# downward view that reads the hero IN the water.
	var head2: Node = hero.get("head")
	var arm2: SpringArm3D = head2.get("arm")
	var wy: float = hero.get("water_y")
	hero.global_position = Vector3(-242.0, wy + 0.6, 27.0)
	hero.velocity = Vector3.ZERO
	await _wait(0.6)
	_check("swimming arms offshore", bool(hero.get("swimming")))
	_check("swim lift engaged", float(head2.get("swim_lift")) > 0.9)
	_check("swim camera rides high",
			float(arm2.position.y) > 0.5, "y=%.2f" % arm2.position.y)

	print("RESULT fails=%d" % _fails)
	quit(1 if _fails > 0 else 0)
