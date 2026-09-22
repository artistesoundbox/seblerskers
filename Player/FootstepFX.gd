class_name FootstepFX
extends Node3D
## Animation-driven footstep dust for the character.
##
## A subtle dust puff spawns at each footfall and a stronger impact puff on
## hard landings, always at the foot's actual contact point on the ground.
##
## Footfalls are detected from the ANIMATION, not a timer: each physics
## frame the foot bones' world heights are sampled; a foot that reverses
## from descending to rising (after a deep enough, fast enough descent)
## has just planted. This follows the walk/run rhythm automatically,
## including the stride-matched animation speed scaling.

## Emitted when a foot plants. `strength` is 0.25..1.0 from descent
## speed (already includes the crouch softening); `crouched` tells
## listeners to back off. Landing puffs emit `landed` instead.
signal stepped(pos: Vector3, strength: float, crouched: bool)
## Emitted on landing; `impact` is 0.3..1.0 from fall speed.
signal landed(pos: Vector3, impact: float)

## Total length of the ground raycast under each foot (m).
@export var ray_length := 1.5
## Physics layers the ground ray hits (default: layer 1 "Objects").
@export_flags_3d_physics var ground_mask := 1
## Descent depth (m) a foot must reach below its recent high point before
## a plant can register — filters out idle sway.
@export var plant_depth := 0.055
## Descent speed (m/s) a foot must reach to count as a step.
@export var plant_speed := 0.25
## Detection is suppressed this long after spawn: the T-pose -> animation
## blend-in otherwise reads as one long foot descent and fakes a step.
@export var warmup_time := 0.4
## Minimum horizontal body speed (m/s) for step FX: idle weight-shifts can
## exceed the descent thresholds but must never kick up dust or sound.
@export var min_step_speed := 1.0
## Minimum seconds between plants on the same foot: at very high speeds the
## stride-matched clip's foot oscillation aliases past the physics rate and
## would otherwise double-fire.
@export var step_refractory := 0.07
## Fall speed (m/s) below which touching down is silent (steps off ledges,
## tiny drops).
@export var min_land_fall_speed := 4.0
## Minimum fall speed (m/s) for the superman landing crack — the
## pavement-shatter burst (LandingCrack) fires on hard touchdowns by
## raw speed OR by the model's severity grade (speed + fall HEIGHT),
## so soft-speed flight landings from up high crack too.
@export var crack_min_fall_speed := 9.0
## Puff strength per footstep (0.2 = subtle, 1.0 = stomp).
@export var step_strength := 0.3
## Landing puff strength at 12 m/s fall speed (scales down for softer falls).
@export var land_strength := 1.0
## Base vertical launch speed of dust particles (m/s).
@export var launch_speed := 0.9
## Dust quad size (m).
@export var particle_size := 0.3
## Number of burst emitters; alternating lets fast footsteps overlap
## without cutting the previous puff short.
@export var emitter_count := 2

const FOOT_BONES: Array[StringName] = [
	&"mixamorig_LeftFoot", &"mixamorig_RightFoot"]
const PARTICLES_PER_BURST := 14
const BURST_LIFETIME := 0.6
## The superman landing crack (preloaded: global class names are not
## reliably resolvable from headless runs).
const CRACK_SCRIPT := preload("res://Player/LandingCrack.gd")

## Incremented on every burst; useful for tests/debugging.
var burst_count := 0

var _skeleton: Skeleton3D
var _bone_idx := [-1, -1]
var _dust: Array[GPUParticles3D] = []
var _mat: ParticleProcessMaterial
var _active := -1
var _last_y := [0.0, 0.0]
var _high_y := [0.0, 0.0]
var _peak_y := [0.0, 0.0]
var _peak_speed := [0.0, 0.0]
var _was_on_floor := true
var _fall_peak := 0.0
var _primed := false
var _age := 0.0
var _last_plant := [0.0, 0.0]

## A foot moving more than this in one physics frame is a teleport or a
## pose snap (e.g. T-pose -> animation on spawn), never a real step.
const TELEPORT_GUARD := 0.4

## Prints every emitted footfall/landing with its trigger values (tuning aid).
var debug_footfalls := false
## When > 0, prints the raw per-frame tracker state for both feet
## (tuning aid); decremented every physics frame.
var debug_trace_frames := 0

@onready var controller: MovementController = get_parent()


func _ready() -> void:
	# World-positioned: the node follows the feet, not the body's transform.
	top_level = true
	var model: Node = controller.get_node(controller.model_path)
	var skel: Skeleton3D = null
	if model.has_method("get_driven_skeleton"):
		# The model's own resolver: the skeleton its AnimationPlayer drives,
		# not just the first Skeleton3D in traversal order (the animation
		# source players each carry skinless armatures of their own).
		skel = model.get_driven_skeleton()
	if skel == null:
		set_physics_process(false)
		return
	_skeleton = skel
	for i in 2:
		_bone_idx[i] = _skeleton.find_bone(String(FOOT_BONES[i]))
	if _bone_idx[0] < 0 and _bone_idx[1] < 0:
		set_physics_process(false)
		return
	_mat = _make_process_material()
	for i in emitter_count:
		_dust.append(_make_dust("Dust%d" % i))
	global_position = controller.global_position


func _physics_process(delta: float) -> void:
	_age += delta
	var on_floor := controller.is_on_floor()
	_check_landing(on_floor)
	if on_floor:
		if _age < warmup_time:
			# Spawn blend-in: keep baselines fresh, detect nothing.
			_prime_trackers()
		else:
			_track_feet(delta)
	else:
		# Airborne: reset trackers so touching down can't fake a footfall.
		_prime_trackers()
	_was_on_floor = on_floor


## Footfall detector: a foot that just reversed from descending to rising
## after a deep + fast descent has planted. While crouching the feet
## travel much less, so the thresholds relax (keeping a floor above idle
## sway so standing still still raises no dust).
func _track_feet(delta: float) -> void:
	if not _primed:
		# First grounded frame: just sample baselines; detecting from them
		# would fire on the spawn-time T-pose -> animation snap.
		_prime_trackers()
		return
	var crouched: bool = controller.crouching and not controller.flying
	var depth_needed := maxf(plant_depth * (0.5 if crouched else 1.0), 0.02)
	var speed_needed := maxf(plant_speed * (0.5 if crouched else 1.0), 0.08)
	if debug_trace_frames > 0:
		debug_trace_frames -= 1
		print("[trace] t=%.2f f0 y=%.3f last=%.3f high=%.3f peak=%.3f ps=%.2f lp=%.2f | f1 y=%.3f last=%.3f high=%.3f peak=%.3f ps=%.2f lp=%.2f need d=%.3f s=%.2f" % [
				_age, _foot_world_y(0), _last_y[0], _high_y[0], _peak_y[0],
				_peak_speed[0], _last_plant[0], _foot_world_y(1), _last_y[1],
				_high_y[1], _peak_y[1], _peak_speed[1], _last_plant[1],
				depth_needed, speed_needed])
	for i in 2:
		if _bone_idx[i] < 0:
			continue
		var y := _foot_world_y(i)
		if absf(y - _last_y[i]) > TELEPORT_GUARD:
			_prime_foot(i)
			continue
		if y < _last_y[i]:
			# Descending: track the lowest point and the descent speed.
			_peak_y[i] = minf(_peak_y[i], y)
			_peak_speed[i] = maxf(_peak_speed[i], (_last_y[i] - y) / delta)
		elif y > _last_y[i]:
			# Rising again: plant if the descent was deep and fast enough.
			if (_high_y[i] - _peak_y[i]) >= depth_needed \
					and _peak_speed[i] >= speed_needed:
				var hs := Vector2(controller.velocity.x,
						controller.velocity.z).length()
				var strength := clampf(_peak_speed[i] / 4.0, 0.5 if crouched else 0.25, 1.0)
				if crouched:
					strength *= 0.6  # crouch-walks kick up less dust
				if hs >= min_step_speed \
						and _age - _last_plant[i] >= step_refractory:
					_last_plant[i] = _age
					if debug_footfalls:
						print("[step] foot=%d depth=%.3f speed=%.2f hs=%.2f" % [
								i, _high_y[i] - _peak_y[i], _peak_speed[i], hs])
					stepped.emit(_foot_ground_pos(i), strength, crouched)
					_burst(_foot_ground_pos(i), strength * step_strength)
			_high_y[i] = maxf(_high_y[i], y)
			_peak_y[i] = y
			_peak_speed[i] = 0.0
		_last_y[i] = y


## Reset both foot trackers to the current pose. Used while airborne (so
## touching down can't fake a footfall) and on the first grounded frame
## (so the spawn-time T-pose -> animation snap can't either).
func _prime_trackers() -> void:
	for i in 2:
		_prime_foot(i)
	_primed = true


func _prime_foot(i: int) -> void:
	var y := _foot_world_y(i)
	_last_y[i] = y
	_high_y[i] = y
	_peak_y[i] = y
	_peak_speed[i] = 0.0
	_last_plant[i] = 0.0


func _check_landing(on_floor: bool) -> void:
	if not on_floor:
		_fall_peak = maxf(_fall_peak, -controller.velocity.y)
		return
	if not _was_on_floor:
		# Severity shares ONE ladder with the absorb crouch: the model
		# graded this touchdown from fall speed + fall HEIGHT (flight
		# landings under-grade by speed alone — glide damping eases the
		# sink). Dust scales with the grade, the crack fires past the
		# shared threshold, and the old speed test still guarantees a
		# puff for plain jumps even if no grade was published.
		var grade := 0.0
		var m: Node = controller.get_node_or_null(controller.model_path)
		if m != null and "landing_grade" in m:
			grade = m.landing_grade
		var speed_hit := _fall_peak > min_land_fall_speed
		if speed_hit or grade > 0.0:
			var speed_impact := clampf(_fall_peak / 12.0, 0.3, 1.0)
			var impact: float = maxf(speed_impact, grade) * land_strength
			var at := _mid_feet_ground_pos()
			# Water touchdown (flight/dive into the sea): the entry
			# splash already spoke — no dirt thud, dust puff or pavement
			# crack replays the fall on the seabed underwater.
			if at.y < controller.water_y - 0.25:
				if debug_footfalls:
					print("[land] water touchdown — dust/thud skipped")
			else:
				if debug_footfalls:
					print("[land] fall=%.2f grade=%.2f impact=%.2f"
							% [_fall_peak, grade, impact])
				landed.emit(at, impact)
				_burst(at, impact)
				var crack := _fall_peak >= crack_min_fall_speed
				if m != null and "fire_absorb_grade" in m:
					crack = crack or grade >= m.fire_absorb_grade
				if crack:
					# Superman: the ground shatters under the hard touchdown.
					var host := get_tree().current_scene
					if host == null:
						host = get_tree().root  # headless/edge fallback
					var s := clampf(grade * 0.9 + 0.3, 0.45, 1.0)
					if grade <= 0.0:
						s = clampf((_fall_peak - crack_min_fall_speed)
								/ 12.0 + 0.45, 0.45, 1.0)
					CRACK_SCRIPT.play(host, at, s)
		# Consume the grade: a later soft touch must not inherit this
		# touchdown's severity.
		if m != null and "landing_grade" in m:
			m.landing_grade = 0.0
	# Always reset when grounded — keeping a stale fall speed across soft
	# touches made later bounces fire phantom landings.
	_fall_peak = 0.0


## Fires a one-shot dust burst at `pos`. Alternating emitters let bursts
## overlap (fast running) without cutting the previous puff short.
func _burst(pos: Vector3, strength: float) -> void:
	if strength <= 0.01 or _dust.is_empty():
		return
	burst_count += 1
	_active = (_active + 1) % _dust.size()
	var p := _dust[_active]
	_mat.initial_velocity_min = launch_speed * 0.4 * (0.6 + strength)
	_mat.initial_velocity_max = launch_speed * (0.6 + strength)
	p.global_position = pos + Vector3.UP * 0.05
	p.restart()
	p.emitting = true


func _foot_world_y(i: int) -> float:
	return _foot_world_pos(i).y


func _foot_world_pos(i: int) -> Vector3:
	return _skeleton.to_global(
			_skeleton.get_bone_global_pose(_bone_idx[i]).origin)


func _mid_feet_ground_pos() -> Vector3:
	var a := _ground_below(_foot_world_pos(0))
	var b := _ground_below(_foot_world_pos(1))
	return (a + b) * 0.5


func _foot_ground_pos(i: int) -> Vector3:
	return _ground_below(_foot_world_pos(i))


## Raycasts straight down to find the ground contact point below `from`
## (the foot bone is slightly above the floor surface).
func _ground_below(from: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
			from + Vector3.UP * (ray_length * 0.5),
			from - Vector3.DOWN * (ray_length * 0.5), ground_mask)
	q.exclude = [controller.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return from - Vector3.UP * (ray_length * 0.5)
	return hit.position


## --- Particle setup (built in code, nothing to wire up by hand) --------


func _make_dust(dust_name: String) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = dust_name
	p.emitting = false
	p.one_shot = true
	p.amount = PARTICLES_PER_BURST
	p.lifetime = BURST_LIFETIME
	p.explosiveness = 0.95
	p.local_coords = false
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.visibility_aabb = AABB(Vector3(-2, -1, -2), Vector3(4, 3, 4))
	p.process_material = _mat
	p.draw_pass_1 = _make_quad()
	add_child(p)
	return p


func _make_process_material() -> ParticleProcessMaterial:
	var m := ParticleProcessMaterial.new()
	m.gravity = Vector3(0, -0.6, 0)
	m.direction = Vector3(0, 1, 0)
	m.spread = 30.0
	m.scale_min = 0.6
	m.scale_max = 1.3
	m.damping_min = 0.5
	m.damping_max = 1.5
	m.color_ramp = _make_color_ramp()
	return m


func _make_color_ramp() -> GradientTexture1D:
	var g := Gradient.new()
	g.set_color(0, Color(0.62, 0.56, 0.47, 0.45))
	g.set_color(1, Color(0.62, 0.56, 0.47, 0.0))
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


func _make_quad() -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(particle_size, particle_size)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _make_soft_dot()
	q.material = mat
	return q


## Soft radial dot texture so puffs fade at the edges instead of showing
## hard quad borders.
func _make_soft_dot() -> GradientTexture2D:
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
