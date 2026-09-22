class_name SailLapTracker
extends Node3D
## The free-sail lap: no buoys, no start line — just you and the helm.
## While the flagship is ROWED, the tracker accumulates the hull's
## bearing around the island's course centre; a full 360° loop (either
## direction) completes a lap. The lap's time only accumulates while
## someone is aboard pulling, and a lap only counts if it covered real
## distance (MIN_LAP_M — a donut spun in a bay is not a voyage).
## The personal best persists to user://sail_race.cfg (section
## "free_lap"), exactly like the regatta's course best, and the helm
## shows the live lap clock, the PB and the lifetime lap count.
##
## Spawned by PropScatter beside the regatta (it needs the course's
## centroid — a point the whole coast encircles).

signal lap_completed(time: float, new_best: bool)

const SAVE_PATH := "user://sail_race.cfg"
## A lap shorter than this didn't round the island (m of rowed travel).
const MIN_LAP_M := 800.0
## Bearing deltas only accumulate while the hull is actually under way.
const WAY_ON := 0.4  # m/s
## Test seam: the harness redirects saves here (the const stays the
## shipped path; the real PB file is never touched by tests).
var save_path := SAVE_PATH
## Test seam: the harness overrides this (the const stays the shipped rule).
var min_lap_m := MIN_LAP_M
## After this long unridden the lap is abandoned: the bearing window
## re-anchors and any half-lap progress is wiped (no pausing the clock
## by jumping ship). Short stops (< 5 s) keep the lap alive.
const REANCHOR_S := 5.0

var _centre := Vector3.ZERO
var _last_bearing := 0.0
var _accum := 0.0
var _lap_t := 0.0
var _lap_m := 0.0
var _unridden_t := 0.0
var _best := -1.0
var _laps := 0
var _had_ship := false

## Helm readout (built lazily; visible only while the ship is ridden).
var _hud: CanvasLayer
var _lap_label: Label
var _best_label: Label
var _msg_label: Label
var _msg_until := 0.0
var _t := 0.0


## PropScatter hands in the course centroid (interior point the coast
## encircles) — bearing laps are measured around it.
func setup(centre: Vector3) -> void:
	_centre = centre
	add_to_group("sail_lap")
	var cf := ConfigFile.new()
	if cf.load(save_path) == OK:
		_best = cf.get_value("free_lap", "best", -1.0)
		_laps = cf.get_value("free_lap", "laps", 0)


func _physics_process(delta: float) -> void:
	_t += delta
	var ship := get_tree().get_first_node_in_group("sailboat") as Node3D
	if ship == null:
		return
	var ridden: bool = ship.get("_rider") != null
	if ridden:
		_unridden_t = 0.0
	else:
		_unridden_t += delta
	# The hull's bearing around the island centre.
	var sp := ship.global_position
	var bearing := atan2(sp.z - _centre.z, sp.x - _centre.x)
	if _unridden_t > REANCHOR_S or not _had_ship:
		# (Re-)anchor: a teleport or a long idle must not read as a
		# bearing sweep — and an abandoned half-lap doesn't survive.
		_last_bearing = bearing
		_had_ship = true
		if _unridden_t > REANCHOR_S and (absf(_accum) > 0.01 or _lap_t > 1.0):
			_accum = 0.0
			_lap_t = 0.0
			_lap_m = 0.0
		if not ridden:
			_update_hud(false, 0.0)
			return
	# Rowed motion: distance and bearing only count under way.
	var speed: float = ship.get("_speed")
	var moving := speed > WAY_ON
	if ridden:
		_lap_t += delta
	if ridden and moving:
		var d := wrapf(bearing - _last_bearing, -PI, PI)
		_accum += d
		_lap_m += speed * delta
	_last_bearing = bearing
	if absf(_accum) >= TAU:
		_accum = wrapf(_accum, -PI, PI)
		_complete_lap()
	_update_hud(ridden, _lap_t)


func _complete_lap() -> void:
	var t := _lap_t
	var far_enough := _lap_m >= min_lap_m
	if not far_enough:
		# Rejected: the clocks KEEP RUNNING, so rowing a slightly
		# wider loop still counts — an 8-minute circuit must not be
		# wiped by clipping one corner.
		_hud_msg("too tight to count as a lap", 2.0)
		return
	_lap_t = 0.0
	_lap_m = 0.0
	_laps += 1
	var new_best := _best < 0.0 or t < _best
	if new_best:
		_best = t
		# Every counted lap persists (best AND lifetime count) —
		# otherwise the lap count resets each session unless the
		# very lap was a personal best.
		_save()
		_hud_msg("LAP  %.2f s  —  NEW BEST!" % t, 4.5)
	else:
		_save()
		_hud_msg("LAP  %.2f s   (best %.2f)" % [t, _best], 4.5)
	lap_completed.emit(t, new_best)


func _save() -> void:
	var cf := ConfigFile.new()
	cf.load(save_path)  # preserve the regatta's section if present
	cf.set_value("free_lap", "best", _best)
	cf.set_value("free_lap", "laps", _laps)
	cf.save(save_path)


## Restart Saga: forget the personal best and the lifetime lap count
## (the HUD's PB line re-reads these every frame it's visible). No
## re-save here — the wipe just deleted the file; the next real lap
## persists fresh values.
func reset_saga() -> void:
	_best = -1.0
	_laps = 0


## Undo Restart: re-read the restored PB and lap count from disk.
func refresh_saga() -> void:
	_best = -1.0
	_laps = 0
	var cf := ConfigFile.new()
	if cf.load(save_path) == OK:
		_best = float(cf.get_value("free_lap", "best", -1.0))
		_laps = int(cf.get_value("free_lap", "laps", 0))


# --- helm readout ----------------------------------------------------------

func _ensure_hud() -> void:
	if _hud != null:
		return
	_hud = CanvasLayer.new()
	_hud.name = "SailLapHUD"
	add_child(_hud)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	vb.position = Vector2(24, -96)
	_hud.add_child(vb)
	_lap_label = Label.new()
	_lap_label.add_theme_font_size_override("font_size", 22)
	_lap_label.text = "LAP  0.0 s"
	vb.add_child(_lap_label)
	_best_label = Label.new()
	_best_label.add_theme_font_size_override("font_size", 15)
	vb.add_child(_best_label)
	_msg_label = Label.new()
	_msg_label.add_theme_font_size_override("font_size", 20)
	vb.add_child(_msg_label)


func _update_hud(ridden: bool, lap_t: float) -> void:
	if ridden:
		_ensure_hud()
		_hud.visible = true
		_lap_label.text = "LAP  %6.1f s" % lap_t
		_best_label.text = "PB %s   ·   %d lap%s" % [
				"%.2f s" % _best if _best > 0.0 else "—",
				_laps, "" if _laps == 1 else "s"]
		if _msg_label != null and _t > _msg_until:
			_msg_label.text = ""
	elif _hud != null:
		_hud.visible = false


func _hud_msg(msg: String, secs: float) -> void:
	_ensure_hud()
	_msg_label.text = msg
	_msg_until = _t + secs


## Diagnostics for the headless harness.
func probe() -> Dictionary:
	return {
		"accum": _accum, "lap_t": _lap_t, "lap_m": _lap_m,
		"best": _best, "laps": _laps,
	}
