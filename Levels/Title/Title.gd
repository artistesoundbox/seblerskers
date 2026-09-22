extends Control
## The title screen. Two ways it runs:
##  - Overlay (Player/Boot.gd spawns it over the real island): the live
##    world drifts behind the menu on a slow crane camera while the hero
##    stands frozen beneath. Set Sail glides that crane down into the
##    hero's own camera — one continuous shot from menu to play — and
##    control hands over in place. No scene change, no load.
##  - Standalone (run directly): the static splash art as backdrop, then
##    the island loads as before.
## Built in code (the project's convention); the .tscn stays a bare root.

const ISLAND_SCENE := "res://Levels/Main/L_Main.tscn"
const AttractCamScript := preload("res://Levels/Title/AttractCam.gd")
const GoldLedgerScript := preload("res://Player/GoldLedger.gd")
const AchievementsScript := preload("res://Player/Achievements.gd")
const GameplayMusicScript := preload("res://Player/GameplayMusic.gd")
const INK := Color(0.98, 0.94, 0.82)      # the game's parchment tone
const INK_DIM := Color(0.90, 0.84, 0.68, 0.85)
const GOLD := Color(1.0, 0.78, 0.25)

## Overlay mode: Boot.gd sets this when it spawns the overlay.
var as_overlay := false

var _fade: ColorRect
var _starting := false
var _attract: Camera3D = null
var _start_btn: Button = null
var _backdrop: Control = null
var _veil: ColorRect = null
var _title: Label = null
var _tagline: Label = null
var _box: VBoxContainer = null
var _summary: Control = null
var _restart_btn: Button = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_menu()

	# --- Fade-in, and the way out -------------------------------------
	_fade = ColorRect.new()
	_fade.color = Color(0.0, 0.0, 0.0, 1.0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)
	create_tween().tween_property(_fade, "color:a", 0.0, 0.7)

	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	if as_overlay:
		_begin_attract()


## The menu itself: backdrop, the name, the buttons and the
## carried-over summary, with the entrance animation. Built fresh at
## boot — and built again by the Restart Saga ceremony, so the menu
## literally re-sets like a fresh boot.
func _build_menu() -> void:
	# --- Backdrop -----------------------------------------------------
	if as_overlay:
		_backdrop = _overlay_backdrop()
	else:
		_backdrop = _static_backdrop()
	add_child(_backdrop)

	# A soft dark veil so the type reads (also eases the live world
	# back when overlaying).
	_veil = ColorRect.new()
	_veil.color = Color(0.0, 0.0, 0.0, 0.30)
	_veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_veil)

	# --- The name -----------------------------------------------------
	# Kept small enough to clear the elder's scroll (the HUD parchment
	# rides the top-right of the live island in overlay mode) — the
	# whole word must stay legible, never tucked behind the scroll.
	var title := Label.new()
	title.text = "SEBLERSKERS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.offset_top = 84.0
	title.offset_bottom = 168.0
	title.add_theme_font_size_override("font_size", 60)
	title.add_theme_color_override("font_color", INK)
	title.add_theme_color_override("font_shadow_color",
			Color(0.0, 0.0, 0.0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 4)
	title.add_theme_constant_override("shadow_offset_y", 5)
	title.add_theme_constant_override("shadow_outline_size", 10)
	add_child(title)

	var tagline := Label.new()
	tagline.text = "a viking island saga"
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tagline.anchor_left = 0.0
	tagline.anchor_right = 1.0
	tagline.offset_top = 176.0
	tagline.offset_bottom = 210.0
	tagline.add_theme_font_size_override("font_size", 20)
	tagline.add_theme_color_override("font_color", INK_DIM)
	tagline.add_theme_color_override("font_shadow_color",
			Color(0.0, 0.0, 0.0, 0.85))
	tagline.add_theme_constant_override("shadow_offset_y", 2)
	add_child(tagline)
	_title = title
	_tagline = tagline

	# --- Buttons ------------------------------------------------------
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.offset_left = -160.0
	box.offset_right = 160.0
	box.offset_top = -290.0
	box.offset_bottom = -140.0
	box.add_theme_constant_override("separation", 18)
	add_child(box)
	_box = box

	_start_btn = _menu_button("Set Sail")
	_start_btn.pressed.connect(_on_start)
	box.add_child(_start_btn)

	# Undo Restart: offered exactly once after a wipe, while the
	# pre-wipe backups still exist — a second chance at the point of
	# no return.
	if GoldLedgerScript.has_backup():
		var undo := _menu_button("Undo Restart")
		undo.name = "UndoRestartBtn"
		undo.pressed.connect(_undo_restart)
		box.add_child(undo)
		if _start_btn != null:
			_start_btn.grab_focus()

	# Restart Saga: visible only once there's a saga to restart.
	if _voyage_tally() != "":
		var wipe := _menu_button("Restart Saga")
		wipe.pressed.connect(_confirm_restart)
		wipe.name = "RestartSagaBtn"
		box.add_child(wipe)
		_restart_btn = wipe
	# The Continue flourish: with a live save, the button itself
	# carries the voyage — a small tally line under the wordmark
	# (gold carried, chests plundered, races won), so returning
	# players see the saga they're resuming right on the button.
	var tally := _voyage_tally()
	if tally != "":
		_start_btn.text = "Set Sail"
		var tlabel := Label.new()
		tlabel.name = "VoyageTally"
		tlabel.text = tally
		tlabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tlabel.add_theme_font_size_override("font_size", 14)
		tlabel.add_theme_color_override("font_color", INK_DIM)
		tlabel.add_theme_color_override("font_shadow_color",
				Color(0, 0, 0, 0.85))
		tlabel.add_theme_constant_override("shadow_offset_y", 1)
		tlabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_start_btn.add_child(tlabel)
		tlabel.set_anchors_preset(Control.PRESET_FULL_RECT)
		tlabel.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		# Raise the button a touch so the two-line layout reads.
		_start_btn.custom_minimum_size.y = 64.0
		tlabel.offset_bottom = -6.0
	var quit := _menu_button("Quit")
	quit.pressed.connect(func() -> void: get_tree().quit())
	box.add_child(quit)
	_start_btn.grab_focus()

	# --- Carried-over plunder ------------------------------------------
	# The saved gold total (and the relic, once found) from
	# user://gold.cfg — the saga remembers what the last voyage earned.
	_summary = _save_summary()
	add_child(_summary)

	# --- Entrance: the name rises softly out of the scene -------------
	title.modulate.a = 0.0
	tagline.modulate.a = 0.0
	title.position.y += 26.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(title, "modulate:a", 1.0, 0.9) \
			.set_ease(Tween.EASE_OUT)
	tw.tween_property(title, "position:y",
			title.position.y - 26.0, 0.9).set_ease(Tween.EASE_OUT)
	tw.tween_property(tagline, "modulate:a", 1.0, 1.2) \
			.set_delay(0.35)


## Overlay mode: freeze the hero under the menu, spawn the crane camera
## on the island scene, and start the drift once the world's ground
## exists (PropScatter grounds the terrain over the first frames).
func _begin_attract() -> void:
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	var hero := players[0] as Node3D
	hero.set("menu_frozen", true)
	_attract = AttractCamScript.new()
	# Headless harnesses spawn the overlay manually with no current
	# scene set — fall back to the hero's parent so the crane still has
	# a home (in the real game current_scene is always the island).
	var host := get_tree().current_scene
	if host == null:
		host = hero.get_parent()
	if host != null:
		host.add_child(_attract)
	await get_tree().physics_frame
	await get_tree().physics_frame
	if is_instance_valid(_attract) and _attract.get_parent() != null:
		_attract.begin(hero)


## Set Sail. Overlay: the continuous shot — the crane glides into the
## hero's own camera, the menu dissolves, control is live. Standalone:
## sink to black and load the island.
func _on_start() -> void:
	if _starting:
		return
	_starting = true
	# Sailing commits the current saga: an unused post-restart backup
	# is spent here — undo is no longer offered.
	GoldLedgerScript.discard_backup()
	if not as_overlay or _attract == null:
		var tw := create_tween()
		tw.tween_interval(0.15)
		tw.tween_property(_fade, "color:a", 1.0, 0.55)
		tw.tween_callback(func() -> void:
			# Standalone boot: start the in-game track as the island loads
			# (the node lives on the root, so the scene change can't kill it).
			var music: Node = GameplayMusicScript.ensure(
					get_tree().root)
			if music != null:
				music.call("begin")
			get_tree().change_scene_to_file(ISLAND_SCENE))
		return
	_attract.handed_over.connect(_finish_overlay)
	_attract.begin_handover()


## The glide has landed: unfreeze the hero, capture the mouse, and
## dissolve the menu away (the world is already the backdrop).
func _finish_overlay() -> void:
	var players := get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		players[0].set("menu_frozen", false)
	# The island never ran its own boot branch (overlay mode), so the
	# score ducks here: title swell -> gameplay ambient.
	var drones := get_tree().get_nodes_in_group("music_drone")
	if not drones.is_empty():
		drones[0].call("to_ambient")
	# Control is the player's: bring in the in-game track.
	var music: Node = GameplayMusicScript.ensure(get_tree().root)
	if music != null:
		music.call("begin")
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.45)
	tw.tween_callback(queue_free)


## Keep focus on Start so Enter / gamepad-A always works.
func _process(_delta: float) -> void:
	if not _starting and get_viewport().gui_get_focus_owner() == null:
		if _start_btn != null and is_instance_valid(_start_btn):
			_start_btn.grab_focus()


func _menu_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(320.0, 54.0)
	b.add_theme_font_size_override("font_size", 28)
	b.add_theme_color_override("font_color", INK)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_focus_color", Color(1, 1, 0.9))
	b.add_theme_color_override("font_pressed_color", INK_DIM)
	return b


## The carried-over save summary: a small gold-coin badge with the
## persistent total (user://gold.cfg), the chest-hunt progress
## ("12 of 46 chests plundered", from the same file the opened ids
## live in) and, once the relic has been claimed, its name beneath.
## Nothing to show for a fresh save — the line simply doesn't appear.
## Bottom-left, quiet parchment styling.
func _save_summary() -> Control:
	var save := GoldLedgerScript.load_save()
	var chests := _chest_progress()
	if int(save["gold"]) <= 0 and not bool(save["relic"]) \
			and chests == "":
		return Control.new()   # fresh save: nothing carried over
	var box := VBoxContainer.new()
	box.name = "SaveSummary"
	box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	box.anchor_top = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = 26.0
	box.offset_top = -64.0
	box.offset_bottom = -18.0
	box.offset_right = 480.0
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(row)
	var coin := Panel.new()
	coin.custom_minimum_size = Vector2(18, 18)
	var sb := StyleBoxFlat.new()
	sb.bg_color = GOLD
	sb.set_corner_radius_all(9)
	sb.border_color = Color(0.55, 0.38, 0.05)
	sb.set_border_width_all(2)
	coin.add_theme_stylebox_override("panel", sb)
	coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(coin)
	var gold := Label.new()
	gold.text = "%d gold carried over" % int(save["gold"])
	gold.add_theme_font_size_override("font_size", 20)
	gold.add_theme_color_override("font_color", GOLD)
	gold.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	gold.add_theme_constant_override("shadow_offset_y", 2)
	gold.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gold)

	# Chest-hunt progress: "12 of 46 chests plundered". Shares the
	# first row when there's gold, stands alone otherwise.
	if chests != "":
		var prog := Label.new()
		prog.text = chests
		prog.add_theme_font_size_override("font_size", 20)
		prog.add_theme_color_override("font_color", INK)
		prog.add_theme_color_override("font_shadow_color",
				Color(0, 0, 0, 0.9))
		prog.add_theme_constant_override("shadow_offset_y", 2)
		prog.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(prog)

	if bool(save["relic"]):
		var rel := Label.new()
		rel.text = "✦ The Horn of the North-Sea — claimed"
		rel.add_theme_font_size_override("font_size", 15)
		rel.add_theme_color_override("font_color", INK_DIM)
		rel.add_theme_color_override("font_shadow_color",
				Color(0, 0, 0, 0.85))
		rel.add_theme_constant_override("shadow_offset_y", 1)
		rel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(rel)

	# The saga's deeds: how many of the four are yours.
	var deeds: String = AchievementsScript.summary_line()
	if deeds != "":
		var dl := Label.new()
		dl.name = "DeedsLine"
		dl.text = deeds
		dl.add_theme_font_size_override("font_size", 15)
		dl.add_theme_color_override("font_color", INK_DIM)
		dl.add_theme_color_override("font_shadow_color",
				Color(0, 0, 0, 0.85))
		dl.add_theme_constant_override("shadow_offset_y", 1)
		dl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(dl)

	# A soft entrance, delayed so it arrives after the title settles.
	box.modulate.a = 0.0
	create_tween().tween_property(box, "modulate:a", 1.0, 0.8) \
			.set_delay(1.1)
	return box


## The chest-hunt readout for the summary: opened ids vs the placed
## denominator persisted by PropScatter (user://chests.cfg). Returns
## "" on a fresh save (nothing opened yet) so no empty line shows.
static func _chest_progress() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("user://chests.cfg") != OK:
		return ""
	var opened: PackedStringArray = (cfg.get_section_keys("opened")
			if cfg.has_section("opened") else PackedStringArray())
	if opened == null or opened.is_empty():
		return ""
	var placed := int(cfg.get_value("progress", "placed", 0))
	if placed < opened.size():
		placed = opened.size()
	return "%d of %d chests plundered" % [opened.size(), placed]


## Restart Saga, confirm pass: a dim overlay with a typed warning and
## Set Sail / Restart Saga (their usual order, so gamepad A always
## presses Set Sail first), Esc = Set Sail (safe default).
func _confirm_restart() -> void:
	if _starting:
		return
	_starting = true
	var veil := ColorRect.new()
	veil.name = "ConfirmVeil"
	veil.color = Color(0.0, 0.0, 0.0, 0.55)
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(veil)
	var cv := VBoxContainer.new()
	cv.set_anchors_preset(Control.PRESET_CENTER)
	cv.grow_horizontal = Control.GROW_DIRECTION_BOTH
	cv.grow_vertical = Control.GROW_DIRECTION_BOTH
	cv.alignment = BoxContainer.ALIGNMENT_CENTER
	cv.add_theme_constant_override("separation", 14)
	veil.add_child(cv)
	var warn := Label.new()
	warn.name = "RestartWarning"
	warn.text = "This will ERASE your whole saga:\n" \
			+ _voyage_tally()
	warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warn.add_theme_font_size_override("font_size", 22)
	warn.add_theme_color_override("font_color", INK)
	warn.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	cv.add_child(warn)
	var sub := Label.new()
	sub.text = "there is no way back"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", INK_DIM)
	cv.add_child(sub)
	var sail := _menu_button("Set Sail (keep everything)")
	sail.pressed.connect(func() -> void:
		veil.queue_free()
		_starting = false)
	cv.add_child(sail)
	var redo := _menu_button("Restart Saga")
	redo.pressed.connect(func() -> void:
		veil.queue_free()
		_do_restart())
	cv.add_child(redo)
	sail.grab_focus()


## The wipe itself: every save gone, every live system reset, the
## summary and tally vanish from the still-open menu (the saga has
## restarted around the player without a reload).
func _do_restart() -> void:
	GoldLedgerScript.backup_saga()
	GoldLedgerScript.wipe_all_saves()
	var ledgers := get_tree().get_nodes_in_group("gold_ledger")
	if not ledgers.is_empty():
		ledgers[0].call("reset_saga")
	for ch in get_tree().get_nodes_in_group("treasure_chest"):
		ch.call("reset_saga")
	for r in ["race_course", "race_regatta", "sail_lap"]:
		for n in get_tree().get_nodes_in_group(r):
			n.call("reset_saga")
	for m in get_tree().get_nodes_in_group("merchant"):
		m.call("reset_saga")
	for q in get_tree().get_nodes_in_group("quest_board"):
		q.call("reset_saga")
	# The wiped menu melts to black for a beat, then rises again exactly
	# as at boot — summary, tally and Restart all gone, because the save
	# they read is gone — while the farewell line fades over the screen.
	_ceremony()


## The 'saga begins anew' moment. The old menu sinks into a held black
## frame — a fresh boot's beat — then the menu builds itself again with
## its full entrance (title rise, tagline, clean Set Sail) as the black
## lifts. Over it all, one quiet line of parchment: the saga's farewell
## and its welcome in the same breath.
func _ceremony() -> void:
	_starting = true
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 1.0, 0.3)
	tw.tween_callback(_rebuild_menu)
	tw.tween_interval(0.35)
	tw.tween_property(_fade, "color:a", 0.0, 0.7)
	tw.tween_callback(func() -> void: _starting = false)	## Free every menu node and rebuild from scratch — the save files are
	## already wiped, so the fresh build shows a clean single-line Set
	## Sail, no summary, no Restart — but an Undo Restart rides beneath,
	## because the pre-wipe saga is one press away. The farewell line
	## rides on top.
func _rebuild_menu() -> void:
	for n: Node in [_backdrop, _veil, _title, _tagline, _box, _summary]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_backdrop = null
	_veil = null
	_title = null
	_tagline = null
	_box = null
	_summary = null
	_start_btn = null
	_restart_btn = null
	_build_menu()
	# The fresh menu must sit beneath the black cover until its beat
	# ends; the farewell line rides above everything.
	move_child(_fade, get_child_count() - 1)
	var fl := Label.new()
	fl.name = "AnewFlourish"
	fl.text = "the saga begins anew"
	fl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fl.set_anchors_preset(Control.PRESET_CENTER)
	fl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	fl.grow_vertical = Control.GROW_DIRECTION_BOTH
	fl.add_theme_font_size_override("font_size", 30)
	fl.add_theme_color_override("font_color", INK)
	fl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	fl.add_theme_constant_override("shadow_offset_y", 3)
	fl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fl.modulate.a = 0.0
	add_child(fl)
	var ftw := create_tween()
	ftw.tween_interval(0.55)
	ftw.tween_property(fl, "modulate:a", 1.0, 0.9)
	ftw.tween_interval(1.3)
	ftw.tween_property(fl, "modulate:a", 0.0, 1.0)
	ftw.tween_callback(fl.queue_free)


## The Set Sail tally line: the whole voyage in one breath — gold
## carried, chests plundered, races won. Empty string on a fresh save
## (the button keeps its clean single-line look).
static func _voyage_tally() -> String:
	var parts: Array[String] = []
	var gold: int = GoldLedgerScript.load_save()["gold"]
	if int(gold) > 0:
		parts.append("%d gold" % int(gold))
	var chests := _chest_progress()
	if chests != "":
		parts.append(chests)
	var wins := 0
	var cf := ConfigFile.new()
	if cf.load("user://race_course.cfg") == OK:
		wins += int(cf.get_value("course", "wins", 0))
	if cf.load("user://sail_race.cfg") == OK:
		wins += int(cf.get_value("regatta", "wins", 0))
	if wins > 0:
		parts.append("%d race%s won" % [wins, "" if wins == 1 else "s"])
	return "  ·  ".join(parts)


## Undo Restart: move the pre-wipe backup set back over the live
## saves, then bring every live system back in step — the ledger
## re-reads its total and deeds, chests settle against the restored
## file, races drop their caches, the merchant re-applies its wares.
## One press: the backup set is consumed by the restore.
func _undo_restart() -> void:
	if _starting:
		return
	_starting = true
	GoldLedgerScript.restore_saga()
	var ledgers := get_tree().get_nodes_in_group("gold_ledger")
	if not ledgers.is_empty():
		ledgers[0].call("refresh_saga")
	for ch in get_tree().get_nodes_in_group("treasure_chest"):
		ch.call("reopen_saga")
	for r in ["race_course", "race_regatta", "sail_lap"]:
		for n in get_tree().get_nodes_in_group(r):
			n.call("refresh_saga")
	for m in get_tree().get_nodes_in_group("merchant"):
		m.call("refresh_saga")
	for q in get_tree().get_nodes_in_group("quest_board"):
		q.call("refresh_saga")
	# Rebuild the menu from the restored files — the summary, tally
	# and Restart button all return with the saga they describe.
	_ceremony()


## Static art (standalone boot): the cover poster, edge to edge.
func _static_backdrop() -> TextureRect:
	var art := TextureRect.new()
	art.texture = load("res://imports/sleblerskersload_cover.png")
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	return art


## Live world (overlay boot): nothing to draw — the island shows
## through the transparent menu.
func _overlay_backdrop() -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if as_overlay:
			_on_start()  # Esc skips the menu straight into the island
		else:
			get_tree().quit()
		return
	# The menu answers the pad exactly like the intro skip does: any
	# gamepad button — X included — presses whatever the menu holds
	# focus on. (If the default map already routes a button through
	# ui_accept, the GUI consumes it first and this never fires; no
	# double-activation either way.)
	var joy := event as InputEventJoypadButton
	if joy != null and joy.pressed:
		var focused := get_viewport().gui_get_focus_owner()
		if focused is BaseButton:
			(focused as BaseButton).emit_signal("pressed")
