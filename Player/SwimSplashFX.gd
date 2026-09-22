class_name SwimSplashFX
extends Node3D
## Swim-stroke splash ripples at the hands, synced to the swim clip's
## rhythm — not a timer. Each physics frame the hand bones' world
## heights are sampled (the same trick FootstepFX uses for footfalls);
## a hand that reverses from descending to rising after a deep, fast
## plunge has just entered the water on its stroke, and a ripple ring
## expands there on the surface. Because it tracks the real bones, the
## ripples follow the stride-matched animation speed automatically —
## sprint-crawl beats faster, a slow crawl saunters.
##
## Resting swimmers (the upright treading idle) hold no prone stroke,
## so no ripples fire; the bob is calm water.

## Base ripple ring diameter before expansion (m).
@export var ripple_size := 0.55
## Ripple lifetime (s): expand + fade.
@export var ripple_life := 0.9
## Plunge depth (m) below the hand's recent high before a stroke can
## register — filters out idle arm sway.
@export var ripple_depth := 0.06
## Plunge speed (m/s) a hand must reach to count as a stroke entry.
@export var ripple_speed := 0.35
## Minimum horizontal body speed (m/s): a resting bobber's arm twitch
## must never ripple the sea.
@export var min_stroke_speed := 0.5
## Refractory (s) per hand against double-fires.
@export var stroke_refractory := 0.12
## Pool of prebuilt rings; strokes alternate so overlapping strokes
## never cut each other short.
@export var ring_pool := 8
## Prints every fired stroke ripple with its trigger values (tuning aid).
var debug_ripples := false

## Incremented on every ripple; useful for tests/debugging.
var ripple_count := 0

const HAND_BONES: Array[StringName] = [
	&"mixamorig_LeftHand", &"mixamorig_RightHand"]
const TELEPORT_GUARD := 0.5  # m per frame — pose snaps are never strokes
const WARMUP := 0.5  # s: the T-pose blend-in must not fake strokes

var _controller: Node
var _skeleton: Skeleton3D
var _anim: AnimationPlayer
var _water_y := 0.0
var _bone_idx := [-1, -1]
var _rings: Array[MeshInstance3D] = []
var _ring_mats: Array[StandardMaterial3D] = []
var _ring_age: Array[float] = []
var _ring_strength: Array[float] = []
var _active := -1
var _stage := [0, 0]  # 0 descending, 1 rising
var _last_y := [0.0, 0.0]
var _high_y := [0.0, 0.0]
var _peak_depth := [0.0, 0.0]
var _peak_speed := [0.0, 0.0]
var _refractory := [0.0, 0.0]
var _age := 0.0


## Called by the controller at boot (child _ready order means the model
## and its skeleton are live by then).
func setup(ctrl: Node) -> void:
	_controller = ctrl
	top_level = true
	var model: Node = ctrl.get_node(ctrl.model_path)
	_skeleton = model.get_driven_skeleton()
	_anim = model.get("anim")
	_water_y = float(ctrl.water_y)
	if _skeleton == null or _anim == null:
		set_physics_process(false)
		return
	for i in 2:
		_bone_idx[i] = _skeleton.find_bone(String(HAND_BONES[i]))
	if _bone_idx[0] < 0 and _bone_idx[1] < 0:
		set_physics_process(false)
		return
	for i in ring_pool:
		_add_ring()
		_ring_age.append(-1.0)
		_ring_strength.append(0.0)


func _physics_process(delta: float) -> void:
	_age += delta
	_refractory[0] = maxf(0.0, _refractory[0] - delta)
	_refractory[1] = maxf(0.0, _refractory[1] - delta)
	# Ripple rings expand and fade in lockstep.
	for i in _rings.size():
		if _ring_age[i] < 0.0:
			continue
		_ring_age[i] += delta
		var t: float = _ring_age[i] / ripple_life
		if t >= 1.0:
			_rings[i].visible = false
			_ring_age[i] = -1.0
			continue
		var s: float = lerpf(0.5, 2.4, t) * (0.7 + 0.6 * _ring_strength[i])
		_rings[i].scale = Vector3(s, 1.0, s)
		_ring_mats[i].albedo_color.a = lerpf(
				0.32 + 0.2 * _ring_strength[i], 0.0, t)
	_tick_strokes(delta)


## The stroke tracker: stage machine per hand, mirroring FootstepFX's
## footfall detector (descent peak -> reversal fires).
func _tick_strokes(delta: float) -> void:
	if _controller == null or not bool(_controller.get("swimming")):
		return
	# Only the prone stroke swims — the upright treading idle is calm
	# water (no strokes to splash).
	if _anim.current_animation != "swim":
		return
	var hvel: Vector3 = _controller.velocity
	hvel.y = 0.0
	if hvel.length() < min_stroke_speed:
		return
	for i in 2:
		if _bone_idx[i] < 0:
			continue
		var pos := _hand_world_pos(i)
		var y := pos.y
		var prev: float = _last_y[i]
		_last_y[i] = y
		if _age < WARMUP:
			continue
		var dy := y - prev
		if absf(dy) > TELEPORT_GUARD:
			_stage[i] = 0
			_high_y[i] = y
			_peak_depth[i] = 0.0
			_peak_speed[i] = 0.0
			continue
		if _stage[i] == 0:
			# Descending: accumulate the plunge's depth and speed.
			_high_y[i] = maxf(_high_y[i], y)
			var depth: float = _high_y[i] - y
			var speed: float = -dy / maxf(delta, 0.0001)
			_peak_depth[i] = maxf(_peak_depth[i], depth)
			_peak_speed[i] = maxf(_peak_speed[i], speed)
			if dy > 0.0:
				# Reversal: the hand is coming back up. If the plunge
				# was deep and fast enough, it crossed the surface —
				# ripple there.
				_stage[i] = 1
				if _peak_depth[i] >= ripple_depth \
						and _peak_speed[i] >= ripple_speed \
						and _refractory[i] <= 0.0:
					_refractory[i] = stroke_refractory
					var strength := clampf(
							(_peak_speed[i] - ripple_speed) / 2.5
							+ _peak_depth[i] / 0.3, 0.3, 1.0)
					_fire(Vector3(pos.x, _water_y + 0.03, pos.z), strength)
		elif dy < 0.0:
			# Rising ended: the next stroke's plunge begins.
			_stage[i] = 0
			_high_y[i] = y
			_peak_depth[i] = 0.0
			_peak_speed[i] = 0.0


func _fire(pos: Vector3, strength: float) -> void:
	ripple_count += 1
	_active = (_active + 1) % _rings.size()
	_ring_age[_active] = 0.0
	_ring_strength[_active] = strength
	_rings[_active].global_position = pos
	_rings[_active].visible = true
	if debug_ripples:
		print("[swim-ripple] strength=%.2f at %s" % [strength, pos])


func _hand_world_pos(i: int) -> Vector3:
	return _skeleton.to_global(
			_skeleton.get_bone_global_pose(_bone_idx[i]).origin)


## --- Visuals: expanding foam rings on the surface (built in code) -----

func _add_ring() -> void:
	var m := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.055
	torus.outer_radius = 0.11
	m.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.85, 0.95, 1.0, 0.0)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	mat.no_depth_test = false
	m.material_override = mat
	m.visible = false
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(m)
	_rings.append(m)
	_ring_mats.append(mat)
