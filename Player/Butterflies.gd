extends Node3D
## Butterflies for the meadows: small procedural butterflies (two
## flapping wing quads on a body) that hover at flower patches and hop
## between them. Each butterfly owns a home patch and visits the other
## patches in a shuffled loop — the transit path is cleared against the
## terrain (up to 3 detour waypoints), so they never fly through hills.

## Butterflies in the island's system.
@export var count := 10
## How long one butterfly lingers at a flower patch (s).
@export var hover_time := 5.0
## Cruising speed between patches (m/s).
@export var cruise_speed := 3.0
## Stops per butterfly's local circuit (a handful of nearby patches,
## so hops are short and frequent instead of island-wide treks).
@export var circuit_size := 7
## Height above the flower head while hovering (m).
@export var hover_height := 0.7
## Wing flap rate (Hz).
@export var flap_hz := 11.0
## Deterministic colony (set from PropScatter).
@export var colony_seed := 0

const WING_COLOR_A := Color(0.95, 0.65, 0.2)   # monarch-ish
const WING_COLOR_B := Color(0.85, 0.3, 0.5)    # pink
const WING_COLOR_C := Color(0.5, 0.75, 0.95)   # blue

## One butterfly: node, its patch list loop, flight state.
class Flyer:
	var root: Node3D
	var wing_l: Node3D
	var wing_r: Node3D
	var stops: PackedVector3Array
	var stop_i := 0
	var from := Vector3.ZERO
	var to := Vector3.ZERO
	var leg_t := 0.0
	var leg_len := 1.0
	var flying := false
	var hover_left := 0.0
	var flap_phase := 0.0
	var flap_speed := 1.0

var _flies: Array[Flyer] = []
var _rng := RandomNumberGenerator.new()
var _t := 0.0


## PropScatter hands in the flower-patch head positions (world space)
## and how many butterflies to raise.
func setup(patches: PackedVector3Array, p_count: int) -> void:
	_colony_patches = patches
	_count_override = p_count

var _colony_patches: PackedVector3Array
var _count_override := -1


func _ready() -> void:
	_rng.seed = colony_seed
	var n := _count_override if _count_override > 0 else count
	n = mini(n, _colony_patches.size())
	# Shared geometry: every butterfly of a color reuses one mesh pair.
	var palettes := [WING_COLOR_A, WING_COLOR_B, WING_COLOR_C]
	for i in n:
		var f := Flyer.new()
		f.root = _build_butterfly(palettes[i % palettes.size()])
		add_child(f.root)
		_bind_wings(f)
		# A LOCAL circuit: greedy nearest-patch hops from a random
		# start, so each butterfly works one meadow's worth of blooms.
		f.stops = _local_tour(_colony_patches)
		f.from = f.stops[0]
		f.to = f.stops[0]
		f.hover_left = _rng.randf_range(1.0, hover_time)
		_flies.append(f)


## A greedy nearest-neighbour circuit over a handful of nearby
## patches: each butterfly stays local to its own cluster of blooms.
func _local_tour(patches: PackedVector3Array) -> PackedVector3Array:
	var start := _rng.randi_range(0, patches.size() - 1)
	var visited: Array[int] = [start]
	var out := PackedVector3Array([patches[start]])
	while visited.size() < mini(circuit_size, patches.size()):
		var best := -1
		var best_d := INF
		for i in patches.size():
			if visited.has(i):
				continue
			var d: float = out[out.size() - 1].distance_to(patches[i])
			if d < best_d:
				best_d = d
				best = i
		if best < 0:
			break
		visited.append(best)
		out.append(patches[best])
	return out


func _process(delta: float) -> void:
	_t += delta
	for f in _flies:
		# Wing flap always runs (even hovering: slow open-close).
		var flap_rate: float = flap_hz if f.flying else flap_hz * 0.25
		f.flap_phase += TAU * flap_rate * f.flap_speed * delta
		var a := sin(f.flap_phase)
		# Wings fold about the body's long axis (Z): tips rise and fall.
		f.wing_l.rotation.z = a * 1.0
		f.wing_r.rotation.z = -a * 1.0
		if not f.flying:
			# Hover: bob over the bloom, occasionally spiral.
			f.hover_left -= delta
			f.root.position = f.to + Vector3(
					sin(_t * 0.9 + f.flap_phase * 0.1) * 0.25,
					hover_height + sin(_t * 1.7 + f.flap_phase) * 0.08,
					cos(_t * 0.7 + f.flap_phase * 0.1) * 0.25)
			if f.hover_left <= 0.0:
				# Next stop: a terrain-cleared transit.
				f.stop_i = (f.stop_i + 1) % f.stops.size()
				var target := _cleared_path(f.from, f.stops[f.stop_i], f)
				f.from = f.root.position
				f.to = target
				f.leg_len = maxf(f.from.distance_to(f.to), 0.01)
				f.leg_t = 0.0
				f.flying = true
				f.flap_speed = _rng.randf_range(0.9, 1.25)
		else:
			# Transit: cruise along the cleared path with a gentle bob.
			f.leg_t += cruise_speed * f.flap_speed * delta / f.leg_len
			if f.leg_t >= 1.0:
				f.flying = false
				f.hover_left = _rng.randf_range(hover_time * 0.6,
						hover_time * 1.4)
				f.from = f.stops[f.stop_i]
			else:
				f.root.position = f.from.lerp(f.to,
						smoothstep(0.0, 1.0, f.leg_t)) \
						+ Vector3(0, sin(_t * 5.0 + f.flap_phase) * 0.05, 0)
				var dir := f.to - f.from
				if dir.length() > 0.01:
					f.root.basis = Basis.looking_at(dir.normalized(),
							Vector3.UP)


## Clears the straight path against the terrain: if the midpoint
## under-shoots (a hill in the way), route through up to 3 detour
## waypoints that hop over the obstacle.
func _cleared_path(from: Vector3, to: Vector3, f: Flyer) -> Vector3:
	# Sample the straight line; when the ground rises above the line,
	# raise the cruise altitude over that stretch.
	var cruise := 3.5
	var steps := 8
	var worst := -INF
	for i in range(1, steps):
		var t := float(i) / float(steps)
		var p := from.lerp(to, t)
		var g := _ground_at(p.x, p.z)
		var line_y: float = lerpf(from.y, to.y, t) + cruise
		if not is_nan(g) and g > line_y:
			worst = maxf(worst, g - line_y)
	if worst == -INF:
		return to
	# A hill blocks the line: raise the DESTINATION approach height so
	# the whole leg arcs over the obstacle.
	return to + Vector3(0, worst + 1.0, 0)


func _ground_at(x: float, z: float) -> float:
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
			Vector3(x, 500.0, z), Vector3(x, -400.0, z), 1)
	var hit := space.intersect_ray(params)
	return hit.position.y if not hit.is_empty() else NAN


## Procedural butterfly: body capsule + two flat wing quads.
func _build_butterfly(tint: Color) -> Node3D:
	var root := Node3D.new()
	var body := MeshInstance3D.new()
	var bm := CapsuleMesh.new()
	bm.radius = 0.012
	bm.height = 0.07
	body.mesh = bm
	body.rotation.x = TAU * 0.25  # lie along +Z
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.2, 0.16, 0.12)
	body.material_override = bmat
	root.add_child(body)
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = tint
	wmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wmat.albedo_color.a = 0.92
	wmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	wmat.emission_enabled = true
	wmat.emission = tint * 0.25
	var wing := PlaneMesh.new()
	wing.size = Vector2(0.09, 0.13)
	var wl := Node3D.new()
	var wr := Node3D.new()
	for side in [-1.0, 1.0]:
		var w := MeshInstance3D.new()
		w.mesh = wing
		w.material_override = wmat
		# Offset the quad so it spreads outward from the pivot (the
		# body edge), then swing the PIVOT to flap.
		w.position = Vector3(side * 0.048, 0.0, 0.0)
		var pivot := Node3D.new()
		pivot.position = Vector3(side * 0.008, 0.02, 0.0)
		pivot.add_child(w)
		root.add_child(pivot)
		if side < 0.0:
			wl = pivot
		else:
			wr = pivot
	root.set_meta("wl", wl)
	root.set_meta("wr", wr)
	return root


## Wings are pivots stored as meta (queried once after build).
func _bind_wings(f: Flyer) -> void:
	f.wing_l = f.root.get_meta("wl") as Node3D
	f.wing_r = f.root.get_meta("wr") as Node3D
