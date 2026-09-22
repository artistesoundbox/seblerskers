class_name QuestBoard
extends Node
## The village elder's board: six saga goals handed out at the well —
## first plunder, a sunken hoard, the Horn, a flight-race medal, a
## regatta medal, and one raid defended. Each pays gold when claimed
## at the elder. Progress is polled from the live world (chest/race/
## raid/ledger groups — no signals to wire), completes itself, and
## claims dedupe. State persists in user://quests.cfg; the HUD tracker
## (top-left) shows the saga's open business, CLAIM! flashing when
## gold waits at the elder.
##
## The HUD tracker is the ELDER'S SCROLL — the player's scroll.png
## parchment pinned top-right. It starts ROLLED (scrollclosed.png, a
## bar with hanging cords) so the sky stays clear during play: Q or
## Select unrolls it, clicking the closed roll or the open parchment
## toggles it too. OPENING FREES THE MOUSE (user report: the mouse
## was disabled in gameplay, so the click-to-toggle path was dead);
## rolling it recaptures. The rolled bar itself carries the toggle
## hint ("Q / Select") so the control is discoverable.
##
## Spawned by PropScatter beside the village elder.
##
## CONTROLLER: D-pad UP or DOWN toggles the scroll (the pad's
## up/down no longer zooms the camera — user report: that trapped
## players in first person). The scroll top rides `hud_y` so touch
## devices (with the on-screen joystick up top) can park it lower.

const SAVE_PATH := "user://quests.cfg"
const GROUP := "quest_board"
const ENDING_SCRIPT := preload("res://Player/EndingMoment.gd")

## The elder's errands, in hand-out order.
const QUESTS := [
	{"id": "plunder", "name": "First Plunder",
	 "desc": "Loot a treasure chest.", "reward": 10},
	{"id": "hoard", "name": "Diver's Luck",
	 "desc": "Loot a sunken hoard chest.", "reward": 30},
	{"id": "relic", "name": "The Horn Calls",
	 "desc": "Recover the Horn of the North-Sea.", "reward": 60},
	{"id": "race", "name": "Off the Mark",
	 "desc": "Medal in the flight race.", "reward": 25},
	{"id": "regatta", "name": "Master of the Coast",
	 "desc": "Medal in the coastal regatta.", "reward": 25},
	{"id": "raid", "name": "Shield of the Village",
	 "desc": "Defend the village through a raid.", "reward": 40},
]

## Quill-ink palette: the scroll parchment is light, so the text is
## dark iron-gall ink — the pale INK tone would vanish on it.
const SCROLL_ART := "res://imports/scroll.png"
const SCROLL_CLOSED_ART := "res://imports/scrollclosed.png"
const INK := Color(0.23, 0.15, 0.08)
const INK_DONE := Color(0.45, 0.4, 0.3)
const SEAL := Color(0.62, 0.16, 0.1)
const GOLD := Color(1.0, 0.78, 0.25)

## Vertical shift (px) for the scroll + its hint on short/wide
## screens (phones): raises/lowers the whole widget to keep it clear
## of the on-screen touch controls. 0 on desktop.
static var hud_y := 0.0
## D-pad edge latch (up or down both toggle).
static var _dpad := false

var claimed := {}
var _poll_t := 0.0
var _hud: CanvasLayer
var _scroll: NinePatchRect
var _box: VBoxContainer
## The scroll starts rolled up; Q / Select / clicking it unrolls it.
var _scroll_open := false
var _rows := {}
var _capstone: Label
var _announce: Label
var _announce_t := 0.0
## The "Q / Select to unroll" hint painted on the rolled bar.
var _hint: Label
var _hud_t := 0.0
var _pulse_t := 0.0


func _ready() -> void:
	add_to_group(GROUP)
	_load_state()
	_build_hud()
	_refresh_hud()
	_update_scroll_open()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_scroll"):
		_toggle_scroll()
	# The controller's D-pad up/down: toggle the elder's scroll.
	# (Same edge-guard scheme as PauseMenu — poll the pad each frame,
	# fire once per physical press.) While the title owns the game the
	# pad is left alone, exactly like the pause menu.
	var dp := Input.get_axis("dpad_up", "dpad_down")
	if dp != 0.0:
		if not _dpad and not _hero_busy():
			_dpad = true
			_toggle_scroll()
	else:
		_dpad = false


## True while the title screen owns the game (same lazy check as
## PauseMenu: the hero reports menu_frozen until Set Sail).
func _hero_busy() -> bool:
	var hero := get_tree().get_first_node_in_group("player")
	if hero == null:
		return true
	return bool(hero.get("menu_frozen"))


func _toggle_scroll() -> void:
	_scroll_open = not _scroll_open
	_update_scroll_open()
	# The mouse rides the TOGGLE (not boot — _ready must never grab
	# the cursor out from under the title screen): open frees it for
	# reading and clicking the parchment; rolled recaptures it.
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if _scroll_open
			else Input.MOUSE_MODE_CAPTURED)


## Swaps the rolled bar in and out. Same-canvas art, so the texture
## swap keeps the click area put; the open roll fades up from the
## pinned end so it reads as unrolling from the cords.
## The mouse rides the scroll's state: OPEN frees the cursor so the
## click-toggle works and the elder's errands can be read over the
## world; ROLLED recaptures (previous mode restored — captured
## gameplay stays captured, a visible-cursor moment stays visible).
func _update_scroll_open() -> void:
	if _scroll == null:
		return
	if _scroll_open:
		_scroll.texture = load(SCROLL_ART)
		_box.visible = true
		_box.modulate.a = 0.0
		var tw := create_tween()
		tw.tween_property(_box, "modulate:a", 1.0, 0.22)
		if _hint != null:
			_hint.visible = false
	else:
		_scroll.texture = load(SCROLL_CLOSED_ART)
		_box.visible = false
		if _hint != null:
			_hint.visible = true


func _physics_process(delta: float) -> void:
	_poll_t -= delta
	if _poll_t <= 0.0:
		_poll_t = 0.25
		_poll_progress()
	_announce_t = maxf(0.0, _announce_t - delta)
	if _announce != null:
		_announce.modulate.a = clampf(_announce_t / 0.5, 0.0, 1.0)
	_pulse_t += delta
	_hud_t -= delta
	if _hud_t <= 0.0:
		_hud_t = 0.25
		_refresh_hud()


## Poll the live world for each unclaimed quest's completion.
func _poll_progress() -> void:
	var tree := get_tree()
	# Chests: one land, one sunken, and the Horn.
	if not _done("plunder") or not _done("hoard") or not _done("relic"):
		for ch in tree.get_nodes_in_group("treasure_chest"):
			var c := ch as TreasureChest
			if c == null or not c.is_open():
				continue
			if c.sunken:
				if c.relic:
					progress("relic")
				progress("hoard")
			else:
				progress("plunder")
	# Races: a medal rank on either course.
	if not _done("race"):
		for r in tree.get_nodes_in_group("race_course"):
			var rank: String = r.get("_last_rank")
			if rank != "" and rank != "FINISHER":
				progress("race")
	if not _done("regatta"):
		for r in tree.get_nodes_in_group("race_regatta"):
			var rank: String = r.get("_last_rank")
			if rank != "" and rank != "FINISHER":
				progress("regatta")
	# Raids: a defended night.
	if not _done("raid"):
		for n in tree.get_nodes_in_group("raid_manager"):
			if str(n.get("_last_result")) == "defended":
				progress("raid")
	_maybe_ending()

var _ending_started := false


## The saga's final goal: the moment Horn + full plunder + both race
## medals hold at once, the ending moment rolls — once per saga
## (EndingMoment checks user://ending.cfg itself). Held while the
## title owns the game; it fires the moment play resumes.
func _maybe_ending() -> void:
	if _ending_started or not _saga_complete():
		return
	for p in get_tree().get_nodes_in_group("player"):
		if bool(p.get("menu_frozen")):
			return
	_ending_started = true
	var e := CanvasLayer.new()  # EndingMoment is a CanvasLayer
	e.set_script(ENDING_SCRIPT)
	get_tree().root.add_child.call_deferred(e)


## Record completion of a quest's goal. True when it just completed.
## The completion itself persists (done-but-unclaimed) so the scroll
## doesn't re-announce old business at every boot.
func progress(kind: String) -> bool:
	if kind.is_empty() or _done(kind):
		return false
	claimed[kind] = false
	_save_state()
	_announce_quest(kind)
	return true


func _done(kind: String) -> bool:
	return claimed.has(kind)


## Claim the reward at the elder. True when gold actually moved.
func claim(id: String) -> bool:
	if not _done(id) or bool(claimed[id]):
		return false
	var ledgers := get_tree().get_nodes_in_group("gold_ledger")
	if ledgers.is_empty():
		return false
	var reward := 0
	for q in QUESTS:
		if q["id"] == id:
			reward = int(q["reward"])
	ledgers[0].call("add", reward)
	claimed[id] = true
	_save_state()
	_announce_claim(id, reward)
	_refresh_hud()  # the row strikes through the moment you claim
	return true


## Claimable quest ids — gold waiting at the elder.
func claimable() -> Array[String]:
	var out: Array[String] = []
	for q in QUESTS:
		if _done(q["id"]) and not bool(claimed[q["id"]]):
			out.append(q["id"])
	return out


func is_done(id: String) -> bool:
	return _done(id)


func is_claimed(id: String) -> bool:
	return bool(claimed.get(id, false))


## Restart Saga: forget every quest, wipe the file, and re-arm the
## ending so a fresh saga can earn it again.
func reset_saga() -> void:
	claimed.clear()
	_ending_started = false
	DirAccess.remove_absolute(SAVE_PATH)
	_refresh_hud()


## Undo Restart: re-read the restored quest file.
func refresh_saga() -> void:
	claimed.clear()
	_load_state()
	_refresh_hud()


# --- persistence ---------------------------------------------------------------

func _save_state() -> void:
	var cfg := ConfigFile.new()
	for q in QUESTS:
		var id: String = q["id"]
		if _done(id):
			cfg.set_value("quests", id, bool(claimed[id]))
	cfg.save(SAVE_PATH)


func _load_state() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	for q in QUESTS:
		var id: String = q["id"]
		if cfg.has_section_key("quests", id):
			claimed[id] = bool(cfg.get_value("quests", id, false))


# --- the HUD tracker -----------------------------------------------------------

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = 90
	add_child(_hud)
	# The legend scroll: the whole saga's to-do list, pinned top-right
	# like a parchment nailed to the frame.
	# The player's own parchment: nine-patch so the rolled edges and
	# wax seal survive while the blurred center stretches behind text.
	var scroll := NinePatchRect.new()
	scroll.name = "LegendScroll"
	scroll.texture = load(SCROLL_ART)
	# Nine-patch margins MATCH THE NEW ART (324x406, measured by pixel
	# profile): the decorated top roll runs ~0-96, the bottom roll/ribbon
	# ~320-406, and the side rolls eat ~100 px on the left / ~60 on the
	# right. The old 52-56 px margins stretched those bands across the
	# middle — the text then sat inside the rolled edges.
	scroll.patch_margin_left = 100
	scroll.patch_margin_right = 60
	scroll.patch_margin_top = 96
	scroll.patch_margin_bottom = 86
	scroll.self_modulate = Color(1, 1, 1, 0.95)
	# Click handling: clicking the closed roll opens it, clicking the
	# open parchment rolls it up. STOP keeps both events away from the
	# fireball's LMB binding and the click-to-recapture handler below.
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	scroll.gui_input.connect(_on_scroll_input)
	scroll.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	scroll.anchor_left = 1.0
	scroll.anchor_right = 1.0
	scroll.offset_left = -344.0
	scroll.offset_right = -18.0
	# Riding a touch lower than the frame's very top edge (but still
	# clearly upper-right, out of the action). TALLER now: the new
	# art's writing band is only the middle ~54% of the texture, so
	# the widget grows to keep the readable parchment big enough.
	scroll.offset_top = 36.0 + hud_y
	scroll.offset_bottom = 36.0 + hud_y + 520.0
	scroll.grow_vertical = Control.GROW_DIRECTION_END
	_hud.add_child(scroll)
	_scroll = scroll
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(box)
	_box = box
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Insets from the MEASURED art bands (324x406: bright flat zone
	# x 96-264 / y 92-318, mild roll shading to ~x48 and ~x284, dark
	# rolls outside). Second user pass: rows still grazed the side
	# margins and the LAST LINE clipped at the bottom ("tight fit at
	# end of page") — so the box is cleared well off the dark rolls,
	# raised to the flat band's top edge, and the widget grew to 520
	# so the capstone ends 2+ lines above the bottom roll.
	box.offset_left = 52.0
	box.offset_right = -50.0
	box.offset_top = 96.0
	box.offset_bottom = -112.0
	box.visible = false  # starts rolled; _update_scroll_open reveals it
	var head := Label.new()
	head.text = "ELDER'S ERRANDS"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", 17)
	head.add_theme_color_override("font_color", INK)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(head)
	for q in QUESTS:
		var row := Label.new()
		row.name = "q_%s" % q["id"]
		row.add_theme_font_size_override("font_size", 14)
		row.add_theme_color_override("font_color", INK)
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(row)
		_rows[q["id"]] = row
	_capstone = Label.new()
	_capstone.add_theme_font_size_override("font_size", 14)
	_capstone.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_capstone.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_capstone)
	_announce = Label.new()
	_announce.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_announce.anchor_left = 0.0
	_announce.anchor_right = 1.0
	# The gold banner sat dead-center top — UNDER the pinned scroll
	# (user report). Reserve the scroll's strip: the banner centers
	# in the space LEFT of it, so quest news never hides behind the
	# parchment. AND it rides BELOW the rolled bar's visual height
	# (second pass: the closed bar reaches ~y100, the banner at 64
	# still collided with it) — lowered clear under it.
	_announce.offset_right = -400.0
	_announce.offset_left = 24.0
	_announce.offset_top = 118.0 + hud_y
	_announce.offset_bottom = 158.0 + hud_y
	_announce.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_announce.add_theme_font_size_override("font_size", 24)
	_announce.add_theme_color_override("font_color", GOLD)
	_announce.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_announce.add_theme_constant_override("shadow_offset_y", 2)
	_announce.modulate.a = 0.0
	_announce.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_announce)
	# The rolled bar's toggle hint: a small inked line ON the roll —
	# "Q / Select" — so the unroll control is discoverable without a
	# manual (user report: the mouse was disabled and nothing said
	# how to open the thing). Hidden while the scroll is open.
	_hint = Label.new()
	_hint.text = "Tab / Q / Select / D-pad — read the elder's errands"
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.35, 0.24, 0.12))
	_hint.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.35))
	_hint.add_theme_constant_override("shadow_offset_y", 1)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hint.anchor_left = 1.0
	_hint.anchor_right = 1.0
	_hint.offset_left = -344.0
	_hint.offset_right = -18.0
	_hint.offset_top = 44.0 + hud_y
	_hint.offset_bottom = 66.0 + hud_y
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.clip_text = false
	_hud.add_child(_hint)


## Left-click on the scroll toggles it; the STOP filter keeps the
## event away from the fireball cast and the click-to-recapture path.
func _on_scroll_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_toggle_scroll()


## The scroll: every errand always listed, in hand-out order — the
## saga's to-do list that empties as it advances. Claimed errands
## strike through and fade; claimable ones pulse seal-red (gold waits
## at the elder); open ones read as their one-line brief. The capstone
## closes the list: the saga's final goal, then its completion.
func _refresh_hud() -> void:
	var beat := 0.7 + 0.3 * sin(_pulse_t * 5.2)
	for q in QUESTS:
		var id: String = q["id"]
		var row: Label = _rows[id]
		row.modulate.a = 1.0
		if _done(id) and bool(claimed[id]):
			row.text = "~ %s ~" % q["name"]
			row.add_theme_color_override("font_color", INK_DONE)
			row.modulate.a = 0.75
		elif _done(id):
			row.text = "%s — %d gold at the elder!" \
					% [q["name"], q["reward"]]
			row.add_theme_color_override("font_color", SEAL)
			row.modulate.a = beat
		else:
			row.text = "· %s" % q["desc"]
			row.add_theme_color_override("font_color", INK)
	if _saga_complete():
		_capstone.text = "✦ the saga is complete ✦"
		_capstone.add_theme_color_override("font_color", SEAL)
		_capstone.modulate.a = beat
	else:
		_capstone.text = "· the saga: Horn, all plunder, both races"
		_capstone.add_theme_color_override("font_color", INK)
		_capstone.modulate.a = 0.85


## The final goal: the Horn recovered, every chest emptied, and a
## medal from BOTH courses — each checked against persistent truth
## (the ledger flag, the live chest group, the races' wins tallies),
## never the volatile last-rank caches.
func _saga_complete() -> bool:
	var ledgers := get_tree().get_nodes_in_group("gold_ledger")
	if ledgers.is_empty() or not bool(ledgers[0].get("relic_found_flag")):
		return false
	var chests := get_tree().get_nodes_in_group("treasure_chest")
	if chests.is_empty():
		return false
	for ch in chests:
		var c := ch as TreasureChest
		if c == null or not c.is_open():
			return false
	return _has_medal("user://race_course.cfg", "course") \
			and _has_medal("user://sail_race.cfg", "regatta")


## A medal ever won on that course (the wins tally only rises on
## gold/silver/bronze finishes — a bare FINISHER run doesn't count).
static func _has_medal(path: String, section: String) -> bool:
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return false
	return int(cf.get_value(section, "wins", 0)) > 0


func _announce_quest(kind: String) -> void:
	for q in QUESTS:
		if q["id"] == kind:
			_announce.text = "ERRAND COMPLETE — %s" % q["name"]
			break
	_announce_t = 3.0
	_chime(false)


func _announce_claim(id: String, reward: int) -> void:
	for q in QUESTS:
		if q["id"] == id:
			_announce.text = "%s — %d gold earned" % [q["name"], reward]
			break
	_announce_t = 3.0
	_chime(true)


# --- the claim chime -----------------------------------------------------------

const SR := 22050
static var _chime_cache: AudioStreamWAV


## A soft two-note pluck: A4 for a completion, the rising E5 for a
## claimed reward — quiet, parchment-flavored.
static func _chime_stream() -> AudioStreamWAV:
	if _chime_cache != null:
		return _chime_cache
	var length := int(0.6 * SR)
	var bytes := PackedByteArray()
	bytes.resize(length * 2)
	for i in length:
		var u := float(i) / float(SR)
		var v := 0.0
		if u < 0.18:
			v += sin(TAU * 440.0 * u) * exp(-u * 16.0) * 0.5
		if u > 0.12:
			var u2 := u - 0.12
			v += sin(TAU * 659.26 * u2) * exp(-u2 * 13.0) * 0.55
		bytes.encode_s16(i * 2,
				int(clampf(v, -1.0, 1.0) * 32767.0 * 0.75))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	wav.data = bytes
	_chime_cache = wav
	return wav


func _chime(_claim: bool) -> void:
	var pl := AudioStreamPlayer.new()
	pl.stream = _chime_stream()
	pl.volume_db = -12.0
	add_child(pl)
	pl.play()
	get_tree().create_timer(1.4).timeout.connect(pl.queue_free)
