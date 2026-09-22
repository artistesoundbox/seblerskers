class_name PlayerModel
extends Node3D
## Drives the character animations of the attached model.
##
## gods1.fbx holds the idle clip; the other FBX files are animation-only
## sources (same Mixamo skeleton). Their "mixamo_com" clips are merged into
## the model's AnimationPlayer as named clips at runtime.
##
## Mixamo clips move toward +Z, while Godot's forward is -Z, so the model
## node is yawed by model_yaw_offset_deg to face the right way.

signal attack_finished
## Emitted the moment a dive-bomb strike begins.
signal dive_started
## Emitted at the attack clip's strike moment (right arm swung forward) —
## the hook point where the fireball projectile spawns.
signal attack_cast
## Emitted at each oar dip of the rowing stroke (the walk clip replayed
## as rowing) — the flagship hooks its oar-splash bursts on here.
## `side` is -1 (port) / +1 (starboard) and alternates per dip;
## `effort` is the rowing throttle 0..1.
signal row_stroke(side: int, effort: float)

const ANIM_IDLE := "idle"
const ANIM_WALK := "walk"
const ANIM_RUN := "run"
const ANIM_JUMP := "jump"
const ANIM_CROUCH := "crouch"
const ANIM_CROUCH_IDLE := "crouch_idle"
## Fallback crouch-walk: the walk gait composed onto the crouch stance
## with per-frame foot grounding, used when the crouch FBX turns out to
## be a pose/idle clip with no stepping gait of its own.
const ANIM_CROUCH_WALK := "crouch_walk"
const ANIM_ATTACK := "attack"
const ANIM_FLY := "fly"
const ANIM_FLY_GLIDE := "fly_glide"
const ANIM_DIVE := "dive"
## The swim clip (imports/Swimming.fbx): plays while the hero is deep
## enough in the sea that walking is over — breaststroke over the waves.
const ANIM_SWIM := "swim"
## Node that wraps the visual model and carries the whole flight attitude:
## dive-strike pitch, speed-driven flight pitch and turn banking
## (created at startup if the scene does not carry one).
const PITCH_NODE := "VisualPitch"
## Clips whose Hips position track must be removed (they drift forward,
## e.g. ~2.1 m per walk loop, ~3.5 m per run loop).
const ANIMS_WITH_ROOT_MOTION: Array[StringName] = [ANIM_WALK, ANIM_RUN, ANIM_SWIM]
## Arm bones driven by the procedural wing-flap clips (fly / fly_glide).
const WING_ARM_L := &"mixamorig_LeftArm"
const WING_ARM_R := &"mixamorig_RightArm"
## Right-hand bone the fireball casts from.
const CAST_HAND := &"mixamorig_RightHand"
## Bones whose walk-cycle swing is composed onto the crouch stance when
## baking the fallback crouch-walk clip (matched as name suffixes).
const LEG_BONE_SUFFIXES: Array[String] = ["UpLeg", "Leg", "Foot", "ToeBase"]

@export var blend_time := 0.2
## Treading-water idle: a swimmer with (almost) no horizontal speed
## hands the prone stroke to the upright land idle — arms read as a
## scull — and a slow buoyancy bob rides the attitude node. Crossing
## the threshold back up brings the prone stroke (and its stride
## scaling) in again.
@export var tread_idle_speed := 0.45
@export var tread_bob_amplitude := 0.09  # rad of nose tilt
@export var tread_bob_period := 2.8  # seconds per bob cycle
## Hard clamp for animation speed scaling, to avoid absurd playback rates.
## High enough that the walk clip can stride-match full sprint speed and
## the in-place crouch clip can stride-match the crouch cap speed.
@export var max_anim_speed_scale := 8.0
@export var min_anim_speed_scale := 0.3
@export var attack_speed_scale := 1.5
## Fallbacks used if a clip has no measurable root motion.
@export var fallback_walk_speed := 2.0
@export var fallback_run_speed := 6.5
## Mixamo models face +Z; set so the model matches the body's -Z forward.
@export var model_yaw_offset_deg := 180.0
## Removes the Hips position track from drifting clips so the character
## stays anchored to the physics body.
@export var strip_root_motion := true
## --- Procedural wing flight (built at runtime; no fly FBX needed) ---
## Wing beats per second at cruise tempo.
@export var flap_frequency := 2.0
## Sweep of each wing beat around the spread pose, degrees.
@export var flap_amplitude_deg := 40.0
## Static raise of the arms from the bind pose (wing spread), degrees.
@export var wing_raise_deg := 20.0
## --- Dive-bomb attack (usable while flying) ---------------------------
## Body pitch at the full dive strike, degrees (nose down).
@export var dive_pitch_deg := 75.0
## How fast the body pitches into the dive (1/s).
@export var dive_pitch_in_speed := 8.0
## How fast the body eases back upright after the dive ends (1/s).
@export var dive_pitch_out_speed := 5.0
## Wing tuck angle of the dive pose relative to the glide spread, degrees
## (negative sweeps the wings back and down, like a raptor's strike).
@export var dive_wing_tuck_deg := -28.0
## --- Flight attitude (bird-like pitch & bank) -------------------------
## Nose-up body pitch at the climb reference speed, degrees.
@export var fly_pitch_climb_deg := 16.0
## Nose-down body pitch at the fall reference speed, degrees.
@export var fly_pitch_fall_deg := 22.0
## Vertical climb speed that maps to the full nose-up pitch (m/s).
@export var fly_climb_ref_speed := 8.0
## Vertical fall speed that maps to the full nose-down pitch (m/s).
@export var fly_fall_ref_speed := 18.0
## Wing-over bank into turns, degrees at the reference yaw rate.
@export var fly_bank_deg := 28.0
## Body yaw rate (rad/s) that maps to the full bank angle.
@export var fly_bank_ref_rate := 3.0
## Forward body lean while flying, degrees — a flying bird tips its
## whole body into the direction of travel instead of standing upright.
@export var fly_forward_lean_deg := 14.0
## Extra forward lean per m/s of dive-glide energy bank, so a fast
## swoop leans visibly harder than a lazy cruise.
@export var fly_lean_per_energy := 0.7
## Cap for the total forward lean (lean + energy bonus), degrees.
@export var fly_forward_lean_max := 35.0
## How fast the flight attitude eases (1/s).
@export var fly_attitude_smooth := 5.0
## --- Flight lean & flap pulse (bird-like takeoff) -----------------------
## Extra forward lean while actively wing-flapping (degrees): flapping
## is the effortful mode, so the body commits harder into travel than
## in an easy glide.
@export var flap_lean_deg := 8.0
## Temporary lean boost (degrees) right after takeoff — the first wing
## beats pitch the body into flight instead of leaving it upright and
## stiff while the attitude eases in.
@export var takeoff_lean_deg := 10.0
## Seconds the takeoff lean boost takes to fade out.
@export var takeoff_lean_time := 1.1
## Forward body nod at mid-downstroke (degrees, full amplitude) — a
## tiny dip into each wing beat so flapping reads as effort, not a
## metronome.
@export var flap_nod_deg := 2.5

## --- Additive torso lean (blended over the playing clip) ---------------
## Tilt the torso into acceleration, degrees at full normal speed.
@export var accel_lean_deg := 9.0
## Extra forward tilt while sprinting (run), degrees.
@export var run_lean_deg := 8.0
## Bank into turns, degrees at max lean rate.
@export var turn_lean_deg := 12.0
## Backward torso tilt on takeoff, degrees at strong upward acceleration.
@export var jump_lean_deg := 10.0
## How fast the lean pose follows its target (1/s).
@export var lean_smooth := 6.0
## Multiplier applied while crouching (keeps the crouch posture intact).
@export var crouch_lean_scale := 0.3
## --- Landing absorb -----------------------------------------------------
## Fall speed (m/s) at which a touchdown sinks the character into the
## crouch pose for a beat — knees soak up the impact instead of
## snapping straight back to idle. Sits between the landing puff
## (FootstepFX min_land_fall_speed) and the pavement crack threshold.
@export var land_absorb_min_fall := 6.0
## Seconds the absorb crouch is held before blending back out.
@export var land_absorb_time := 0.45
## Landing-severity grade (0..1) at which FootstepFX fires the superman
## pavement-crack burst. Kept beside the absorb tuning so the crouch
## depth and the crack stay on one severity ladder: grade 0 = a hop's
## soft landing (no crouch, faint dust), 0.55 = a big drop (full absorb
## crouch + crack), 1.0 = terminal-velocity touchdown.
@export var fire_absorb_grade := 0.55
## --- Crouch blend space ------------------------------------------------
## Walking speed above which the crouch clip plays fully and stride-matched
## instead of blending towards the standing crouch pose (m/s).
@export var crouch_walk_blend_speed := 1.2
## How fast the crouch blend weight eases between pose and clip (1/s).
@export var crouch_blend_speed := 7.0
## Below this weight a source is considered fully faded out (stops it
## restarting every frame once its contribution is inaudible).
@export var crouch_weight_epsilon := 0.01
## Fallback natural speed for the crouch clip if even its stance-foot
## retreat can't be measured.
@export var fallback_crouch_speed := 1.4

@onready var anim: AnimationPlayer = $gods1/AnimationPlayer
@onready var controller: MovementController = get_parent()
@onready var _walk_src: AnimationPlayer = $WalkSource/AnimationPlayer
@onready var _run_src: AnimationPlayer = $RunSource/AnimationPlayer
@onready var _jump_src: AnimationPlayer = $JumpSource/AnimationPlayer
@onready var _crouch_src: AnimationPlayer = $CrouchSource/AnimationPlayer
@onready var _attack_src: AnimationPlayer = $AttackSource/AnimationPlayer
@onready var _swim_src: AnimationPlayer = $SwimSource/AnimationPlayer

var _attacking := false
var _jumping := false
var _flying := false
## True while a dive-bomb strike is in progress.
var _diving := false
## True while the dive pitch target is the full strike angle.
var _dive_active := false
## Eased visual pitch (radians, + = nose-down) carried by the attitude
## node: the dive strike and the flight attitude both drive it.
var _vis_pitch := 0.0
## Eased visual bank (radians) carried by the attitude node while flying.
var _vis_bank := 0.0
## True while the flapping fly clip (not glide) is the active pose.
var _flapping := false
## Countdown of the post-takeoff lean boost (seconds left).
var _takeoff_left := 0.0
## Probed rotation signs: +1 means a positive attitude-node rotation.x
## pitches the nose down, and +1 on the bank sign means a positive
## rotation.z dips the LEFT wing.
var _att_pitch_sign := 1.0
var _att_bank_sign := 1.0
## Downstroke body nod (radians, + nose-down) — applied directly on
## the attitude node, OUTSIDE the eased pitch channel: the easing is
## tuned for slow attitude changes and would low-pass a 2 Hz wing
## beat into mush.
var _nod_now := 0.0
var _attitude_node: Node3D
## Vertical speed and yaw rate fed in by the controller each physics
## frame while flying; zeroed otherwise so the attitude eases level.
var _fly_vy := 0.0
var _fly_yaw_rate := 0.0
## Ground speed (m/s) each locomotion clip covers in one second of playback
## at speed_scale 1.0, measured from its own Hips root motion.
var _natural_speeds := {}
## --- Crouch blend space state ---
## 0 = standing crouch pose, 1 = stride-matched crouch-walk clip.
var _crouch_weight := 1.0
## True while the character is crouched and actually moving.
var _crouch_moving := false
## Ground speed snapshot for the crouch blend's stride matching.
var _crouch_speed := 0.0
## True once the crouch blend space owns the animation.
var _in_crouch_blend := false
## Countdown of the landing-absorb crouch (seconds left).
var _land_absorb_left := 0.0
## Landing severity of the most recent touchdown, 0..1 (1 = full-depth
## absorb crouch, strongest dust). FootstepFX reads it so dust and the
## crack scale with the SAME grade as the crouch — a grade that blends
## fall speed with fall HEIGHT, so soft-speed flight landings from up
## high still read as hard.
var landing_grade := 0.0
## True while the standing crouch pose source is layered in.
var _crouch_pose_on := false
## Which clip plays the moving side of the crouch blend space: the crouch
## clip itself when it has a measurable gait, else the walk derivative.
var _crouch_walk_clip: StringName = ANIM_CROUCH
## --- Additive torso lean state ---
## Lean targets from the last motion state (degrees).
var _target_pitch := 0.0
var _target_roll := 0.0
## Current smoothed lean angles (radians).
var _lean_pitch := 0.0
var _lean_roll := 0.0
var _lean_modifier: LeanModifier
## The commander seat clip's name in the model's animation library.
const SIT_CLIP := StringName("sit_helm")
## Attack clip timeline time of the strike moment (fireball release).
var _attack_cast_time := 0.0
## True once attack_cast has been emitted for the current attack.
var _attack_cast_fired := false


func _ready() -> void:
	rotation.y = deg_to_rad(model_yaw_offset_deg)

	var lib := anim.get_animation_library("")
	lib.add_animation(ANIM_WALK, _walk_src.get_animation("mixamo_com"))
	lib.add_animation(ANIM_RUN, _run_src.get_animation("mixamo_com"))
	lib.add_animation(ANIM_JUMP, _jump_src.get_animation("mixamo_com"))
	lib.add_animation(ANIM_CROUCH, _crouch_src.get_animation("mixamo_com"))
	lib.add_animation(ANIM_ATTACK, _attack_src.get_animation("mixamo_com"))
	if _swim_src.has_animation("mixamo_com"):
		lib.add_animation(ANIM_SWIM, _swim_src.get_animation("mixamo_com"))
	lib.rename_animation("mixamo_com", ANIM_IDLE)

	anim.get_animation(ANIM_IDLE).loop_mode = Animation.LOOP_LINEAR
	anim.get_animation(ANIM_WALK).loop_mode = Animation.LOOP_LINEAR
	anim.get_animation(ANIM_RUN).loop_mode = Animation.LOOP_LINEAR
	anim.get_animation(ANIM_CROUCH).loop_mode = Animation.LOOP_LINEAR
	anim.get_animation(ANIM_JUMP).loop_mode = Animation.LOOP_NONE
	anim.get_animation(ANIM_ATTACK).loop_mode = Animation.LOOP_NONE
	if anim.has_animation(ANIM_SWIM):
		anim.get_animation(ANIM_SWIM).loop_mode = Animation.LOOP_LINEAR

	# Measure the natural stride speed BEFORE the root motion is stripped.
	_natural_speeds[ANIM_WALK] = _measure_clip_speed(
			anim.get_animation(ANIM_WALK), fallback_walk_speed)
	_natural_speeds[ANIM_RUN] = _measure_clip_speed(
			anim.get_animation(ANIM_RUN), fallback_run_speed)
	# A crouch-walk's natural pace, so the crouch stride matches too.
	# First detect whether the crouch clip carries a stepping gait (a
	# measurable stance-foot retreat); a pose/idle crouch has none.
	var crouch_a := anim.get_animation(ANIM_CROUCH)
	var crouch_retreat := _measure_plant_retreat_runtime(crouch_a, -1.0)
	if crouch_retreat > 0.05:
		# The crouch FBX is a real crouch-walk; stride-match it directly.
		_natural_speeds[ANIM_CROUCH] = crouch_retreat
	else:
		# The crouch FBX is a pose/idle clip (no gait): derive the moving
		# side from the measured walk clip lowered by the crouch's own
		# Hips drop, so crouch-walking steps with crouched posture.
		# Bake the moving side from the walk gait composed onto the crouch
		# stance, with the Hips height re-solved per frame so the feet stay
		# out of the floor (a bare hips drop sinks the straight legs).
		if _build_crouch_walk_clip(anim.get_animation(ANIM_WALK), crouch_a):
			_crouch_walk_clip = ANIM_CROUCH_WALK
		else:
			# No skeleton to bake on: fall back to the pose clip itself.
			_crouch_walk_clip = ANIM_CROUCH
			_natural_speeds[ANIM_CROUCH] = fallback_crouch_speed

	if strip_root_motion:
		for anim_name in ANIMS_WITH_ROOT_MOTION:
			var a: Animation = anim.get_animation(anim_name)
			for i in range(a.get_track_count() - 1, -1, -1):
				if (a.track_get_type(i) == Animation.TYPE_POSITION_3D
						and String(a.track_get_path(i)).contains("Hips")):
					a.remove_track(i)

	# Build the procedural wing-flap clips (fly / fly_glide) from the
	# skeleton's rest pose plus the idle clip's static body pose.
	_build_fly_animations()

	# The dive clip is the fly clip with tucked wings; the pitch node
	# wraps the visual model so the strike angle tips the whole character.
	_build_dive_animation()
	_setup_attitude_node()

	# Build the crouch blend space: "crouch_idle" = the most planted frame
	# of the crouch clip, so blending down from "crouch" eases into the
	# standing crouch with no foot sliding.
	_setup_crouch_blend()

	# Strike moment of the attack clip, for the fireball cast signal.
	_attack_cast_time = _measure_attack_cast_time(anim.get_animation(ANIM_ATTACK))

	_setup_lean_modifier()

	anim.animation_finished.connect(_on_animation_finished)
	anim.play(ANIM_IDLE)


func is_attacking() -> bool:
	return _attacking and not _sit_active


func is_jumping() -> bool:
	return _jumping


## --- Additive torso lean -----------------------------------------------


## Installs the lean modifier on the skeleton. It runs inside the
## Skeleton3D's modifier pass — after the AnimationPlayer writes the pose,
## before skinning — so it adds on top of any clip with no track conflicts.
func _setup_lean_modifier() -> void:
	var skel := _find_skeleton()
	if skel == null:
		return
	for bone_name in LeanModifier.BONE_SHARES:
		if skel.find_bone(String(bone_name)) < 0:
			return  # unexpected skeleton: skip lean entirely
	_lean_modifier = LeanModifier.new()
	_lean_modifier.name = "TorsoLean"
	# Calibrate the lean axes against the real skeleton: apply the
	# modifier's own formula as a probe and pick the axis signs that pitch
	# the chest toward the character's front (+Z in bone space) and bank it
	# toward its left (+X when facing +Z).
	var spine := skel.find_bone("mixamorig_Spine")
	var head := skel.find_bone("mixamorig_Head")
	if spine >= 0 and head >= 0:
		var base_head: Vector3 = skel.get_bone_global_rest(head).origin
		var rest_q: Quaternion = skel.get_bone_rest(spine).basis.get_rotation_quaternion()
		skel.set_bone_pose_rotation(spine,
				rest_q * Quaternion(Vector3.RIGHT, -0.25))
		skel.force_update_all_bone_transforms()
		var moved: Vector3 = skel.get_bone_global_pose(head).origin - base_head
		skel.set_bone_pose_rotation(spine, rest_q)
		skel.force_update_all_bone_transforms()
		if moved.z < 0.0:
			# The probe pitched backwards: flip the pitch axis.
			_lean_modifier.pitch_axis = Vector3.LEFT
		skel.set_bone_pose_rotation(spine,
				rest_q * Quaternion(Vector3(0, 0, 1), 0.25))
		skel.force_update_all_bone_transforms()
		moved = skel.get_bone_global_pose(head).origin - base_head
		skel.set_bone_pose_rotation(spine, rest_q)
		skel.force_update_all_bone_transforms()
		if moved.x < 0.0:
			# The probe banked right: flip the roll axis.
			_lean_modifier.roll_axis = Vector3(0, 0, -1)
	skel.add_child(_lean_modifier)


func _physics_process(delta: float) -> void:
	_tick_crouch_blend(delta)
	_tick_land_absorb(delta)
	# The post-takeoff lean boost is a countdown, not a state.
	if _takeoff_left > 0.0:
		_takeoff_left = maxf(0.0, _takeoff_left - delta)
	# Fire the cast signal once per attack, at the measured strike moment
	# of the attack clip (the fireball projectile hooks on here).
	if _attacking and not _attack_cast_fired \
			and anim.current_animation == ANIM_ATTACK \
			and anim.current_animation_position >= _attack_cast_time:
		_attack_cast_fired = true
		attack_cast.emit()
	var k := minf(1.0, lean_smooth * delta)
	_lean_pitch = lerpf(_lean_pitch, deg_to_rad(_target_pitch), k)
	_lean_roll = lerpf(_lean_roll, deg_to_rad(_target_roll), k)
	if _lean_modifier != null:
		_lean_modifier.pitch = _lean_pitch
		_lean_modifier.roll = _lean_roll
	# The commander seat owns the pose (and the attitude node, already
	# set by sit_pose): no further per-frame animation work below.
	if _sit_active:
		return
	# Visual attitude, eased onto a node wrapping the model (never on
	# bones) so the angles stay crisp over any playing animation: the
	# dive strike pitches hard nose-down, flight pitches with vertical
	# speed and banks into turns, everything eases level on the ground.
	var pitch_target := 0.0
	var bank_target := 0.0
	var pitch_rate := fly_attitude_smooth
	if _dive_active:
		pitch_target = deg_to_rad(dive_pitch_deg)
		pitch_rate = dive_pitch_in_speed
	elif _flying:
		if _fly_vy >= 0.0:
			pitch_target -= deg_to_rad(fly_pitch_climb_deg) * clampf(
					_fly_vy / fly_climb_ref_speed, 0.0, 1.0)
		else:
			pitch_target += deg_to_rad(fly_pitch_fall_deg) * clampf(
					-_fly_vy / fly_fall_ref_speed, 0.0, 1.0)
		# Positive yaw rate = turning left: the probed sign dips the left
		# wing into the turn.
		bank_target = _att_bank_sign * deg_to_rad(fly_bank_deg) * clampf(
				_fly_yaw_rate / fly_bank_ref_rate, -1.0, 1.0)
		# Forward lean: always tipped a little into travel while flying,
		# growing with the dive-glide energy bank (a swoop leans harder
		# than a cruise). Same nose-down-positive channel as the dive.
		var lean := fly_forward_lean_deg
		if controller != null:
			lean += fly_lean_per_energy * controller.dive_energy
		if _flapping:
			lean += flap_lean_deg
			# Per-beat nod: bypasses the eased channel (see _nod_now).
			_nod_now = _flap_nod()
		lean = minf(lean, fly_forward_lean_max)
		# Post-takeoff boost fades over its window, so the first wing
		# beats visibly pitch the body into flight.
		if _takeoff_left > 0.0:
			lean += takeoff_lean_deg * clampf(
					_takeoff_left / takeoff_lean_time, 0.0, 1.0)
		pitch_target += deg_to_rad(lean)
	else:
		pitch_rate = dive_pitch_out_speed
		_nod_now = 0.0
		# Treading-water bob: the idle swimmer rises and settles with
		# the swell — a slow nose tilt on the attitude node (raw angle:
		# the application site multiplies the probed pitch sign, same
		# convention as the flap nod). Only while the upright idle clip
		# owns the pose — a moving stroke or dive yields.
		if _swimming and not _dive_active \
				and anim.current_animation == ANIM_IDLE:
			_tread_t += delta
			_nod_now = sin(_tread_t * TAU / tread_bob_period) \
					* tread_bob_amplitude
		elif _tread_t != 0.0:
			_tread_t = 0.0
	_vis_pitch = lerpf(_vis_pitch, pitch_target,
			minf(1.0, pitch_rate * delta))
	_vis_bank = lerpf(_vis_bank, bank_target,
			minf(1.0, fly_attitude_smooth * delta))
	if _attitude_node != null:
		_attitude_node.rotation.x = _att_pitch_sign * (_vis_pitch + _nod_now)
		_attitude_node.rotation.z = _vis_bank


## Called by the controller every physics frame with the body's motion.
## `up_accel` is nonzero only on the tick the character takes off.
func set_motion_state(forward_speed: float, yaw_rate: float, airborne: bool,
		up_accel: float, sprinting: bool, crouching: bool) -> void:
	_target_pitch = 0.0
	_target_roll = 0.0
	if airborne:
		if up_accel > 0.0:
			# Takeoff: torso pushes back as the body rises.
			_target_pitch = -jump_lean_deg * clampf(up_accel / 20.0, 0.0, 1.0)
		return
	if _flying or _attacking or _jumping:
		return
	if _land_absorb_left > 0.0:
		return  # the absorb crouch damps the torso lean
	var ref_speed: float = controller.current_speed() if controller != null else 4.0
	# Into-acceleration pitch from speed along the body's forward axis
	# (backpedaling then tilts the torso slightly backwards, as it should).
	_target_pitch = accel_lean_deg * clampf(forward_speed / ref_speed, -1.0, 1.0)
	if sprinting:
		_target_pitch += run_lean_deg
	# Bank into turns from the body's yaw rate.
	_target_roll = turn_lean_deg * clampf(yaw_rate * 0.5, -1.0, 1.0)
	if crouching:
		_target_pitch *= crouch_lean_scale
		_target_roll *= crouch_lean_scale


## Applies the smoothed torso lean additively on top of the animated pose.
## Runs inside the Skeleton3D's modifier pass: after the AnimationPlayer
## writes the pose, before skinning — no track conflicts, no retargeting.
class LeanModifier:
	extends SkeletonModifier3D

	## Per-bone share of the total lean, distributed so the bend reads
	## natural instead of a single hinge.
	const BONE_SHARES := {
		&"mixamorig_Spine": 0.5,
		&"mixamorig_Spine1": 0.3,
		&"mixamorig_Spine2": 0.2,
		&"mixamorig_Neck": 0.15,
	}

	## Total lean angles (radians), set by the owning PlayerModel.
	var pitch := 0.0
	var roll := 0.0
	## Bone-local axes: pitch rotates around X, roll banks around Z.
	var pitch_axis := Vector3.RIGHT
	var roll_axis := Vector3(0, 0, 1)

	## Previous lean per bone, so a repeated pass in the same frame can
	## remove its own last application before re-adding (no compounding).
	var _prev_lean := {}

	func _process_modification_with_delta(_delta: float) -> void:
		var skel := get_skeleton()
		if skel == null:
			return
		for bone_name in BONE_SHARES:
			var idx := skel.find_bone(String(bone_name))
			if idx < 0:
				continue
			var share: float = BONE_SHARES[bone_name]
			var cur := Quaternion(pitch_axis, -pitch * share) \
					* Quaternion(roll_axis, roll * share)
			var prev: Quaternion = _prev_lean.get(idx, Quaternion.IDENTITY)
			# Animated rotation written by the AnimationPlayer this pass,
			# with our previous application removed.
			var base := skel.get_bone_pose(idx).basis.get_rotation_quaternion() \
					* prev.inverse()
			skel.set_bone_pose_rotation(idx, base * cur)
			_prev_lean[idx] = cur


func play_idle() -> void:
	_swimming = false
	if _attacking or _land_absorb_left > 0.0 or _rowing > 0.0:
		return  # the landing absorb crouch owns the pose
	if anim.current_animation != ANIM_IDLE:
		anim.play(ANIM_IDLE, blend_time)
	anim.speed_scale = 1.0


## Plays the swim clip. `speed` (m/s) scales the stroke so the arms
## beat in rhythm with the actual crossing speed. While swimming, the
## land locomotion/attack plays are refused — the water owns the pose.
## `sinking` (a crouch dive) keeps the prone stroke — the upright
## treading idle is only for resting at the surface.
func play_swim(speed := 1.0, sinking := false) -> void:
	if _attacking or _jumping or _land_absorb_left > 0.0 \
			or _rowing > 0.0 or not anim.has_animation(ANIM_SWIM):
		return
	_swimming = true
	# Treading idle: below the crossover speed the prone stroke hands
	# to the upright idle clip (reads as sculling) — a moving or
	# sinking swimmer gets the stroke back with its speed-matched
	# rhythm.
	if speed < tread_idle_speed and not sinking:
		if anim.current_animation != ANIM_IDLE:
			anim.play(ANIM_IDLE, blend_time)
		anim.speed_scale = 1.0
	else:
		if anim.current_animation != ANIM_SWIM:
			anim.play(ANIM_SWIM, blend_time)
		_set_locomotion_scale(ANIM_SWIM, speed)


## True while the swim clip owns the pose (cleared by every land play).
func is_swimming() -> bool:
	return _swimming


func play_walk(ground_speed := 1.0) -> void:
	_swimming = false
	if _attacking or _jumping or _land_absorb_left > 0.0 \
			or _rowing > 0.0:
		return  # the landing absorb crouch owns the pose
	if anim.current_animation != ANIM_WALK:
		anim.play(ANIM_WALK, blend_time)
	_set_locomotion_scale(ANIM_WALK, ground_speed)


func play_run(ground_speed := 1.0) -> void:
	_swimming = false
	if _attacking or _jumping or _land_absorb_left > 0.0 \
			or _rowing > 0.0:
		return  # the landing absorb crouch owns the pose
	if anim.current_animation != ANIM_RUN:
		anim.play(ANIM_RUN, blend_time)
	_set_locomotion_scale(ANIM_RUN, ground_speed)


## Scales the locomotion clip so its feet cover the same ground per second
## as the physics body: speed_scale = ground_speed / natural_clip_speed.
func _set_locomotion_scale(clip: StringName, ground_speed: float) -> void:
	anim.speed_scale = clampf(
			ground_speed / float(_natural_speeds.get(clip, 1.0)),
			min_anim_speed_scale, max_anim_speed_scale)


## Ground speed a clip covers per second of playback, derived from the
## horizontal drift of its Hips position track (stride length per cycle
## divided by cycle duration). Clips without root motion ("In Place"
## exports) fall back to their stance-foot retreat speed.
func _measure_clip_speed(a: Animation, fallback: float) -> float:
	for i in a.get_track_count():
		if (a.track_get_type(i) == Animation.TYPE_POSITION_3D
				and String(a.track_get_path(i)).contains("Hips")):
			var start: Vector3 = a.position_track_interpolate(i, 0.0)
			var end: Vector3 = a.position_track_interpolate(i, a.length)
			var drift := Vector2(end.x - start.x, end.z - start.z).length()
			if drift > 0.01 and a.length > 0.01:
				return drift / a.length
			break
	return fallback


## Natural pace of an in-place locomotion clip (no Hips root motion),
## measured by applying the clip's bone tracks DIRECTLY to the skeleton
## (no AnimationPlayer playback) and integrating the stance foot's
## backward retreat — which is exactly the clip's walking pace. The
## skeleton's pose is saved and restored.
func _measure_plant_retreat_runtime(a: Animation, fallback: float) -> float:
	var skel := _find_skeleton()
	if skel == null or a.length < 0.05:
		return fallback
	var feet: Array[int] = []
	for bone in [&"mixamorig_LeftFoot", &"mixamorig_RightFoot"]:
		var fi := skel.find_bone(String(bone))
		if fi >= 0:
			feet.append(fi)
	if feet.is_empty():
		return fallback
	# Map the clip's tracks to bone indices (parallel arrays) and save
	# the pose values we are about to overwrite.
	var rot_tracks: Array[int] = []
	var rot_bones: Array[int] = []
	var pos_tracks: Array[int] = []
	var pos_bones: Array[int] = []
	var saved_rot := {}
	var saved_pos := {}
	for i in a.get_track_count():
		var p := a.track_get_path(i)
		if p.get_subname_count() == 0:
			continue
		var bi := skel.find_bone(String(p.get_subname(0)))
		if bi < 0:
			continue
		match a.track_get_type(i):
			Animation.TYPE_ROTATION_3D:
				rot_tracks.append(i)
				rot_bones.append(bi)
				saved_rot[bi] = skel.get_bone_pose_rotation(bi)
			Animation.TYPE_POSITION_3D:
				pos_tracks.append(i)
				pos_bones.append(bi)
				saved_pos[bi] = skel.get_bone_pose_position(bi)
	if rot_tracks.is_empty():
		return fallback
	var steps := 48
	var dt := a.length / float(steps)
	var prev := {}
	var total := 0.0
	var time := 0.0
	for s in range(steps + 1):
		var t := a.length * float(s) / float(steps)
		for k in rot_tracks.size():
			skel.set_bone_pose_rotation(rot_bones[k],
					a.rotation_track_interpolate(rot_tracks[k], t))
		for k in pos_tracks.size():
			skel.set_bone_pose_position(pos_bones[k],
					a.position_track_interpolate(pos_tracks[k], t))
		skel.force_update_all_bone_transforms()
		var low_idx := -1
		var low_y := INF
		var poses := {}
		for idx in feet:
			var p: Vector3 = skel.get_bone_global_pose(idx).origin
			poses[idx] = p
			if p.y < low_y:
				low_y = p.y
				low_idx = idx
		if prev.has(low_idx):
			var p0: Vector3 = prev[low_idx]
			var p1: Vector3 = poses[low_idx]
			# Same foot stayed planted (its height barely changed).
			if absf(p1.y - p0.y) < 0.03:
				total += Vector2(p1.x - p0.x, p1.z - p0.z).length()
				time += dt
		prev = poses
	# Restore the pose the measurement overwrote.
	for bi in saved_rot:
		skel.set_bone_pose_rotation(bi, saved_rot[bi])
	for bi in saved_pos:
		skel.set_bone_pose_position(bi, saved_pos[bi])
	skel.force_update_all_bone_transforms()
	if time > 0.05:
		var measured := total / time
		if measured > 0.05:
			return measured
	return fallback


func get_natural_speed(clip: StringName) -> float:
	return float(_natural_speeds.get(clip, 0.0))


## Plays the crouch blend space: `ground_speed` 0 eases into the standing
## crouch pose, any real speed plays the stride-matched crouch-walk clip.
func play_crouch(ground_speed := 0.0) -> void:
	if _attacking or _jumping or _land_absorb_left > 0.0:
		return  # the landing absorb crouch owns the pose
	_crouch_moving = ground_speed > crouch_walk_blend_speed
	_crouch_speed = ground_speed
	if _in_crouch_blend:
		return  # the ticker eases between stance and walk by itself
	_in_crouch_blend = true
	_crouch_weight = 1.0 if _crouch_moving else 0.0
	anim.play(_crouch_walk_clip, blend_time)
	anim.seek(0.0, true)  # both blend sources start in sync from frame 0
	_crouch_pose_on = false


## True while the crouch blend space is actively playing the walk clip
## (as opposed to holding the standing crouch pose).
func is_crouch_moving() -> bool:
	return _crouch_moving


## Ends the crouch blend space and hands control back to `play_idle()`.
func stop_crouch() -> void:
	_crouch_moving = false
	if _in_crouch_blend:
		_in_crouch_blend = false
		anim.play(ANIM_IDLE, blend_time)
		anim.speed_scale = 1.0


## Called by the controller on a touchdown: a hard-enough landing sinks
## the character into the crouch pose for `land_absorb_time`, knees
## soaking up the impact, then hands back to the normal locomotion the
## per-frame play_* calls pick. The pose is OWNED outright (not blended
## through the crouch blend space — its weight ticker would instantly
## swap the static pose for the crouch-walk clip at zero weight).
func absorb_landing(fall_speed: float, grade := -1.0) -> void:
	if _flying or _attacking or _jumping:
		return
	if grade < 0.0:
		grade = fall_speed  # legacy callers: fall speed only
	if grade < land_absorb_min_fall:
		return
	# Severity 0..1: how far past the absorb threshold the grade sits
	# (speed alone, or the controller's speed+height blend).
	landing_grade = clampf((grade - land_absorb_min_fall) / 8.0,
			0.0, 1.0)
	var weight := landing_grade
	_land_absorb_left = land_absorb_time * (0.8 + 0.4 * weight)
	anim.play(ANIM_CROUCH_IDLE, minf(blend_time, 0.12))
	anim.speed_scale = 1.0


## True while the landing absorb crouch owns the pose.
func absorbing_landing() -> bool:
	return _land_absorb_left > 0.0


## Runs down the absorb clock. While it lasts, the pose clip is
## re-asserted every frame (headless or blend glitches could otherwise
## replace it silently); on expiry the play_* guards release and
## locomotion takes over seamlessly.
func _tick_land_absorb(delta: float) -> void:
	if _land_absorb_left <= 0.0:
		return
	_land_absorb_left -= delta
	if _land_absorb_left <= 0.0:
		_land_absorb_left = 0.0
		return
	if _flying or _attacking or _jumping:
		_land_absorb_left = 0.0  # a higher-priority state took over
		return
	if anim.current_animation != ANIM_CROUCH_IDLE:
		anim.play(ANIM_CROUCH_IDLE, 0.08)
		anim.speed_scale = 1.0


## Ticks the crouch blend space: eases the weight towards the target mix
## between the stride-matched crouch-walk clip (1.0) and the standing
## crouch pose (0.0), then keeps the walk's stride matched to the body.
func _tick_crouch_blend(_delta: float) -> void:
	if not _in_crouch_blend:
		return
	# Any other play_*() call ends the blend space by replacing the clip.
	if anim.current_animation != _crouch_walk_clip \
			and anim.current_animation != ANIM_CROUCH_IDLE:
		_in_crouch_blend = false
		return
	var target := 1.0 if _crouch_moving else 0.0
	_crouch_weight = lerpf(_crouch_weight, target,
			minf(1.0, crouch_blend_speed * _delta))
	if _crouch_weight > crouch_weight_epsilon and not _crouch_pose_on:
		anim.play(ANIM_CROUCH_IDLE, blend_time)
		_crouch_pose_on = true
	elif _crouch_weight <= crouch_weight_epsilon and _crouch_pose_on:
		anim.play(_crouch_walk_clip, blend_time)
		_crouch_pose_on = false
	# Stride match so the crouch-walk's feet cover the real ground speed.
	anim.speed_scale = clampf(
			_crouch_speed / float(_natural_speeds.get(ANIM_CROUCH, fallback_crouch_speed)),
			min_anim_speed_scale, max_anim_speed_scale)


## Builds the fallback crouch-walk clip: the crouch stance (knees bent,
## hips low, grounded by the crouch clip's own Hips track) with the walk
## clip's leg-cycle swing composed on top, and the Hips height re-solved
## per frame so the lowest foot rests on the stance's ground level. The
## old bake (walk clip + a constant hips drop) kept the legs straight and
## sank the feet through the floor — the drop must come WITH a knee bend,
## which is what this composition produces. Returns false if the skeleton
## can't be probed (then the crouch pose clip is used as-is).
func _build_crouch_walk_clip(walk: Animation, crouch: Animation) -> bool:
	var skel := _find_skeleton()
	var hips_idx := -1
	if skel != null:
		hips_idx = skel.find_bone("mixamorig_Hips")
	if skel == null or hips_idx < 0 or walk == null or crouch == null:
		return false
	var feet: Array[int] = []
	for foot_name in ["mixamorig_LeftFoot", "mixamorig_RightFoot"]:
		var fi := skel.find_bone(foot_name)
		if fi >= 0:
			feet.append(fi)
	if feet.is_empty():
		return false

	# Reference crouch stance at the clip's most planted frame: applied to
	# the skeleton so its grounded foot height can be measured and its
	# pose snapshotted as the composition base.
	var ref_time := crouch.length * _most_planted_time(crouch)
	for i in crouch.get_track_count():
		var p := crouch.track_get_path(i)
		if p.get_subname_count() == 0:
			continue
		var bi := skel.find_bone(String(p.get_subname(0)))
		if bi < 0:
			continue
		match crouch.track_get_type(i):
			Animation.TYPE_ROTATION_3D:
				skel.set_bone_pose_rotation(bi,
						crouch.rotation_track_interpolate(i, ref_time))
			Animation.TYPE_POSITION_3D:
				skel.set_bone_pose_position(bi,
						crouch.position_track_interpolate(i, ref_time))
	skel.force_update_all_bone_transforms()
	var ground_ref := INF
	for fi in feet:
		ground_ref = minf(ground_ref, skel.get_bone_global_pose(fi).origin.y)
	if ground_ref == INF:
		return false
	var hips_pos_ref: Vector3 = skel.get_bone_pose_position(hips_idx)
	var crouch_rot := {}
	for bi in skel.get_bone_count():
		crouch_rot[bi] = skel.get_bone_pose_rotation(bi)

	# Walk rotation tracks for the leg chain + hips only (torso, arms and
	# head keep the crouch stance).
	var walk_tracks: Array[int] = []
	var walk_bones: Array[int] = []
	var walk_paths: Array[NodePath] = []
	for i in walk.get_track_count():
		if walk.track_get_type(i) != Animation.TYPE_ROTATION_3D:
			continue
		var p := walk.track_get_path(i)
		if p.get_subname_count() == 0:
			continue
		var bone_name := String(p.get_subname(0))
		if not _is_leg_or_hips(bone_name):
			continue
		var bi := skel.find_bone(bone_name)
		if bi < 0:
			continue
		walk_tracks.append(i)
		walk_bones.append(bi)
		walk_paths.append(p)

	# Hips position track path: the crouch clip's own if it carries one.
	var hips_path := _hips_track_path(crouch)
	for i in crouch.get_track_count():
		if (crouch.track_get_type(i) == Animation.TYPE_POSITION_3D
				and String(crouch.track_get_path(i)).contains("Hips")):
			hips_path = crouch.track_get_path(i)
			break

	var baked := Animation.new()
	baked.length = walk.length
	baked.loop_mode = Animation.LOOP_LINEAR
	var rot_track_of := {}
	var pos_track := -1
	var rest_q := {}
	var samples := 24
	for s in range(samples + 1):
		var t := walk.length * float(s) / float(samples)
		# Reset to the stance, then compose the walk's leg swing on top.
		for bi in crouch_rot:
			skel.set_bone_pose_rotation(bi, crouch_rot[bi])
		skel.set_bone_pose_position(hips_idx, hips_pos_ref)
		for k in walk_tracks.size():
			var bi: int = walk_bones[k]
			if not rest_q.has(bi):
				var rq: Quaternion = skel.get_bone_rest(bi).basis \
						.get_rotation_quaternion().normalized()
				rest_q[bi] = rq
			var base_q: Quaternion = crouch_rot.get(bi, rest_q[bi])
			var delta: Quaternion = \
					walk.rotation_track_interpolate(walk_tracks[k], t) \
					* rest_q[bi].inverse()
			var composed: Quaternion = base_q * delta
			skel.set_bone_pose_rotation(bi, composed)
			var ti: int = rot_track_of.get(bi, -1)
			if ti < 0:
				ti = baked.add_track(Animation.TYPE_ROTATION_3D)
				baked.track_set_path(ti, walk_paths[k])
				rot_track_of[bi] = ti
			baked.rotation_track_insert_key(ti, t, composed)
		skel.force_update_all_bone_transforms()
		# Re-solve the hips height: lift or drop so the LOWER foot rests on
		# the stance's ground level (the higher foot is the swing leg — its
		# lift is correct gait, not a bug).
		var low_y := INF
		for fi in feet:
			low_y = minf(low_y, skel.get_bone_global_pose(fi).origin.y)
		if low_y == INF:
			return false
		var dy := clampf(ground_ref - low_y, -0.35, 0.6)
		if pos_track < 0:
			pos_track = baked.add_track(Animation.TYPE_POSITION_3D)
			baked.track_set_path(pos_track, hips_path)
		baked.position_track_insert_key(pos_track, t,
				hips_pos_ref + Vector3(0.0, dy, 0.0))

	# Global sink correction: re-sample the finished clip exactly the way
	# playback interpolates it (between keys included) and lift every
	# hips key by any residual dip, so the feet never sink mid-cycle —
	# linear hips keys over a non-linear leg chain can still dip without
	# this pass.
	var baked_rot: Array[int] = []
	var baked_bones: Array[int] = []
	for bi in rot_track_of:
		baked_rot.append(rot_track_of[bi])
		baked_bones.append(bi)
	var sink := 0.0
	for s in range(97):
		var t2 := baked.length * float(s) / 96.0
		for k in baked_rot.size():
			skel.set_bone_pose_rotation(baked_bones[k],
					baked.rotation_track_interpolate(baked_rot[k], t2))
		skel.set_bone_pose_position(hips_idx,
				baked.position_track_interpolate(pos_track, t2))
		skel.force_update_all_bone_transforms()
		var low := INF
		for fi in feet:
			low = minf(low, skel.get_bone_global_pose(fi).origin.y)
		sink = maxf(sink, (ground_ref + 0.02) - low)
	if sink > 0.0:
		for k in baked.track_get_key_count(pos_track):
			var kt := baked.track_get_key_time(pos_track, k)
			baked.position_track_insert_key(pos_track, kt,
					baked.position_track_interpolate(pos_track, kt)
							+ Vector3(0.0, sink, 0.0))
	# Leave the skeleton at its rest pose for the later builders.
	for bi in skel.get_bone_count():
		skel.set_bone_pose_rotation(bi,
				skel.get_bone_rest(bi).basis.get_rotation_quaternion())
		skel.set_bone_pose_position(bi, skel.get_bone_rest(bi).origin)
	skel.force_update_all_bone_transforms()

	# Static tracks: every crouch-driven track that is not composed
	# per-frame (torso, arms, head) holds the stance pose for the clip.
	var composed_names := {}
	for k in walk_bones.size():
		composed_names[skel.get_bone_name(walk_bones[k])] = true
	for i in crouch.get_track_count():
		var p := crouch.track_get_path(i)
		if p.get_subname_count() == 0:
			continue
		var bone_name := String(p.get_subname(0))
		var is_rot: bool = crouch.track_get_type(i) == Animation.TYPE_ROTATION_3D
		if is_rot and composed_names.has(bone_name):
			continue
		if (bone_name == "mixamorig_Hips"
				and crouch.track_get_type(i) == Animation.TYPE_POSITION_3D):
			continue
		_copy_static_key(crouch, i, baked, ref_time)

	anim.get_animation_library("").add_animation(ANIM_CROUCH_WALK, baked)
	# The baked gait's own pace, measured from the finished clip so the
	# stride matcher matches the composed legs, not the raw walk clip.
	var pace := _measure_plant_retreat_runtime(baked,
			float(_natural_speeds.get(ANIM_WALK, 1.0)))
	_natural_speeds[ANIM_CROUCH_WALK] = pace
	_natural_speeds[ANIM_CROUCH] = pace
	return true


## True for bones the crouch-walk composition drives per-frame: the leg
## chain plus the hips.
func _is_leg_or_hips(bone_name: String) -> bool:
	if bone_name == "mixamorig_Hips":
		return true
	for suffix in LEG_BONE_SUFFIXES:
		if bone_name.ends_with(suffix):
			return true
	return false


## NodePath for a constant Hips position track on `a`'s skeleton,
## derived from one of its existing bone tracks.
func _hips_track_path(a: Animation) -> NodePath:
	for i in a.get_track_count():
		var p := a.track_get_path(i)
		if p.get_subname_count() > 0:
			return NodePath("%s:mixamorig_Hips" % String(
					p.get_concatenated_names()))
	return NodePath("Skeleton3D:mixamorig_Hips")





## Builds the standing-crouch pose and registers the blend weight.
func _setup_crouch_blend() -> void:
	if not anim.has_animation(ANIM_CROUCH):
		return
	var src := anim.get_animation(ANIM_CROUCH)
	var pose := Animation.new()
	for i in src.get_track_count():
		pose.add_track(src.track_get_type(i))
		pose.track_set_path(pose.get_track_count() - 1, src.track_get_path(i))
	var t := src.length * _most_planted_time(src)
	for i in pose.get_track_count():
		_copy_static_key(src, i, pose, t)
	anim.get_animation_library("").add_animation(ANIM_CROUCH_IDLE, pose)


## Fraction (0..1) of the clip's timeline at which the feet are closest to
## the ground — the most "standing" frame of a crouch cycle.
func _most_planted_time(src: Animation) -> float:
	var feet := _foot_track_indices(src)
	if feet.is_empty():
		return 0.0
	var steps := 12
	var best_time := 0.0
	var best_y := INF
	for s in steps:
		var t := src.length * float(s) / float(steps - 1)
		var y := 0.0
		for idx in feet:
			y += src.position_track_interpolate(idx, t).y
		if y < best_y:
			best_y = y
			best_time = float(s) / float(steps - 1)
	return best_time


## Indices of the animation's foot position tracks (empty for clips like
## the crouch that were authored without planted-foot keyframes).
func _foot_track_indices(a: Animation) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in a.get_track_count():
		if a.track_get_type(i) == Animation.TYPE_POSITION_3D:
			var p := String(a.track_get_path(i))
			if p.contains("LeftFoot") or p.contains("RightFoot"):
				out.append(i)
	return out


## Starts the jump clip. Returns false if blocked (attacking / already jumping).
func start_jump() -> bool:
	if _attacking or _jumping:
		return false
	_jumping = true
	anim.play(ANIM_JUMP, 0.1)
	anim.speed_scale = 1.0
	return true


## Called when the character lands again.
func finish_jump() -> void:
	_jumping = false
	play_idle()


func play_fly(ground_speed := 1.0, flapping := true) -> void:
	if _attacking:
		return
	# Takeoff edge: starting flight from the ground starts the fading
	# lean boost so the body tips forward with the first wing beats.
	if not _flying:
		_takeoff_left = takeoff_lean_time
	_flying = true
	_flapping = flapping
	var clip := ANIM_FLY if flapping else ANIM_FLY_GLIDE
	if not anim.has_animation(clip):
		return
	if anim.current_animation != clip:
		anim.play(clip, blend_time)
	if flapping:
		# One wing beat per loop; the tempo quickens a little with speed.
		var tempo := clampf(0.8 + ground_speed / 20.0, 0.8, 2.0)
		anim.speed_scale = flap_frequency * tempo
	else:
		# Glide: wings held spread with a gentle slow bob.
		anim.speed_scale = 1.0


## Returns true if flight mode is currently active.
func is_flying() -> bool:
	return _flying


## Forward body nod for the current moment of the wing-beat loop: an
## effort swell centred on the mid-downstroke (loop fraction 0.5 —
## the same convention the flap-audio beats use), squared for a soft
## attack. Zero outside the flapping clip.
func _flap_nod() -> float:
	if not anim.has_animation(ANIM_FLY) \
			or anim.current_animation != ANIM_FLY:
		return 0.0
	var flap: Animation = anim.get_animation(ANIM_FLY)
	var frac := fposmod(anim.current_animation_position \
			/ maxf(flap.length, 0.01), 1.0)
	var s := clampf(1.0 - absf(frac - 0.5) / 0.35, 0.0, 1.0)
	return deg_to_rad(flap_nod_deg) * s * s


## Feeds the flight attitude solver: vertical speed pitches the body
## nose-up/down, yaw rate banks it into the turn. The controller calls
## this every physics frame while flying; once it stops (flight over)
## the attitude eases back level on its own.
func set_flight_attitude(vy: float, yaw_rate: float) -> void:
	_fly_vy = vy
	_fly_yaw_rate = yaw_rate


## --- Rowing (the sailable longship) --------------------------------------
## Rowing effort 0..1, set by the controller every physics frame while
## aboard the flagship. Nonzero: the walk clip is replayed as the rowing
## stroke (hull-bench cadence), and idle/run/crouch plays are refused so
## the pose never pops to land animations mid-voyage.
var _rowing := 0.0
## Previous normalized phase (0..1) of the rowing clip — used to detect
## the oar dips; -1 means "no cycle yet" (re-primed on every clip start
## so a fresh play can't fake a dip).
var _row_phase := -1.0
## Which oar dips next: -1 = port, +1 = starboard (alternates).
var _row_side := 1
## Normalized times of the two oar dips within the rowing cycle.
const ROW_DIP_PHASES: Array[float] = [0.25, 0.75]
## Commander seat: while true, sit_pose owns the model (locked pose,
## no locomotion/attack/flight overrides). Driven per-frame by the
## controller while the hero sits at the flagship's tiller.
var _sit_active := false
## True from play_swim() until a land pose takes over — the controller
## polls this to know the swim clip owns the character.
var _swimming := false
## Bob clock for the treading-water idle (s since the idle began).
var _tread_t := 0.0


## --- Seated (commander) pose --------------------------------------------

## Locks a seated helm pose. While active it overrides locomotion,
## attack and flight state (the controller calls this every physics
## frame while the hero sits at the flagship's tiller). `turn` (-1..1)
## eases a torso lean against the rudder; `speed` eases a small
## forward intent lean while the hull has way on.
func sit_pose(on: bool, turn: float, speed: float) -> void:
	if not on:
		if _sit_active:
			_sit_active = false
			anim.speed_scale = 1.0
			play_idle()
		return
	if not _sit_active:
		_sit_active = true
		_attacking = false
		_dive_active = false
		_flying = false
		_flapping = false
		_rowing = 0.0
		anim.speed_scale = 1.0
		# The seat IS an animation (see _build_sit_clip): direct bone
		# writes can't survive the mixer's deterministic re-application.
		if not anim.has_animation(SIT_CLIP) and not _build_sit_clip():
			_sit_active = false
			return
		anim.play(SIT_CLIP, blend_time)
	# The lean channels: rudder counter-lean on the torso modifier,
	# speed intent on the attitude node.
	_target_roll = clampf(-turn * 9.0, -9.0, 9.0)
	_target_pitch = 0.0
	_vis_pitch = deg_to_rad(clampf(speed * 1.6, 0.0, 9.0))
	_vis_bank = deg_to_rad(_target_roll)
	if _attitude_node != null:
		_attitude_node.rotation.x = _att_pitch_sign * _vis_pitch
		_attitude_node.rotation.z = _vis_bank


## The seated helm clip, built once at runtime: the idle pose as
## static keys for the whole body (the proven fly-clip recipe), then
## authored overrides for the seat — hips dropped, torso eased aft,
## legs bent up onto the bench, arms held low and forward toward the
## tiller. Looping static keys hold the pose under the mixer.
func _build_sit_clip() -> bool:
	var skel := _find_skeleton()
	if skel == null:
		return false
	var idle := anim.get_animation(ANIM_IDLE)
	var lib := anim.get_animation_library("")
	var root := _skel_track_root(idle)
	if root.is_empty():
		return false
	var sit := Animation.new()
	sit.length = 1.0
	sit.loop_mode = Animation.LOOP_LINEAR
	for i in idle.get_track_count():
		_copy_static_key(idle, i, sit)
	# Hips: drop into the seat (base position from the idle clip).
	var hips_path := NodePath("%s:mixamorig_Hips" % root)
	var hips_base := Vector3(0.0, 1.0, 0.0)
	for i in idle.get_track_count():
		if idle.track_get_type(i) == Animation.TYPE_POSITION_3D \
				and idle.track_get_path(i) == hips_path:
			hips_base = idle.position_track_interpolate(i, 0.0)
			break
	_seat_key(sit, root, "mixamorig_Hips", "position",
			hips_base + Vector3(0.0, -0.22, 0.0))
	_seat_key(sit, root, "mixamorig_Hips", "rotation",
			Quaternion(Vector3.RIGHT, deg_to_rad(-8.0)))
	_seat_key(sit, root, "mixamorig_Spine", "rotation",
			Quaternion(Vector3.RIGHT, deg_to_rad(-6.0)))
	_seat_key(sit, root, "mixamorig_LeftUpLeg", "rotation",
			Quaternion(Vector3.RIGHT, deg_to_rad(-80.0)))
	_seat_key(sit, root, "mixamorig_RightUpLeg", "rotation",
			Quaternion(Vector3.RIGHT, deg_to_rad(-80.0)) \
					* Quaternion(Vector3.UP, deg_to_rad(6.0)))
	_seat_key(sit, root, "mixamorig_LeftLowerLeg", "rotation",
			Quaternion(Vector3.RIGHT, deg_to_rad(85.0)))
	_seat_key(sit, root, "mixamorig_RightLowerLeg", "rotation",
			Quaternion(Vector3.RIGHT, deg_to_rad(85.0)))
	_seat_key(sit, root, "mixamorig_LeftArm", "rotation",
			Quaternion(Vector3.RIGHT, deg_to_rad(-38.0)))
	_seat_key(sit, root, "mixamorig_RightArm", "rotation",
			Quaternion(Vector3.RIGHT, deg_to_rad(-38.0)) \
					* Quaternion(Vector3.UP, deg_to_rad(-14.0)))
	_seat_key(sit, root, "mixamorig_LeftForeArm", "rotation",
			Quaternion(Vector3.RIGHT, deg_to_rad(-40.0)))
	_seat_key(sit, root, "mixamorig_RightForeArm", "rotation",
			Quaternion(Vector3.RIGHT, deg_to_rad(-40.0)))
	lib.add_animation(SIT_CLIP, sit)
	return true


## The NodePath root every idle bone track uses (e.g. "Skeleton3D").
func _skel_track_root(idle: Animation) -> String:
	for i in idle.get_track_count():
		var p := idle.track_get_path(i)
		if p.get_subname_count() > 0:
			return p.get_concatenated_names()
	return ""


## Inserts one static pose key (position or rotation) for a bone.
func _seat_key(dst: Animation, root: String, bone: String,
		kind: String, value: Variant) -> void:
	var idx := dst.get_track_count()
	dst.add_track(Animation.TYPE_POSITION_3D if kind == "position"
			else Animation.TYPE_ROTATION_3D)
	dst.track_set_path(idx, NodePath("%s:%s" % [root, bone]))
	if kind == "position":
		dst.position_track_insert_key(idx, 0.0, value)
	else:
		dst.rotation_track_insert_key(idx, 0.0, value)


func set_rowing(throttle: float) -> void:
	_rowing = clampf(throttle, 0.0, 1.0)
	if _attacking:
		return  # the strike plays out; rowing resumes after it
	if _rowing > 0.0:
		if anim.current_animation != ANIM_WALK:
			anim.play(ANIM_WALK, blend_time)
			_row_phase = -1.0  # fresh stroke cycle
		_set_locomotion_scale(ANIM_WALK, 2.0)
		# Tempo: a lazy drift rows slower than a full stroke.
		anim.speed_scale = anim.speed_scale \
				* lerpf(0.6, 1.5, _rowing)
		_track_row_phase()
	else:
		_row_phase = -1.0
		play_idle()


## Fires row_stroke at each oar dip of the rowing cycle. The phase is
## read from the playing clip itself (position / length), so the splash
## rhythm follows the true playback tempo — including the throttle
## scaling — exactly like the footfall detector follows the
## stride-matched walk. Two dips per cycle, alternating sides.
func _track_row_phase() -> void:
	if anim.current_animation != ANIM_WALK \
			or anim.current_animation_length <= 0.0:
		return
	var ph := anim.current_animation_position / anim.current_animation_length
	if _row_phase < 0.0:
		_row_phase = ph
		return
	# How far the clip advanced this frame (forward-wrapped to 0..1).
	var delta := fposmod(ph - _row_phase, 1.0)
	if delta <= 0.0:
		_row_phase = ph
		return  # paused / no advance this frame
	for dip_v in ROW_DIP_PHASES:
		var dip := float(dip_v)
		# A dip fires when its forward distance from the previous phase
		# fits inside this frame's advance.
		if fposmod(dip - _row_phase, 1.0) <= delta:
			_row_side = -_row_side
			row_stroke.emit(_row_side, _rowing)
	_row_phase = ph


## Ends flight mode; the next play_* call picks the landing state.
func stop_flying() -> void:
	_flying = false
	_flapping = false
	_takeoff_left = 0.0
	_rowing = 0.0
	_row_phase = -1.0
	# Leave no stale attitude input behind; the tilt eases level.
	_fly_vy = 0.0
	_fly_yaw_rate = 0.0
	# Leaving flight (landing or toggle) always ends a dive.
	finish_dive()


## Starts the dive-bomb strike. Returns false if it can't start: not
## flying, an attack is already playing, or a dive is already active.
func start_dive() -> bool:
	if not _flying or _attacking or _diving:
		return false
	_diving = true
	_dive_active = true
	anim.play(ANIM_DIVE, 0.08)
	anim.speed_scale = 1.0
	dive_started.emit()
	return true


## True while a dive-bomb strike is in progress.
func is_diving() -> bool:
	return _diving


## Ends the dive (impact, or the player pulled out of it); the body eases
## back upright and the controller picks the next state.
func finish_dive() -> void:
	_diving = false
	_dive_active = false


## Returns false if an attack or a dive is already playing.
func play_attack() -> bool:
	if _attacking or _diving:
		return false
	_attacking = true
	_attack_cast_fired = false
	anim.play(ANIM_ATTACK, 0.1)
	anim.speed_scale = attack_speed_scale
	return true


func _on_animation_finished(finished: StringName) -> void:
	match finished:
		ANIM_ATTACK:
			_attacking = false
			attack_finished.emit()
			play_idle()
		ANIM_JUMP:
			# Jump clip ended while still airborne: hold the last pose until landing.
			anim.pause()


## World-space origin for the fireball cast: the right hand's position
## while the attack swing plays (falls back to chest height).
func get_cast_origin() -> Vector3:
	var skel := _find_skeleton()
	if skel != null:
		var hi := skel.find_bone(String(CAST_HAND))
		if hi >= 0:
			return skel.to_global(skel.get_bone_global_pose(hi).origin)
	return global_position + Vector3(0.0, 1.2, 0.0)


## --- Fireball cast timing ---------------------------------------------


## Finds the attack clip's strike moment: the timeline time at which the
## right hand reaches its furthest point towards the model's visual front.
## Measured by applying the clip to the skeleton directly; the idle clip
## that starts right after resets the pose.
func _measure_attack_cast_time(a: Animation) -> float:
	if a == null or a.length < 0.05:
		return 0.0
	var skel := _find_skeleton()
	if skel == null:
		return a.length * 0.5
	var hand := skel.find_bone(String(CAST_HAND))
	if hand < 0:
		return a.length * 0.5
	# The model's visual front (its own +Z) expressed in skeleton space.
	var front := skel.global_transform.basis.inverse() \
			* global_transform.basis.z
	var tracks: Array[int] = []
	var bones: Array[int] = []
	for i in a.get_track_count():
		if a.track_get_type(i) != Animation.TYPE_ROTATION_3D:
			continue
		var p := a.track_get_path(i)
		if p.get_subname_count() == 0:
			continue
		var bi := skel.find_bone(String(p.get_subname(0)))
		if bi >= 0:
			tracks.append(i)
			bones.append(bi)
	if tracks.is_empty():
		return a.length * 0.5
	var best_t := 0.0
	var best_d := -INF
	for s in range(33):
		var t := a.length * float(s) / 32.0
		for k in tracks.size():
			skel.set_bone_pose_rotation(bones[k],
					a.rotation_track_interpolate(tracks[k], t))
		skel.force_update_all_bone_transforms()
		var d: float = skel.get_bone_global_pose(hand).origin.dot(front)
		if d > best_d:
			best_d = d
			best_t = t
	return best_t


## --- Procedural dive-bomb ---------------------------------------------


## Builds the "dive" clip: the fly clip with the two wing tracks
## retargeted to a raptor-like tuck (wings swept back/down) so the strike
## pose reads as a predator folding in for the kill.
func _build_dive_animation() -> void:
	if not anim.has_animation(ANIM_FLY):
		return
	var flap: Animation = anim.get_animation(ANIM_FLY)
	var dive: Animation = flap.duplicate(true)
	var tuck_l: Variant = _wing_tuck_quaternion(flap, WING_ARM_L)
	var tuck_r: Variant = _wing_tuck_quaternion(flap, WING_ARM_R)
	for i in dive.get_track_count():
		if dive.track_get_type(i) != Animation.TYPE_ROTATION_3D:
			continue
		var bone := String(dive.track_get_path(i).get_subname(0))
		if bone != String(WING_ARM_L) and bone != String(WING_ARM_R):
			continue
		var tuck_q: Variant = tuck_l if bone == String(WING_ARM_L) else tuck_r
		if tuck_q == null:
			continue
		for k in range(dive.track_get_key_count(i) - 1, -1, -1):
			dive.track_remove_key(i, k)
		var length: float = dive.length
		for k in 3:
			dive.rotation_track_insert_key(i, length * float(k) / 2.0, tuck_q)
	if not anim.has_animation(ANIM_DIVE):
		anim.get_animation_library("").add_animation(ANIM_DIVE, dive)


## The tucked wing pose for one arm, reusing the same beat axis, lift sign
## and TRACK PATH the flap clip was authored with (the path must match or
## the dive's retargeted track would not resolve). Returns null if the
## wing geometry can't be measured.
func _wing_tuck_quaternion(flap: Animation, arm_name: StringName) -> Variant:
	var skel := _find_skeleton()
	if skel == null:
		return null
	var arm_idx := skel.find_bone(String(arm_name))
	if arm_idx < 0:
		return null
	# The flap clip's own track path for this arm is the source of truth.
	var has_track := false
	for i in flap.get_track_count():
		if flap.track_get_type(i) == Animation.TYPE_ROTATION_3D \
				and String(flap.track_get_path(i).get_subname(0)) == String(arm_name):
			has_track = true
			break
	if not has_track:
		return null
	var rest_q := skel.get_bone_rest(arm_idx).basis.get_rotation_quaternion().normalized()
	var world_q := skel.get_bone_global_rest(arm_idx).basis.get_rotation_quaternion().normalized()
	var hand_idx := skel.find_bone(String(arm_name).replace("Arm", "Hand"))
	if hand_idx < 0:
		return null
	var arm_dir := (skel.get_bone_global_rest(hand_idx).origin
			- skel.get_bone_global_rest(arm_idx).origin).normalized()
	var axis_world := arm_dir.cross(Vector3.UP)
	if axis_world.length_squared() < 0.01:
		axis_world = Vector3.UP
	var axis := (world_q.inverse() * axis_world.normalized()).normalized()
	var base_y: float = skel.get_bone_global_rest(hand_idx).origin.y
	skel.set_bone_pose_rotation(arm_idx,
			rest_q * Quaternion(axis, deg_to_rad(25.0)))
	skel.force_update_all_bone_transforms()
	var raised_y: float = skel.get_bone_global_pose(hand_idx).origin.y
	skel.set_bone_pose_rotation(arm_idx, rest_q)
	skel.force_update_all_bone_transforms()
	var raise_sign := 1.0 if raised_y > base_y else -1.0
	var tuck_ang := wing_raise_deg + dive_wing_tuck_deg
	return rest_q * Quaternion(axis, raise_sign * deg_to_rad(tuck_ang))


## Creates (or finds) the node that wraps the visual model so the dive
## strike and the flight attitude can tilt the whole character. Both
## rotation signs are calibrated by probing a real rotation and checking
## which way the head / left hand actually moved — never a sign guess.
func _setup_attitude_node() -> void:
	if has_node(PITCH_NODE):
		_attitude_node = get_node(PITCH_NODE)
	else:
		_attitude_node = Node3D.new()
		_attitude_node.name = PITCH_NODE
		add_child(_attitude_node)
		for c in get_children():
			if c == _attitude_node:
				continue
			if String(c.name).begins_with("gods1"):
				c.reparent(_attitude_node)
	var skel := _find_skeleton()
	if skel == null:
		return
	# Pitch sign: the character's visual front is the model node's own
	# +Z axis (independent of whatever world yaw it currently faces).
	var head_idx := skel.find_bone("mixamorig_Head")
	if head_idx >= 0:
		var front := global_transform.basis.z
		var base: Vector3 = skel.to_global(
				skel.get_bone_global_pose(head_idx).origin)
		var saved_x: float = _attitude_node.rotation.x
		_attitude_node.rotation.x = 0.3
		var moved: Vector3 = skel.to_global(
				skel.get_bone_global_pose(head_idx).origin) - base
		_attitude_node.rotation.x = saved_x
		# A positive rotation.x that swings the head towards the visual
		# front pitches the nose down — keep it; otherwise flip.
		if moved.length() > 0.001 and moved.dot(front) < 0.0:
			_att_pitch_sign = -1.0
	# Bank sign: the turn should dip the wing it is turning towards.
	var left_idx := skel.find_bone("mixamorig_LeftHand")
	if left_idx >= 0:
		var base_y: float = skel.to_global(
				skel.get_bone_global_pose(left_idx).origin).y
		var saved_z: float = _attitude_node.rotation.z
		_attitude_node.rotation.z = 0.3
		var hand_y: float = skel.to_global(
				skel.get_bone_global_pose(left_idx).origin).y
		_attitude_node.rotation.z = saved_z
		# A positive rotation.z that lowers the left hand dips the left
		# wing — keep it; otherwise flip.
		_att_bank_sign = 1.0 if hand_y < base_y - 0.001 else -1.0


## Builds the "fly" (wing flap) and "fly_glide" (wings spread) clips at
## runtime: the whole body holds the idle pose's first frame while the two
## arm bones get authored wing tracks around the character's forward axis.
func _build_fly_animations() -> void:
	var skel := _find_skeleton()
	if skel == null:
		push_warning("PlayerModel: no Skeleton3D found; wing flight disabled.")
		return
	var idle := anim.get_animation(ANIM_IDLE)
	var lib := anim.get_animation_library("")
	var flap := Animation.new()
	flap.length = 1.0
	flap.loop_mode = Animation.LOOP_LINEAR
	var glide := Animation.new()
	glide.length = 2.0
	glide.loop_mode = Animation.LOOP_LINEAR

	# Static body pose (idle's first frame) for everything except the arms.
	for i in idle.get_track_count():
		var track_path := idle.track_get_path(i)
		if track_path.get_subname_count() > 0:
			var bone := String(track_path.get_subname(0))
			if bone == String(WING_ARM_L) or bone == String(WING_ARM_R):
				continue
		_copy_static_key(idle, i, flap)
		_copy_static_key(idle, i, glide)

	# Authored wing tracks for the two arms (mirrored per side).
	for arm_name in [WING_ARM_L, WING_ARM_R]:
		_add_wing_tracks(skel, arm_name, idle, flap, glide)

	lib.add_animation(ANIM_FLY, flap)
	lib.add_animation(ANIM_FLY_GLIDE, glide)


func _copy_static_key(src: Animation, src_track: int, dst: Animation,
		at_time := 0.0) -> void:
	var type := src.track_get_type(src_track)
	match type:
		Animation.TYPE_POSITION_3D:
			var t := dst.add_track(type)
			dst.track_set_path(t, src.track_get_path(src_track))
			dst.position_track_insert_key(
					t, 0.0, src.position_track_interpolate(src_track, at_time))
		Animation.TYPE_ROTATION_3D:
			var t := dst.add_track(type)
			dst.track_set_path(t, src.track_get_path(src_track))
			dst.rotation_track_insert_key(
					t, 0.0, src.rotation_track_interpolate(src_track, at_time))
		Animation.TYPE_SCALE_3D:
			var t := dst.add_track(type)
			dst.track_set_path(t, src.track_get_path(src_track))
			dst.scale_track_insert_key(
					t, 0.0, src.scale_track_interpolate(src_track, at_time))


## Adds rotation tracks for one arm: raised out to the side (wing_raise_deg)
## and beating up/down, mirrored per side so both wings move together like
## a bird's. The beat axis is chosen as the world axis most perpendicular
## to the arm so it sweeps the wing instead of twisting it, and the lift
## direction is probed with real bone poses.
func _add_wing_tracks(skel: Skeleton3D, arm_name: StringName, idle: Animation,
		flap: Animation, glide: Animation) -> void:
	var arm_idx := skel.find_bone(String(arm_name))
	if arm_idx < 0:
		return
	var hand_idx := skel.find_bone(String(arm_name).replace("Arm", "Hand"))
	if hand_idx < 0:
		return
	var rest_q := skel.get_bone_rest(arm_idx).basis.get_rotation_quaternion().normalized()
	var world_q := skel.get_bone_global_rest(arm_idx).basis.get_rotation_quaternion().normalized()
	var arm_pos: Vector3 = skel.get_bone_global_rest(arm_idx).origin
	var hand_pos: Vector3 = skel.get_bone_global_rest(hand_idx).origin
	var arm_dir := (hand_pos - arm_pos).normalized()

	# Beat axis: the horizontal axis perpendicular to the arm. Rotating
	# around it sweeps the hand straight up/down (a vertical wing beat);
	# around UP it would merely swing the T-pose arm horizontally.
	var axis_world := arm_dir.cross(Vector3.UP)
	if axis_world.length_squared() < 0.01:
		axis_world = Vector3.UP  # degenerate (vertical arm); just fall back
	axis_world = axis_world.normalized()
	var axis := (world_q.inverse() * axis_world).normalized()

	# Probe the lift sign with a real pose update (never trust sign guesses).
	var base_y := hand_pos.y
	skel.set_bone_pose_rotation(arm_idx,
			rest_q * Quaternion(axis, deg_to_rad(25.0)))
	skel.force_update_all_bone_transforms()
	var raised_y: float = skel.get_bone_global_pose(hand_idx).origin.y
	skel.set_bone_pose_rotation(arm_idx, rest_q)
	skel.force_update_all_bone_transforms()
	var raise_sign := 1.0 if raised_y > base_y else -1.0

	var track_path := _bone_track_path(idle, arm_name)

	var flap_t := flap.add_track(Animation.TYPE_ROTATION_3D)
	flap.track_set_path(flap_t, track_path)
	var glide_t := glide.add_track(Animation.TYPE_ROTATION_3D)
	glide.track_set_path(glide_t, track_path)

	var keys := 24
	for k in keys + 1:
		var f := float(k) / float(keys)
		# Full wing beat per loop (one down-up sweep).
		var flap_ang := wing_raise_deg + flap_amplitude_deg * sin(TAU * f)
		flap.rotation_track_insert_key(flap_t, f,
				rest_q * Quaternion(axis, raise_sign * deg_to_rad(flap_ang)))
		# Glide: wings held spread with a gentle slow bob.
		var glide_ang := wing_raise_deg + 4.0 * sin(PI * f)
		glide.rotation_track_insert_key(glide_t, f,
				rest_q * Quaternion(axis, raise_sign * deg_to_rad(glide_ang)))


## Reuses the exact track path the idle clip uses for `bone`, so the wing
## tracks target the same skeleton regardless of node layout.
func _bone_track_path(idle: Animation, bone: StringName) -> NodePath:
	for i in idle.get_track_count():
		var p := idle.track_get_path(i)
		if p.get_subname_count() > 0 and String(p.get_subname(0)) == String(bone):
			return p
	return NodePath("Skeleton3D:%s" % String(bone))


## Public resolver for other systems (footstep FX, audio) that need the
## live skeleton — not the first Skeleton3D in traversal order.
func get_driven_skeleton() -> Skeleton3D:
	return _find_skeleton()


func _find_skeleton() -> Skeleton3D:
	# The skeleton the main AnimationPlayer actually drives (under its
	# root node, i.e. the visible gods1 instance) — NOT the first
	# Skeleton3D in traversal order, which may belong to an
	# animation-source copy (the *Source players hold skinless
	# armatures of their own).
	var anim_root: Node = anim.get_node(anim.root_node)
	var skels: Array = anim_root.find_children("*", "Skeleton3D", true, false)
	if skels.is_empty():
		skels = find_children("*", "Skeleton3D", true, false)
	if skels.is_empty():
		return null
	return skels[0] as Skeleton3D
