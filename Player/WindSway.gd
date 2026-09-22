extends Node3D
class_name WindSway
## The island's wind field: leans the scattered trees (and grass
## tufts) downwind every frame. A gentle breathing breeze always
## blows; every player's slipstream pushes the canopy harder — walk
## past a tree and it barely notices, swoop past in flight and the
## woods bend, a dive-bomb strike sends a gust through everything
## (downwash adds raw strength on top of the lateral push).
##
## PropScatter registers each swaying prop with register_tree(); every
## frame this node solves the shared wind vector (breeze + the strongest
## nearby player's slipstream) and leans each trunk TOWARDS it in
## WORLD space. Per-tree phasing (deterministic from a stable index)
## staggers the motion so the forest shimmers instead of moving like
## one rigid hedge. The sway is additive — the placement pose is never
## modified — and the pool of animated trunks is capped for cheapness.

## Breeze strength at rest: trunk-top lean in metres.
@export var breeze_strength := 0.22
## Slow oscillation of the breeze direction (radians of arc it sweeps).
@export var breeze_sweep := 1.1
## Seconds for the breeze vector to complete one full breathe cycle.
@export var breeze_period := 11.0
## Slipstream: lean (m) per (m/s) of player speed. 8 m/s of flight ~
## doubles the breeze; a 26 m/s swoop bends the canopy hard.
@export var slipstream_per_speed := 0.045
## How far from the player the wind is still felt (m): trunks beyond
## this distance sway barely at all, trunks beside it sway fully.
@export var sway_radius := 120.0
## Downwash extra during a dive (m of lean), added on top.
@export var dive_downwash := 0.85
## How fast gusts ease in and out (1/s) — punchy but not instant.
@export var gust_attack := 6.0
@export var gust_release := 1.8
## Lean response: how quickly a trunk follows the wind target (1/s).
@export var follow_speed := 3.2
## Deterministic per-tree phase scatter (indices hash into phases).
@export var phase_scatter := 1.0
## Cap on simultaneously animated trunks (perf): trees are gathered by
## score each frame from this pool. Sized for the full island (~300
## plants at the current tree line) — each animated trunk is a couple
## of vector lerps, so the true ceiling is far away.
@export var max_animated := 600

## One registered tree: node, world position, top height, per-tree
## phase offsets and current lean (for smoothing).
class SwayTree:
	var node: Node3D
	var pos: Vector3
	var height: float
	var phase_a := 0.0
	var phase_b := 0.0
	var amp := 1.0
	var lean := Vector2.ZERO

var _trees: Array[SwayTree] = []
var _rng := RandomNumberGenerator.new()
var _t := 0.0
## Last solved gust strength (0..1 blend of breeze->storm).
var _gust := 0.0
## True when at least one player is in the island's radius.
var _have_players := false


func _ready() -> void:
	_rng.seed = 0x57123


## Register a swaying prop. `index` should be stable across runs (the
## placement order from PropScatter) so each tree keeps its own phase.
func register_tree(node: Node3D, top_world_y: float, index: int) -> void:
	var st := SwayTree.new()
	st.node = node
	st.pos = node.global_position
	st.height = maxf(top_world_y - st.pos.y, 1.0)
	st.phase_a = float((index * 2654435761) % 1000) / 1000.0 * TAU
	st.phase_b = float((index * 40503 + 17) % 1000) / 1000.0 * TAU
	# Grass and small trees flicker faster (amp < 1 shortens the lever
	# feel); big trees respond deeper.
	st.amp = clampf(st.height / 10.0, 0.45, 1.0)
	_trees.append(st)


func _process(delta: float) -> void:
	_t += delta
	var breeze := _breeze_vec()
	var gust_target := 0.0
	var push := Vector3(breeze.x, 0.0, breeze.y)
	var strongest := 0.0
	# Slipstream: the strongest NEARBY player drives the gust. Several
	# players don't stack — the wind follows whoever shakes the woods
	# hardest.
	for p in get_tree().get_nodes_in_group("player"):
		var mc := p as MovementController
		if mc == null:
			continue
		_have_players = true
		var speed := mc.velocity.length()
		# Gust strength is SPEED-driven; the per-tree distance weight
		# below handles locality (only nearby woods get shaken).
		var s := speed * slipstream_per_speed
		if s > strongest:
			strongest = s
			var pv := mc.velocity * Vector3(1, 0, 1)
			var dir := pv.normalized() if pv.length() > 0.5 \
					else Vector3(push.x, 0.0, push.z).normalized()
			push = dir * s
			gust_target = clampf((speed - 4.0) / 30.0, 0.0, 1.0)
			if mc.diving:
				gust_target = 1.0
	# Dive downwash: raw extra strength, pushes DOWN the trunk tops.
	var downwash := 0.0
	if _gust >= 0.98:
		downwash = dive_downwash
	# Ease the gust.
	if gust_target > _gust:
		_gust = move_toward(_gust, gust_target, gust_attack * delta)
	else:
		_gust = move_toward(_gust, gust_target, gust_release * delta)
	# Total wind vector (XZ lean target for a 10 m tree).
	var wind := push * (1.0 + _gust * 1.6)
	# Animate a bounded pool: score by (distance to wind source) —
	# trees near the wind source sway hardest. Gather players' XZ.
	var pxz := Vector2.INF
	if _have_players:
		for p in get_tree().get_nodes_in_group("player"):
			var mc := p as MovementController
			if mc != null:
				var pp := mc.global_position
				pxz = Vector2(pp.x, pp.z)
				break
	var animated := 0
	for st in _trees:
		if animated >= max_animated:
			# Freeze the rest at a tiny standing shimmer.
			st.node.rotation = st.node.rotation.lerp(
					Vector3(0, st.node.rotation.y, 0), 0.2)
			continue
		var w := 1.0
		if pxz != Vector2.INF:
			var d := pxz.distance_to(Vector2(st.pos.x, st.pos.z))
			w = clampf(1.0 - d / sway_radius, 0.15, 1.0)
		# Per-tree phase: staggered breathing so the wood shimmers.
		var ph := sin(_t * 0.9 + st.phase_a) * 0.5 + 0.5
		var target := Vector2(wind.x, wind.z) * st.amp * (0.7 + 0.6 * ph)
		# Dive downwash compresses the canopy downward: extra lean with
		# a downward pitch, strongest on the tallest trees.
		if downwash > 0.0:
			target += target.normalized() * downwash * st.amp \
					* (st.height / 10.0)
		st.lean = st.lean.lerp(target, minf(1.0, follow_speed * delta))
		# Apply as a WORLD-frame tilt: rotate the trunk top towards
		# the lean vector while keeping the yaw.
		var lean_len := st.lean.length()
		if lean_len > 0.001:
			var yaw := st.node.rotation.y
			var tilt_axis := Vector3(-st.lean.y, 0.0, st.lean.x)
			var angle := atan2(lean_len, st.height)
			st.node.basis = Basis(tilt_axis.normalized(), angle) \
					* Basis(Vector3.UP, yaw)
		else:
			st.node.basis = Basis(Vector3.UP, st.node.rotation.y)
		animated += 1


## Current gust level (0..1) — exposed for audio systems (grass
## rustle, leaf sound) that want to react to the same wind.
func gust_level() -> float:
	return _gust


## The breathing breeze: a fixed base direction that sweeps slowly.
func _breeze_vec() -> Vector2:
	var dir := TAU * 0.15 + sin(_t * TAU / breeze_period) * breeze_sweep
	return Vector2(cos(dir), sin(dir)) * breeze_strength

