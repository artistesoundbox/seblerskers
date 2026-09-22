class_name ShipCrew
extends Node3D
## The flagship's viking crew: three rowers on the benches and a
## helmsman at the stern tiller. Built by Sailboat (the placement scale
## must be known first — all deck positions are model units, scaled at
## build time).
##
## The crew rows on the PLAYER's real stroke events (Sailboat forwards
## every row_stroke from the rowing clip), so oars, splash bursts and
## the rower's own animation all beat together. Rowers lean into the
## pull and settle between strokes; the helmsman counters the rudder.
## Idle, rowers sit easy and glance at the player when he's aboard; a
## chest opened from the hull gets a bounce-and-cheer.

const ROWER_COUNT := 3
## Deck seats in MODEL units: x = outboard side, z along the hull
## (bow = +z). The hull spans about +-4 model units in z, +-1.7 in x.
const ROWER_SEATS := [
	Vector3(-1.05, 0.0, 2.6),
	Vector3(1.05, 0.0, 1.6),
	Vector3(-1.05, 0.0, 0.4),
]
## The helmsman stands at the stern, facing the bow.
const HELM_SEAT := Vector3(0.0, 0.0, -2.6)
## The spotter stands on the starboard quarter, forward of the helm.
const SPOTTER_SEAT := Vector3(1.05, 0.0, -1.4)
## The spotter stands on a foothold (crate): a bit taller than deck.
const SPOTTER_BOOST := 0.35
## Seating a standing GLB: sink it by seated hip height (model units).
const SIT_SINK := 0.55
## Rowing pose amplitudes (procedural, tweened on stroke events).
const PULL_LEAN_DEG := 26.0
## Oar stroke: degrees of pitch on the gunwale pivot.
const OAR_PITCH_DEG := 26.0
## Seconds of pull (blade through the water) and settle (recovery).
const PULL_TIME := 0.30
const SETTLE_TIME := 0.34
## --- The spotter --------------------------------------------------------
## Hull-to-glint range for a callout (matches the chest glint band,
## just past it so the shout arrives as the bubbles start).
const SPOT_RANGE := 30.0
## How long the callout text and the pointing arm hold (s).
const CALLOUT_TIME := 3.0
## Quiet time between callouts (s), so a hoard stretch reads as
## separate shouts, not a chant.
const SPOT_COOLDOWN := 5.0
## The callout lines (viking-flavored; picked per sighting).
const SPOT_LINES := [
	"Glittri í sjónum!",
	"Bubbles — ho!",
	"Sunken chest, alee!",
]
## The crew keeps its own copy of the boat's cruise speed (m/s) for
## the rowing-intensity estimate — no back-reference to Sailboat (it
## preloads this script; a class reference would be a cyclic load).
const CRUISE_SPEED := 5.5

var _rowers: Array[Dictionary] = []
var _helm: Node3D = null
## The lookout: watches for sunken-chest glints, shouts and points.
var _spotter: Node3D = null
## The spotter's pointing arm (raised while a callout holds).
var _spot_arm: MeshInstance3D = null
## The floating callout text (Label3D over the chest).
var _spot_msg: Label3D = null
## The chest currently called out (null when none).
var _spot_target: Node3D = null
## Remaining callout time; cooldown until the next scan fires.
var _spot_left := 0.0
var _spot_cd := 0.0
## Eased 0..1: how raised the pointing arm is.
var _spot_point := 0.0
## Glints already shouted (instance ids) — each chest once per run.
var _spotted := {}
## Sailboat's rudder (-1..1); the helmsman counters it.
var _helm_lean := 0.0
## Eased 0..1: how hard the crew is rowing (from the boat's speed).
var _row_amp := 0.0
## Remaining cheer time; rowers bounce while it runs.
var _cheer_left := 0.0
var _rng := RandomNumberGenerator.new()
## Headless-verifiable event counters (dummy RenderingServer shows no
## motion, so tests count events, like FootstepFX's burst_count).
var stroke_count := 0
var cheer_count := 0
## Headless-verifiable: how many glint callouts have fired.
var spot_count := 0


## Builds the crew under the boat (once, from Sailboat._ready).
## `scl` is the placement scale; every model-unit offset multiplies it.
## `paths` are the warrior GLB res:// paths (shuffled for variety).
func build(scl: float, paths: Array) -> void:
	_rng.seed = 911
	var shuffled := paths.duplicate()
	shuffled.shuffle()
	for i in ROWER_COUNT:
		var seat: Vector3 = ROWER_SEATS[i] * scl
		var rower := _make_viking(shuffled[i % shuffled.size()], scl)
		var base_y := seat.y - SIT_SINK * scl
		rower.position = Vector3(seat.x, base_y, seat.z)
		# GLBs face -Z; yawing PI faces them toward the bow (+Z).
		rower.rotation.y = PI
		add_child(rower)
		var oar := _make_oar(scl)
		var side := -1.0 if seat.x < 0.0 else 1.0
		oar.position = Vector3(side * 1.75 * scl, 0.15 * scl, seat.z)
		oar.rotation.y = PI if seat.x < 0.0 else 0.0
		add_child(oar)
		_rowers.append({"root": rower, "oar": oar, "pull": 0.0,
				"base_y": base_y, "tw": null,
				"bounce_seed": _rng.randf() * TAU})
	_helm = _make_viking(shuffled[ROWER_COUNT % shuffled.size()], scl)
	_helm.position = HELM_SEAT * scl
	_helm.rotation.y = PI
	add_child(_helm)
	# The spotter: standing, on a foothold, facing the bow quarter.
	_spotter = _make_viking(shuffled[(ROWER_COUNT + 1) % shuffled.size()],
			scl)
	_spotter.position = (SPOTTER_SEAT \
			+ Vector3(0.0, SPOTTER_BOOST, 0.0)) * scl
	add_child(_spotter)
	# The pointing arm: a raised wooden-tone limb that lifts toward
	# whatever he shouts about.
	_spot_arm = MeshInstance3D.new()
	var am := CylinderMesh.new()
	am.top_radius = 0.035
	am.bottom_radius = 0.03
	am.height = 0.7
	am.radial_segments = 6
	_spot_arm.mesh = am
	var arm_mat := StandardMaterial3D.new()
	arm_mat.albedo_color = Color(0.75, 0.58, 0.45)
	arm_mat.roughness = 0.9
	_spot_arm.material_override = arm_mat
	_spot_arm.position = Vector3(0.22, 1.05, 0.0) * scl
	# Rests at his side, angled slightly forward.
	_spot_arm.rotation_degrees = Vector3(-18.0, 0.0, -14.0)
	_spotter.add_child(_spot_arm)


## One stroke event from the rowing clip (forwarded by Sailboat):
## every rower leans into the pull; the oars sweep through the water.
func on_stroke(_side: int, _effort: float) -> void:
	stroke_count += 1
	for r in _rowers:
		r.pull = 1.0
		var oar: Node3D = r.get("oar")
		if oar == null:
			continue
		# A new stroke restarts the sweep (no fighting tweens).
		var old: Tween = r.get("tw")
		if old != null and old.is_valid():
			old.kill()
		var tw := create_tween()
		r.tw = tw
		tw.tween_property(oar, "rotation_degrees:x",
				-OAR_PITCH_DEG, PULL_TIME).set_ease(Tween.EASE_OUT)
		tw.tween_property(oar, "rotation_degrees:x",
				OAR_PITCH_DEG, PULL_TIME).set_ease(Tween.EASE_IN)
		tw.tween_property(oar, "rotation_degrees:x",
				0.0, SETTLE_TIME).set_ease(Tween.EASE_IN_OUT)


## The helmsman counters the rudder (Sailboat's turn, -1..1).
func set_turn(turn: float) -> void:
	_helm_lean = turn


## Commander mode: the player sits at the tiller, so the NPC helmsman
## steps aside (hidden, not freed — he's back when the hero hops off).
func set_helm_visible(on: bool) -> void:
	if _helm != null:
		_helm.visible = on


## Chest opened from the hull: the rowers bounce (a cheer, wordlessly).
func cheer() -> void:
	_cheer_left = 1.4
	cheer_count += 1


func _process(delta: float) -> void:
	var rowing := 0.0
	var boat := get_parent()
	if boat != null and is_instance_valid(boat):
		var host: Node = boat.get("_rider")
		if host != null and is_instance_valid(host) \
				and bool(host.get("sailing")):
			var spd: float = boat.get("_speed")
			rowing = clampf(spd / CRUISE_SPEED, 0.0, 1.0)
	_row_amp = lerpf(_row_amp, rowing, 5.0 * delta)

	var want_look := _cheer_left <= 0.0 and _row_amp < 0.25
	for r in _rowers:
		var root: Node3D = r.get("root")
		r.pull = maxf(0.0, (r.get("pull") as float) - delta * 2.2)
		var sway := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 1000.0 * 2.2
				+ (r.get("bounce_seed") as float))
		var lean: float = (r.get("pull") as float) * deg_to_rad(PULL_LEAN_DEG) \
				+ _row_amp * deg_to_rad(12.0) * sway
		# Positive lean = forward (toward the bow): the root faces the
		# bow via its PI yaw, so forward is NEGATIVE rotation.x.
		root.rotation.x = lerpf(root.rotation.x, -lean, 8.0 * delta)
		if _cheer_left > 0.0:
			_bounce(root, r.get("base_y") as float,
					r.get("bounce_seed") as float)
		elif want_look:
			_glance(root, delta)
		else:
			_settle(root, r.get("base_y") as float, delta)
	if _helm != null:
		if _helm.visible:
			_helm.rotation.z = lerpf(_helm.rotation.z,
					-_helm_lean * deg_to_rad(10.0), 6.0 * delta)
	if _cheer_left > 0.0:
		_cheer_left -= delta
	if _spotter != null:
		_tick_spotter(delta)


## --- The spotter ----------------------------------------------------------

## Per-frame spotter tick: the scan (every frame, it's a cheap group
## walk), the pointing arm ease, and the callout clock.
func _tick_spotter(delta: float) -> void:
	# The arm: eases up toward the shoulder when pointing, back when
	# the callout is done.
	var want := 1.0 if _spot_left > 0.0 else 0.0
	_spot_point = lerpf(_spot_point, want, 6.0 * delta)
	if _spot_arm != null:
		var rest := Vector3(-18.0, 0.0, -14.0)
		var up := Vector3(-78.0, 0.0, -8.0)
		_spot_arm.rotation_degrees = rest.lerp(up, _spot_point)
	if _spot_left > 0.0:
		_spot_left -= delta
		if _spot_left <= 0.0 and _spot_msg != null:
			_spot_msg.visible = false
			_spot_target = null
		return
	if _spot_cd > 0.0:
		_spot_cd -= delta
		return
	# The lookout only watches while someone is at the helm — no
	# shouting to nobody from the moored boat.
	if not _helm_manned():
		return
	# The scan: nearest un-shouted, un-opened sunken chest in range.
	var best: Node3D = null
	var best_d := SPOT_RANGE
	var from: Vector3 = _spotter.global_position if _spotter != null \
			else global_position
	for c in get_tree().get_nodes_in_group("sunken_chest"):
		var n3 := c as Node3D
		if n3 == null or _spotted.has(c.get_instance_id()):
			continue
		if bool(c.call("is_open")):
			continue
		var d := from.distance_to(n3.global_position)
		if d < best_d:
			best_d = d
			best = n3
	if best == null:
		return
	_spot_target = best
	_spotted[best.get_instance_id()] = true
	_spot_cd = SPOT_COOLDOWN
	_spot_left = CALLOUT_TIME
	spot_count += 1
	_callout(best, best_d)


## True when the player is aboard and sailing (the spotter only
## watches then) — commander at the helm counts.
func _helm_manned() -> bool:
	var boat := get_parent()
	if boat == null or not is_instance_valid(boat):
		return false
	var host: Node = boat.get("_rider")
	return host != null and is_instance_valid(host) \
			and bool(host.get("sailing"))


## The shout: floating gold text over the chest + the raised arm.
func _callout(chest: Node3D, dist: float) -> void:
	var from: Vector3 = _spotter.global_position if _spotter != null \
			else global_position
	var to := chest.global_position - from
	to.y = 0.0
	if to.length() > 0.05:
		# Face the sighting (the model's base yaw is PI, facing the
		# bow — the same convention as the rowers' glance).
		var base := PI
		var want := atan2(-to.x, -to.z)
		_spotter.rotation.y = base + clampf(wrapf(want - base, -1.6, 1.6),
				-1.6, 1.6)
	# The callout text: same recipe as the forage prompt (billboard,
	# no depth test) but gold, sized by sighting distance so far glints
	# read from across the deck.
	if _spot_msg == null:
		_spot_msg = Label3D.new()
		_spot_msg.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_spot_msg.no_depth_test = true
		_spot_msg.pixel_size = 0.004
		_spot_msg.font_size = 34
		_spot_msg.outline_size = 8
		_spot_msg.modulate = Color(1.0, 0.85, 0.4)
		_spot_msg.visible = false
		get_tree().current_scene.add_child(_spot_msg)
	_spot_msg.text = "%s\n(%d m)" % [
			SPOT_LINES[spot_count % SPOT_LINES.size()],
			int(dist + 0.5)]
	_spot_msg.global_position = chest.global_position \
			+ Vector3.UP * (1.6 + 0.02 * dist)
	_spot_msg.visible = true


## A quick glance toward the player when things are calm. The model's
## base yaw is PI (facing the bow); the glance eases a small clamped
## yaw offset toward him — looking around, never spinning.
func _glance(root: Node3D, delta: float) -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		return
	var to := (player as Node3D).global_position - root.global_position
	to.y = 0.0
	if to.length() < 0.05:
		return
	var want := atan2(-to.x, -to.z)
	var base := PI
	var target := base + clampf(wrapf(want - base, -0.7, 0.7), -0.7, 0.7)
	root.rotation.y = lerpf(root.rotation.y, target, 2.0 * delta)


func _bounce(root: Node3D, base_y: float, seed_v: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	root.position.y = base_y + 0.14 * absf(sin((t + seed_v) * 11.0))


## Ease back to the seated rest height after a cheer.
func _settle(root: Node3D, base_y: float, delta: float) -> void:
	root.position.y = lerpf(root.position.y, base_y, 10.0 * delta)


## --- construction ---------------------------------------------------------


func _make_viking(path: String, scl: float) -> Node3D:
	var root := Node3D.new()
	var ps: PackedScene = load(path)
	if ps == null:
		return root
	var glb: Node3D = ps.instantiate()
	glb.scale = Vector3.ONE * scl * 0.55
	root.add_child(glb)
	return root


## An oar: the pivot node sits at the gunwale; the shaft (a Y cylinder)
## is rotated flat along +X with the blade at the far outboard end.
## The rowing tween pitches the PIVOT around X, dipping the blade.
func _make_oar(_scl: float) -> Node3D:
	var pivot := Node3D.new()
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.4, 0.27, 0.14)
	wm.roughness = 0.85
	var shaft := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.025
	cm.bottom_radius = 0.02
	cm.height = 2.6
	cm.radial_segments = 6
	shaft.mesh = cm
	shaft.rotation_degrees = Vector3(0.0, 0.0, -90.0)
	shaft.position = Vector3(1.3, 0.0, 0.0)
	shaft.material_override = wm
	pivot.add_child(shaft)
	var blade := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.34, 0.015, 0.09)
	blade.mesh = bm
	blade.position = Vector3(2.45, 0.0, 0.0)
	blade.material_override = wm
	pivot.add_child(blade)
	return pivot
