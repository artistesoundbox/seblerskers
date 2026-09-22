extends CharacterBody3D
class_name VikingWanderer
## A wandering viking NPC: strolls between nearby spots on the real
## terrain, grounded by physics (move_and_slide), pausing to idle
## between strolls. Spawned by PropScatter for the warrior props.
##
## Animation, three tiers (checked in order):
## 1. CLIPS — the GLB has an AnimationPlayer with a walk-looking clip:
##    it is played on loop with playback speed matched to ground speed.
## 2. SKELETON — no clips but a real Skeleton3D (viking_lowpoly): a
##    procedural walk gait drives the thigh/calf/arm bones directly
##    (swing phase locked to actual ground speed, so feet plant, and
##    the pelvis bobs).
## 3. RIGID — neither (viking_warrior, warrior_of_the_north are rigid
##    multi-part models): each leg-looking mesh part is reparented under
##    a hip-height pivot and marched, with a body bob on the wrapper.
##
## The current GLB files contain ZERO animation data (verified by
## parsing their glTF JSON) — tiers 2 and 3 are what makes them walk
## today; re-export with clips and tier 1 takes over automatically.

@export var walk_speed := 1.6
## Yaw easing rate while steering toward the target (rad/s).
@export var turn_speed := 3.0
## How far from home it roams when picking stroll targets.
@export var wander_radius := 22.0
@export var idle_time_min := 1.5
@export var idle_time_max := 5.0
## Never targets spots inside this radius of the world origin (arena).
@export var keep_out_radius := 26.0
## Never targets ground below this height (keeps them off the sea).
@export var min_ground_height := -40.0
## Below this the wanderer counts as "in the sea" and is returned home.
@export var water_level := -1.3
## Dead wanderers are BURIED this deep under their death spot instead
## of having their collider disabled: toggling any collider in a world
## this big storms the physics broadphase for ~1 s (37 ms frames,
## measured; reproducible in the bare engine). Even a far parking
## teleport re-pairs the body against everything and hitches ~1 s at
## every respawn wave (measured). A short move in place changes
## nothing outside the local broadphase cells — storm-free.
const BURY_DEPTH := 4.5
## Distance gate: wanderers farther than this from the player skip
## their whole walk simulation (steering AND move_and_slide). Twenty
## characters trawling the huge trimesh terrain every physics tick was
## the island's lag: each physics frame cost ~40 ms once they started
## strolling. A 160 m ring keeps every villager you can SEE fully
## alive; parked ones resume their stroll exactly where they left off
## when you come back.
@export var sim_radius := 160.0
## Moving bodies used to cost ~7 ms/frame EACH against the big trimesh
## island on the stock physics server — five strolling villagers alone
## were ~34 ms. After the collider consolidation (terrain on ONE body,
## props in regional bins) a 16 s village walk beside 4 awake walkers
## measured 13.8 ms worst, so the budget has real headroom again: the
## cap is raised for a livelier village. Parked wanderers stay cheap
## static-ish bodies; only the nearest few ever move at once.
@export var wake_cap := 6
## Hysteresis band (m) between the wake and sleep rings: a wanderer
## walking toward you at the boundary cannot flicker on/off — it must
## cross wake_band metres INWARD to claim a moving slot, and anyone
## who already has one keeps it until they leave sim_radius.
@export var wake_band := 24.0
## --- Procedural gait (tiers 2/3) ---------------------------------------
## Thigh swing amplitude at full stride, degrees.
@export var gait_swing_deg := 26.0
## Knee bend amplitude, degrees.
@export var gait_calf_deg := 32.0
## Arm counter-swing amplitude, degrees.
@export var gait_arm_deg := 18.0
## Body bob height as a fraction of model height.
@export var gait_bob_frac := 0.035
## Stride length for the rigid march phase (m of travel per full swing
## cycle — sets the march tempo from ground speed).
@export var gait_stride_len := 1.1
## Height fraction (of the model) where the hip pivots sit.
@export var hip_height_frac := 0.55
## --- Life & death -------------------------------------------------------
## Seconds a killed viking stays gone before respawning.
@export var respawn_delay := 20.0
## Random extra delay (s) so a whole squad doesn't pop back in sync.
@export var respawn_jitter := 8.0

## --- Night raids ----------------------------------------------------------
## While raiding, target selection is hijacked by the RaidManager: the
## wanderer marches to its assigned `raid_point` (beside a village
## house) and stands there ransacking — the manager measures proximity
## and deals the damage. No strolls, no flower picking. Killed raiders
## stay dead for the night (`raid_no_respawn`); at dawn `end_raid()`
## sends everyone home and they become villagers again.
var raiding := false
var raid_point := Vector3.INF
var raid_no_respawn := false
var _raid_speed_restore := 0.0

## Diagnostics/tests.
var strolls_taken := 0
var anim_playing := false
## Which animation tier is active: "clips", "skeleton" or "rigid".
var gait_mode := "rigid"
## True from a killing fireball blast until the respawn.
var dead := false
var _dead_left := 0.0

var _home := Vector3.ZERO
var _target := Vector3.ZERO
var _has_target := false
var _idle_left := 2.0
var _stuck_left := 0.0
var _last_pos := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _anim: AnimationPlayer
var _walk_name := ""
## --- Procedural gait state ---
var _gait_phase := 0.0
## Eased 0..1 stride amplitude (fades out when standing).
var _gait_amp := 0.0
## Skeleton tier: bone indices + rest data + probed swing axes.
var _bones := {}
## Rigid tier: {pivot: Node3D, axis: Vector3, phase: float} per leg part.
var _legs: Array[Dictionary] = []
## Rigid tier: the wrapper node that carries the body bob.
var _bob_node: Node3D
var _bob_base_y := 0.0


## Rigid tier: bob wrapper offset amplitude in local units.
var _bob_amp_local := 0.0
## Rigid tier: model height in self-local units (for hand-height pin).
var _model_h_local := 1.0

## --- Wake-budget accounting (shared by every wanderer) ---------------
## How many wanderers island-wide currently hold a moving slot.
static var _wake_used := 0
## True while THIS wanderer holds one of the moving slots.
var _wake_slot := false
## Set at spawn and respawn: the parked branch must keep sliding (not
## skip) until the body has really touched down once — is_on_floor()
## alone can read stale-true right after a teleport.
var _needs_ground := true


## Give back this wanderer's moving slot (parked, killed or freed).
func _release_wake() -> void:
	if _wake_slot:
		_wake_slot = false
		_wake_used -= 1


func _exit_tree() -> void:
	_release_wake()


## Try to claim one of the global moving slots. Holders keep theirs
## while inside the ring (hysteresis); new claims must sit well
## inside it, so border-walkers can't flicker on and off.
func _claim_wake(near: float) -> bool:
	if _wake_slot:
		return true
	var band := minf(wake_band, sim_radius * 0.5)
	if _wake_used < maxi(wake_cap, 1) and near <= sim_radius - band:
		_wake_slot = true
		_wake_used += 1
		return true
	return false


func _ready() -> void:
	_rng.randomize()
	add_to_group("viking")
	_home = global_position
	_last_pos = global_position
	floor_snap_length = 0.6
	_setup_animation()


func _setup_animation() -> void:
	for node in find_children("*", "AnimationPlayer", true, false):
		_anim = node
		break
	if _anim != null and not _anim.get_animation_list().is_empty():
		gait_mode = "clips"
		# Prefer a walk-looking clip; otherwise the first available.
		for clip in _anim.get_animation_list():
			if "walk" in String(clip).to_lower():
				_walk_name = clip
				break
		if _walk_name.is_empty():
			_walk_name = _anim.get_animation_list()[0]
		var res := _anim.get_animation(_walk_name)
		if res != null:
			res.loop_mode = Animation.LOOP_LINEAR
		_anim.play(_walk_name)
		anim_playing = true
		return
	_anim = null
	if not _setup_skeleton_gait():
		_setup_rigid_gait()


func _physics_process(delta: float) -> void:
	# Dead: just run the respawn clock. Hidden and intangible; nothing
	# else (steering, gravity, gaits) runs.
	if dead:
		_dead_left -= delta
		if _dead_left <= 0.0 and not raid_no_respawn:
			_respawn()
		return
	# Distance gate: out of the player's ring, park. The respawn clock
	# above keeps running even while parked. RAIDERS never park: a war
	# band frozen mid-island (because the player watches from afar)
	# would never reach the village — the march always goes on, and
	# the raid-sized physics budget holds it easily.
	var near := INF
	for p in get_tree().get_nodes_in_group("player"):
		var pc := p as Node3D
		if pc != null:
			near = minf(near, global_position.distance_to(
					pc.global_position))
	var sim := raiding or near <= sim_radius
	if not sim:
		_release_wake()
		velocity.x = 0.0
		velocity.z = 0.0
		return
	# Wake budget: even inside the ring, only the nearest few get to
	# MOVE — each moving body costs ~7 ms/frame on the stock physics
	# server, so the strolling crowd is capped and the rest stand
	# (their slide query is skipped below while they have nowhere to
	# be). Raiders always claim movement: the raid IS the gameplay,
	# and the squad is small enough that the charfield-era physics
	# budget holds. Airborne parked bodies still settle — a
	# frozen-in-mid-air villager is worse than a brief extra query.
	if not (raiding or _claim_wake(near)):
		velocity.x = 0.0
		velocity.z = 0.0
		if is_on_floor() and not _needs_ground:
			velocity.y = 0.0
			return
		var g: float = ProjectSettings.get_setting(
				"physics/3d/default_gravity", 9.8)
		velocity.y -= g * delta
		move_and_slide()
		if is_on_floor():
			_needs_ground = false
		return
	# Sea safety net: never wander (or get pushed) into the water.
	# Raiders wade ashore AT their target instead of going home — a
	# war band beelining across a bay swims the last stretch.
	if global_position.y < water_level - 0.5:
		global_position = (raid_point if raiding \
				and raid_point != Vector3.INF else _home) \
				+ Vector3(0, 1.0, 0)
		velocity = Vector3.ZERO
		_has_target = raiding
		_idle_left = 1.0
		return

	if not is_on_floor():
		var g: float = ProjectSettings.get_setting(
				"physics/3d/default_gravity", 9.8)
		velocity.y -= g * delta
	else:
		velocity.y = 0.0

	# A picked flower only rides so long: eventually it is let go.
	_tick_carry(delta)

	if not _has_target:
		velocity.x = move_toward(velocity.x, 0.0, walk_speed * delta * 4.0)
		velocity.z = move_toward(velocity.z, 0.0, walk_speed * delta * 4.0)
		if raiding:
			# Raid behaviour: re-grab the march target (a stuck watch
			# may have dropped it); standing within reach = ransacking,
			# which the manager ticks by proximity. No strolls, no
			# flowers, no idle clock while the raid is on.
			if raid_point != Vector3.INF \
					and global_position.distance_to(raid_point) > 1.6:
				_target = raid_point
				_has_target = true
			_tick_gait(delta)
			return
		if picking:
			# Standing at the patch: the pluck clock runs, the gait
			# fades to idle, and the (expensive) slide is skipped.
			_pick_left -= delta
			if _pick_left <= 0.0:
				_pluck_bloom()
			_tick_gait(delta)
			return
		_idle_left -= delta
		if _idle_left <= 0.0:
			if not _maybe_pick():
				_pick_target()
	else:
		_steer_and_walk(delta)
		_watch_for_stuck(delta)

	# Cost cull: a body with nowhere to be skips its slide query —
	# the closest a CharacterBody3D gets to sleeping without breaking
	# is_on_floor(). The gait still ticks so a just-arrived walker
	# fades to its idle pose instead of freezing mid-step.
	if not _has_target and velocity.length_squared() < 0.01:
		_tick_gait(delta)
		return
	move_and_slide()
	_update_animation_speed()
	_tick_gait(delta)


## --- Life & death -------------------------------------------------------


## A fireball blast caught this viking: vanish and queue a respawn.
## Hidden and intangible (collision off) while dead — the world keeps
## the spot warm; _physics_process runs only the respawn clock.
## Raiders (raid_no_respawn) stay buried until the raid ends — every
## kill during a night raid permanently thins the assault.
func die() -> void:
	if dead:
		return
	dead = true
	_release_wake()
	_dead_left = respawn_delay + randf_range(0.0, respawn_jitter)
	visible = false
	velocity = Vector3.ZERO
	_has_target = false
	_drop_carry()
	picking = false
	_pick_patch = null
	# Bury the whole body under the death spot instead of touching its
	# colliders (see BURY_DEPTH): no shape ever changes and the move
	# stays inside the same broadphase cells, so nothing rebuilds.
	# Buried is unreachable — dead bodies skip all physics below —
	# invisible, and out of fireball reach.
	set_deferred("global_position",
			global_position - Vector3(0, BURY_DEPTH, 0))


## Back from the dead: reappear at the original scatter spot (it was
## placement-validated and nothing static can have taken it — props
## keep their spacing from wanderer spawn points, and wanderers don't
## collide with each other). Dropped in slightly above ground for a
## clean re-grounding.
func _respawn() -> void:
	dead = false
	visible = true
	_needs_ground = true
	# Un-bury: rise from the grave to home — a short kinematic move,
	# not a mutation. Colliders were never touched while dead.
	global_position = _home + Vector3(0, 0.5, 0)
	velocity = Vector3.ZERO
	_last_pos = global_position
	_drop_carry()
	picking = false
	_pick_patch = null
	_idle_left = randf_range(0.5, 1.5)


## --- Procedural gaits (no clips in the GLB) ----------------------------


## --- Flower picking ------------------------------------------------------
## Some vikings stroll to a nearby flower patch, pluck one bloom with
## a petal-burst FX and a pluck chirp, then carry the bloom in one
## hand around the village until they get bored of it. Hooks the
## EXISTING state machine (idle target selection) — no parallel loop.
const PICK_SCRIPT := preload("res://Player/FlowerPickFX.gd")
## Chance per idle pause that a wanderer starts a flower trip.
const PICK_PROB := 0.035
## Seconds a viking carries the picked bloom before dropping it.
const CARRY_TIME := 30.0
## Radius a wanderer will stroll to pick from.
const FLOWER_TRIP_RADIUS := 45.0

## True while strolling to (or standing at) a flower patch.
var picking := false
var _pick_patch: Node3D
var _pick_left := 0.0
var _carry: Node3D
var _carry_left := 0.0


## Consider starting a flower trip each time an idle pause ends.
func _maybe_pick() -> bool:
	if _rng.randf() > PICK_PROB or _carry != null:
		return false
	var patch := _find_flower_patch()
	if patch == null:
		return false
	picking = true
	_pick_patch = patch
	_pick_approach()
	return true


## Nearest visible-bloom patch within trip radius of the wanderer.
func _find_flower_patch() -> Node3D:
	var best: Node3D = null
	var best_d := FLOWER_TRIP_RADIUS
	for p in get_tree().get_nodes_in_group("flower_patch"):
		var n := p as Node3D
		if n == null or int(n.call("bloom_count")) == 0:
			continue
		var d: float = Vector2(n.global_position.x - global_position.x,
				n.global_position.z - global_position.z).length()
		if d < best_d:
			best_d = d
			best = n
	return best


## Flower-trip approach: a walkable spot beside the patch with a
## visible bloom.
func _pick_approach() -> void:
	_stuck_left = 0.0
	if _pick_patch == null:
		picking = false
		_idle_left = 2.0
		return
	var pp: Vector3 = _pick_patch.global_position
	for i in 24:
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(0.7, 1.6)
		var p := pp + Vector3(cos(a) * r, 0.0, sin(a) * r)
		var hit := _probe_ground(p)
		if hit.is_empty():
			continue
		var y: float = hit.position.y
		if absf(y - pp.y) > 1.4:
			continue
		var normal: Vector3 = hit.get("normal", Vector3.UP)
		if rad_to_deg(normal.angle_to(Vector3.UP)) > 30.0:
			continue
		_target = hit.position
		_has_target = true
		return
	# Patch unreachable: give up this trip.
	picking = false
	_pick_patch = null
	_idle_left = 2.0


## One pluck: petal burst + chirp at the bloom, flower hidden, a
## carried copy appears in the hand and the trip ends.
func _pluck_bloom() -> void:
	if _pick_patch == null:
		picking = false
		return
	var pp: Vector3 = _pick_patch.global_position
	var at := Vector3(pp.x, pp.y + 0.25, pp.z)
	var kind := _rng.randi_range(0, 1)
	if not bool(_pick_patch.call("take_bloom")):
		return
	PICK_SCRIPT.play(get_tree().current_scene, self, at, kind)
	_grow_carry(at, kind)
	picking = false
	_pick_patch = null
	_idle_left = _rng.randf_range(idle_time_min, idle_time_max)


## A small copy of the picked bloom rides the viking's hand side:
## A small copy of the picked bloom rides the viking's hand side:
## hung from an arm BONE via a BoneAttachment3D (skeleton tier) or
## pinned to the body's side at hand height (rigid tier, which has no
## arm pivots — only legs are reparented for the march).
func _grow_carry(at: Vector3, kind: int) -> void:
	_drop_carry()
	var bloom := Node3D.new()
	var stem := MeshInstance3D.new()
	var sm := CylinderMesh.new()
	sm.top_radius = 0.008
	sm.bottom_radius = 0.011
	sm.height = 0.22
	stem.mesh = sm
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.3, 0.5, 0.22)
	stem.material_override = smat
	stem.position.y = 0.11
	bloom.add_child(stem)
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.055
	hm.height = 0.1
	hm.radial_segments = 7
	hm.rings = 4
	head.mesh = hm
	var hmat := StandardMaterial3D.new()
	hmat.albedo_color = Color(0.9, 0.32, 0.42) if kind == 0 \
			else Color(0.55, 0.4, 0.85)
	hmat.emission_enabled = true
	hmat.emission = hmat.albedo_color * 0.3
	hmat.emission_energy_multiplier = 0.4
	head.material_override = hmat
	head.position.y = 0.24
	bloom.add_child(head)
	var host: Node3D = _carry_host()
	if host == null:
		bloom.queue_free()
		return
	host.add_child(bloom)
	if host is BoneAttachment3D:
		# Hanging below the hand bone, like loosely held.
		bloom.position = Vector3(0.0, -0.3, 0.0)
	else:
		# Bob wrapper (rigid tier): hand height at the body's side.
		bloom.position = Vector3(0.17, _model_h_local * 0.42, 0.05)
	bloom.rotation.y = _rng.randf() * TAU
	_carry = bloom
	_carry_left = CARRY_TIME


## The node the carried bloom hangs from: a BoneAttachment3D on an
## arm/hand bone (skeleton tier), else the bob wrapper (rigid tier).
func _carry_host() -> Node3D:
	var sk: Skeleton3D = null
	for n in find_children("*", "Skeleton3D", true, false):
		sk = n
		break
	if sk != null:
		for i in sk.get_bone_count():
			var bn := sk.get_bone_name(i).to_lower()
			if bn.contains("arm") or bn.contains("hand"):
				var att := BoneAttachment3D.new()
				att.bone_idx = i
				att.name = "CarryAttach"
				sk.add_child(att)
				return att
	return _bob_node


## The carried bloom has a lifespan: when the clock runs out the
## viking simply lets it go (it fades — patches regrow, no litter).
func _tick_carry(delta: float) -> void:
	if _carry == null:
		return
	_carry_left -= delta
	if _carry_left <= 0.0:
		_drop_carry()


func _drop_carry() -> void:
	if _carry != null:
		_carry.queue_free()
		_carry = null


## Tier 2: a real skeleton without clips — build the gait on bones.
## Returns false when no usable skeleton exists.
func _setup_skeleton_gait() -> bool:
	var sk: Skeleton3D = null
	for node in find_children("*", "Skeleton3D", true, false):
		sk = node
		break
	if sk == null or sk.get_bone_count() < 8:
		return false
	gait_mode = "skeleton"
	# Skeleton-space axes: the GLB wrappers rotate/scale the skeleton
	# node (Sketchfab Z-up art), so "up" and "forward" must be expressed
	# in SKELETON space before any bone math.
	var inv: Basis = sk.global_transform.basis.inverse()
	var up_s: Vector3 = (inv * global_transform.basis.y).normalized()
	var fwd_s: Vector3 = (inv * (-global_transform.basis.z)).normalized()
	# Model height in skeleton-local units: the rest bounds are already
	# in skeleton space, and Z-up art puts the height along Z there.
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for i in sk.get_bone_count():
		var p: Vector3 = sk.get_bone_global_rest(i).origin
		lo = lo.min(p)
		hi = hi.max(p)
	var model_h: float = maxf(maxf(hi.y - lo.y, hi.z - lo.z), 0.5)
	var thigh_names := ["Thigh", "UpLeg", "Leg"]
	var calf_names := ["Calf", "Shin", "LowerLeg"]
	var arm_names := ["UpperArm", "Arm"]
	var hips_names := ["Pelvis", "Hips", "Root"]
	# The lowpoly's bone names are Sketchfab-mangled (" L Thigh_025"):
	# match on a normalized form (whitespace stripped, trailing _NN
	# numeric suffixes removed).
	var norm := func(bone_name: String) -> String:
		var s := bone_name.strip_edges()
		var us := s.rfind("_")
		if us > 0 and s.substr(us + 1).is_valid_int():
			s = s.substr(0, us)
		return s
	var find_bone := func(skel: Skeleton3D, want: String) -> int:
		for i in skel.get_bone_count():
			if norm.call(skel.get_bone_name(i)) == want:
				return i
		return -1
	_bones = {"sk": sk, "left": {}, "right": {}, "hips": -1}
	for side in ["left", "right"]:
		var pre: String = "L" if side == "left" else "R"
		for tn in thigh_names:
			var idx: int = find_bone.call(sk, "%s %s" % [pre, tn])
			if idx >= 0:
				_bones[side]["thigh"] = idx
				break
		for cn in calf_names:
			var idx2: int = find_bone.call(sk, "%s %s" % [pre, cn])
			if idx2 >= 0:
				_bones[side]["calf"] = idx2
				break
		for an in arm_names:
			var idx3: int = find_bone.call(sk, "%s %s" % [pre, an])
			if idx3 >= 0:
				_bones[side]["arm"] = idx3
				break
	for hn in hips_names:
		var hidx: int = find_bone.call(sk, hn)
		if hidx >= 0:
			_bones["hips"] = hidx
			break
	if not _bones["left"].has("thigh") and not _bones["right"].has("thigh"):
		return false
	for side in ["left", "right"]:
		var leg: Dictionary = _bones[side]
		if not leg.has("thigh"):
			continue
		leg["thigh_rest"] = sk.get_bone_pose_rotation(
				leg["thigh"]).normalized()
		var axis := _probe_swing_axis(sk, leg["thigh"], fwd_s, up_s)
		if axis == Vector3.ZERO:
			return false
		leg["axis"] = axis
		leg["swing_sign"] = _probe_swing_sign(sk, leg["thigh"], axis,
				leg["thigh_rest"], fwd_s)
		leg["hip_y"] = sk.get_bone_global_rest(leg["thigh"]).origin.y
		if leg.has("calf"):
			leg["calf_rest"] = sk.get_bone_pose_rotation(
					leg["calf"]).normalized()
		if leg.has("arm"):
			leg["arm_rest"] = sk.get_bone_pose_rotation(
					leg["arm"]).normalized()
	if _bones["hips"] >= 0:
		_bones["hips_pos"] = sk.get_bone_pose_position(_bones["hips"])
		# Bob direction: skeleton-space up converted into the hips bone's
		# PARENT space (position tracks are parent-relative).
		var parent_idx: int = sk.get_bone_parent(_bones["hips"])
		var pb: Basis = sk.get_bone_global_rest(maxf(parent_idx, 0)).basis \
				.get_rotation_quaternion()
		_bones["hips_up"] = (pb.inverse() * up_s).normalized()
	_bones["model_h"] = model_h
	return true


## The bone-local axis whose rotation swings the limb along the body's
## forward direction: the hinge axis perpendicular to both the limb and
## the forward vector, all in skeleton space, taken into bone-local.
func _probe_swing_axis(sk: Skeleton3D, idx: int, fwd_s: Vector3,
		up_s: Vector3) -> Vector3:
	# Limb direction: towards its first child joint (fall back: down).
	var dir := up_s * -1.0
	for c in sk.get_bone_children(idx):
		dir = (sk.get_bone_global_rest(c).origin
				- sk.get_bone_global_rest(idx).origin).normalized()
		break
	var axis_s := dir.cross(fwd_s)
	if axis_s.length_squared() < 0.01:
		return Vector3.ZERO
	var world_q := sk.get_bone_global_rest(idx).basis \
			.get_rotation_quaternion().normalized()
	return (world_q.inverse() * axis_s.normalized()).normalized()


## Probe: does a small positive swing rotate the limb's tip towards the
## body's front? Returns +1 / −1.
func _probe_swing_sign(sk: Skeleton3D, idx: int, axis: Vector3,
		rest_q: Quaternion, fwd_s: Vector3) -> float:
	var child := -1
	for c in sk.get_bone_children(idx):
		child = c
		break
	if child < 0:
		return 1.0
	var base: Vector3 = sk.get_bone_global_pose(child).origin
	sk.set_bone_pose_rotation(idx,
			rest_q * Quaternion(axis, deg_to_rad(20.0)))
	sk.force_update_all_bone_transforms()
	var moved: Vector3 = sk.get_bone_global_pose(child).origin - base
	sk.set_bone_pose_rotation(idx, rest_q)
	sk.force_update_all_bone_transforms()
	return 1.0 if moved.dot(fwd_s) > 0.0 else -1.0


## Tier 3: a rigid multi-part model with no skeleton — reparent each
## leg-looking mesh part under a hip-height pivot node and march them.
func _setup_rigid_gait() -> void:
	gait_mode = "rigid"
	var model := get_child(0) as Node3D
	if model == null:
		return
	# Bob wrapper between the body and the model.
	_bob_node = Node3D.new()
	_bob_node.name = "MarchBob"
	add_child(_bob_node)
	model.reparent(_bob_node)
	_bob_base_y = _bob_node.position.y
	# Model bounds in world space (the wanderer is already in the tree).
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	var meshes: Array[MeshInstance3D] = []
	for node in _bob_node.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.skin != null:
			# Skinned meshes ignore node transforms (the skeleton drives
			# the vertices), so a pivot would do nothing — skip them.
			continue
		meshes.append(mi)
		var b: AABB = mi.global_transform * mi.mesh.get_aabb()
		lo = lo.min(b.position)
		hi = hi.max(b.position + b.size)
	if meshes.is_empty():
		return
	var model_h := hi.y - lo.y
	var hip_y := lo.y + hip_height_frac * model_h
	var axis_world := global_transform.basis.x.normalized()
	var phase_of_x := func(w: Vector3) -> float:
		var lp: Vector3 = global_transform.affine_inverse() * w
		return 1.0 if lp.x >= 0.0 else -1.0
	for mi in meshes:
		var aabb: AABB = mi.mesh.get_aabb()
		var bottom_w: Vector3 = mi.global_transform * Vector3(
				aabb.get_center().x, aabb.position.y, aabb.get_center().z)
		# Leg parts reach below knee height; the rest stay put.
		if bottom_w.y > lo.y + 0.55 * model_h:
			continue
		var parent := mi.get_parent() as Node3D
		if parent == null:
			continue
		var pivot := Node3D.new()
		pivot.name = "LegPivot"
		parent.add_child(pivot)
		pivot.global_transform = Transform3D(Basis.IDENTITY,
				Vector3(bottom_w.x, hip_y, bottom_w.z))
		mi.reparent(pivot)
		var axis_local: Vector3 = (parent.global_transform.basis.inverse()
				* axis_world).normalized()
		_legs.append({"pivot": pivot, "axis": axis_local,
				"rest": pivot.basis,
				"sign": _probe_rigid_sign(pivot, axis_world),
				"phase": phase_of_x.call(pivot.global_position)})
	# Bob amplitude in this node's local units (self is uniformly scaled).
	_bob_amp_local = gait_bob_frac * model_h / maxf(scale.y, 0.0001)
	_model_h_local = model_h / maxf(scale.y, 0.0001)
	_model_h_local = model_h / maxf(scale.y, 0.0001)


## Probe which swing sign marches the leg forward (towards −Z of self):
## rotate the pivot slightly and see which way the leg tip (a point
## below the pivot) swings.
func _probe_rigid_sign(pivot: Node3D, axis_world: Vector3) -> float:
	var front := -global_transform.basis.z
	var tip_before: Vector3 = pivot.global_transform * Vector3(0, -1, 0)
	pivot.global_rotate(axis_world, 0.35)
	var tip_after: Vector3 = pivot.global_transform * Vector3(0, -1, 0)
	pivot.global_rotate(axis_world, -0.35)
	return 1.0 if (tip_after - tip_before).dot(front) > 0.0 else -1.0


func _steer_and_walk(delta: float) -> void:
	var to := _target - global_position
	to.y = 0.0
	if to.length() < 0.7:
		_arrive()
		return
	# Face the target (-Z forward convention), easing the yaw.
	var desired := atan2(-to.x, -to.z)
	var current := rotation.y
	var diff := wrapf(desired - current, -PI, PI)
	rotation.y = current + clampf(diff, -turn_speed * delta,
			turn_speed * delta)
	var forward := -global_transform.basis.z
	velocity.x = forward.x * walk_speed
	velocity.z = forward.z * walk_speed


func _watch_for_stuck(delta: float) -> void:
	var moved := global_position.distance_to(_last_pos) / maxf(delta, 0.0001)
	_last_pos = global_position
	if moved < walk_speed * 0.15:
		_stuck_left += delta
		if _stuck_left > 2.0:
			if raiding:
				# A raider never abandons the march for a stroll spot:
				# re-commit to the assigned house and push on. The
				# counter is CUMULATIVE — it is not reset by the
				# re-commit, so ~4 s of real grinding trips the
				# pinch escape (a reset here made it dead code and
				# pinned marchers grinded forever).
				if _stuck_left > 4.0 and raid_point != Vector3.INF:
					_stuck_left = 0.0
					global_position = raid_point \
							+ Vector3(0, 1.0, 0)
					velocity = Vector3.ZERO
					_last_pos = global_position
					return
				if raid_point != Vector3.INF:
					_target = raid_point
					_has_target = true
					return
				_stuck_left = 0.0
				_pick_target()
				return
			_stuck_left = 0.0
			_pick_target()  # abandon an unreachable target
	else:
		_stuck_left = 0.0


func _arrive() -> void:
	_has_target = false
	strolls_taken += 1
	if picking:
		# Reached the patch: pause a beat, then pluck.
		_pick_left = _rng.randf_range(0.7, 1.4)
		return
	_idle_left = _rng.randf_range(idle_time_min, idle_time_max)


func _pick_target() -> void:
	_stuck_left = 0.0
	for i in 24:
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(4.0, wander_radius)
		var p := _home + Vector3(cos(a) * r, 0.0, sin(a) * r)
		if Vector2(p.x, p.z).length() < keep_out_radius + 1.0:
			continue
		var hit := _probe_ground(p)
		if hit.is_empty():
			continue
		var y: float = hit.position.y
		if y < min_ground_height or y < water_level + 0.3:
			continue
		var normal: Vector3 = hit.get("normal", Vector3.UP)
		if rad_to_deg(normal.angle_to(Vector3.UP)) > 30.0:
			continue
		_target = hit.position
		_has_target = true
		return
	# Nothing valid found: try again after a pause.
	_idle_left = 1.0


## Downward ray to solid ground, ignoring this wanderer's own body and
## other moving wanderers (only static world counts).
func _probe_ground(at: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = [get_rid()]
	var params := PhysicsRayQueryParameters3D.create(
			Vector3(at.x, at.y + 30.0, at.z),
			Vector3(at.x, at.y - 80.0, at.z), 1, exclude)
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return hit
	var col: Object = hit.get("collider")
	# Never target a neighbour's capsule or its static hitbox —
	# only real world geometry counts.
	if col is CharacterBody3D:
		return {}
	if col is StaticBody3D \
			and (col as StaticBody3D).get_parent() is CharacterBody3D:
		return {}
	return hit


## Per-frame gait driver: fades the stride amplitude with actual ground
## speed and marches the legs (and bob) in phase with real travel.
func _tick_gait(delta: float) -> void:
	if gait_mode == "clips":
		return
	var speed := Vector2(velocity.x, velocity.z).length()
	_gait_amp = move_toward(_gait_amp, 1.0 if speed > 0.15 else 0.0,
			delta * 4.0)
	if _gait_amp <= 0.001:
		return
	# March tempo from real travel: one full stride cycle per stride_len.
	_gait_phase = wrapf(_gait_phase + speed / maxf(gait_stride_len, 0.1)
			* delta, 0.0, 1.0)
	var amp := _gait_amp
	match gait_mode:
		"skeleton":
			_tick_gait_skeleton(amp)
		"rigid":
			_tick_gait_rigid(amp)


func _tick_gait_skeleton(amp: float) -> void:
	var sk: Skeleton3D = _bones["sk"]
	var model_h: float = _bones["model_h"]
	for side in ["left", "right"]:
		var leg: Dictionary = _bones[side]
		if not leg.has("thigh"):
			continue
		# Left leg leads by half a cycle; the arm counter-swings; the
		# knee bends as the leg swings through.
		var ph := _gait_phase if side == "left" else _gait_phase + 0.5
		var swing := sin(TAU * ph)
		var axis: Vector3 = leg["axis"]
		var sgn: float = leg["swing_sign"]
		sk.set_bone_pose_rotation(leg["thigh"],
				(leg["thigh_rest"] as Quaternion) * Quaternion(axis,
				sgn * deg_to_rad(gait_swing_deg * swing * amp)))
		if leg.has("calf"):
			var bend := maxf(0.0, sin(TAU * ph + 1.1))
			sk.set_bone_pose_rotation(leg["calf"],
					(leg["calf_rest"] as Quaternion) * Quaternion(axis,
					-sgn * deg_to_rad(gait_calf_deg * bend * amp)))
		if leg.has("arm"):
			sk.set_bone_pose_rotation(leg["arm"],
					(leg["arm_rest"] as Quaternion) * Quaternion(axis,
					-sgn * deg_to_rad(gait_arm_deg * swing * amp)))
	if _bones["hips"] >= 0:
		var dy: float = amp * gait_bob_frac * model_h \
				* (0.5 - 0.5 * cos(2.0 * TAU * _gait_phase))
		sk.set_bone_pose_position(_bones["hips"],
				(_bones["hips_pos"] as Vector3)
				+ (_bones["hips_up"] as Vector3) * dy)


func _tick_gait_rigid(amp: float) -> void:
	for leg in _legs:
		var ph := _gait_phase + (0.0 if leg["phase"] > 0.0 else 0.5)
		var swing := sin(TAU * ph)
		var pivot: Node3D = leg["pivot"]
		# Swing composes ON TOP of the pivot's rest basis (which carries
		# the GLB wrapper's Z-up compensation — replacing it would fold
		# the leg sideways).
		pivot.basis = Basis(leg["axis"] as Vector3,
				(leg["sign"] as float) * deg_to_rad(
				gait_swing_deg * swing * amp)) * (leg["rest"] as Basis)
	if _bob_node != null:
		var dy := amp * _bob_amp_local \
				* (0.5 - 0.5 * cos(2.0 * TAU * _gait_phase))
		_bob_node.position.y = _bob_base_y + dy


## Stride matching for the clips tier: assume clips are authored near
## 1.5 m/s and scale playback so the footfall rhythm matches the actual
## walk speed.
func _update_animation_speed() -> void:
	if _anim != null and anim_playing:
		_anim.speed_scale = clampf(walk_speed / 1.5, 0.7, 1.5)


## --- Night raids -----------------------------------------------------------


## The RaidManager drafts this villager: march to `point` beside a
## house at double pace and start ransacking.
func begin_raid(point: Vector3) -> void:
	if raiding:
		raid_point = point  # re-assignment mid-raid (house lost, etc.)
		_target = point
		_has_target = true
		return
	raiding = true
	raid_point = point
	_raid_speed_restore = walk_speed
	walk_speed = maxf(walk_speed, 3.2)  # an urgent march-jog
	_drop_carry()
	picking = false
	_pick_patch = null
	_stuck_left = 0.0
	_target = point
	_has_target = true


## Dawn: the raid is over. Survivors walk home and resume their
## strolls; buried raiders (raid_no_respawn) are released to respawn
## by the normal dead-clock.
func end_raid() -> void:
	if not raiding:
		raid_no_respawn = false  # release any buried raider anyway
		return
	raiding = false
	raid_point = Vector3.INF
	raid_no_respawn = false
	walk_speed = _raid_speed_restore
	_has_target = true
	_target = _home  # the long walk home at the old stroll pace
