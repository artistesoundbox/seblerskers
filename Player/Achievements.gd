class_name Achievements
extends RefCounted
## The saga's deeds, earned once and kept forever (until Restart Saga):
## the FIRST CHEST looted, the FIRST RACE MEDAL placed, the RELIC
## recovered from the deep, and 100% PLUNDER — every chest on the
## island emptied. Unlocks persist in user://achievements.cfg; the
## title screen reads them statically, and live unlocks announce
## themselves with a quiet toast.
##
## There is no live node: everything is static. Awards dedupe — a
## repeated award is a no-op — and backfill() harvests the four deeds
## from the existing save files, so sagas played before this system
## still earn their due the next time anything loads.

const SAVE_PATH := "user://achievements.cfg"

## The four deeds of the saga, in the order they tend to be earned.
const DEFS := [
	{"id": "first_chest", "name": "First Blood Plunder",
		"hint": "Loot your first treasure chest."},
	{"id": "first_medal", "name": "Off the Mark",
		"hint": "Place in any race — gold, silver or bronze."},
	{"id": "relic", "name": "Voice of the North-Sea",
		"hint": "Recover the Horn from the deepest hoard."},
	{"id": "plunder_all", "name": "Clean the Shelves",
		"hint": "Empty every chest on the island."},
]

const INK := Color(0.98, 0.94, 0.82)
const GOLD := Color(1.0, 0.78, 0.25)


## Every unlocked id, as a dictionary {id: true}.
static func load_unlocked() -> Dictionary:
	var out := {}
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return out
	for d in DEFS:
		if bool(cfg.get_value("unlocked", d["id"], false)):
			out[d["id"]] = true
	return out


static func is_unlocked(id: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return false
	return bool(cfg.get_value("unlocked", id, false))


## Grant a deed. True when it's NEWLY unlocked (and the toast plays);
## false when it was already held or the id is unknown.
static func award(id: String) -> bool:
	if not _known(id) or is_unlocked(id):
		return false
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("unlocked", id, true)
	cfg.save(SAVE_PATH)
	_toast(id)
	return true


## Harvest earned deeds from the existing saves — used at boot so a
## saga played before this system gets its due. Returns the ids that
## were newly granted (their toasts have already played).
static func backfill() -> Array[String]:
	var got: Array[String] = []
	var save: Dictionary = load("res://Player/GoldLedger.gd").call("load_save")
	if bool(save["relic"]) and award("relic"):
		got.append("relic")
	var cf := ConfigFile.new()
	var opened := 0
	var placed := 0
	if cf.load("user://chests.cfg") == OK:
		if cf.has_section("opened"):
			opened = cf.get_section_keys("opened").size()
		placed = int(cf.get_value("progress", "placed", 0))
	if opened > 0 and award("first_chest"):
		got.append("first_chest")
	if placed > 0 and opened >= placed and award("plunder_all"):
		got.append("plunder_all")
	var wins := 0
	if cf.load("user://race_course.cfg") == OK:
		wins += int(cf.get_value("course", "wins", 0))
	if cf.load("user://sail_race.cfg") == OK:
		wins += int(cf.get_value("regatta", "wins", 0))
	if wins > 0 and award("first_medal"):
		got.append("first_medal")
	return got


## Restart Saga: the deeds are forgotten with everything else.
static func reset_saga() -> void:
	DirAccess.remove_absolute(SAVE_PATH)


## The title-screen readout: "2 of 4 saga deeds earned" — empty until
## the first deed lands.
static func summary_line() -> String:
	var n := load_unlocked().size()
	if n <= 0:
		return ""
	return "%d of %d saga deeds earned" % [n, DEFS.size()]


static func _known(id: String) -> bool:
	for d in DEFS:
		if d["id"] == id:
			return true
	return false


static func _def(id: String) -> Dictionary:
	for d in DEFS:
		if d["id"] == id:
			return d
	return {}


# --- the toast ----------------------------------------------------------------

## The announcement: a small dark band top-center — "DEED EARNED",
## the deed's name in gold, its hint beneath — with a two-note chime.
## Self-frees; safe to call from any static context.
static func _toast(id: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var d := _def(id)
	if d.is_empty():
		return
	var layer := CanvasLayer.new()
	layer.layer = 96
	tree.root.add_child(layer)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.offset_left = -230.0
	box.offset_right = 230.0
	box.offset_top = 96.0
	box.offset_bottom = 168.0
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.06, 0.05, 0.88)
	sb.set_corner_radius_all(8)
	sb.border_color = Color(0.75, 0.6, 0.25, 0.8)
	sb.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(panel)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 2)
	panel.add_child(inner)
	var kick := Label.new()
	kick.name = "Kick"
	kick.text = "DEED EARNED"
	kick.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kick.add_theme_font_size_override("font_size", 12)
	kick.add_theme_color_override("font_color", GOLD)
	inner.add_child(kick)
	var t := Label.new()
	t.name = "Name"
	t.text = d["name"]
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 24)
	t.add_theme_color_override("font_color", INK)
	t.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	inner.add_child(t)
	var s := Label.new()
	s.text = d["hint"]
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	s.add_theme_font_size_override("font_size", 13)
	s.add_theme_color_override("font_color",
			Color(0.9, 0.84, 0.68, 0.85))
	inner.add_child(s)
	box.modulate.a = 0.0
	box.position.y -= 14.0
	layer.add_child(box)
	var tw := tree.create_tween()
	tw.set_parallel(true)
	tw.tween_property(box, "modulate:a", 1.0, 0.35)
	tw.tween_property(box, "position:y", box.position.y + 14.0, 0.4) \
			.set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(2.6)
	tw.chain().tween_property(box, "modulate:a", 0.0, 0.7)
	tw.chain().tween_callback(layer.queue_free)
	var pl := AudioStreamPlayer.new()
	pl.stream = _chime_stream()
	pl.volume_db = -10.0
	tree.root.add_child(pl)
	pl.play()
	tree.create_timer(2.0).timeout.connect(pl.queue_free)


## The deed chime: two soft ascending notes (E5 -> A5), pure sines
## with a quick decay — a quiet flourish, not a fanfare.
const SR := 22050
static var _chime_cache: AudioStreamWAV


static func _chime_stream() -> AudioStreamWAV:
	if _chime_cache != null:
		return _chime_cache
	var length := int(0.7 * SR)
	var bytes := PackedByteArray()
	bytes.resize(length * 2)
	for i in length:
		var u := float(i) / float(SR)
		var v := 0.0
		if u < 0.22:
			var e := u / 0.22
			v += sin(TAU * 659.26 * u) * exp(-u * 14.0) * 0.6 * minf(e * 4.0, 1.0)
		if u > 0.14:
			var u2 := u - 0.14
			v += sin(TAU * 880.0 * u2) * exp(-u2 * 12.0) * 0.7
		bytes.encode_s16(i * 2,
				int(clampf(v, -1.0, 1.0) * 32767.0 * 0.8))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	wav.data = bytes
	_chime_cache = wav
	return wav
