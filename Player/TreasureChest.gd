class_name TreasureChest
extends Node3D
## A lootable treasure chest, placed by PropScatter on castle rooftops,
## lighthouse galleries and climb-spot tops — the reward for getting up
## high. Procedural build (no model exists in the project): wood body,
## iron bands, a pulsing GOLD SEAM between lid and body that reads from
## a distance, and a faint warm light. Get close and the lid swings
## open with a sparkle burst and a rising fanfare.
##
## Opened chests persist in user://chests.cfg (keyed by chest id) —
## they stay open across restarts, with the gold spilling out. Cheap:
## idle chests tick only the seam pulse, and the Area does the rest.

const SAVE_PATH := "user://chests.cfg"
const ACH := preload("res://Player/Achievements.gd")
const PICKUP_RANGE := 2.6
const OPEN_TIME := 0.6
## Sunken (sea-floor) chests: opened only from a hull nearly above and
## nearly stopped — sailing is the only way to reach them.
const SUNKEN_PICKUP_RANGE := 2.4
const SUNKEN_MAX_OPEN_SPEED := 1.2
const SUNKEN_GLINT_RANGE := 26.0

## Wood / iron / gold palette (low-poly warm kit).
const WOOD_A := Color(0.45, 0.30, 0.16)
const WOOD_B := Color(0.36, 0.23, 0.11)
const IRON := Color(0.16, 0.15, 0.15)
const GOLD := Color(1.0, 0.78, 0.25)

## Emitted the moment this chest is opened (world position) — the
## merchant's torn map ticks its uses down on any hoard loot.
signal opened(at: Vector3)

var chest_id := ""
## World position of the standing surface the chest sits ON.
var surface_y := 0.0
## Sunken mode: sits on the offshore seabed, glowing almost not at all
## (marked on no map). Discovered only by sailing near — a faint wisp
## of bubbles rises when a hull passes within glint range.
var sunken := false

## This chest carries THE HORN OF THE NORTH-SEA: opening it launches
## the relic flight (rise, breach, fly to the hero) and the banner.
## Marked by PropScatter on the deepest sea-hoard chest.
var relic := false

var _body: MeshInstance3D
var _lid: Node3D
var _seam: MeshInstance3D
var _gold_mat: StandardMaterial3D
var _light: OmniLight3D
var _opened := false
var _t := 0.0
## Sunken-mode glint: bubble wisps while a sailing hull is near.
var _bubbles: GPUParticles3D
var _glinting := false
## Incremented each time the glint starts (headless-verifiable).
var glint_count := 0
## Dive-loot dressing: sparkle trail + surface depth marker.
var _trail: GPUParticles3D
var _pillar: MeshInstance3D
var _marker: Label3D
## Waterline height above the chest origin (m) — the marker reads
## this; headless-verifiable.
var marker_height := 0.0
## Waterline hint (set by the spawner from the sea level; the
## player-group fallback covers ordering races).
var _water_y_hint := 0.0


func set_waterline(w: float) -> void:
	_water_y_hint = w


func _ready() -> void:
	add_to_group("treasure_chest")
	if sunken:
		add_to_group("sunken_chest")
	_build()
	_load_state()
	if sunken:
		_build_dive_dressing()


func _build() -> void:
	# --- materials (shared per instance; chests are few) ----------------
	var wood := StandardMaterial3D.new()
	wood.albedo_color = WOOD_A
	wood.roughness = 0.85
	var wood_dark := StandardMaterial3D.new()
	wood_dark.albedo_color = WOOD_B
	wood_dark.roughness = 0.9
	var iron := StandardMaterial3D.new()
	iron.albedo_color = IRON
	iron.metallic = 0.7
	iron.roughness = 0.45
	var gold := StandardMaterial3D.new()
	gold.albedo_color = GOLD
	gold.emission_enabled = true
	gold.emission = GOLD
	gold.emission_energy_multiplier = 2.2
	_gold_mat = gold
	if sunken:
		# Ten years under the sea: algae-stained timber, duller iron.
		wood.albedo_color = WOOD_A.lerp(Color(0.22, 0.30, 0.22), 0.55)
		wood_dark.albedo_color = WOOD_B.lerp(Color(0.16, 0.24, 0.17), 0.55)
		iron.albedo_color = IRON.lerp(Color(0.25, 0.32, 0.26), 0.4)
		iron.metallic = 0.2
		gold.emission_energy_multiplier = 0.55

	# --- body: a bevelled box with iron bands ---------------------------
	_body = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.9, 0.55, 0.6)
	_body.mesh = bm
	_body.material_override = wood
	_body.position.y = 0.275
	add_child(_body)
	for side in [-1.0, 1.0]:
		var band := MeshInstance3D.new()
		var bam := BoxMesh.new()
		bam.size = Vector3(0.08, 0.56, 0.62)
		band.mesh = bam
		band.material_override = iron
		band.position = Vector3(side * 0.28, 0.275, 0.0)
		add_child(band)
	# Feet: four little iron stubs keep it off the stone.
	for fx in [-0.36, 0.36]:
		for fz in [-0.2, 0.2]:
			var foot := MeshInstance3D.new()
			var fm := BoxMesh.new()
			fm.size = Vector3(0.08, 0.06, 0.08)
			foot.mesh = fm
			foot.material_override = iron
			foot.position = Vector3(fx, 0.03, fz)
			add_child(foot)

	# --- lid: hinged at the back edge, swings open ----------------------
	_lid = Node3D.new()
	_lid.position = Vector3(0.0, 0.55, -0.3)  # the hinge line
	add_child(_lid)
	var lid_mesh := MeshInstance3D.new()
	var lm := CylinderMesh.new()
	# A half-round lid: full cylinder, sunk so the top half shows.
	lm.top_radius = 0.3
	lm.bottom_radius = 0.3
	lm.height = 0.9
	lm.radial_segments = 10
	lid_mesh.mesh = lm
	lid_mesh.material_override = wood_dark
	lid_mesh.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	lid_mesh.position = Vector3(0.0, 0.0, 0.3)
	_lid.add_child(lid_mesh)
	# Iron straps over the lid.
	for side in [-1.0, 1.0]:
		var strap := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(0.08, 0.1, 0.62)
		strap.mesh = sm
		strap.material_override = iron
		strap.position = Vector3(side * 0.28, 0.0, 0.3)
		_lid.add_child(strap)
	# Lock plate on the front.
	var lock := MeshInstance3D.new()
	var lkm := BoxMesh.new()
	lkm.size = Vector3(0.14, 0.18, 0.04)
	lock.mesh = lkm
	lock.material_override = iron
	lock.position = Vector3(0.0, 0.47, 0.32)
	add_child(lock)

	# --- the gold seam: glowing slot between lid and body ---------------
	_seam = MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(0.86, 0.03, 0.56)
	_seam.mesh = gm
	_seam.material_override = _gold_mat
	_seam.position.y = 0.56
	add_child(_seam)

	# --- a faint warm glow so high chests read at dusk ------------------
	# Sunken chests carry NO light: nothing may read from the surface.
	if not sunken:
		_light = OmniLight3D.new()
		_light.light_color = Color(1.0, 0.75, 0.4)
		_light.light_energy = 0.5
		_light.omni_range = 3.5
		_light.shadow_enabled = false
		_light.position.y = 0.8
		add_child(_light)
	else:
		_build_bubbles()


## Called by PropScatter after positioning: id keys persistence.
func setup(id: String, y_surface: float) -> void:
	chest_id = id
	surface_y = y_surface


## Sunken variant: same persistence, different pickup rules and look.
## Call INSTEAD of setup (before the node enters the tree).
func setup_sunken(id: String, y_surface: float) -> void:
	sunken = true
	setup(id, y_surface)


## Diagnostics/tests.
func get_id() -> String:
	return chest_id


func is_open() -> bool:
	return _opened


## Restart Saga: this chest seals itself — lid shut, seam burning,
## dressing relit — so it can be plundered again on the new voyage.
func reset_saga() -> void:
	if not _opened:
		return
	_opened = false
	_lid.rotation_degrees.x = 0.0
	# The fresh-built seam energies (land burns bright, sunken glows
	# under water); the idle pulse takes the rhythm from here.
	_gold_mat.emission_energy_multiplier = 0.55 if sunken else 2.2
	if _light != null:
		_light.light_energy = 0.5
	if _trail != null:
		_trail.emitting = true
	if _pillar != null:
		(_pillar.material_override as StandardMaterial3D).albedo_color.a = 0.10
	if _marker != null:
		_marker.text = _depth_text()


## Undo Restart: settle this chest against the RESTORED save. A chest
## the wipe resealed but the backup says looted hangs its lid back
## open (as _load_state would after a reboot); one looted only in the
## wiped timeline reseals its payout file — the reopened gold must not
## survive an undo.
func reopen_saga() -> void:
	var was := false
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		was = bool(cfg.get_value("opened", chest_id, false))
	if was:
		if not _opened:
			_opened = true
			_lid.rotation_degrees.x = -105.0
			_gold_mat.emission_energy_multiplier = 0.0
			if _light != null:
				_light.light_energy = 0.0
			if _trail != null:
				_trail.emitting = false
			if _pillar != null:
				(_pillar.material_override as StandardMaterial3D).albedo_color.a = 0.03
			if _marker != null:
				_marker.text = "%s — LOOTED" % _depth_text()
		return
	# Plundered only in the wiped timeline: rewind to sealed — the
	# restored save has no record of this chest's gold.
	reset_saga()


func _process(delta: float) -> void:
	_t += delta
	# The relic flies home after opening (rise, breach, absorb).
	if _relic != null:
		_tick_relic(delta)
	# Idle seam pulse; dead still once opened and emptied.
	if not _opened:
		if sunken:
			_tick_sunken(delta)
			return
		var pulse := 1.6 + sin(_t * 2.4) * 0.7
		_gold_mat.emission_energy_multiplier = pulse
		if _light != null:
			_light.light_energy = 0.35 + sin(_t * 2.4) * 0.18
		# Pickup check — cheap distance test, no physics callback needed.
		for p in get_tree().get_nodes_in_group("player"):
			var pc := p as Node3D
			if pc != null and pc.global_position.distance_to(
					global_position + Vector3(0, 0.4, 0)) <= PICKUP_RANGE:
				_open()
	# Gold light dies down after opening.
	elif _light != null and _light.light_energy > 0.06:
		_light.light_energy = maxf(_light.light_energy - delta, 0.06)


## Sunken idle: a subdued seam shimmer (visible only to a diver), the
## glint wisp while a sailing hull is near, and the hull-above open
## check — a swimmer at the lid can NOT open it; only a nearly-stopped
## hull almost directly overhead does.
func _tick_sunken(delta: float) -> void:
	# The relic chest's seam burns brighter — a diver who knows the
	# difference can spot the one that matters.
	var seam_base := 1.4 if relic else 0.55
	_gold_mat.emission_energy_multiplier = seam_base + sin(_t * 1.1) * 0.15
	var ship_near := false
	for p in get_tree().get_nodes_in_group("player"):
		var pc := p as Node3D
		if pc == null or not bool(p.get("sailing")):
			continue
		var d := Vector2(pc.global_position.x - global_position.x,
				pc.global_position.z - global_position.z).length()
		if d > SUNKEN_GLINT_RANGE:
			continue
		ship_near = true
		if d <= SUNKEN_PICKUP_RANGE:
			var host: Node = p.get("_sail_host")
			var spd: float = 0.0
			if host != null and is_instance_valid(host):
				spd = host.get("_speed")
			if spd <= SUNKEN_MAX_OPEN_SPEED:
				_open()
				return
	if ship_near != _glinting:
		_glinting = ship_near
		if _bubbles != null:
			_bubbles.emitting = ship_near
		if ship_near:
			glint_count += 1
	# A DIVER at the lid may open it too — the swim-and-dive loot loop.
	# Nearly stopped, at chest depth, within reach of the body.
	for p in get_tree().get_nodes_in_group("player"):
		var pc := p as Node3D
		if pc == null or bool(p.get("sailing")):
			continue
		if pc.global_position.distance_to(
				global_position + Vector3(0, 0.6, 0)) > SUNKEN_PICKUP_RANGE:
			continue
		var v: Vector3 = p.get("velocity")
		if Vector2(v.x, v.z).length() <= SUNKEN_MAX_OPEN_SPEED + 0.8:
			_open()
			return


## --- Dive-loot dressing ---------------------------------------------------

## The dive-loot dressing for sunken chests: an always-on gold sparkle
## trail rising from the lid (the underwater breadcrumb), and a surface
## depth marker — a slim light pillar from the waterline down plus a
## floating depth label readable from a sailing deck.
func _build_dive_dressing() -> void:
	# Sparkle trail: sparse gold motes drifting up from the lid.
	_trail = GPUParticles3D.new()
	_trail.emitting = true
	_trail.amount = 7
	_trail.lifetime = 3.2
	_trail.local_coords = false
	_trail.visibility_aabb = AABB(Vector3(-1.5, 0, -1.5), Vector3(3, 30, 3))
	var m := ParticleProcessMaterial.new()
	m.gravity = Vector3(0.0, 0.35, 0.0)
	m.direction = Vector3.UP
	m.spread = 24.0
	m.initial_velocity_min = 0.5
	m.initial_velocity_max = 1.1
	m.scale_min = 0.25
	m.scale_max = 0.55
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.85, 0.4, 0.85))
	g.set_color(1, Color(1.0, 0.85, 0.4, 0.0))
	var t := GradientTexture1D.new()
	t.gradient = g
	m.color_ramp = t
	_trail.process_material = m
	var q := QuadMesh.new()
	q.size = Vector2(0.08, 0.08)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.vertex_color_use_as_albedo = true
	qm.albedo_texture = _soft_dot()
	q.material = qm
	_trail.draw_pass_1 = q
	_trail.position.y = 0.7
	add_child(_trail)

	# The waterline height above the chest — the spawner's hint wins;
	# otherwise read the player's shared water level.
	var water_y := _water_y_hint
	if water_y == 0.0:
		for n in get_tree().get_nodes_in_group("player"):
			water_y = float(n.get("water_y"))
			break
	marker_height = clampf(water_y - global_position.y, 2.0, 60.0)

	# Pillar: slim additive column, bottom near the lid, top at the
	# waterline (chest-local y: waterline is (water_y - origin.y) up).
	_pillar = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.45
	cyl.bottom_radius = 0.9
	cyl.height = marker_height
	cyl.radial_segments = 10
	cyl.rings = 1
	_pillar.mesh = cyl
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	pm.albedo_color = Color(1.0, 0.85, 0.4, 0.10)
	pm.cull_mode = BaseMaterial3D.CULL_DISABLED
	pm.no_depth_test = false
	_pillar.material_override = pm
	_pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pillar.position.y = (water_y - global_position.y) - marker_height * 0.5
	add_child(_pillar)

	# Depth label: floats just above the waterline, readable from a
	# sailing deck at distance.
	_marker = Label3D.new()
	_marker.text = _depth_text()
	_marker.font_size = 52
	_marker.pixel_size = 0.01
	_marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_marker.modulate = Color(1.0, 0.88, 0.55, 0.9)
	_marker.outline_size = 8
	_marker.position.y = (water_y - global_position.y) + 1.2
	add_child(_marker)
	# Pre-looted (persisted from a past session): the dressing must
	# match — trail off, pillar dim, label already claimed.
	if _opened:
		_trail.emitting = false
		(pm as StandardMaterial3D).albedo_color.a = 0.03
		_marker.text = "%s — LOOTED" % _depth_text()


## The depth readout for the marker label.
func _depth_text() -> String:
	return "%d m down" % int(round(marker_height))


## A faint wisp of bubbles rising from the lid — one of the surface
## cues, and only while a sailing hull is within glint range.
func _build_bubbles() -> void:
	_bubbles = GPUParticles3D.new()
	_bubbles.emitting = false
	_bubbles.amount = 9
	_bubbles.lifetime = 2.2
	_bubbles.local_coords = false
	_bubbles.visibility_aabb = AABB(Vector3(-1, 0, -1), Vector3(2, 26, 2))
	var m := ParticleProcessMaterial.new()
	m.gravity = Vector3(0.0, 0.55, 0.0)
	m.direction = Vector3.UP
	m.spread = 12.0
	m.initial_velocity_min = 0.7
	m.initial_velocity_max = 1.3
	m.scale_min = 0.35
	m.scale_max = 0.8
	var g := Gradient.new()
	g.set_color(0, Color(0.85, 0.95, 1.0, 0.5))
	g.set_color(1, Color(0.85, 0.95, 1.0, 0.0))
	var t := GradientTexture1D.new()
	t.gradient = g
	m.color_ramp = t
	_bubbles.process_material = m
	var q := QuadMesh.new()
	q.size = Vector2(0.09, 0.09)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.vertex_color_use_as_albedo = true
	qm.albedo_texture = _soft_dot()
	q.material = qm
	_bubbles.draw_pass_1 = q
	_bubbles.position.y = 0.6
	add_child(_bubbles)


## Soft radial dot texture (same recipe as the dust/foam puffs).
func _soft_dot() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color.WHITE)
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 64
	t.height = 64
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	return t


func _open() -> void:
	if _opened:
		return
	_opened = true
	_save_state()
	opened.emit(global_position)
	_pay_out()
	if _bubbles != null:
		_bubbles.emitting = false  # the hoard is claimed; no more cues
	if _trail != null:
		_trail.emitting = false
	if _marker != null:
		_marker.text = "%s — LOOTED" % _depth_text()
	if _pillar != null:
		(_pillar.material_override as StandardMaterial3D).albedo_color.a = 0.03
	# Swing the lid back on its hinge.
	var tw := create_tween()
	tw.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_property(_lid, "rotation_degrees:x", -105.0, OPEN_TIME)
	# The seam goes dark — the gold is OUT.
	_gold_mat.emission_energy_multiplier = 0.0
	_sparkles()
	_fanfare()
	if relic:
		_relic_flight()


## The plunder: every chest pays gold into the ledger (sunken chests
## pay big — they earned a dive), and the relic chest launches the
## flight home instead of paying out directly.
const HOARD_GOLD := 40
const LAND_GOLD := 15

func _pay_out() -> void:
	var ledgers := get_tree().get_nodes_in_group("gold_ledger")
	if ledgers.is_empty():
		return
	var amount := HOARD_GOLD if sunken else LAND_GOLD
	ledgers[0].call("add", amount)
	_coin_burst(HOARD_GOLD / 4 if sunken else 6)
	# The saga's deeds: the first chest ever, and the day the island
	# runs out of chests to plunder.
	ACH.award("first_chest")
	var placed := 0
	var cf := ConfigFile.new()
	if cf.load("user://chests.cfg") == OK:
		placed = int(cf.get_value("progress", "placed", 0))
	var opened := 0
	for ch in get_tree().get_nodes_in_group("treasure_chest"):
		var c := ch as TreasureChest
		if c != null and c.is_open():
			opened += 1
	if placed > 0 and opened >= placed:
		ACH.award("plunder_all")


## A fountain of fat coins arcing out of the opening, in the same
## ballistic style as the sparkle fountain (but slower, heavier).
func _coin_burst(count: int) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GOLD
	mat.emission_enabled = true
	mat.emission = GOLD
	mat.emission_energy_multiplier = 1.6
	mat.metallic = 0.8
	mat.roughness = 0.3
	for i in count:
		var c := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.055
		cm.bottom_radius = 0.055
		cm.height = 0.018
		cm.radial_segments = 10
		c.mesh = cm
		c.material_override = mat
		c.rotation_degrees = Vector3(_rand_range(-70, -110), _rand_range(0, 360), 0)
		c.position = Vector3(_rand_range(-0.2, 0.2), 0.55,
				_rand_range(-0.12, 0.12))
		add_child(c)
		var dir := Vector3(_rand_range(-0.8, 0.8), _rand_range(1.6, 2.6),
				_rand_range(-0.8, 0.8))
		var flight := _rand_range(0.55, 0.85)
		var tw := c.create_tween()
		tw.set_parallel(true)
		tw.tween_property(c, "position", c.position + dir * 0.8, flight) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(c, "rotation_degrees:z",
				c.rotation_degrees.z + _rand_range(-360, 360), flight)
		tw.chain().tween_property(c, "position:y",
				c.position.y + dir.y * 0.8 - 0.9, 0.5) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.chain().tween_callback(c.queue_free)


## The relic: a golden horn materializes over the lid, rises out of
## the sea spinning, breaches with a glow, then streaks to the hero.
## The chest's _process drives the flight stages.
var _relic: MeshInstance3D
var _relic_stage := 0
var _relic_t := 0.0
var _relic_from := Vector3.ZERO

func _relic_flight() -> void:
	_horn = MeshInstance3D.new()
	var hm := TorusMesh.new()
	hm.inner_radius = 0.06
	hm.outer_radius = 0.16
	_horn.mesh = hm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GOLD
	mat.emission_enabled = true
	mat.emission = GOLD
	mat.emission_energy_multiplier = 2.2
	mat.metallic = 0.85
	mat.roughness = 0.25
	_horn.material_override = mat
	_horn.position = global_position + Vector3(0, 0.6, 0)
	get_parent().add_child(_horn)
	_relic = _horn
	_relic_stage = 1
	_relic_t = 0.0
	_relic_from = _horn.global_position


var _horn: MeshInstance3D

## Two flight stages: rise straight up from the seabed to above the
## waves (spinning, 2.2 s), then home to the hero's chest accelerating
## — absorbed into the ledger with the banner + gong.
func _tick_relic(delta: float) -> void:
	if _relic_stage == 1:
		_relic_t += delta
		var u := clampf(_relic_t / 2.2, 0.0, 1.0)
		var ease_u := 1.0 - pow(1.0 - u, 2.2)
		_horn.global_position = _relic_from \
				+ Vector3(0, ease_u * (2.2 - _relic_from.y), 0)
		_horn.rotation.y += delta * 4.0
		if u >= 1.0:
			_relic_stage = 2
			_relic_t = 0.0
	elif _relic_stage == 2:
		_relic_t += delta
		var heroes := get_tree().get_nodes_in_group("player")
		if heroes.is_empty():
			return
		var head_y: float = 1.5
		var target: Vector3 = (heroes[0] as Node3D).global_position \
				+ Vector3(0, head_y, 0)
		var speed := 6.0 + _relic_t * 26.0
		var to := target - _horn.global_position
		if to.length() < 0.6 or _relic_t > 6.0:
			_relic_stage = 0
			_horn.queue_free()
			_relic = null
			for ledgers in [get_tree().get_nodes_in_group("gold_ledger")]:
				if not ledgers.is_empty():
					ledgers[0].call("relic_found")
			return
		_horn.global_position += to.normalized() * speed * delta
		_horn.rotation.y += delta * 9.0


## PropScatter marks the deepest sea-hoard chest as the relic carrier
## (after _ready, so the marker label gets updated here).
func mark_relic() -> void:
	relic = true
	if _marker != null and not _opened:
		_marker.text = "%s — SOMETHING GLINTS BELOW" % _depth_text()


## A little fountain of gold sparks from the opening.
func _sparkles() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GOLD
	mat.emission_enabled = true
	mat.emission = GOLD
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for i in 14:
		var s := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2.ONE * _rand_range(0.06, 0.13)
		s.mesh = qm
		s.material_override = mat
		s.position = Vector3(_rand_range(-0.25, 0.25), 0.6,
				_rand_range(-0.15, 0.15))
		add_child(s)
		_animate_spark(s)


func _animate_spark(s: MeshInstance3D) -> void:
	var dir := Vector3(_rand_range(-1, 1), _rand_range(1.2, 2.2),
			_rand_range(-1, 1))
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(s, "position",
			s.position + dir * 0.9, 0.7).set_ease(Tween.EASE_OUT)
	tw.tween_property(s, "rotation_degrees:y",
			_rand_range(-360, 360), 0.7)
	tw.chain().tween_property(s, "position:y",
			s.position.y + dir.y * 0.9 - 1.6, 0.8) \
			.set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(s.queue_free)


func _rand_range(a: float, b: float) -> float:
	return randf_range(a, b)


# --- the fanfare ---------------------------------------------------------------

const SR := 22050
static var _fan_cache: AudioStreamWAV


## A rising three-note brass riff (C-E-G arpeggio) with a shimmer tail.
static func _fanfare_stream() -> AudioStreamWAV:
	if _fan_cache != null:
		return _fan_cache
	var length := int(1.1 * SR)
	var bytes := PackedByteArray()
	bytes.resize(length * 2)
	var notes := [[0.0, 0.22, 523.25], [0.2, 0.22, 659.25],
			[0.4, 0.5, 783.99]]  # start, dur, freq (C5 E5 G5)
	var data := PackedFloat32Array()
	data.resize(length)
	for n in notes:
		var start := int(n[0] * SR)
		var dur := int(n[1] * SR)
		for i in dur:
			var idx := start + i
			if idx >= length:
				break
			var u := float(i) / float(SR)
			var du := float(i) / float(dur)
			# Saw + a fifth above, softening: bright brass-ish.
			var ph := fposmod(n[2] * u, 1.0)
			var ph5 := fposmod(n[2] * 1.5 * u, 1.0)
			var v := (2.0 * ph - 1.0) * 0.6 + (2.0 * ph5 - 1.0) * 0.25
			var env := minf(du / 0.15, 1.0) * (1.0 - du * 0.4)
			if du > 0.8:
				env *= (1.0 - du) / 0.2
			data[idx] += v * env * 0.4
	for i in length:
		bytes.encode_s16(i * 2,
				int(clampf(data[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	wav.data = bytes
	_fan_cache = wav
	return wav


func _fanfare() -> void:
	var pl := AudioStreamPlayer3D.new()
	pl.stream = _fanfare_stream()
	pl.volume_db = -7.0 if sunken else 2.0  # muffled from the deep
	pl.unit_size = 14.0
	pl.max_db = 3.0
	add_child(pl)
	pl.play()
	get_tree().create_timer(1.3).timeout.connect(pl.queue_free)


# --- persistence ---------------------------------------------------------------

func _save_state() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("opened", chest_id, true)
	cfg.save(SAVE_PATH)


func _load_state() -> void:
	if chest_id.is_empty():
		return
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	if bool(cfg.get_value("opened", chest_id, false)):
		# Already looted in a previous session: lid hangs open, seam
		# dark, light out. Still there — a marker of past conquests.
		_opened = true
		_lid.rotation_degrees.x = -105.0
		_gold_mat.emission_energy_multiplier = 0.0
		if _light != null:
			_light.light_energy = 0.0
