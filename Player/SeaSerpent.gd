class_name SeaSerpent
extends Node3D
## The hoard's guardian: a deep-sea serpent that circles one sunken
## chest forever, just under the surface. A diver who comes near is
## chased and bitten — the first bite is a warning (water slam, red
## flash, air squeezed out); the second drags the hero under and back
## to his spawn. A fireball blast near it (a hull-top defense, or a
## desperate underwater shot) drives it off in a fright for a while.
##
## Purely procedural: a chain of nine meshes solved as a trailing
## spine with a traveling sine wave, so it swims like an eel. No
## physics bodies — the bite is a distance check, no broadphase cost.
## Spawned by PropScatter, one per sea-hoard chest.

const SEG_COUNT := 9
const SEG_SPACING := 0.62
const HIDE_COLOR := Color(0.13, 0.20, 0.22)
const EYE_COLOR := Color(0.75, 0.9, 0.35)

## Circle radius around the chest (m) and angular speed (rad/s).
@export var circle_radius := 7.0
@export var circle_speed := 0.35
## A diver closer than this to the head is chased.
@export var aggro_radius := 9.0
## Chase speed (m/s) — fast, but a sprinting swimmer can just gain.
@export var chase_speed := 5.2
## Bite range (m) and cooldown (s) between lunges.
@export var bite_radius := 1.9
@export var bite_cooldown := 1.7
## Fright speed and duration after a fireball.
@export var flee_speed := 11.0
@export var flee_time := 5.0

enum State { CIRCLE, CHASE, FLEE }

var state: int = State.CIRCLE
var _chest: Node3D
var _center := Vector3.ZERO
var _angle := 0.0
var _wave_t := 0.0
var _head_vel := Vector3.ZERO
var _bites := 0
var _cd := 0.0
var _flee_t := 0.0
var _growl_t := 0.0
var _bite_pause := 0.0
var _segs: Array[MeshInstance3D] = []
var _trail: PackedVector3Array = []


func setup(chest: Node3D) -> void:
	_chest = chest


func _ready() -> void:
	add_to_group("sea_serpent")
	_angle = randf() * TAU
	_build()
	# The spine starts ON its beat around the chest — the wrapper spawns
	# at the world origin, so without this the serpent would have to
	# swim a hundred meters before guarding anything.
	if _chest != null and is_instance_valid(_chest):
		_center = _chest.global_position + Vector3(0, -1.05, 0)
	else:
		_center = global_position
	_trail.resize(SEG_COUNT)
	for i in SEG_COUNT:
		var a := _angle - i * 0.35
		_trail[i] = _center + Vector3(cos(a), 0.0, sin(a)) * circle_radius
		_segs[i].global_position = _trail[i]


func _build() -> void:
	var hide_mat := StandardMaterial3D.new()
	hide_mat.albedo_color = HIDE_COLOR
	hide_mat.roughness = 0.55
	hide_mat.metallic = 0.1
	var fin_mat := StandardMaterial3D.new()
	fin_mat.albedo_color = Color(0.16, 0.26, 0.26, 0.85)
	fin_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fin_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = EYE_COLOR
	eye_mat.emission_enabled = true
	eye_mat.emission = EYE_COLOR
	eye_mat.emission_energy_multiplier = 1.6
	for i in SEG_COUNT:
		var seg := MeshInstance3D.new()
		var r := lerpf(0.45, 0.12, float(i) / float(SEG_COUNT - 1))
		var sm := SphereMesh.new()
		sm.radius = r
		sm.height = r * 2.0
		sm.radial_segments = 10
		sm.rings = 6
		seg.mesh = sm
		seg.material_override = hide_mat
		seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		seg.top_level = true
		add_child(seg)
		_segs.append(seg)
		if i >= 2 and i <= 7:
			# Dorsal ridge rings: thin tori around the spine axis.
			var ring := MeshInstance3D.new()
			var tm := TorusMesh.new()
			tm.inner_radius = r * 0.72
			tm.outer_radius = r * 0.86
			tm.rings = 6
			tm.ring_segments = 4
			ring.mesh = tm
			ring.material_override = fin_mat
			ring.rotation_degrees.x = 90.0
			ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			seg.add_child(ring)
		if i == 0:
			# The head: a vertical fin and two glowing eyes forward.
			var fin := MeshInstance3D.new()
			var fm := BoxMesh.new()
			fm.size = Vector3(0.04, 0.42, 0.5)
			fin.mesh = fm
			fin.material_override = fin_mat
			fin.position = Vector3(0.0, 0.42, 0.05)
			fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			seg.add_child(fin)
			for side in [-1.0, 1.0]:
				var eye := MeshInstance3D.new()
				var em := SphereMesh.new()
				em.radius = 0.055
				em.height = 0.11
				em.radial_segments = 6
				em.rings = 3
				eye.mesh = em
				eye.material_override = eye_mat
				eye.position = Vector3(0.19 * side, 0.13, -0.36)
				seg.add_child(eye)


func _physics_process(delta: float) -> void:
	if _chest == null or not is_instance_valid(_chest):
		return
	_wave_t += delta
	_cd = maxf(0.0, _cd - delta)
	_growl_t -= delta
	_center = _chest.global_position + Vector3(0, -1.05, 0)
	var head_pos := _segs[0].global_position if _segs[0].global_position != \
			Vector3.ZERO else _trail[0]
	var heroes := get_tree().get_nodes_in_group("player")
	var hero: Node3D = heroes[0] if not heroes.is_empty() else null

	match state:
		State.CIRCLE:
			_angle += circle_speed * delta
			var desired := _center + Vector3(cos(_angle), 0, sin(_angle)) \
					* circle_radius \
					+ Vector3(0, sin(_wave_t * 0.9) * 0.35, 0)
			_steer(head_pos, desired, 5.0, delta)
			if _growl_t <= 0.0:
				_growl_t = randf_range(7.0, 12.0)
				_growl(-12.0)
			if hero != null and head_pos.distance_to(
					hero.global_position) < aggro_radius:
				state = State.CHASE
				_growl(-4.0)
		State.CHASE:
			if hero == null:
				state = State.CIRCLE
				return
			var target: Vector3 = hero.global_position + Vector3(0, -0.4, 0)
			if _bite_pause > 0.0:
				_bite_pause -= delta
			else:
				_steer(head_pos, target, chase_speed, delta)
			if _growl_t <= 0.0:
				_growl_t = randf_range(2.5, 4.0)
				_growl(-8.0)
			if head_pos.distance_to(target) < bite_radius and _cd <= 0.0 \
					and _bite_pause <= 0.0:
				_cd = bite_cooldown
				_bite_pause = 0.45
				_bites += 1
				hero.call("serpent_bite", head_pos)
				if _bites >= 2:
					_bites = 0
					state = State.CIRCLE
			if head_pos.distance_to(hero.global_position) > aggro_radius * 2.2:
				state = State.CIRCLE
				_bites = 0
		State.FLEE:
			_flee_t -= delta
			if hero != null:
				var away := (head_pos - hero.global_position).normalized()
				_steer(head_pos, head_pos + away * 10.0 \
						+ Vector3(0, 0.6, 0), flee_speed, delta)
			if _flee_t <= 0.0:
				state = State.CIRCLE
				_bites = 0

	_solve_chain(delta)


## Smooth pursuit: ease the head velocity toward the target point.
func _steer(head_pos: Vector3, to: Vector3, speed: float, delta: float) -> void:
	var dir := to - head_pos
	if dir.length_squared() < 0.0001:
		return
	_head_vel = _head_vel.lerp(dir.normalized() * speed,
			1.0 - exp(-3.0 * delta))
	var next := head_pos + _head_vel * delta
	# Stay under the surface, above the deep.
	next.y = clampf(next.y, _center.y - 1.2, sea_surface() - 0.35)
	_segs[0].global_position = next
	_face(_segs[0], _head_vel)
	_trail[0] = next


func sea_surface() -> float:
	for p in get_tree().get_nodes_in_group("player"):
		return float(p.get("water_y"))
	return -0.75


## Trailing spine: each segment chases the one ahead at fixed spacing,
## with a traveling sine wave for the eel-swim.
func _solve_chain(delta: float) -> void:
	var amp := 0.20 if state == State.CHASE else 0.12
	for i in range(1, SEG_COUNT):
		var prev := _trail[i - 1]
		var cur := _trail[i]
		var dir := prev - cur
		if dir.length_squared() < 0.000001:
			dir = Vector3.FORWARD
		dir = dir.normalized()
		var p := prev - dir * SEG_SPACING
		var perp := dir.cross(Vector3.UP).normalized() \
				if absf(dir.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
		p += perp * sin(_wave_t * 3.5 - i * 0.55) * amp
		_trail[i] = p
		_segs[i].global_position = p
		_face(_segs[i], -dir)


func _face(seg: MeshInstance3D, dir: Vector3) -> void:
	if dir.length_squared() < 0.000001:
		return
	var flat := Vector3(dir.x, 0, dir.z)
	if flat.length_squared() < 0.000001:
		flat = Vector3.FORWARD
	seg.look_at(seg.global_position + dir.normalized(), Vector3.UP)


## A fireball blast near the serpent scares it off (near misses count).
func _on_fireball(at: Vector3) -> void:
	if _segs.is_empty():
		return
	if at.distance_to(_segs[0].global_position) < 14.0:
		state = State.FLEE
		_flee_t = flee_time
		_growl(-2.0)


# --- the growl ---------------------------------------------------------------

const SR := 22050
static var _growl_cache: AudioStreamWAV


## A deep rumbling growl: a descending saw through tremolo — the
## telegraph that something big just noticed you.
static func _growl_stream() -> AudioStreamWAV:
	if _growl_cache != null:
		return _growl_cache
	var length := int(0.9 * SR)
	var bytes := PackedByteArray()
	bytes.resize(length * 2)
	for i in length:
		var u := float(i) / float(SR)
		var f := lerpf(90.0, 48.0, u)
		var saw := 2.0 * fposmod(f * u, 1.0) - 1.0
		var trem := 0.6 + 0.4 * sin(TAU * 7.0 * u)
		var env := minf(u / 0.12, 1.0) * exp(-2.2 * u)
		bytes.encode_s16(i * 2,
				int(clampf(saw * trem * env * 0.5, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	wav.data = bytes
	_growl_cache = wav
	return wav


func _growl(db: float) -> void:
	var pl := AudioStreamPlayer3D.new()
	pl.stream = _growl_stream()
	pl.volume_db = db
	pl.pitch_scale = randf_range(0.9, 1.1)
	pl.unit_size = 10.0
	pl.max_distance = 60.0
	add_child(pl)
	pl.global_position = _segs[0].global_position
	pl.play()
	get_tree().create_timer(1.2).timeout.connect(pl.queue_free)
