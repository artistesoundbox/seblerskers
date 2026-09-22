extends Area3D
## Procedural fireball projectile: a white-hot core inside an additive
## glow halo (so it reads as a fireball at any distance), a warm light,
## an ember trail and its own procedural explosion boom, launched from
## the character's right-hand attack. By default it flies DEAD STRAIGHT
## with UNLIMITED range — the flight only ends when it collides with
## world geometry (ray-per-step, so it never tunnels).
##
## Collision is ray-based: every physics tick a ray is cast from the
## previous position to the next, so the ball detonates on ANY wall or
## object it crosses — no tunneling at speed, thin walls included.
## Body overlaps (moving doors, future enemies) detonate it too.
##
## Built entirely at runtime — no scene or asset dependencies.

signal exploded(at: Vector3)

## Synthesis sample rate for the procedural boom (Hz).
const SYNTH_SAMPLE_RATE := 22050

@export var speed := 18.0
## Seconds before the ball self-detonates mid-air. 0 = unlimited range:
## the flight only ends on a collision (raise this if balls can escape
## the map into open sky).
@export var lifetime := 0.0
## Downward pull on the projectile (m/s^2). 0 = dead-straight flight —
## the ball never falls to the floor on its own.
@export var gravity_pull := 0.0
## Radius of the flame ball core (m).
@export var ball_radius := 0.22
## Radius of the additive glow halo around the core (m) — this is what
## makes the ball visible against bright geometry and at distance.
@export var glow_radius := 0.45
## Explosion flash duration (s).
@export var explosion_time := 0.5
## How long trail puffs linger (s).
@export var trail_puff_life := 0.4
## --- Explosion boom ---------------------------------------------------
## Loudness of the collision boom.
@export var explosion_db := -4.0
## Loudness of the flight whoosh that rides the ball (a shot is
## audible from the moment it leaves the hand, not only at impact).
@export var whoosh_db := -5.0
## Random pitch variation per boom.
@export var boom_pitch_variance := 0.1
## Optional boom override.
@export var boom_stream: AudioStream
## Blast radius: characters in the `viking` group inside this range of
## the impact are killed by the explosion (ranged damage). 0 = direct
## hit only — but a direct hit IS a ray contact on their collision, so
## they die at the impact point even with radius 0. Kept >0 so near
## misses hurt too.
@export var blast_radius := 3.0

var velocity := Vector3.ZERO

## 0 = flying, 1 = exploding, 2 = lingering embers, 3 = fizzled
## (parked far away, waiting out its trail puffs, then freed).
var _state := 0
var _age := 0.0
var _state_time := 0.0
var _ball: MeshInstance3D
var _core_mat: StandardMaterial3D
var _halo: MeshInstance3D
var _halo_mat: StandardMaterial3D
var _light: OmniLight3D
var _shell: MeshInstance3D
var _shell_mat: StandardMaterial3D
## World-fixed puff records: { node, age, life, vel, r0, mat }.
var _puffs: Array = []
var _trail_timer := 0.0
var _boom: AudioStreamPlayer3D
## Flight whoosh: a looping fire-roar that follows the ball and hands
## over to the boom at impact.
var _whoosh: AudioStreamPlayer3D
## Boom sounds fired this session (diagnostics/tests).
var boom_count := 0

## The synthesized boom is built once and shared by every fireball.
static var _boom_cache: AudioStreamWAV
## The flight whoosh loop, likewise shared.
static var _whoosh_cache: AudioStreamWAV


## Place the ball at `from` and set it flying along `dir` (world space).
## `inherit` adds the caster's own momentum (throw feel).
func launch(from: Vector3, dir: Vector3, inherit := Vector3.ZERO) -> void:
	global_position = from
	velocity = dir.normalized() * speed + inherit
	# The launch sound: the whoosh starts the instant the ball is
	# away, loud at full throw speed, then rides the flight.
	if _whoosh != null:
		_whoosh.volume_db = whoosh_db
		_whoosh.pitch_scale = clampf(0.9 + velocity.length() / 60.0,
				0.8, 1.4)
		_whoosh.play()


func _ready() -> void:
	# Fireballs never block each other; the caster sets collision_mask
	# (world geometry) before the node enters the tree.
	collision_layer = 0
	monitorable = false
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = ball_radius
	shape.shape = sphere
	add_child(shape)

	# Core: white-hot center. Unshaded + strong emission so it reads
	# even against a bright sky.
	_ball = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = ball_radius
	mesh.height = ball_radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	_ball.mesh = mesh
	_core_mat = StandardMaterial3D.new()
	_core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_core_mat.albedo_color = Color(1.0, 0.85, 0.55)
	_core_mat.emission_enabled = true
	_core_mat.emission = Color(1.0, 0.62, 0.2)
	_core_mat.emission_energy_multiplier = 5.0
	_ball.material_override = _core_mat
	add_child(_ball)

	# Halo: a larger additive-blended shell — the soft fire glow around
	# the hard core. This is the main distance legibility trick; the
	# core alone is a dot, the halo is a flame.
	_halo = MeshInstance3D.new()
	var hmesh := SphereMesh.new()
	hmesh.radius = glow_radius
	hmesh.height = glow_radius * 2.0
	hmesh.radial_segments = 16
	hmesh.rings = 8
	_halo.mesh = hmesh
	_halo_mat = StandardMaterial3D.new()
	_halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_halo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_halo_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_halo_mat.albedo_color = Color(1.0, 0.45, 0.1, 0.30)
	_halo_mat.emission_enabled = true
	_halo_mat.emission = Color(1.0, 0.4, 0.05)
	_halo_mat.emission_energy_multiplier = 2.0
	_halo_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	_halo.material_override = _halo_mat
	add_child(_halo)

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.55, 0.18)
	_light.omni_range = 5.0
	_light.light_energy = 2.4
	add_child(_light)

	_boom = AudioStreamPlayer3D.new()
	_boom.name = "Boom"
	_boom.max_distance = 60.0
	_boom.bus = "Master"
	_boom.stream = boom_stream if boom_stream != null else _make_boom_stream()
	add_child(_boom)

	_whoosh = AudioStreamPlayer3D.new()
	_whoosh.name = "Whoosh"
	_whoosh.max_distance = 45.0
	_whoosh.bus = "Master"
	_whoosh.stream = _make_whoosh_stream()
	add_child(_whoosh)

	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	_tick_puffs(delta)
	if _state == 0:
		_age += delta
		velocity.y -= gravity_pull * delta
		var prev := global_position
		var next := prev + velocity * delta
		# Ray the whole step: any wall crossed between prev and next
		# detonates the ball at the wall surface. Immune to tunneling
		# no matter how thin the wall or fast the ball.
		var hit := _ray_step(prev, next)
		if not hit.is_empty():
			var n: Vector3 = hit.get("normal", Vector3.UP)
			global_position = hit.position + n * ball_radius * 0.5
			_explode()
			return
		global_position = next
		# The whoosh breathes with the throw: faster ball = louder,
		# slightly higher roar. A dying lob goes quiet.
		if _whoosh != null and _whoosh.playing:
			var spd := velocity.length()
			# Below throw speed fades the roar out; a boosted fast throw
			# (momentum inherited from flight) swells up to +2 dB.
			_whoosh.volume_db = whoosh_db \
					+ linear_to_db(clampf(spd / 18.0, 0.12, 1.25))
			_whoosh.pitch_scale = clampf(0.9 + spd / 60.0, 0.8, 1.4)
		_trail_timer -= delta
		if _trail_timer <= 0.0:
			_trail_timer = 0.025
			_spawn_puff(global_position, Vector3.ZERO, ball_radius * 0.7,
					trail_puff_life)
		# Flicker: the core breathes like open flame; the halo pulses
		# slightly out of phase so the fire never looks static.
		var flick := 1.0 + 0.18 * sin(_age * 41.0)
		_ball.scale = Vector3.ONE * (0.9 + 0.1 * sin(_age * 23.0))
		_core_mat.emission_energy_multiplier = 5.0 * flick
		_halo_mat.albedo_color.a = 0.30 * (1.0 + 0.25 * sin(_age * 29.0))
		_light.light_energy = 2.4 * flick
		# lifetime 0 = unlimited: only a collision ends the flight.
		if lifetime > 0.0 and _age >= lifetime:
			_explode()
	elif _state == 1:
		_state_time += delta
		var f := clampf(_state_time / explosion_time, 0.0, 1.0)
		if _shell != null:
			_shell.scale = Vector3.ONE * (1.0 + f * 6.0)
			_shell_mat.albedo_color.a = 0.85 * (1.0 - f)
			_shell_mat.emission_energy_multiplier = 3.0 * (1.0 - f)
		_light.light_energy = 7.0 * (1.0 - f)
		if f >= 1.0:
			_state = 2
			_shell.visible = false
			_light.visible = false
	else:
		# The embers and the boom are all that is left; once both are
		# done, remove the node. The boom outlives the embers, so the
		# node must not free while it is still sounding.
		var boom_active := _boom != null and _boom.playing
		if _puffs.is_empty() and not boom_active:
			queue_free()


## Casts the step ray. Returns {} when the path is clear.
func _ray_step(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	if space == null:
		return {}
	var params := PhysicsRayQueryParameters3D.create(
			from, to, collision_mask)
	# Slight overshoot along the travel direction so grazing corners
	# still register a surface hit instead of slipping past.
	params.hit_from_inside = false
	var hit := space.intersect_ray(params)
	return hit


func _on_body_entered(_body: Node3D) -> void:
	# Secondary path: moving bodies (doors, enemies) overlapping the
	# ball. Deferred: the tree can't be restructured while flushing.
	if _state == 0:
		call_deferred("_explode")


## Fizzle: a far-away ball is quietly retired to free a cap slot.
## Kinematic only — the ball is teleported to a deep parking spot
## (a transform move, storm-free) with its visuals hidden, and the
## node frees itself once its already-spawned trail puffs burn out
## (an orphaned puff would never be freed by anyone). No pop, no
## boom, no kill check: at 80+ m the ball is a dot in the world.
func fizzle() -> void:
	if _state != 0:
		return
	_state = 3
	velocity = Vector3.ZERO
	if _whoosh != null and _whoosh.playing:
		_whoosh.stop()
	global_position = Vector3(1.1e5, -50.0, 1.1e5)
	_ball.visible = false
	_halo.visible = false
	if _light != null:
		_light.visible = false


## Impact: boom + fire dome + ember spray at the impact point.
func _explode() -> void:
	if _state != 0:
		return
	_state = 1
	_state_time = 0.0
	# monitoring left ON: the state guard ignores overlap callbacks
	# now, and toggling would storm the broadphase.
	# The whoosh is done: the boom takes over the frequency band.
	if _whoosh != null and _whoosh.playing:
		_whoosh.stop()
	exploded.emit(global_position)
	_kill_vikings()
	# The hoard's guardians fear fire: any serpent nearby flees.
	for s in get_tree().get_nodes_in_group("sea_serpent"):
		s.call("_on_fireball", global_position)
	# The boom: spatial, at the impact point, slight pitch variation.
	if _boom != null:
		if _boom.playing:
			_boom.stop()
		_boom.volume_db = explosion_db
		_boom.pitch_scale = clampf(
				1.0 + randf_range(-boom_pitch_variance, boom_pitch_variance),
				0.05, 8.0)
		_boom.play()
		boom_count += 1
	_spawn_shell(1.0)
	_ball.visible = false
	_halo.visible = false
	_light.omni_range = 7.0
	_light.light_energy = 7.0
	# Ember spray thrown outward from the impact point.
	for i in 14:
		var vel := Vector3(randf_range(-1.0, 1.0), randf_range(0.1, 1.0),
				randf_range(-1.0, 1.0)).normalized() * randf_range(2.0, 5.0)
		_spawn_puff(global_position, vel, randf_range(0.06, 0.13),
				randf_range(0.35, 0.6))


## The impact dome: a fading fire shell at the impact point.
func _spawn_shell(scale_mult: float) -> void:
	_shell = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = ball_radius * scale_mult
	mesh.height = ball_radius * scale_mult * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	_shell.mesh = mesh
	_shell_mat = StandardMaterial3D.new()
	_shell_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shell_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shell_mat.albedo_color = Color(1.0, 0.5, 0.1, 0.85)
	_shell_mat.emission_enabled = true
	_shell_mat.emission = Color(1.0, 0.35, 0.0)
	_shell_mat.emission_energy_multiplier = 3.0
	_shell.material_override = _shell_mat
	add_child(_shell)


## Kills every wanderer ("viking" group) caught in the blast: any
## member whose physics body comes within `blast_radius` of the impact
## point. Direct hits are covered because the impact IS on their body.
func _kill_vikings() -> void:
	for v in get_tree().get_nodes_in_group("viking"):
		var n := v as Node3D
		if n != null and n.global_position.distance_to(global_position) \
				<= blast_radius:
			n.call("die")
	# Barrels chain the blast: smash_neighbours spreads the pop from
	# barrel to barrel, so the pile goes off piece by piece.
	for b in get_tree().get_nodes_in_group("barrel"):
		var n := b as Node3D
		if n != null and n.visible \
				and n.global_position.distance_to(global_position) \
				<= blast_radius + 0.5:
			n.call("die")
	# Birds flush from the canopy at any blast within earshot — near
	# misses scare the flock just like direct hits.
	for f in get_tree().get_nodes_in_group("birds"):
		var flock := f as Node3D
		if flock != null and flock.global_position.distance_to(
				global_position) <= 60.0:
			flock.call("scare_from_blast", global_position)


func _spawn_puff(at: Vector3, vel: Vector3, r: float, life: float) -> void:
	var puff := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = r
	mesh.height = r * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	puff.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.5, 0.12, 0.6)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.32, 0.0)
	mat.emission_energy_multiplier = 2.5
	puff.material_override = mat
	# Puffs are world-fixed: they belong to the FX layer, not the ball.
	get_parent().add_child(puff)
	puff.global_position = at
	_puffs.append({"node": puff, "age": 0.0, "life": life,
			"vel": vel, "r0": r, "mat": mat})


func _tick_puffs(delta: float) -> void:
	for i in range(_puffs.size() - 1, -1, -1):
		var p: Dictionary = _puffs[i]
		p.age += delta
		var node: MeshInstance3D = p.node
		if p.age >= p.life or not is_instance_valid(node):
			if is_instance_valid(node):
				node.queue_free()
			_puffs.remove_at(i)
			continue
		var f: float = p.age / float(p.life)
		node.global_position += p.vel * delta
		p.vel.y -= 4.0 * delta  # embers fall
		node.scale = Vector3.ONE * (1.0 - 0.7 * f)
		var mat: StandardMaterial3D = p.mat
		mat.albedo_color.a = 0.6 * (1.0 - f)


## --- Procedural boom synthesis -----------------------------------------


## Packs float samples into a 16-bit mono AudioStreamWAV. Static so the
## shared boom cache can be built from a static function too.
static func _to_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2,
				int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SYNTH_SAMPLE_RATE
	wav.stereo = false
	wav.data = bytes
	return wav


## The flight whoosh: a seamless loop of filtered fire-roar — a mid
## rumble sweeping around 110 Hz plus crackle brights. Loops cleanly
## because every LFO in the synthesis rides whole cycles of the loop.
static func _make_whoosh_stream() -> AudioStreamWAV:
	if _whoosh_cache != null:
		return _whoosh_cache
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260918
	var length := int(1.2 * SYNTH_SAMPLE_RATE)
	var data := PackedFloat32Array()
	data.resize(length)
	var lp := 0.0
	var phase := 0.0
	for i in length:
		var u := float(i) / float(length)
		# Rumble: 96 -> 128 -> 96 Hz sweep over the loop (smooth fire
		# breathing), amplitude gated by a matching whole-cycle LFO.
		phase += TAU * (96.0 + 32.0 * sin(TAU * u)) \
				/ float(SYNTH_SAMPLE_RATE)
		var gate := 0.62 + 0.38 * sin(TAU * 2.0 * u - PI * 0.5)
		# Roar: noise through a low-pass that opens and closes twice
		# per loop (bright crackle cresting twice a second at speed).
		var bright := 0.35 + 0.65 * pow(
				0.5 + 0.5 * sin(TAU * u - PI * 0.5), 2.0)
		lp = lerpf(lp, rng.randf_range(-1.0, 1.0), 0.02 + 0.22 * bright)
		data[i] = (sin(phase) * 0.5 + lp * 0.9) * gate * 0.55
	var s := _to_stream(data)
	# The whoosh is a LOOP: it rides the flight until impact or fizzle.
	s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s.loop_begin = 0
	s.loop_end = length
	_whoosh_cache = s
	return _whoosh_cache


## The explosion boom, synthesized once and shared: a low body-thump
## (65->32 Hz sine — the hit in the chest), a noise roar through a
## closing low-pass (bright crack settling into dark rumble) and a
## sparse ember-crackle tail. Deterministic seed so every session's
## boom is the same mix.
static func _make_boom_stream() -> AudioStreamWAV:
	if _boom_cache != null:
		return _boom_cache
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260915
	var length := int(0.85 * SYNTH_SAMPLE_RATE)
	var data := PackedFloat32Array()
	data.resize(length)
	var lp := 0.0
	var phase := 0.0
	for i in length:
		var u := float(i) / float(length)
		var v := 0.0
		# Body thump: 65 -> 32 Hz over the first 40% of the sample.
		if u < 0.4:
			var tu := u / 0.4
			phase += TAU * (65.0 - 33.0 * tu) / float(SYNTH_SAMPLE_RATE)
			v += sin(phase) * 0.85 * exp(-6.5 * tu)
		# Roar: noise through a low-pass that closes as it decays.
		var bright := exp(-4.0 * u)
		lp = lerpf(lp, rng.randf_range(-1.0, 1.0), 0.02 + 0.30 * bright)
		v += lp * 1.1 * exp(-3.0 * u)
		# Ember crackle: sparse ticks in the tail.
		if u > 0.35 and rng.randf() < 0.004:
			var tick := int(0.006 * SYNTH_SAMPLE_RATE)
			var amp := rng.randf_range(0.08, 0.2)
			for k in tick:
				var idx := i + k
				if idx >= length:
					break
				data[idx] += rng.randf_range(-1.0, 1.0) * amp \
						* (1.0 - float(k) / float(tick))
		data[i] += v
	_boom_cache = _to_stream(data)
	return _boom_cache
