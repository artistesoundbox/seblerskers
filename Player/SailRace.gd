class_name SailRace
extends Node3D
## The coastal regatta: a loop of buoys hugging the island's shoreline,
## rounded IN ORDER under sail. Get the flagship near the ember buoy to
## start the clock, round every mark, and the last buoy stops it —
## gold/silver/bronze against course-solved target times. Best times
## persist (user://sail_race.cfg). R / gamepad Back resets. The clock
## belongs to the SHIP: hop off mid-race and it keeps ticking until you
## sail on (or reset).
##
## Built at runtime by PropScatter from real shoreline samples: buoys
## sit 12 m off the waterline wherever the shelf is deep enough to
## sail, spread evenly around the coast starting beside the flagship.

## Round a mark by bringing the hull this close (m).
@export var round_radius := 10.0
## Rank thresholds (seconds), solved from the course's true length.
@export var gold_t := 90.0
@export var silver_t := 115.0
@export var bronze_t := 150.0
## Course seed (from PropScatter; stable layout every session).
@export var course_seed := 0

signal mark_rounded(index: int)
signal race_started
signal race_finished(time: float, rank: String)

const SAVE_PATH := "user://sail_race.cfg"
const AchievementsS := preload("res://Player/Achievements.gd")

## Buoys: {node, area_pos, base_y, buzz_until}. The course node sits at
## the origin; all positions are world-space.
var _buoys: Array[Dictionary] = []
var _next := 0
var _state := 0
var _clock := 0.0
var _t := 0.0
var _last_rank := ""
var _swell := Callable()
## Rank thresholds cache + best-time cache.
var _best_cache := -1.0
var _best_loaded := false

## HUD (built lazily on first start).
var _hud: CanvasLayer
var _time_label: Label
var _prog_label: Label
var _rank_label: Label
var _msg_label: Label
## Spinning pointer hovering over the next mark.
var _pointer: MeshInstance3D

# --- buoy look -------------------------------------------------------------
var _mat_next: StandardMaterial3D
var _mat_future: StandardMaterial3D
var _mat_passed: StandardMaterial3D
var _mat_flash: StandardMaterial3D


## PropScatter hands in the world-space buoy points and the rank times.
func setup(points: Array, ranks: Array, swell: Callable) -> void:
	gold_t = ranks[0]
	silver_t = ranks[1]
	bronze_t = ranks[2]
	_swell = swell
	_build(points)


func _ready() -> void:
	add_to_group("race_regatta")
	if _mat_next == null:
		_make_mats()


func _make_mats() -> void:
	# Next mark: bright ember. Future marks: faint silhouettes — at
	# night the course reads by the ONE glowing target. Passed: quiet.
	_mat_next = _band_mat(Color(1.0, 0.62, 0.18), 3.2)
	_mat_future = _band_mat(Color(0.55, 0.72, 0.95), 0.14)
	_mat_passed = _band_mat(Color(0.35, 0.85, 0.45), 0.28)
	_mat_flash = _band_mat(Color(1.0, 1.0, 0.9), 6.0)


func _band_mat(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# The albedo dims WITH the emission: unshaded surfaces read at
	# their albedo brightness, so a dim future mark must be dim in
	# both channels (not a flat bright band with no glow).
	m.albedo_color = c * clampf(0.3 + 0.23 * energy, 0.0, 1.0)
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


## One buoy: a red-and-white float with a pole, flag and an emissive
## band (the band carries the race color, readable at dusk).
##
## Course readability (the user must be able to READ the race from
## the water): every mark carries a NUMBER (1, 2, 3...) above it, a
## gold chevron on the flag pointing the way the course rounds it,
## and mark 1 wears a "START" banner — the origin is unmissable.
func _build(points: Array) -> void:
	if _mat_next == null:
		_make_mats()
	for i in points.size():
		var p: Vector3 = points[i]
		var b := Node3D.new()
		b.position = p
		b.rotation.y = fposmod(float(i) * 2.39996, TAU)
		# Float: two stacked drums (white hull, red top).
		var white := MeshInstance3D.new()
		var dw := CylinderMesh.new()
		dw.top_radius = 0.55
		dw.bottom_radius = 0.62
		dw.height = 0.7
		white.mesh = dw
		white.position.y = 0.05
		var wm := StandardMaterial3D.new()
		wm.albedo_color = Color(0.92, 0.9, 0.86)
		white.material_override = wm
		b.add_child(white)
		var red := MeshInstance3D.new()
		var dr := CylinderMesh.new()
		dr.top_radius = 0.5
		dr.bottom_radius = 0.55
		dr.height = 0.5
		red.mesh = dr
		red.position.y = 0.62
		red.material_override = _mat_future
		red.set_meta("band", true)
		b.add_child(red)
		# Pole + pennant.
		var pole := MeshInstance3D.new()
		var dp := CylinderMesh.new()
		dp.top_radius = 0.045
		dp.bottom_radius = 0.055
		dp.height = 2.3
		pole.mesh = dp
		pole.position.y = 1.9
		var pm := StandardMaterial3D.new()
		pm.albedo_color = Color(0.35, 0.28, 0.22)
		pole.material_override = pm
		b.add_child(pole)
		var flag := MeshInstance3D.new()
		var df := PrismMesh.new()
		df.size = Vector3(0.7, 0.35, 0.05)
		flag.mesh = df
		flag.position = Vector3(0.33, 2.9, 0.0)
		flag.material_override = _mat_future
		flag.set_meta("band", true)
		b.add_child(flag)
		# The mark's number: tall gold Label3D above the buoy, visible
		# from a hull length away, billboarding so it reads from any
		# heading. The rounding order is the numbers.
		var num := Label3D.new()
		num.text = str(i + 1)
		num.font_size = 96
		num.pixel_size = 0.014
		num.outline_size = 14
		num.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		num.modulate = Color(1.0, 0.82, 0.35)
		num.outline_modulate = Color(0.1, 0.06, 0.02, 0.9)
		num.position = Vector3(0.0, 4.1, 0.0)
		num.no_depth_test = false
		b.add_child(num)
		# Course chevron: a small gold arrow head under the number,
		# pointing at the NEXT mark — the trajectory reads buoy to
		# buoy without the HUD.
		if i < points.size() - 1:
			var nxt: Vector3 = points[i + 1]
			var to_next := Vector3(nxt.x - p.x, 0.0, nxt.z - p.z)
			var chev := MeshInstance3D.new()
			var cm := PrismMesh.new()
			cm.size = Vector3(0.62, 0.3, 0.16)
			chev.mesh = cm
			var chev_mat := StandardMaterial3D.new()
			chev_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			chev_mat.albedo_color = Color(1.0, 0.82, 0.35)
			chev_mat.emission_enabled = true
			chev_mat.emission = Color(1.0, 0.82, 0.35)
			chev_mat.emission_energy_multiplier = 0.9
			chev.material_override = chev_mat
			# The prism's ridge runs along Z; yaw it so the apex aims
			# at the next mark and park it above the flag.
			chev.position = Vector3(0.0, 3.55, 0.0)
			chev.rotation = Vector3(0.0, atan2(-to_next.x, -to_next.z), 0.0)
			b.add_child(chev)
		# Mark 1 = the START: a banner plank across the pole with the
		# word on it, plus a wider white base drum so the origin reads
		# as different from every other mark.
		if i == 0:
			var banner := Label3D.new()
			banner.text = "START"
			banner.font_size = 72
			banner.pixel_size = 0.016
			banner.outline_size = 16
			banner.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			banner.modulate = Color(1.0, 0.95, 0.85)
			banner.outline_modulate = Color(0.35, 0.1, 0.05, 0.95)
			banner.position = Vector3(0.0, 3.3, 0.0)
			b.add_child(banner)
			var base := MeshInstance3D.new()
			var db := CylinderMesh.new()
			db.top_radius = 0.8
			db.bottom_radius = 0.9
			db.height = 0.5
			base.mesh = db
			base.position.y = -0.25
			var bm := StandardMaterial3D.new()
			bm.albedo_color = Color(0.95, 0.93, 0.88)
			base.material_override = bm
			b.add_child(base)
		add_child(b)
		_buoys.append({"node": b, "base_y": p.y, "buzz_until": 0.0})
	# The floating pointer that guides to the next mark.
	_pointer = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.7
	cone.height = 1.8
	_pointer.mesh = cone
	var pm2 := StandardMaterial3D.new()
	pm2.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm2.albedo_color = Color(1.0, 0.62, 0.18, 0.85)
	pm2.emission_enabled = true
	pm2.emission = Color(1.0, 0.62, 0.18)
	_pointer.material_override = pm2
	_pointer.visible = false
	add_child(_pointer)


## The flagship (the only member of the "sailboat" group), or null.
func _ship() -> Node3D:
	var s := get_tree().get_first_node_in_group("sailboat")
	return s as Node3D


func _physics_process(delta: float) -> void:
	_t += delta
	if _state == 1:
		_clock += delta
		_race_hud()
	var ship := _ship()
	if ship == null:
		return
	var sp := ship.global_position
	if _state == 0:
		# The start mark: bring the hull near the ember buoy.
		if _buoys.size() > 0 and _dist_xz(sp, _buoy_pos(0)) < round_radius:
			_start_race()
		return
	# (the idle pointer below runs from _process, not here)
	if _state != 1 or _next >= _buoys.size():
		return
	var d := _dist_xz(sp, _buoy_pos(_next))
	if d < round_radius:
		_round_mark(_next)
		return
	# Wrong-mark guard: straying into a future mark buzzes (cooldown
	# per buoy so drifting beside it doesn't machine-gun the buzzer).
	for j in range(_next + 1, _buoys.size()):
		if _dist_xz(sp, _buoy_pos(j)) < round_radius \
				and _t > (_buoys[j].buzz_until as float):
			_buoys[j].buzz_until = _t + 1.5
			_buzz(j)
			return


func _dist_xz(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _buoy_pos(i: int) -> Vector3:
	return (_buoys[i].node as Node3D).position


func _start_race() -> void:
	_state = 1
	_clock = 0.0
	_next = 1
	_last_rank = ""
	_paint()
	_hud_msg("CAST OFF!", 1.2)
	_chime(880.0)
	race_started.emit()
	_ensure_hud()


func _round_mark(idx: int) -> void:
	_flash(idx)
	_next += 1
	mark_rounded.emit(idx)
	if idx == _buoys.size() - 1:
		_finish_race()
		return
	_chime(620.0 + float(idx % 6) * 40.0)
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
		cf.set_value("regatta", "wins",
				int(cf.get_value("regatta", "wins", 0)) + 1)
		cf.save(SAVE_PATH)
		AchievementsS.award("first_medal")
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
	var base := 560.0
	if rank == "GOLD":
		base = 760.0
	elif rank == "SILVER":
		base = 650.0
	for k in 3:
		get_tree().create_timer(float(k) * 0.18).timeout.connect(
				_chime.bind(base + float(k) * 110.0))
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
	_chime(140.0, -6.0)
	_paint_flash(idx)
	_hud_msg("wrong mark!", 1.0)


func _flash(idx: int) -> void:
	_paint_flash(idx)
	get_tree().create_timer(0.35).timeout.connect(_repaint)


func _paint_flash(idx: int) -> void:
	var b := _buoys[idx].node as Node3D
	for c in b.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).has_meta("band"):
			(c as MeshInstance3D).material_override = _mat_flash


func _repaint() -> void:
	_paint()


func _paint() -> void:
	for i in _buoys.size():
		var mat := _mat_future
		if _state == 0:
			mat = _mat_next if i == 0 else _mat_future
		elif i < _next:
			mat = _mat_passed
		elif i == _next:
			mat = _mat_next
		var b := _buoys[i].node as Node3D
		for c in b.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).has_meta("band"):
				(c as MeshInstance3D).material_override = mat


func _process(delta: float) -> void:
	# Every buoy rides the shared swell like the fleet.
	if _swell.is_valid():
		for bd in _buoys:
			var b := bd.node as Node3D
			var p := b.position
			b.position.y = (bd.base_y as float) \
					+ _swell.call(p.x, p.z)
	# Pointer over the next mark — and BEFORE the race, over the
		# START buoy: the idle arrow points the player to the origin
		# so the course's start is findable from anywhere on the water.
	if _pointer != null:
		if _state == 1 and _next < _buoys.size():
			_pointer.visible = true
			var tgt := _buoy_pos(_next)
			_pointer.position = tgt + Vector3(0,
					3.6 + 0.3 * sin(_t * 3.0), 0)
			_pointer.rotation.y += delta * 2.0
		elif _state == 0 and _buoys.size() > 0:
			_pointer.visible = true
			var tgt := _buoy_pos(0)
			_pointer.position = tgt + Vector3(0,
					3.6 + 0.3 * sin(_t * 3.0), 0)
			_pointer.rotation.y += delta * 2.0
		else:
			_pointer.visible = false


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed \
			and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_R and _state != 0:
			_reset()
	# Gamepad Back/Select resets (button 4), matching the flight race.
	if event is InputEventJoypadButton and event.pressed \
			and (event as InputEventJoypadButton).button_index == 4 \
			and _state != 0:
		_reset()


func _reset() -> void:
	_state = 0
	_next = 0
	_paint()
	_hud_msg("reset — sail to the ember buoy to start", 2.0)


# --- HUD -------------------------------------------------------------------

func _ensure_hud() -> void:
	if _hud != null:
		_hud.visible = true
		return
	_hud = CanvasLayer.new()
	_hud.name = "SailRaceHUD"
	add_child(_hud)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER_TOP)
	vb.position = Vector2(24, 130)
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


func _race_hud() -> void:
	if _time_label == null:
		return
	_time_label.text = "%.2f" % _clock
	_prog_label.text = "mark %d / %d" % [mini(_next + 1, _buoys.size()),
			_buoys.size()]
	if _next < _buoys.size():
		var ship := _ship()
		if ship != null:
			_prog_label.text += "    %.0f m" % _dist_xz(
					ship.global_position, _buoy_pos(_next))
	var best := _load_best()
	if best > 0.0:
		_prog_label.text += "    best %.2f" % best


func _hud_msg(msg: String, secs: float) -> void:
	_ensure_hud()
	_msg_label.text = msg
	get_tree().create_timer(secs).timeout.connect(func() -> void:
		if _msg_label != null and _msg_label.text == msg:
			_msg_label.text = "")


# --- audio (procedural chimes, same recipe as the flight race) ------------

const SR := 22050
static var _chime_cache := {}


func _chime(freq: float, db := -3.0) -> void:
	var stream := _chime_stream(freq)
	var pl := AudioStreamPlayer.new()
	pl.stream = stream
	pl.volume_db = db
	add_child(pl)
	pl.play()
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


# --- best-time persistence -------------------------------------------------

func _load_best() -> float:
	if _best_loaded:
		return _best_cache
	_best_loaded = true
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) == OK:
		_best_cache = cf.get_value("regatta", "best", -1.0)
	else:
		_best_cache = -1.0
	return _best_cache


func _save_best(t: float) -> void:
	var cf := ConfigFile.new()
	# Load-first merge: the file also carries the wins tally — a fresh
	# write it would wipe it.
	cf.load(SAVE_PATH)
	cf.set_value("regatta", "best", t)
	cf.save(SAVE_PATH)


## Restart Saga: forget the best time, the wins tally and the last
## rank — the regatta resets to "hit the ember mark to start".
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
func buoy_count() -> int:
	return _buoys.size()


func state() -> int:
	return _state


func clock() -> float:
	return _clock


func next_index() -> int:
	return _next
