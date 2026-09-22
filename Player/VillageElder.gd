class_name VillageElder
extends Node3D
## The village elder: a weathered viking by the well who hands out the
## saga's errands and pays out their gold. Walk close and his counsel
## panel opens (left side) — every errand of the QuestBoard with its
## state; ready rewards claim with keys 1-6. He holds no state himself:
## the QuestBoard owns progress and persistence; he is its voice.
##
## Spawned by PropScatter beside the village's merchant.

const NEAR_DIST := 4.2

var _prompt: Label3D
var _panel: CanvasLayer
var _rows := {}
var _gold_row: Label
var _near := false
var _yaw := 0.0
var _t := 0.0


func _ready() -> void:
	add_to_group("village_elder")
	_build_staff()
	_build_prompt()
	_build_panel()


func _physics_process(delta: float) -> void:
	_t += delta
	var players := get_tree().get_nodes_in_group("player")
	var near := false
	if not players.is_empty():
		var p := players[0] as Node3D
		if p != null:
			near = global_position.distance_to(p.global_position) < NEAR_DIST
	if near != _near:
		_near = near
		_panel.visible = near
		if near:
			_refresh_panel()
	# Face the customer while they listen; a slow scan otherwise.
	if near and not players.is_empty():
		var to := (players[0] as Node3D).global_position - global_position
		var want := atan2(-to.x, -to.z)
		_yaw = lerp_angle(_yaw, want, 1.0 - exp(-5.0 * delta))
	else:
		_yaw += delta * 0.25
	rotation.y = _yaw
	_prompt.text = "" if near else "speak"


func _unhandled_input(event: InputEvent) -> void:
	if not _near:
		return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	var idx := keycode_to_index(k.keycode)
	if idx >= 0:
		_claim(idx)


func keycode_to_index(code: int) -> int:
	match code:
		KEY_1: return 0
		KEY_2: return 1
		KEY_3: return 2
		KEY_4: return 3
		KEY_5: return 4
		KEY_6: return 5
		_: return -1


func _claim(idx: int) -> void:
	var boards := get_tree().get_nodes_in_group("quest_board")
	if boards.is_empty():
		return
	var board: Node = boards[0]
	var quests: Array = board.get("QUESTS")
	if idx >= quests.size():
		return
	board.call("claim", quests[idx]["id"])
	_refresh_panel()


## A weathered wooden staff — the tell that this viking counsels.
func _build_staff() -> void:
	var staff := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.035
	cyl.bottom_radius = 0.05
	cyl.height = 1.9
	staff.mesh = cyl
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.45, 0.31, 0.18)
	m.roughness = 0.95
	staff.material_override = m
	staff.position = Vector3(0.42, 0.95, 0.05)
	staff.rotation_degrees.z = -4.0
	add_child(staff)
	# A knot of gold thread near the top: he pays in plunder.
	var knot := MeshInstance3D.new()
	var km := TorusMesh.new()
	km.inner_radius = 0.055
	km.outer_radius = 0.085
	knot.mesh = km
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(1.0, 0.78, 0.25)
	gm.metallic = 0.8
	gm.roughness = 0.35
	knot.material_override = gm
	knot.position = Vector3(0.415, 1.62, 0.05)
	add_child(knot)


func _build_prompt() -> void:
	_prompt = Label3D.new()
	_prompt.text = "speak"
	_prompt.font_size = 40
	_prompt.pixel_size = 0.004
	_prompt.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_prompt.no_depth_test = true
	_prompt.modulate = Color(0.98, 0.94, 0.82)
	_prompt.outline_modulate = Color(0, 0, 0, 0.9)
	_prompt.position = Vector3(0, 2.35, 0)
	add_child(_prompt)


## The counsel panel: the board's errands with their state, parchment
## on the LEFT (the trader's shop sits on the right).
func _build_panel() -> void:
	_panel = CanvasLayer.new()
	_panel.layer = 88
	add_child(_panel)
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
	_panel.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(box)
	var t := Label.new()
	t.text = "— VILLAGE ELDER —"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 22)
	t.add_theme_color_override("font_color", Color(1.0, 0.78, 0.25))
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(t)
	_gold_row = Label.new()
	_gold_row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gold_row.add_theme_font_size_override("font_size", 18)
	_gold_row.add_theme_color_override("font_color",
			Color(0.98, 0.94, 0.82))
	_gold_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_gold_row)
	var boards := get_tree().get_nodes_in_group("quest_board")
	var quests: Array = (boards[0].get("QUESTS")
			if not boards.is_empty() else [])
	for q in quests:
		var row := Label.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_font_size_override("font_size", 17)
		row.add_theme_color_override("font_color", Color(0.9, 0.86, 0.72))
		row.add_theme_color_override("font_shadow_color",
				Color(0, 0, 0, 0.8))
		box.add_child(row)
		_rows[q["id"]] = row
	var hint := Label.new()
	hint.text = "1-6: claim ready rewards"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color",
			Color(0.9, 0.84, 0.68, 0.7))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(hint)
	panel.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	panel.anchor_left = 0.0
	panel.anchor_right = 0.0
	panel.offset_left = 24.0
	panel.offset_right = 384.0
	panel.offset_top = -150.0
	panel.offset_bottom = 150.0
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.visible = false


func _refresh_panel() -> void:
	var boards := get_tree().get_nodes_in_group("quest_board")
	if boards.is_empty():
		return
	var board: Node = boards[0]
	var quests: Array = board.get("QUESTS")
	var ledgers := get_tree().get_nodes_in_group("gold_ledger")
	var gold := int(ledgers[0].get("total")) if not ledgers.is_empty() else 0
	_gold_row.text = "your gold: %d" % gold
	var key := 1
	for q in quests:
		var id: String = q["id"]
		var row: Label = _rows[id]
		if row == null:
			continue
		var claimed_now: bool = board.call("is_claimed", id)
		var done_now: bool = board.call("is_done", id)
		if claimed_now:
			row.text = "✓ %s" % q["name"]
			row.add_theme_color_override("font_color",
					Color(0.62, 0.57, 0.44))
		elif done_now:
			row.text = "%d) %s — CLAIM %d gold" % [key, q["name"], q["reward"]]
			row.add_theme_color_override("font_color",
					Color(1.0, 0.78, 0.25))
		else:
			row.text = "· %s" % q["desc"]
			row.add_theme_color_override("font_color",
					Color(0.9, 0.86, 0.72))
		key += 1
