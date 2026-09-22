class_name WanderingMerchant
extends Node3D
## The island's trader: a viking wanderer with a pack who strolls the
## village and sells three wares for plundered gold — a hotter fireball
## (faster, quicker recovery), a swim-boost charm (a faster crossing
## pace), and a torn map marking one random hoard chest on its pillar.
## Purchases persist across sessions (user://merchant.cfg); the map's
## marker burns out after 6 chest-loots. Spawned by PropScatter near
## the village's densest house cluster.

const SAVE_PATH := "user://merchant.cfg"
const MAP_USES := 6
const MAP_COLOR := Color(0.55, 1.0, 0.85)

const WARES := [
	{"id": "fire", "name": "Greater Fireballs", "cost": 60,
	 "blurb": "Fly faster, recover faster"},
	{"id": "charm", "name": "Swim Charm", "cost": 45,
	 "blurb": "Cross the sea at 5 m/s"},
	{"id": "map", "name": "Torn Sea Map", "cost": 80,
	 "blurb": "Marks one hoard chest (6 loots)"},
]

var _pack: Node3D
var _prompt: Label3D
var _shop: CanvasLayer
var _shop_box: VBoxContainer
var _shop_rows := {}
var _gold_row: Label
var _near := false
var _marker: MeshInstance3D
var _marker_label: Label3D
var _marker_chest: Node3D
var _marker_uses := 0
## Model animation (the GLB's walk clip, played in place) and the
## idle clock for the facing behavior.
var _anim: AnimationPlayer
var _walk_name := ""
var _t := 0.0
var _yaw := 0.0


func _ready() -> void:
	add_to_group("merchant")
	_build_pack()
	_build_prompt()
	_build_shop()
	_load_state()
	_apply_purchases()
	_setup_animation()
	_yaw = rotation.y


## The GLB's walk clip plays in place (a trader marking time at his
## stall — never walks, so the stride never has to match anything).
func _setup_animation() -> void:
	for node in find_children("*", "AnimationPlayer", true, false):
		_anim = node
		break
	if _anim != null and not _anim.get_animation_list().is_empty():
		for clip in _anim.get_animation_list():
			if "walk" in String(clip).to_lower():
				_walk_name = clip
				break
		if _walk_name.is_empty():
			_walk_name = _anim.get_animation_list()[0]
		var res := _anim.get_animation(_walk_name)
		if res != null:
			res.loop_mode = Animation.LOOP_LINEAR
		_anim.play(_walk_name)
		_anim.speed_scale = 0.0  # a statue until someone approaches


## Proximity scan; opens/closes the shop, turns to face the customer,
## and brings the walk clip alive only while someone is near.
func _physics_process(delta: float) -> void:
	_t += delta
	var players := get_tree().get_nodes_in_group("player")
	var near := false
	if not players.is_empty():
		var pc := players[0] as Node3D
		near = pc != null and pc.global_position.distance_to(
				global_position) < 5.0
	if near != _near:
		_near = near
		_shop.visible = near
		if near:
			_refresh_shop()
	# Face the customer while they browse; a slow idle scan otherwise.
	if near and not players.is_empty():
		var to := (players[0] as Node3D).global_position - global_position
		var want := atan2(-to.x, -to.z)
		_yaw = lerp_angle(_yaw, want, 1.0 - exp(-5.0 * delta))
	else:
		_yaw += delta * 0.25
	rotation.y = _yaw
	if _anim != null:
		# Stride in place while browsed, frozen when alone.
		_anim.speed_scale = 1.0 if near else 0.0
	_prompt.text = "" if near else "1 / 2 / 3 — buy"
	_prompt.visible = not near


## The pack on his back — the tell that this wanderer trades.
func _build_pack() -> void:
	_pack = Node3D.new()
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.34, 0.46, 0.18)
	body.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.52, 0.36, 0.20)
	mat.roughness = 0.9
	body.material_override = mat
	_pack.add_child(body)
	var flap := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(0.32, 0.16, 0.05)
	flap.mesh = fm
	flap.material_override = mat
	flap.position = Vector3(0, 0.26, -0.10)
	flap.rotation_degrees.x = -28
	_pack.add_child(flap)
	# A little coin pouch that says gold changes hands here.
	var pouch := MeshInstance3D.new()
	var pm := SphereMesh.new()
	pm.radius = 0.07
	pm.height = 0.14
	pouch.mesh = pm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.85, 0.66, 0.22)
	pmat.metallic = 0.6
	pmat.roughness = 0.4
	pouch.material_override = pmat
	pouch.position = Vector3(0.12, -0.12, -0.06)
	_pack.add_child(pouch)
	_pack.position = Vector3(0.0, 1.15, -0.42)
	_pack.rotation_degrees.x = 8.0
	add_child(_pack)


func _build_prompt() -> void:
	_prompt = Label3D.new()
	_prompt.text = ""
	_prompt.font_size = 40
	_prompt.pixel_size = 0.004
	_prompt.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_prompt.no_depth_test = true
	_prompt.modulate = Color(0.98, 0.94, 0.82)
	_prompt.outline_modulate = Color(0, 0, 0, 0.9)
	_prompt.position = Vector3(0, 2.35, 0)
	add_child(_prompt)


## The shop: a bordered parchment panel, opened near the trader.
func _build_shop() -> void:
	_shop = CanvasLayer.new()
	_shop.layer = 88
	add_child(_shop)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.07, 0.05, 0.93)
	sb.border_color = Color(1.0, 0.78, 0.25, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop.add_child(panel)
	_shop_box = VBoxContainer.new()
	_shop_box.add_theme_constant_override("separation", 6)
	_shop_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_shop_box)
	var t := Label.new()
	t.text = "— WANDERING TRADER —"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 22)
	t.add_theme_color_override("font_color",
			Color(1.0, 0.78, 0.25))
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop_box.add_child(t)
	_gold_row = Label.new()
	_gold_row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gold_row.add_theme_font_size_override("font_size", 18)
	_gold_row.add_theme_color_override("font_color",
			Color(0.98, 0.94, 0.82))
	_gold_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop_box.add_child(_gold_row)
	for w in WARES:
		var row := Label.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_font_size_override("font_size", 17)
		row.add_theme_color_override("font_color",
				Color(0.9, 0.86, 0.72))
		row.add_theme_color_override("font_shadow_color",
				Color(0, 0, 0, 0.8))
		_shop_box.add_child(row)
		_shop_rows[w.id] = row
	panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -360.0
	panel.offset_right = -24.0
	panel.offset_top = -150.0
	panel.offset_bottom = 150.0
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_shop.visible = false


## Keys 1/2/3 buy the three wares while the shop is open.
func _unhandled_input(event: InputEvent) -> void:
	if not _near:
		return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	var idx := keycode_to_index(k.keycode)
	if idx >= 0:
		buy(WARES[idx].id)


func keycode_to_index(code: int) -> int:
	match code:
		KEY_1: return 0
		KEY_2: return 1
		KEY_3: return 2
		_: return -1


func _refresh_shop() -> void:
	var ledgers := get_tree().get_nodes_in_group("gold_ledger")
	var gold := int(ledgers[0].get("total")) if not ledgers.is_empty() else 0
	_gold_row.text = "your gold: %d" % gold
	for w in WARES:
		var row: Label = _shop_rows[w.id]
		var owned: bool = _owned(w.id)
		var afford: bool = gold >= w.cost
		if owned:
			row.text = "[1] Greater Fireballs — owned"
			row.add_theme_color_override("font_color",
					Color(0.55, 0.85, 0.55))
		elif not afford:
			row.text = "[%d] %s — %d g  (need %d more)" \
					% [keycode_to_index_of(w), w.name, w.cost,
					w.cost - gold]
			row.add_theme_color_override("font_color",
					Color(0.75, 0.7, 0.6, 0.8))
		else:
			row.text = "[%d] %s — %d g" % [keycode_to_index_of(w),
					w.name, w.cost]
			row.add_theme_color_override("font_color",
					Color(0.9, 0.86, 0.72))


func keycode_to_index_of(w: Dictionary) -> int:
	for i in WARES.size():
		if WARES[i].id == w.id:
			return i
	return 0


## Owned-ware reads; called once at ready after loading the save.
func _apply_purchases() -> void:
	if fire_owned:
		_apply_fire()
	if charm_owned:
		_apply_charm()
	if map_uses > 0 and _marker_chest != null:
		_build_marker()


func _owned(id: String) -> bool:
	match id:
		"fire": return fire_owned
		"charm": return charm_owned
		"map": return map_uses > 0
	return false


## Buy a ware: deducts through the ledger, applies the effect.
func buy(id: String) -> bool:
	var w: Dictionary = {}
	for x in WARES:
		if x.id == id:
			w = x
	if w.is_empty() or _owned(id):
		return false
	var ledgers := get_tree().get_nodes_in_group("gold_ledger")
	if ledgers.is_empty():
		return false
	if not ledgers[0].call("spend", w.cost):
		return false
	match id:
		"fire":
			fire_owned = true
			_apply_fire()
		"charm":
			charm_owned = true
			_apply_charm()
		"map":
			map_uses = MAP_USES
			_place_map_marker()
	_save_state()
	_refresh_shop()
	_chime()
	return true


## --- the wares ------------------------------------------------------------

## Fireballs fly faster and recover faster.
func _apply_fire() -> void:
	var heroes := get_tree().get_nodes_in_group("player")
	if heroes.is_empty():
		return
	var caster: Node = (heroes[0] as Node).get_node_or_null("FireballCaster")
	if caster != null:
		caster.set("fireball_speed", 30.0)
		caster.set("cooldown", 0.28)


## The swim charm: a crossing pace of 5 m/s (from 3.4).
func _apply_charm() -> void:
	var heroes := get_tree().get_nodes_in_group("player")
	if heroes.is_empty():
		return
	heroes[0].set("swim_speed", 5.0)


## The map: marks one random unopened hoard chest with a teal pillar
## visible anywhere on the island. The mark burns out after 6 loots.
func _place_map_marker() -> void:
	var chests := get_tree().get_nodes_in_group("sunken_chest")
	var fresh: Array = []
	for c in chests:
		if not bool(c.call("is_open")):
			fresh.append(c)
	if fresh.is_empty():
		return
	var pick: Node3D = fresh[randi() % fresh.size()]
	_marker_chest = pick
	_marker_uses = MAP_USES
	_build_marker()
	# All chests learn the signal: when ANY chest is looted, the map's
	# usefulness ticks down.
	for c in chests:
		if not (c as Node).is_connected("opened", Callable(self, "_on_chest_looted")):
			(c as Node).connect("opened", Callable(self, "_on_chest_looted"))


func _build_marker() -> void:
	if _marker != null:
		_marker.queue_free()
		_marker = null
	# The chest's own surface marker sits ~marker_height up; ours stands
	# taller in teal so the two read apart.
	var top := (_marker_chest as Node3D).global_position \
			+ Vector3(0, 34.0, 0)
	_marker = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.25
	cyl.bottom_radius = 0.7
	cyl.height = 34.0
	cyl.radial_segments = 12
	_marker.mesh = cyl
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(MAP_COLOR.r, MAP_COLOR.g, MAP_COLOR.b, 0.20)
	m.emission_enabled = true
	m.emission = MAP_COLOR
	m.emission_energy_multiplier = 1.3
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_marker.material_override = m
	_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(_marker)
	_marker.global_position = top - Vector3(0, 17.0, 0)
	# A floating label at the top.
	_marker_label = Label3D.new()
	_marker_label.text = "HOARD (mapped)"
	_marker_label.font_size = 48
	_marker_label.pixel_size = 0.004
	_marker_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_marker_label.modulate = MAP_COLOR
	_marker_label.outline_modulate = Color(0, 0, 0, 0.9)
	get_tree().current_scene.add_child(_marker_label)
	_marker_label.global_position = top + Vector3(0, 2.5, 0)


func _on_chest_looted(_pos: Vector3) -> void:
	if map_uses <= 0:
		return
	map_uses -= 1
	_save_state()
	if map_uses <= 0:
		# The ink has run out.
		if _marker != null:
			_marker.queue_free()
			_marker = null
		if _marker_label != null:
			_marker_label.queue_free()
			_marker_label = null


# --- persistence ---------------------------------------------------------------

var fire_owned := false
var charm_owned := false
var map_uses := 0


func _save_state() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("wares", "fire", fire_owned)
	cfg.set_value("wares", "charm", charm_owned)
	cfg.set_value("wares", "map_uses", map_uses)
	cfg.save(SAVE_PATH)


func _load_state() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	fire_owned = bool(cfg.get_value("wares", "fire", false))
	charm_owned = bool(cfg.get_value("wares", "charm", false))
	map_uses = int(cfg.get_value("wares", "map_uses", 0))
	if map_uses > 0:
		# Re-mark: random chest again (the sea shifts, the trader shrugs).
		call_deferred("_place_map_marker")


## Restart Saga: forget every ware, drop the map marker, and restore
## the hero's base caster/swim stats the upgrades had overridden —
## the trader arrives at a fresh island with an empty satchel.
func reset_saga() -> void:
	fire_owned = false
	charm_owned = false
	map_uses = 0
	_marker_uses = 0
	_marker_chest = null
	if _marker != null:
		_marker.queue_free()
		_marker = null
	if _marker_label != null:
		_marker_label.queue_free()
		_marker_label = null
	DirAccess.remove_absolute(SAVE_PATH)
	var heroes := get_tree().get_nodes_in_group("player")
	if not heroes.is_empty():
		var caster: Node = (heroes[0] as Node).get_node_or_null("FireballCaster")
		if caster != null:
			caster.set("fireball_speed", 18.0)
			caster.set("cooldown", 0.45)
		heroes[0].set("swim_speed", 3.4)


## Undo Restart: re-read the restored wares and re-apply everything
## the restored save says the hero owns.
func refresh_saga() -> void:
	_load_state()
	_apply_purchases()
	_refresh_shop()


# --- the chime ---------------------------------------------------------------

const SR := 22050
static var _chime_cache: AudioStreamWAV


## A little two-note "sold!" — F5 then A5, soft and quick.
static func _chime_stream() -> AudioStreamWAV:
	if _chime_cache != null:
		return _chime_cache
	var length := int(0.55 * SR)
	var bytes := PackedByteArray()
	bytes.resize(length * 2)
	var notes := [[0.0, 0.18, 698.46], [0.15, 0.35, 880.0]]
	for n in notes:
		var start := int(n[0] * SR)
		var dur := int(n[1] * SR)
		for i in dur:
			var idx := start + i
			if idx >= length:
				break
			var u := float(i) / float(SR)
			var du := float(i) / float(dur)
			var env := minf(du / 0.08, 1.0) * exp(-3.0 * du)
			var v := sin(TAU * n[2] * u) + 0.3 * sin(TAU * n[2] * 2.0 * u)
			bytes.encode_s16(idx * 2,
					int(clampf(v * env * 0.35, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	wav.data = bytes
	_chime_cache = wav
	return wav


func _chime() -> void:
	var pl := AudioStreamPlayer.new()
	pl.stream = _chime_stream()
	pl.volume_db = -6.0
	add_child(pl)
	pl.play()
	get_tree().create_timer(0.8).timeout.connect(pl.queue_free)
