class_name RaceCourse
extends Node3D
## A fly-through race course over the island: a chain of glowing rings
## threading the landmarks. Cross ring 1 to START the clock, thread
## every ring IN ORDER, and the last ring STOPS it — gold/silver/
## bronze against course-tuned target times. Best times persist across
## sessions (user://race_course.cfg). Wrong-order rings buzz; R resets
## the attempt anytime. A small HUD shows timer, ring progress, rank
## thresholds and a floating arrow to the next ring.
##
## Built entirely at runtime by PropScatter along a spline whose
## waypoints hug the real terrain: villages and groves get low slalom
## rings, open water and castle flybys get big high-speed gates.

## Ring radius (the hole the player threads).
@export var ring_radius := 5.0
## Rings are solved to this DIAMETER unless a per-waypoint radius is
## given in the course table.
@export var ring_size_override := -1.0
## Rank thresholds per course (seconds). Gold beats gold_t, silver
## beats silver_t, everything under bronze_t still medals.
@export var gold_t := 75.0
@export var silver_t := 95.0
@export var bronze_t := 125.0
## Course seed (set from PropScatter; stable layout every session).
@export var course_seed := 0

signal ring_passed(index: int)
signal race_started
signal race_finished(time: float, rank: String)

const SAVE_PATH := "user://race_course.cfg"
const AchievementsR := preload("res://Player/Achievements.gd")

var _rings: Array[Node3D] = []
var _areas: Array[Area3D] = []
## Which course ring is next (checkpoint mode).
var _next := 0
## Attempt state: idle -> running -> finished.
var _state := 0
var _clock := 0.0
var _last_rank := ""
var _t := 0.0
var _best_cache := -1.0
## Per-ring bob phase (visual life, no two rings bob in sync).
var _bob: PackedFloat32Array = PackedFloat32Array()

## HUD (built lazily on first race start; invisible otherwise).
var _hud: CanvasLayer
var _time_label: Label
var _prog_label: Label
var _rank_label: Label
var _msg_label: Label
## Floating pointer to the next ring (a cone bobbing over the ring).
var _pointer: MeshInstance3D

# --- ring look -----------------------------------------------------------
var _mat_next: StandardMaterial3D
var _mat_future: StandardMaterial3D
var _mat_passed: StandardMaterial3D
var _mat_flash: StandardMaterial3D
const RING_TUBE := 0.45
## Light-pillar height above each ring — the chain's silhouette.
const PILLAR_HEIGHT := 26.0


## PropScatter hands in the world-space course waypoints
## [{ "p": Vector3, "r": ring_hole_radius }] and the rank times.
func setup(points: Array, ranks: Array) -> void:
	gold_t = ranks[0]
	silver_t = ranks[1]
	bronze_t = ranks[2]
	_build(points)


func _ready() -> void:
	add_to_group("race_course")
	if _mat_next == null:
		_make_mats()


func _make_mats() -> void:
	# Next ring: bright ember — unmissable against terrain or sky.
	_mat_next = _ring_mat(Color(1.0, 0.62, 0.18), 3.2)
	# Future rings: a FAINT silhouette (barely-emitting steel) — the
	# course reads at night by the one ember target, not a glow chain.
	_mat_future = _ring_mat(Color(0.55, 0.72, 0.95), 0.14)
	# Passed: very dim mossy green — history, not a beacon.
	_mat_passed = _ring_mat(Color(0.35, 0.85, 0.45), 0.28)
	# Cross flash: white-hot, fades back in _process.
	_mat_flash = _ring_mat(Color(1.0, 1.0, 0.9), 6.0)


func _ring_mat(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# The albedo dims WITH the emission: unshaded surfaces read at
	# their albedo brightness, so a dim future ring must be dim in
	# both channels (not a flat bright band with no glow).
	var dim := clampf(0.3 + 0.23 * energy, 0.0, 1.0)
	m.albedo_color = Color(c.r * dim, c.g * dim, c.b * dim, 0.9)
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	m.disable_receive_shadows = true
	return m


## One torus ring + its crossing Area, both world-positioned before
## add_child (the course node itself sits at the origin).
func _build(points: Array) -> void:
	# setup() runs BEFORE the node enters the tree (_ready hasn't
	# fired), so the materials must exist before the first ring uses
	# them.
	if _mat_next == null:
		_make_mats()
	var torus := TorusMesh.new()
	torus.inner_radius = ring_radius - RING_TUBE * 0.5
	torus.outer_radius = ring_radius + RING_TUBE * 0.5
	# Godot's torus lies in the XZ plane; rings stand upright, so the
	# mesh itself is pre-rotated into XY by pitching every ring node.
	for i in points.size():
		var pt: Dictionary = points[i]
		var p: Vector3 = pt.p
		var hole: float = pt.get("r", ring_radius)
		var ring := Node3D.new()
		ring.position = p
		# Face the NEXT waypoint (the natural approach direction);
		# the first ring faces the second, the last keeps its chain
		# direction. Pitch the node so the torus (born flat) stands
		# upright facing that heading.
		var ahead: Vector3 = (points[mini(i + 1, points.size() - 1)].p
				as Vector3) - p
		var yaw := atan2(-ahead.x, -ahead.z)
		ring.rotation = Vector3(deg_to_rad(90.0), yaw, 0.0)
		var mi := MeshInstance3D.new()
		mi.mesh = torus
		if absf(hole - ring_radius) > 0.01:
			# A bigger/smaller gate: scale the whole ring node (the
			# tube thickens proportionally, which reads fine at speed).
			ring.scale = Vector3.ONE * (hole / ring_radius)
		mi.material_override = _mat_future
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.add_child(mi)
		# Course readability (the user must be able to trace the
		# chain's ORIGIN and TRAJECTORY): every ring carries its
		# number, ring 1 wears a START label, and a soft light pillar
		# rises from each ring so the chain's shape reads from across
		# the island. The pillars paint with the race state (ember on
		# the next ring, mossy on passed ones) via the same _paint().
		var num := Label3D.new()
		num.text = str(i + 1)
		num.font_size = 72
		num.pixel_size = 0.012
		num.outline_size = 12
		num.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		num.modulate = Color(1.0, 0.82, 0.35)
		num.outline_modulate = Color(0.1, 0.06, 0.02, 0.9)
		num.position = Vector3(0.0, hole * 0.72 + 0.4, 0.0)
		ring.add_child(num)
		if i == 0:
			var start_lbl := Label3D.new()
			start_lbl.text = "START"
			start_lbl.font_size = 56
			start_lbl.pixel_size = 0.014
			start_lbl.outline_size = 14
			start_lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			start_lbl.modulate = Color(1.0, 0.95, 0.85)
			start_lbl.outline_modulate = Color(0.35, 0.1, 0.05, 0.95)
			start_lbl.position = Vector3(0.0, hole * 0.72 + 1.5, 0.0)
			ring.add_child(start_lbl)
		var pillar := MeshInstance3D.new()
		var pcyl := CylinderMesh.new()
		pcyl.top_radius = 0.22
		pcyl.bottom_radius = 0.5
		pcyl.height = PILLAR_HEIGHT
		pcyl.radial_segments = 8
		pcyl.rings = 1
		pillar.mesh = pcyl
		var pilmat := StandardMaterial3D.new()
		pilmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pilmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pilmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		pilmat.albedo_color = Color(0.55, 0.72, 0.95, 0.10)
		pilmat.cull_mode = BaseMaterial3D.CULL_DISABLED
		pillar.material_override = pilmat
		pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Local Y of the pitched ring: the ring plane is XZ-before-
		# pitch, so +Y local lies along the face normal. Park the
		# pillar just behind the torus plane, running outward.
		pillar.position = Vector3(0.0, 0.0, -PILLAR_HEIGHT * 0.5 + 0.4)
		pillar.rotation = Vector3(deg_to_rad(-90.0), 0.0, 0.0)
		ring.add_child(pillar)
		pillar.set_meta("pillar", true)
		# Base Y recorded once: the bob in _process swings around it.
		ring.set_meta("base_y", p.y)
		add_child(ring)
		_rings.append(ring)
		_bob.append(_rand_phase(i))
		# Crossing detector: a flat cylinder filling the ring's hole,
		# on the player's collision layer. Rings sit in open air, so
		# only the player can ever overlap them.
		var area := Area3D.new()
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.height = 0.5
		cyl.radius = hole
		cs.shape = cyl
		# The area is a child of the pitched ring: rotate the flat
		# cylinder back level with its face normal (+Z of the ring).
		cs.rotation = Vector3(deg_to_rad(-90.0), 0.0, 0.0)
		area.add_child(cs)
		area.collision_layer = 0
		# THE START GATE WAS DEAF (user report: "it says hit start and i
		# dont know where that is"): these triggers listened on mask 1
		# (the world layer), but the hero's body is LAYER 2 — flying
		# through a ring never registered and the hint just repeated.
		# Mask the PLAYER layer; rings sit in open air so nothing else
		# can ever trip them.
		area.collision_mask = 2
		area.monitoring = true
		area.body_entered.connect(_on_ring_entered.bind(i))
		ring.add_child(area)
		_areas.append(area)
	# The floating pointer that guides to the next ring.
	_pointer = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.6
	cone.height = 1.6
	_pointer.mesh = cone
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.albedo_color = Color(1.0, 0.62, 0.18, 0.85)
	pm.emission_enabled = true
	pm.emission = Color(1.0, 0.62, 0.18)
	_pointer.material_override = pm
	_pointer.visible = false
	add_child(_pointer)


func _rand_phase(i: int) -> float:
	# Deterministic per-index bob phases (no RNG state needed).
	return fposmod(float(i) * 2.39996, TAU)


func _on_ring_entered(_body: Node3D, idx: int) -> void:
	if idx == 0 and _state == 0:
		# The start gate starts the race.
		_start_race()
		return
	if _state != 1:
		return
	if idx == _next:
		_pass_ring(idx)
	elif idx == _rings.size() - 1:
		# Crossing the finish early — ignoring it would let players
		# skip the course; buzz instead.
		_buzz(idx)
	else:
		_buzz(idx)


func _start_race() -> void:
	_state = 1
	_clock = 0.0
	_next = 1
	_last_rank = ""
	_paint()
	_hud_msg("GO!", 1.2)
	_chime(880.0)
	race_started.emit()
	_ensure_hud()


func _pass_ring(idx: int) -> void:
	_flash(idx)
	_next += 1
	ring_passed.emit(idx)
	if idx == _rings.size() - 1:
		_finish_race()
		return
	_chime(660.0 + float(idx % 6) * 40.0)
	_paint()


func _finish_race() -> void:
	_state = 2
	var t := _clock
	var rank := _rank_for(t)
	_last_rank = rank
	# A won race (any medal) tallies for the title's voyage summary.
	if rank != "FINISHER":
		var cf := ConfigFile.new()
		cf.load(SAVE_PATH)
		cf.set_value("course", "wins",
				int(cf.get_value("course", "wins", 0)) + 1)
		cf.save(SAVE_PATH)
		AchievementsR.award("first_medal")
	var best := _load_best()
	var new_best := best < 0.0 or t < best
	if new_best:
		_save_best(t)
		_best_cache = t
	var msg := "%s  %.2f s" % [rank, t]
	if new_best:
		msg += "   NEW BEST!"
	else:
		msg += "   best %.2f" % best
	_hud_msg(msg, 4.0)
	_rank_label.text = "RANK  %s" % rank
	# A little fanfare: three ascending chimes (gold rings higher).
	var base := 660.0
	if rank == "GOLD":
		base = 880.0
	elif rank == "SILVER":
		base = 740.0
	for k in 3:
		get_tree().create_timer(float(k) * 0.18).timeout.connect(
				_chime.bind(base + float(k) * 120.0))
	_race_hud(true, t)
	race_finished.emit(t, rank)


func _rank_for(t: float) -> String:
	if t <= gold_t:
		return "GOLD"
	if t <= silver_t:
		return "SILVER"
	if t <= bronze_t:
		return "BRONZE"
	return "FINISHER"


func _buzz(idx: int) -> void:
	# Wrong ring: harsh low buzz + red flash on that ring.
	_chime(140.0, -6.0)
	var mi := (_rings[idx].get_child(0) as MeshInstance3D)
	mi.material_override = _mat_flash
	mi.set_meta("flash", _t + 0.35)
	_hud_msg("wrong ring!", 1.0)


## The idle-state HUD hint: before the race, the message line points
## at the START gate with a REAL DISTANCE, so the origin is findable,
## not just stated ("hit start" with no where was unreadable).
func _idle_hint() -> void:
	if _state == 0 and _rings.size() > 0:
		var hero := get_tree().get_first_node_in_group("player") as Node3D
		var where := ""
		if hero != null:
			var d := Vector2(hero.global_position.x - _rings[0].position.x,
					hero.global_position.z - _rings[0].position.z).length()
			where = " — %.0f m away" % d
		_hud_msg("FLY THROUGH the glowing ring marked START (ring 1)%s"
				% where, 3.0)


func _flash(idx: int) -> void:
	var mi := (_rings[idx].get_child(0) as MeshInstance3D)
	mi.material_override = _mat_flash
	mi.set_meta("flash", _t + 0.35)


func _paint() -> void:
	for i in _rings.size():
		var mi := (_rings[i].get_child(0) as MeshInstance3D)
		if mi.has_meta("flash"):
			continue  # mid-flash; _process hands it back
		if _state == 0:
			mi.material_override = _mat_future if i > 0 else _mat_next
		elif i < _next:
			mi.material_override = _mat_passed
		elif i == _next:
			mi.material_override = _mat_next
		else:
			mi.material_override = _mat_future
		# The light pillar rides the same state colors (subtle): the
		# chain's trajectory always reads, the next target glows.
		var pm := _pillar_mat_for(i)
		for c in _rings[i].get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).has_meta("pillar"):
				(c as MeshInstance3D).material_override = pm


## The pillar material for ring i (additive, state-tinted).
func _pillar_mat_for(i: int) -> StandardMaterial3D:
	var c := Color(0.55, 0.72, 0.95)   # future: cold steel
	var a := 0.10
	if _state == 0:
		c = Color(1.0, 0.62, 0.18) if i == 0 else Color(0.55, 0.72, 0.95)
		a = 0.16 if i == 0 else 0.10
	elif i < _next:
		c = Color(0.35, 0.85, 0.45)        # passed: mossy
		a = 0.05
	elif i == _next:
		c = Color(1.0, 0.62, 0.18)         # next: ember
		a = 0.22
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	pm.albedo_color = Color(c.r, c.g, c.b, a)
	pm.cull_mode = BaseMaterial3D.CULL_DISABLED
	return pm


func _process(delta: float) -> void:
	_t += delta
	# Bob: every ring breathes a few centimetres, phase-offset, around
	# its build-time base Y. Flashing rings fade back by expiry time.
	for i in _rings.size():
		var ring := _rings[i]
		ring.position.y = (ring.get_meta("base_y") as float) \
				+ sin(_t * 0.9 + _bob[i]) * 0.25
		var mi := (ring.get_child(0) as MeshInstance3D)
		if mi.has_meta("flash") and _t > (mi.get_meta("flash") as float):
			mi.remove_meta("flash")
			_paint()
	if _state == 1:
		_clock += delta
		_race_hud(false, _clock)
	# Pre-race: the pointer hovers the START gate and the hint line
	# reminds where the course begins — origin first, always.
	if _state == 0 and _rings.size() > 0:
		if fposmod(_t, 9.0) < delta:
			_idle_hint()
	# Pointer: hover above the next ring, bobbing, spinning slowly.
	if _pointer != null and _state == 1 and _next < _rings.size():
		_pointer.visible = true
		var tgt: Vector3 = _rings[_next].position
		_pointer.position = tgt + Vector3(0, 2.6
				+ 0.3 * sin(_t * 3.0), 0)
		_pointer.rotation.y += delta * 2.0
	elif _pointer != null and _state == 0 and _rings.size() > 0:
		_pointer.visible = true
		var tgt: Vector3 = _rings[0].position
		_pointer.position = tgt + Vector3(0, 2.6
				+ 0.3 * sin(_t * 3.0), 0)
		_pointer.rotation.y += delta * 2.0
	elif _pointer != null:
		_pointer.visible = false


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed \
			and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_R and _state != 0:
			# Reset the attempt: fly through the start gate again.
			_state = 0
			_next = 0
			_paint()
			_hud_msg("reset — fly through the glowing START ring (1)", 2.0)
	# Gamepad Y is owned by the camera toggle; the pad's Back/Select
	# button resets (button 4 = Godot's JOY_BUTTON_BACK).
	if event is InputEventJoypadButton and event.pressed \
			and (event as InputEventJoypadButton).button_index == 4 \
			and _state != 0:
		_state = 0
		_next = 0
		_paint()
		_hud_msg("reset — fly through the glowing START ring (1)", 2.0)


# --- HUD -------------------------------------------------------------------

func _ensure_hud() -> void:
	if _hud != null:
		_hud.visible = true
		return
	_hud = CanvasLayer.new()
	_hud.name = "RaceHUD"
	add_child(_hud)
	var vb := VBoxContainer.new()
	# Top-LEFT at (24, 20): the old CENTER_TOP preset + position combo
	# landed the timer mid-screen, where it grazed the elder's scroll
	# on narrow windows (phone landscape).
	vb.position = Vector2(24, 20)
	_hud.add_child(vb)
	_time_label = Label.new()
	_time_label.add_theme_font_size_override("font_size", 30)
	_time_label.text = "0.00"
	vb.add_child(_time_label)
	_prog_label = Label.new()
	_prog_label.add_theme_font_size_override("font_size", 16)
	vb.add_child(_prog_label)
	_rank_label = Label.new()
	_rank_label.add_theme_font_size_override("font_size", 16)
	_rank_label.text = "GOLD < %.0f   SILVER < %.0f   BRONZE < %.0f" \
			% [gold_t, silver_t, bronze_t]
	vb.add_child(_rank_label)
	_msg_label = Label.new()
	_msg_label.add_theme_font_size_override("font_size", 22)
	vb.add_child(_msg_label)


func _race_hud(running: bool, t: float) -> void:
	if _time_label == null:
		return
	_time_label.text = "%.2f" % t
	_prog_label.text = "ring %d / %d" % [mini(_next + 1, _rings.size()),
			_rings.size()]
	var best := _load_best()
	if best > 0.0:
		_prog_label.text += "    best %.2f" % best


func _hud_msg(msg: String, secs: float) -> void:
	_ensure_hud()
	_msg_label.text = msg
	# Auto-clear via a scene timer.
	get_tree().create_timer(secs).timeout.connect(func() -> void:
		if _msg_label != null and _msg_label.text == msg:
			_msg_label.text = "")


# --- audio (procedural chimes, same recipe as the rest of the island) ------

const SR := 22050
static var _chime_cache := {}


func _chime(freq: float, db := -3.0) -> void:
	var stream := _chime_stream(freq)
	var pl := AudioStreamPlayer.new()
	pl.stream = stream
	pl.volume_db = db
	add_child(pl)
	pl.play()
	# Fire-and-forget: free when the tone is done.
	get_tree().create_timer(0.6).timeout.connect(pl.queue_free)


static func _chime_stream(freq: float) -> AudioStreamWAV:
	var key := int(freq)
	if _chime_cache.has(key):
		return _chime_cache[key]
	var length := int(0.5 * SR)
	var data := PackedFloat32Array()
	data.resize(length)
	for i in length:
		var u := float(i) / float(SR)
		var env := exp(-7.0 * u)
		var v := sin(TAU * freq * u) * env * 0.5
		# A octave-up sparkle gives it a "chime" rather than a beep.
		v += sin(TAU * freq * 2.0 * u) * env * 0.2
		data[i] = v
	var bytes := PackedByteArray()
	bytes.resize(length * 2)
	for i in length:
		bytes.encode_s16(i * 2,
				int(clampf(data[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	wav.data = bytes
	_chime_cache[key] = wav
	return wav


# --- best-time persistence ---------------------------------------------------

## Best time: read from disk ONCE, then cached (-1 = no best yet).
var _best_loaded := false


func _load_best() -> float:
	if _best_loaded:
		return _best_cache
	_best_loaded = true
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) == OK:
		_best_cache = cf.get_value("course", "best", -1.0)
	else:
		_best_cache = -1.0
	return _best_cache


func _save_best(t: float) -> void:
	var cf := ConfigFile.new()
	# Load-first merge: the file also carries the wins tally — a fresh
	# write here would wipe it.
	cf.load(SAVE_PATH)
	cf.set_value("course", "best", t)
	cf.save(SAVE_PATH)


## Restart Saga: forget the best time, the wins tally and the last
## rank — the race resets to "hit the ember ring to start".
func reset_saga() -> void:
	DirAccess.remove_absolute(SAVE_PATH)
	_best_loaded = true
	_best_cache = -1.0
	_last_rank = ""
	if _state == 1:
		_state = 0
		_clock = 0.0


## Undo Restart: drop the best-time cache so the next read pulls the
## restored record from disk.
func refresh_saga() -> void:
	_best_loaded = false


## Diagnostics for the headless harness.
func ring_count() -> int:
	return _rings.size()


func state() -> int:
	return _state


func clock() -> float:
	return _clock


func next_index() -> int:
	return _next
