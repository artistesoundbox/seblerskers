class_name GoldLedger
extends Node
## The player's plunder: a persistent gold count with a HUD coin
## counter (top right) and the relic banner. Spawned by the player
## controller at boot; chests find it through the "gold_ledger" group.
## The total survives sessions in user://gold.cfg — like the opened
## chests, the plunder is remembered.

signal gold_changed(total: int)

const SAVE_PATH := "user://gold.cfg"
const GROUP := "gold_ledger"
const RELIC_GOLD := 150
const ACH := preload("res://Player/Achievements.gd")
const INK := Color(0.98, 0.94, 0.82)      # the game's parchment tone
const GOLD := Color(1.0, 0.78, 0.25)

var total := 0
## Set true when the relic is absorbed (harness/menu readout).
var relic_found_flag := false

var _layer: CanvasLayer
var _label: Label
var _shown := 0.0        # the animated roll-up value


func _ready() -> void:
	add_to_group(GROUP)
	total = read_saved()
	relic_found_flag = bool(load_save()["relic"])
	_build_hud()
	_shown = float(total)
	_refresh()
	# The saga's deeds: harvest anything the older save files already
	# earned (relic claimed, medals won, chests emptied) so sagas played
	# before achievements existed keep their due.
	for id in ACH.backfill():
		print("[deeds] earned: %s" % id)


## Restart Saga: zero the live total, hide the HUD counter, and clear
## the relic flag — then wipe the save file. Chests, races and the
## merchant wipe their own files through their reset_saga() hooks.
## Every file the saga writes — the whole set moves together on a
## backup/restore.
const SAVE_FILES := ["user://gold.cfg", "user://chests.cfg",
		"user://race_course.cfg", "user://sail_race.cfg",
		"user://merchant.cfg", "user://achievements.cfg",
		"user://quests.cfg", "user://ending.cfg"]


## Restart Saga: wipe every save file.
static func wipe_all_saves() -> void:
	for p in SAVE_FILES:
		DirAccess.remove_absolute(p)


## The safety net before a wipe: copy the whole save set to *.bak so
## Restart can be undone once from the title screen.
static func backup_saga() -> void:
	for p in SAVE_FILES:
		if FileAccess.file_exists(p):
			DirAccess.copy_absolute(p, p + ".bak")


## Undo Restart: move every *.bak back over the live saves. A leftover
## .bak with no live file IS restored — that's exactly the wiped state
## (no live file, backup intact). True when anything was restored.
static func restore_saga() -> bool:
	var any := false
	for p in SAVE_FILES:
		var bak: String = p + ".bak"
		if FileAccess.file_exists(bak):
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)
			DirAccess.copy_absolute(bak, p)
			DirAccess.remove_absolute(bak)
			any = true
		elif FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	return any


## The undo is spent (Set Sail after a restart): drop the backups
## without touching the live saves.
static func discard_backup() -> void:
	for p in SAVE_FILES:
		if FileAccess.file_exists(p + ".bak"):
			DirAccess.remove_absolute(p + ".bak")


## True while a pre-restart backup set exists — the title offers the
## undo only then.
static func has_backup() -> bool:
	for p in SAVE_FILES:
		if FileAccess.file_exists(p + ".bak"):
			return true
	return false


## The live half of Restart Saga: zero this ledger and its HUD.
func reset_saga() -> void:
	total = 0
	relic_found_flag = false
	_shown = 0.0
	_refresh()
	if _layer != null:
		_layer.visible = false


## Undo Restart: re-read the restored save files — the live total, the
## relic flag and the deed list all come back from disk.
func refresh_saga() -> void:
	total = read_saved()
	relic_found_flag = bool(load_save()["relic"])
	_shown = float(total)
	_refresh()
	if _layer != null:
		_layer.visible = total > 0
	ACH.backfill()


## For tests/menus: the saved total without spawning the HUD.
func read_saved() -> int:
	return int(load_save()["gold"])


## The whole saved plunder (gold + relic) as a dictionary — the title
## screen's carried-over summary reads this without spawning the HUD.
static func load_save() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return {"gold": 0, "relic": false}
	return {
		"gold": int(cfg.get_value("plunder", "gold", 0)),
		"relic": bool(cfg.get_value("plunder", "relic_found", false)),
	}


func _build_hud() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 92
	add_child(_layer)
	var box := HBoxContainer.new()
	box.anchor_left = 1.0
	box.anchor_right = 1.0
	# Below the elder's scroll strip, not inside it (user report: the
	# gold counter sat BEHIND the closed scroll — the roll occupies
	# x W-344..W-18 from y 36 down; these offsets park the coin under
	# the parchment, right-aligned with it). hud_y follows the scroll
	# on touch screens, so this never drifts back under it.
	box.offset_left = -160.0
	box.offset_right = -20.0
	box.offset_top = 576.0 + QuestBoard.hud_y
	box.offset_bottom = 606.0 + QuestBoard.hud_y
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(box)
	var coin := Panel.new()
	coin.custom_minimum_size = Vector2(22, 22)
	var sb := StyleBoxFlat.new()
	sb.bg_color = GOLD
	sb.set_corner_radius_all(11)
	sb.border_color = Color(0.55, 0.38, 0.05)
	sb.set_border_width_all(2)
	coin.add_theme_stylebox_override("panel", sb)
	coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(coin)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 24)
	_label.add_theme_color_override("font_color", INK)
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_label.add_theme_constant_override("shadow_offset_y", 2)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_label)
	_layer.visible = false   # shown once plunder exists


## Loot lands here. The counter rolls up to the new total.
func add(amount: int) -> void:
	if amount <= 0:
		return
	total += amount
	_save()
	if _layer != null:
		_layer.visible = true
	if _label != null:
		_label.modulate = Color(1.7, 1.45, 0.7)
		create_tween().tween_property(_label, "modulate",
				Color(1, 1, 1), 0.5)
	gold_changed.emit(total)


## The relic flew home: pay its gold and raise the banner.
func relic_found() -> void:
	relic_found_flag = true
	add(RELIC_GOLD)
	ACH.award("relic")
	_banner()


## Try to pay `amount`. True (and deducted) if affordable; false with a
## red HUD flash if the purse is too light.
func spend(amount: int) -> bool:
	if amount > total:
		if _label != null:
			_label.modulate = Color(1.8, 0.35, 0.3)
			create_tween().tween_property(_label, "modulate",
					Color(1, 1, 1), 0.6)
		return false
	total -= amount
	_save()
	gold_changed.emit(total)
	return true


func _process(delta: float) -> void:
	if _label == null or is_equal_approx(_shown, float(total)):
		return
	var step := maxf(24.0, absf(_shown - float(total)) * 4.0) * delta
	_shown = move_toward(_shown, float(total), step)
	_refresh()


func _refresh() -> void:
	if _label != null:
		_label.text = str(int(round(_shown)))


## The relic banner: the find's name over a sub-line, center screen,
## with a low ceremonial gong. Fades in, holds, dissolves.
func _banner() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 95
	add_child(layer)
	var t := Label.new()
	t.text = "THE HORN OF THE NORTH-SEA"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.anchor_left = 0.0
	t.anchor_right = 1.0
	t.offset_top = 220.0
	t.offset_bottom = 292.0
	t.add_theme_font_size_override("font_size", 46)
	t.add_theme_color_override("font_color", INK)
	t.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	t.add_theme_constant_override("shadow_offset_y", 3)
	t.add_theme_constant_override("shadow_outline_size", 8)
	layer.add_child(t)
	var s := Label.new()
	s.text = "a relic of the drowned fleet  ·  %d gold" % RELIC_GOLD
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	s.anchor_left = 0.0
	s.anchor_right = 1.0
	s.offset_top = 294.0
	s.offset_bottom = 330.0
	s.add_theme_font_size_override("font_size", 22)
	s.add_theme_color_override("font_color", Color(0.9, 0.84, 0.68, 0.92))
	s.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	s.add_theme_constant_override("shadow_offset_y", 2)
	layer.add_child(s)
	t.modulate.a = 0.0
	s.modulate.a = 0.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(t, "modulate:a", 1.0, 0.6)
	tw.tween_property(s, "modulate:a", 1.0, 0.6).set_delay(0.25)
	tw.chain().tween_interval(2.4)
	tw.chain().tween_property(t, "modulate:a", 0.0, 0.9)
	tw.parallel().tween_property(s, "modulate:a", 0.0, 0.9)
	tw.chain().tween_callback(layer.queue_free)
	var pl := AudioStreamPlayer.new()
	pl.stream = _gong_stream()
	pl.volume_db = -4.0
	add_child(pl)
	pl.play()
	get_tree().create_timer(2.2).timeout.connect(pl.queue_free)


# --- the gong ---------------------------------------------------------------

const SR := 22050
static var _gong_cache: AudioStreamWAV


## A low ceremonial bell: G3 with its fifth and octave, long decay.
static func _gong_stream() -> AudioStreamWAV:
	if _gong_cache != null:
		return _gong_cache
	var length := int(1.8 * SR)
	var bytes := PackedByteArray()
	bytes.resize(length * 2)
	for i in length:
		var u := float(i) / float(SR)
		var env := exp(-2.6 * u)
		var v := 0.6 * sin(TAU * 196.0 * u) \
				+ 0.35 * sin(TAU * 294.0 * u) \
				+ 0.15 * sin(TAU * 392.0 * u)
		bytes.encode_s16(i * 2,
				int(clampf(v * env * 0.5, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	wav.data = bytes
	_gong_cache = wav
	return wav


# --- persistence ---------------------------------------------------------------

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("plunder", "gold", total)
	cfg.set_value("plunder", "relic_found", relic_found_flag)
	cfg.save(SAVE_PATH)
