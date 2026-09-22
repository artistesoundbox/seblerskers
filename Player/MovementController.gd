extends CharacterBody3D
class_name MovementController

## Classic analog movement controller, updated for Godot 4.
## Handles gravity, jumping, crouching, analog gamepad input and the
## animation state (idle / walk / run / jump / crouch / attack) of the
## attached PlayerModel. Movement direction is relative to the camera (Head).

@export var gravity_multiplier := 3.0
## Ground walking speed (m/s). Sprint.gd raises this while sprinting; the
## torso lean and the controller rumble scale against it.
@export var walk_speed := 4.0
@export var acceleration := 8.0
@export var deceleration := 10.0
@export var air_control := 0.3  # (float, 0.0, 1.0, 0.05)
@export var jump_height := 10.0
## Movement speed multiplier while crouching.
@export var crouch_speed_multiplier := 0.5
## Jump height multiplier while crouching (crouch-jumps launch lower).
@export var crouch_jump_multiplier := 0.6
## Speeds below this count as standing still while crouched (m/s) —
## inside the deadzone the model blends to the standing crouch pose.
@export var crouch_idle_speed := 0.6
## How fast the body turns towards the camera yaw while moving (1/s).
@export var yaw_turn_speed := 12.0
## PlayerModel child that holds the animated character.
@export var model_path := NodePath("Model")
## Head node that owns the camera; movement is camera-relative.
@export var head_path := NodePath("Head")

## --- Flight (bird-style) ---
## Upward acceleration while flapping (jump held), m/s^2.
@export var fly_thrust := 30.0
## Falling acceleration while airborne (gravity is partially countered
## by wing lift while gliding).
@export var fly_lift := 0.4  # fraction of gravity cancelled while gliding
## Horizontal speed while flying (matches the run speed).
@export var fly_speed := 16.0
## How fast flying vertical speed eases (flap bursts feel less jerky).
@export var fly_damping := 2.0
## --- Dive-bomb strike (attack while flying) ---------------------------
## Downward speed the dive accelerates towards (m/s).
@export var dive_terminal_speed := 38.0
## How fast the dive builds to terminal speed (m/s^2).
@export var dive_accel := 85.0
## Horizontal speed kept while diving (0 = straight down strike).
@export var dive_keep_horizontal := 0.15
## --- Dive-glide energy conversion (bird-style) -------------------------
## How much of a glide's lost altitude (m) converts into bonus speed
## (m/s). 0.3 = every 10 m of sink adds 3 m/s of carry.
@export_range(0.0, 1.0) var glide_energy_gain := 0.3
## Maximum bonus speed the glide bank can hold (m/s).
@export var glide_energy_max := 14.0
## How fast the bonus bleeds off while actively flapping (1/s) — flaps
## cost climb power, not free speed.
@export var glide_energy_flap_decay := 2.5
## How fast the bonus bleeds off while flying level with no stick
## input (1/s) — momentum persists; it is not instantly confiscated.
@export var glide_energy_coast_decay := 0.15
## --- Foraging (berries & herbs on bushes) ------------------------------
## Gather reach (m, horizontal to the bush centre).
@export var gather_reach := 2.6
## Gathered food so far this run (berries + herbs).
var food_count := 0
## Emitted after a successful gather (kind, display name, amount).
signal food_gathered(kind: String, food_name: String, amount: int)
## Rising edge latch for the gather action.
var _gather_pressed := false
## The active "gather ..." prompt (shown while a ripe bush is in reach).
var _forage_prompt: Label3D
## --- Sea plane (FUTURE USE) --------------------------------------------
## The visible sea surface height, exported for whatever the ocean
## becomes next (swimming, boats, fishing...). The lethal-water respawn
## is DISABLED: falling into the sea no longer kills, and nothing
## destroys the player on water contact anymore.
@export var water_y := -0.2
## The old lethal-water toggle, kept so the splash/respawn machinery
## survives for future use.
@export var sea_death := false
## Extra seconds to linger at the respawn before controls resume.
@export var respawn_freeze := 0.3
## Viewport flash/light color on a water death (tints the splash).
@export var death_flash_color := Color(0.35, 0.65, 0.95)
var _respawn_timer := 0.0
## --- Live sea-entry splash (water is NOT lethal) ------------------------
## Lowest capsule point (feet) when a splash should fire. A little
## above the surface: this map's sea is an ankle-deep shelf, so the
## capsule center never submerges — the trigger is the FEET crossing
## the waterline while moving downward.
@export var sea_entry_y := water_y + 0.25
## Meters the feet must rise back above the line before another entry
## can fire (stops wave-slap double-fire while wading at the edge).
@export var sea_entry_rearm := 0.5
## Minimum downward speed (m/s) for a splash at all.
@export var sea_entry_min_speed := 0.8
## Cooldown between splashes (s) — deep plunge + bob can cross the
## line many times in a second.
@export var sea_entry_cooldown := 0.5
var _sea_armed := false
var _sea_splash_cd := 0.0
## Headless-verifiable: how many live entry splashes have fired.
var sea_entry_count := 0

## The old sea-death respawn (splash at the surface, then back to the
## spawn point). DISABLED behind `sea_death = false`: the ocean is no
## longer lethal. The machinery is kept intact for future water
## gameplay — flip the flag (or call this directly) to re-enable.
func _check_void() -> void:
	if not sea_death:
		return
	if _respawn_timer > 0.0 or global_position.y > water_y:
		return
	# Splash where the player crossed the surface, not at the respawn.
	var impact := global_position
	var entry_speed := -minf(velocity.y, 0.0) \
			+ Vector2(velocity.x, velocity.z).length()
	global_position = _spawn_transform.origin
	var body_node := get_node_or_null("Collision") as CollisionShape3D
	var disabled := false
	if body_node != null:
		disabled = body_node.disabled
		body_node.set_deferred("disabled", true)
	velocity = Vector3.ZERO
	flying = false
	diving = false
	wing_flapping = false
	dive_energy = 0.0
	sprint_boost = 1.0
	_end_dive_local()
	model.cancel_attack()
	model.stop_flying()
	_respawn_timer = respawn_freeze
	if body_node != null:
		body_node.set_deferred("disabled", disabled)
	_play_splash(impact, entry_speed)


## The underwater muffle: low-pass + tint driven by the CAMERA's
## depth, punched harder the faster the hero enters the sea.
const UnderwaterFXScript := preload("res://Player/UnderwaterFX.gd")
const BreathMeterScript := preload("res://Player/BreathMeter.gd")
const GoldLedgerScript := preload("res://Player/GoldLedger.gd")
const SwimSplashFXScript := preload("res://Player/SwimSplashFX.gd")
## Live FX instance; null until _ready.
var _uw_fx = null
## Swim-stroke ripple FX (hand-bone stroke detector).
var _swim_fx = null
## Camera below the waterline (hysteresis-tracked).
var _cam_sub := false
## --- Breath (dive-loot) ----------------------------------------------------
## Seconds of air while the camera is underwater.
@export var breath_max := 12.0
## Breath refill rate at the surface (per second, fraction).
@export var breath_refill_rate := 2.2
## Current air, 0..1.
var breath := 1.0
## UI readout.
var _breath_meter = null


## --- The hoard's guardian --------------------------------------------------

## A serpent bite: 1 = warning (slam, red flash, air squeezed out);
## 2 = dragged under — the sea takes the hero back to his spawn.
var serpent_bites := 0

func serpent_bite(from: Vector3) -> void:
	serpent_bites += 1
	# The slam: thrown away from the jaws, wet and violent.
	var away := (global_position - from).normalized()
	if away.length_squared() < 0.001:
		away = Vector3.UP
	velocity = away * 7.5 + Vector3(0, 3.0, 0)
	breath = maxf(0.0, breath - 0.5)
	if _uw_fx != null:
		_uw_fx.trigger_punch(12.0)
	if serpent_bites >= 2:
		serpent_bites = 0
		# Dragged under: same machinery as the old sea death — body
		# frozen at the spawn, splash where the soul left the water.
		var impact := global_position
		global_position = _spawn_transform.origin
		var body_node := get_node_or_null("Collision") as CollisionShape3D
		var disabled := false
		if body_node != null:
			disabled = body_node.disabled
			body_node.set_deferred("disabled", true)
		velocity = Vector3.ZERO
		flying = false
		diving = false
		wing_flapping = false
		dive_energy = 0.0
		sprint_boost = 1.0
		_end_dive_local()
		model.cancel_attack()
		model.stop_flying()
		_respawn_timer = respawn_freeze
		if body_node != null:
			body_node.set_deferred("disabled", disabled)
		breath = 1.0
		_play_splash(impact, 9.0)


## Spawns the self-contained splash FX at the crossing point. The FX
## node is independent of the player, so the respawn freeze doesn't
## interrupt its animation.
const WaterSplashScript := preload("res://Player/WaterSplash.gd")


## The live sea entry: fires the splash FX + sound when the player
## hits the water. The trigger is the FEET crossing the waterline
## downward at speed (the capsule center only submerges in deep maps;
## this coast is an ankle-deep shelf). A re-arm band above the line
## plus a cooldown keeps wading/bobbing from double-firing. Skipped
## while sailing (the hull owns the body; the wake foam owns the sea).
func _check_sea_entry() -> void:
	if _sail_host != null and sailing:
		return
	var feet := global_position.y - _capsule_half()
	if not _sea_armed:
		if feet > water_y + sea_entry_rearm:
			_sea_armed = true
		return
	if feet <= water_y + 0.05 and velocity.y < -sea_entry_min_speed \
			and _sea_splash_cd <= 0.0:
		_sea_splash_cd = sea_entry_cooldown
		_sea_armed = false
		sea_entry_count += 1
		var entry_speed := -minf(velocity.y, 0.0) \
				+ Vector2(velocity.x, velocity.z).length()
		_play_splash(global_position, entry_speed)
		# Fast plunge: punch the underwater muffle harder the faster
		# the hit (the splash FX + sound already scale the same way).
		if _uw_fx != null:
			_uw_fx.trigger_punch(entry_speed)


## Underwater camera mood: the muffle FX tracks the CAMERA against
## the waterline (the body can wade while the camera stays dry), with
## hysteresis so a bobbing swimmer doesn't flicker the filter. While
## the camera is DEEP the tint darkens a touch — a dive reads.
func _update_underwater(delta: float) -> void:
	if _uw_fx == null:
		return
	var cam: Camera3D = head.cam
	var cam_y: float = cam.global_position.y if cam != null else global_position.y
	if cam_y < water_y - 0.08:
		_cam_sub = true
	elif cam_y > water_y + 0.02:
		_cam_sub = false
	var depth := clampf((water_y - cam_y) / 3.0, 0.0, 0.3) \
			if _cam_sub else 0.0
	_uw_fx.update(delta, _cam_sub, depth, water_y,
			cam.global_position if cam != null else global_position)


## The diver's lungs: drain while the CAMERA is underwater (a surface
## bobber keeps full air — no punishing people who wade or swim on top).
## Empty lungs push the swimmer UP toward the surface automatically —
## the sea gives you back.
func _update_breath(delta: float) -> void:
	if _breath_meter == null:
		return
	if _cam_sub:
		breath = maxf(0.0, breath - delta / breath_max)
	else:
		breath = minf(1.0, breath + breath_refill_rate * delta)
	_breath_meter.call("show_level", breath, _cam_sub)
	if _cam_sub and breath <= 0.0 and not sailing:
		# Out of air: a firm buoyant shove toward the surface (still
		# player-steerable, just insistent). Fires while SWIMMING and
		# while WADING on a shallow seabed — a drowned walk at 0 air
		# would otherwise be free.
		velocity.y = maxf(velocity.y, 3.6)


## Half height of the capsule collider (the feet sit half-height below
## the body origin).
func _capsule_half() -> float:
	var cs := get_node_or_null("Collision") as CollisionShape3D
	if cs != null and cs.shape is CapsuleShape3D:
		var cap := cs.shape as CapsuleShape3D
		return cap.height * 0.5 + cap.radius
	return 1.0


func _play_splash(at: Vector3, entry_speed: float) -> void:
	if get_tree() == null or get_tree().current_scene == null:
		return
	var splash: Node3D = WaterSplashScript.new()
	get_tree().current_scene.add_child(splash)
	splash.global_position = Vector3(at.x, water_y, at.z)
	splash.setup(entry_speed, death_flash_color)

var direction := Vector3()
var input_axis := Vector2()
var crouching := false
## Bird-style flight mode (toggled with F / Start).
var flying := false
## True while the jump button is held in flight (wing-flapping).
var wing_flapping := false
## Set by Sprint.gd: true while the sprint trigger is held (runs on the
## ground, boosts the fly speed in flight).
var sprinting := false
## Extra speed multiplier set by Sprint.gd while flying and sprinting.
var sprint_boost := 1.0
## Emitted when the character starts an attack.
signal attacked
## Emitted when a dive-bomb strike begins (attack while flying).
signal dive_started
## Node that launches the fireballs at the attack's strike moment.
@export var fireball_cast_path := NodePath("FireballCaster")
@onready var model: PlayerModel = get_node(model_path)
@onready var head: PlayerHead = get_node(head_path)
@onready var fireball_cast: Node = get_node_or_null(fireball_cast_path)
# Get the gravity from the project settings to be synced with RigidBody nodes.
@onready var gravity = (ProjectSettings.get_setting("physics/3d/default_gravity")
		* gravity_multiplier)

## Current ground speed cap; Sprint.gd swaps this between walk and run.
var _speed: float = walk_speed
var _was_on_floor := true
## Peak downward speed of the current fall (m/s) — consumed at
## touchdown to grade how hard the landing was.
var _fall_peak := 0.0
## Peak height (m) of the current fall ABOVE ITS TOUCHDOWN POINT —
## recomputed every frame, so walking off a ledge starts from 0 and
## only climbing counts. Height joins speed in grading landings:
## flight eases the sink (glide damping keeps touch-down speed soft),
## so a long glide-down lands feather-soft by SPEED — but dropping
## from up high is hard on the knees no matter how gently the air
## broke it.
var _fall_peak_height := 0.0
## Seconds spent airborne in the current fall (soft-damped flight
## sinks read as hard when they last long enough).
var _fall_air_time := 0.0
## True once the current airborne stretch included flight mode.
var _fall_from_flight := false
## Walking is the default locomotion; run only while sprint is held.
var _run_requested := false
## Body yaw of the previous physics tick (for the lean's turn rate).
var _prev_yaw := 0.0
## Where the player entered the scene; the void-respawn returns here.
var _spawn_transform := Transform3D.IDENTITY
## True while a dive-bomb strike is in progress.
var diving := false
## Alternate-fire bookkeeping: the attack key while flying alternates
## between a dive-bomb and a mid-flight fireball throw. True while the
## NEXT flying attack press should sling a fireball instead of diving.
var _fly_attack_is_throw := false
## --- Sailing (the flagship longship) ---
## True while aboard: the hull owns this body (deck-anchored).
var sailing := false
## Set by Sailboat.board while the hero sits at the tiller (commander
## mode): the hull drives the seat pose and owns the stroke clock.
var _sail_commander: Node = null
## The Sailboat currently hosting this body (null when ashore).
var _sail_host: Node = null
## Re-arm window (s) after deboarding: the jump/held-swim board path
## may not re-grab the hull for this long. (User report: tapping the
## board button right after hopping off snapped him straight back
## aboard — he had to swim clear before the button was safe.)
var _sail_board_rearm := 0.0
## Board reach: how close the hull must be to offer boarding (m).
const SAIL_BOARD_REACH := 13.0
## Below this depth the world is lost (no surface exists there): the
## controller lifts the hero back into play. The island's terrain
## floor never approaches this, so only real fallout triggers it.
const FALL_RESCUE_Y := -60.0
## --- Swimming (the sea) ---------------------------------------------------
## Water depth (surface minus floor, m) at which wading becomes
## swimming: the swim clip and buoyancy take over below this depth.
## Minimum water depth (m) before the swim clip arms. MEASURED: this
## coast's shelf floor sits only ~0.28 m under the surface (sea at
## -0.5, seabed ~-0.8) — the user wades the whole coast and reads it
## as walking. The gate sits just under the shelf so ANY real water
## swims; only the first splash fringe at the shoreline stays a wade.
@export var swim_depth := 0.22
## Swim speed cap (m/s) — a real crossing pace, not a run on water.
@export var swim_speed := 3.4
## Vertical targets (m/s): the buoyant rise to the surface line, the
## jump-paddle breach and the crouch dive. Applied via move_toward so
## the buoyancy actually lifts the swimmer OFF the seabed (the shelf
## is chest-deep — a damped trickle left him standing on the bottom,
## which read as "walking underwater").
@export var swim_buoy_rise := 2.2
@export var swim_paddle_up := 3.0
@export var swim_dive_down := 3.0
## Acceleration toward those vertical targets (m/s^2).
@export var swim_up_accel := 9.0
@export var swim_down_accel := 7.0
## True while the sea owns the locomotion (deep water, not aboard).
var swimming := false
## The body's floor-snap length, captured at boot — floor snap is
## disabled while swimming (the seabed must not hold the swimmer
## down) and restored the moment land locomotion resumes.
var _floor_snap_default := 0.1
## Current dive-glide energy bonus speed (m/s), charged by sinking in
## glide and spent as extra horizontal speed.
var dive_energy := 0.0


func _ready() -> void:
	# The model reports the attack clip's strike moment; launch the
	# fireball from the right hand then.
	model.attack_cast.connect(_on_attack_cast)
	# The underwater muffle (bus low-pass + viewport tint) rides with
	# the hero for life — punched by fast sea entries.
	_uw_fx = UnderwaterFXScript.new()
	add_child(_uw_fx)
	# The diver's breath gauge (visible only while the camera is down).
	_breath_meter = BreathMeterScript.new()
	add_child(_breath_meter)
	# The plunder: persistent gold total + HUD coin counter. Chests
	# find it through the "gold_ledger" group when they open.
	add_child(GoldLedgerScript.new())
	# Level systems (PropScatter's death-plane sync) find the player
	# through this group.
	add_to_group("player")
	_spawn_transform = global_transform
	_floor_snap_default = floor_snap_length
	_register_gather_input()
	# Swim-stroke splash ripples: foam rings on the sea where the hands
	# plunge, detected from the swim clip's own bone rhythm.
	_swim_fx = SwimSplashFXScript.new()
	add_child(_swim_fx)
	_swim_fx.setup(self)


## The attack input is gated so the elder's scroll (and the pause
## menu) own left-clicks while the mouse is visible — a scroll click
## must never also sling a fireball. Keyboard and gamepad attacks stay
## live: with the mouse free, only a gamepad X / right-trigger press
## counts (checked against the pad's live button/axis state).
## Touch devices get a pass: there is no mouse cursor to fight with,
## the on-screen ATK button is the attack (it feeds a synthetic
## "attack" action through TouchControls).
func can_attack() -> bool:
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		return true
	# Touch device (phone/tablet): there is no mouse cursor to fight
	# with — the on-screen ATK button is the attack.
	if DisplayServer.is_touchscreen_available():
		return true
	# Mouse is visible (the scroll owns clicks): allow pad-only attacks.
	return Input.is_joy_button_pressed(0, JOY_BUTTON_X) \
			or Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) > 0.5


## The attack animation reached its strike: cast a fireball from the
## right hand along the camera aim (the body already snapped to face it).
func _on_attack_cast() -> void:
	if fireball_cast == null:
		return
	var dir: Vector3 = -head.cam.global_transform.basis.z
	var inherit := Vector3(velocity.x, 0.0, velocity.z) * 0.25
	# Mid-flight throws launch from the chest: the wing-beat pose swings
	# the hand behind/below the body, which flung the ball backwards.
	var origin: Vector3 = model.get_cast_origin()
	if flying:
		origin = global_position + Vector3(0.0, 1.2, 0.0)
	fireball_cast.call("cast", origin, dir, inherit)


## Current ground speed cap (Sprint.gd raises it while sprinting).
func current_speed() -> float:
	return _speed


## Registers the gather action (G key / gamepad Back) if the project
## does not define it — keeps the InputMap self-maintaining.
func _register_gather_input() -> void:
	if InputMap.has_action("herb_gather"):
		return
	InputMap.add_action("herb_gather")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_G
	InputMap.action_add_event("herb_gather", key)
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_BACK
	InputMap.action_add_event("herb_gather", pad)


## Foraging: find the nearest ripe bush in reach, show the prompt,
## gather on G / pad Back. Grounded only — you can't pick while flying.
func _update_forage() -> void:
	var best: Node = null
	var best_d := gather_reach
	for f in get_tree().get_nodes_in_group("forage"):
		var n := f as Node3D
		if n == null or n.get("ripe") != true:
			continue
		var d := Vector2(n.global_position.x - global_position.x,
				n.global_position.z - global_position.z).length()
		if d < best_d:
			best_d = d
			best = n
	if best == null or flying or diving:
		_hide_forage_prompt()
		_gather_pressed = false
		return
	_show_forage_prompt(best)
	if Input.is_action_just_pressed("herb_gather") and not _gather_pressed:
		_gather_pressed = true
		var got: Dictionary = best.call("harvest")
		if not got.is_empty():
			food_count += got.food
			food_gathered.emit(got.type, got.name, got.food)
	if Input.is_action_just_released("herb_gather"):
		_gather_pressed = false


## Floating prompt above the ripe bush (built once, reused).
func _show_forage_prompt(bush: Node) -> void:
	if _forage_prompt == null:
		_forage_prompt = Label3D.new()
		_forage_prompt.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_forage_prompt.no_depth_test = true
		_forage_prompt.pixel_size = 0.004
		_forage_prompt.font_size = 34
		_forage_prompt.outline_size = 8
		_forage_prompt.modulate = Color(1, 1, 0.8)
		get_tree().current_scene.add_child(_forage_prompt)
	var dn: String = bush.call("display_name")
	_forage_prompt.text = "G / Back — gather %s" % dn
	var bp: Vector3 = (bush as Node3D).global_position
	var height := 1.3
	var h := bp.y - _ground_y_below(bp)
	if h > 0.1:
		height = h + 0.6
	_forage_prompt.global_position = bp + Vector3(0, height, 0)
	_forage_prompt.visible = true


func _hide_forage_prompt() -> void:
	if _forage_prompt != null:
		_forage_prompt.visible = false


## Ground height under a point with a LONG reach (height meter for
## landing grading): the usual ±5 m probe first, then a far ray that
## reaches the terrain from any flight altitude. Falls far above the
## ground still get a real reference height; over deep water the ray
## misses and the sea level is the reference.
func _ground_far_y(p: Vector3) -> float:
	var near := _ground_y_below(p)
	if near > p.y - 5.0 and near < p.y + 3.0:
		return near
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
			Vector3(p.x, p.y, p.z),
			Vector3(p.x, p.y - 600.0, p.z), 1)
	var hit := space.intersect_ray(params)
	if not hit.is_empty():
		return hit.position.y
	return water_y

## Terrain height under a point (for prompt placement).
func _ground_y_below(p: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
			Vector3(p.x, p.y + 3.0, p.z), Vector3(p.x, p.y - 5.0, p.z), 1)
	var hit := space.intersect_ray(params)
	return hit.position.y if not hit.is_empty() else p.y - 1.0


# Called every physics tick. 'delta' is constant
## True while the title screen owns the game (attract camera): input,
## physics and animation all hold still until Set Sail hands over.
var menu_frozen := false


func _physics_process(delta: float) -> void:
	_respawn_timer = maxf(0.0, _respawn_timer - delta)
	_sail_board_rearm = maxf(0.0, _sail_board_rearm - delta)
	# Below-map fallout rescue: flying or sinking mounts can carry the
	# capsule under the world (player report: through a castle roof).
	# The terrain never dips near this depth, so anything below it is
	# lost — return the hero to the spawn point (instant, back on the
	# island), the same contract as the old void-respawn.
	if global_position.y < FALL_RESCUE_Y:
		global_position = _spawn_transform.origin
		velocity = Vector3.ZERO
		flying = false
		wing_flapping = false
		dive_energy = 0.0
		sprint_boost = 1.0
		_end_dive_local()
		model.cancel_attack()
		model.stop_flying()
		model.sit_pose(false, 0.0, 0.0)
		_respawn_timer = respawn_freeze
		head.clear_helm()
	# Title overlay: the menu owns the game until Set Sail.
	if menu_frozen:
		return
	# Aboard the flagship: the hull owns the body — teleport to the
	# deck anchor, no gravity, no landing grading. Boarding is the
	# same key (jump) that disembarks.
	# Board / disembark is the same key (jump). One handling point so
	# the same frame's press can never board and immediately hop off.
	# The helm-EYES hold (toggle_camera while seated) is consumed here
	# so releasing the hold ashore never flips the walk camera to FP.	# While swimming, a HELD jump also boards — paddling into the hull
	# grabs the gunwale without needing a fresh press (the prompt's
	# "swim to the boat" flow). Gated on not-sailing so holding the
	# key aboard can't re-fire the board call.
	var board_press := _sail_board_rearm <= 0.0 and (
			Input.is_action_just_pressed("jump")
			or (swimming and not sailing
					and Input.is_action_pressed("jump")))
	if board_press and not model.is_attacking():
		if sailing:
			(_sail_host as Sailboat).disembark()
			# Deboard courtesy (user report): the walk camera returns
			# to THIRD PERSON automatically — the oar view parked the
			# zoom at 0 and its stash was never handed back — and the
			# board key cools down so the tap right after hopping off
			# cannot re-grab the hull.
			head.clear_helm()
			_sail_board_rearm = 1.2
		elif not diving:
			# Swimming up to the hull and pressing jump IS the boarding
			# flow (the prompt says so) — the sea must not block it.
			_sail_try_board()
	if _sail_host != null and sailing:
		_sail_physics()
		return
	if not sailing:
		head.helm_boom = 0.0
		head.helm_eyes = false
		head.oar_mode = false
		# The swim camera lift (user request): the head raises the boom
		# while this rides 0..1, so the swimmer reads IN the water, not
		# perched on top of it.
		head.swim_lift = 1.0 if swimming else 0.0
	_check_swim_state()
	_check_void()
	_check_sea_entry()
	_sea_splash_cd = maxf(0.0, _sea_splash_cd - delta)
	_update_underwater(delta)
	_update_breath(delta)
	# Left stick = movement (analog), so use a small action deadzone.
	input_axis = Input.get_vector("move_back", "move_forward",
			"move_left", "move_right", 0.2)

	if Input.is_action_just_pressed("toggle_fly"):
		_toggle_fly()

	# Attack while flying ALTERNATES between the two air strikes: one
	# press dive-bombs, the next (once the dive is over) slings a
	# fireball mid-flight along the camera aim, then the cycle repeats.
	# Pressing it mid-dive pulls out of the dive (wings snap back open,
	# flight continues) WITHOUT spending the throw slot — dive, pull
	# out, and the next press throws. The flag flips only when a strike
	# actually starts, so a refused press (a swing already owning the
	# pose) never desyncs the cycle.
	if flying and Input.is_action_just_pressed("attack") and can_attack():
		if diving:
			_end_dive_local()
		elif _fly_attack_is_throw:
			if _fly_throw():
				_fly_attack_is_throw = false  # next press dives again
		else:
			_start_dive()
			_fly_attack_is_throw = true  # next press throws

	direction_input()

	if swimming:
		_swim_physics(delta)
	elif flying:
		_fly_physics(delta)
	else:
		_walk_physics(delta)

	accelerate(delta)

	move_and_slide()

	_update_forage()

	_update_model(delta)

	var on_floor := is_on_floor()
	if not on_floor:
		_fall_peak = maxf(_fall_peak, -velocity.y)
		# Height above the touchdown point, recomputed every frame so
		# stepping off a ledge starts from 0 and only real height counts.
		_fall_peak_height = maxf(_fall_peak_height,
				global_position.y - _ground_far_y(global_position))
		_fall_air_time += delta
		if flying:
			_fall_from_flight = true
	elif not _was_on_floor:
		# Touchdown: end the jump clip, then grade the landing. Speed
		# ALONE under-grades flight landings (glide damping eases the
		# sink to a soft touch), so height and airtime join the grade —
		# the crouch absorb fires when ANY of them is hard enough, and
		# the model scales the pose depth by the combined severity.
		if model.is_jumping():
			model.finish_jump()
		# Underwater touchdown (flight/dive into the sea): the water
		# already caught this fall — the surface entry splashed through
		# _check_sea_entry, so no dirt thud, dust puff, crack or absorb
		# crouch replays it on the seabed (player: "landing on water
		# should sound water-like"). The fall clock below is consumed
		# silently; swimming arms next frame and buoyancy takes over.
		var water_touch := global_position.y < water_y - 0.25
		# Flight touchdown: move_and_slide lands the body one frame
		# BEFORE _fly_physics sees the floor and toggles flight off —
		# leave flight NOW, or the model's flight guard swallows the
		# landing crouch silently.
		if flying:
			flying = false
			wing_flapping = false
			dive_energy = 0.0
			model.stop_flying()
			_fly_attack_is_throw = false
		var grade: float = maxf(_fall_peak, _fall_air_time * 4.0)
		grade = maxf(grade, _fall_peak_height * (1.8 if _fall_from_flight
				else 1.2))
		if not water_touch:
			model.absorb_landing(_fall_peak, grade)
		_fall_peak = 0.0
		_fall_peak_height = 0.0
		_fall_air_time = 0.0
		_fall_from_flight = false
	_was_on_floor = on_floor


## --- Sailing -------------------------------------------------------------
## While aboard, the hull owns the body: the capsule is teleported to
## the deck anchor every frame (velocity zeroed so the landing grader
## never reads the ride as a fall), gravity is skipped, and the model
## plays the rowing stroke driven by the throttle.
func _sail_physics() -> void:
	velocity = Vector3.ZERO
	global_transform = (_sail_host as Node3D).rider_xf()
	var host: Node = _sail_host
	# --- The helm camera: raised, hull-locked, looking over the bow --
	# The seat is rigid to the hull, so the camera must chase the
	# HULL's azimuth (the wrapper's yaw), not the capsule's (which is
	# deliberately rotation-free while seated). The follow-camera's
	# "behind the body" logic keys off ground motion, which a seated
	# helmsman never reports — so drive it from the hull instead.
	var hull_yaw: float = (host as Node3D).global_rotation.y
	# The seat basis already carries the PI (hero faces the bow), so
	# the head's world yaw must be hull+PI for the spring arm to hang
	# off the hero's BACK. We glue the FOLLOW TARGET to the hull every
	# frame; the head's follow-camera then eases the view back to it
	# whenever nobody is looking — while the right stick or mouse
	# free-look around from the tiller without touching the steering.
	var helm_yaw: float = hull_yaw + PI
	head.sync_body_yaw(helm_yaw)
	# The follow target rides the hull; during the EYES lean the view
	# holds wherever the player is looking (set_body_moving paused).
	head.set_body_moving(not Input.is_action_pressed("toggle_camera"))
	# Raised helm view: the boom parks FURTHER back and higher than the
	# walk camera so the bow, the deck and the water ahead stay framed.
	# Holding the camera toggle (Y / V) while seated leans the camera
	# into the helmsman's eyes — release glides back to the boom.
	if _sail_commander != null:
		# AT THE TILLER (command seat): the classic helm rig — raised
		# boom becalmed, tiller eyes as she gathers way.
		head.oar_mode = false
		head.helm_boom = 4.2
		head.helm_height = 1.35
		# The helm lag and drift swell with hull speed — boosting feels
		# wilder at the tiller than a lazy cruise.
		head.helm_surge = _sail_host.call("surge_amount")
		# Tiller resistance: the rudder hardens with speed (boat-side)
		# and the helm camera leans back a touch against the turn —
		# the pull you feel leaning into a hard rudder.
		head.helm_pull = _sail_host.call("rudder_load")
		head.helm_eyes = Input.is_action_pressed("toggle_camera")
		# Underway camera: as the hull gathers way the camera leans
		# into the tiller eyes — first-person at the raised helm, the
		# same view as holding C — so the bow fills the frame while she
		# moves; when she loses way it glides back to the boom.
		head.helm_underway = clampf(
				(_sail_host as Node).call("speed_now") / 2.4, 0.0, 1.0)
		# Tiller-eyes suspension while the hero ROWS (oar bench): the
		# camera lives at the bench — the hull's speed must not drag
		# the view to the tiller when the seat is the oars.
		if head.oar_mode:
			head.helm_underway = 0.0
	else:
		# AT THE OARS (the C — take an oar seat, the BOARDING DEFAULT):
		# the camera LIVES at the bench — the raised rower's-eyes view
		# (Head.oar_mode). The helm machinery is parked so nothing
		# pulls the view to the tiller while you row; your own stroke
		# dips the frame.
		head.oar_mode = true
		head.helm_boom = 0.0
		head.helm_height = 0.0
		head.helm_eyes = false
		head.helm_underway = 0.0
		head.helm_surge = 0.0
		head.helm_pull = 0.0
		# Keep the follow target glued to the hull heading here too:
		# set_body_moving(false) parks the follow cam mid-swing, which
		# at the bench read as a locked sideways gaze. True lets the
		# (slowed) helm follow ease the view to the bow — free look
		# (right stick / mouse) still decouples exactly like at the
		# tiller.
		head.set_body_moving(not Input.is_action_pressed("toggle_camera"))
	var throttle: float = absf(Input.get_axis("move_back", "move_forward"))
	if _sail_commander != null:
		# Seated at the tiller: the boat drives the pose each frame
		# (rudder as torso lean, speed as forward intent).
		model.set_rowing(0.0)
		var cmd: Node = _sail_commander
		model.sit_pose(true, float(cmd.get("_turn")),
				float(cmd.get("_speed")))
		return
	model.set_rowing(throttle)


## Boarding: the nearest sailable hull within reach, if any. A dive
## onto the deck cancels the dive first; flight is handed off too.
func _sail_try_board() -> void:
	var best: Node3D = null
	var best_d := SAIL_BOARD_REACH
	for n in get_tree().get_nodes_in_group("sailboat"):
		var n3 := n as Node3D
		if n3 == null:
			continue
		var d := Vector2(n3.global_position.x - global_position.x,
				n3.global_position.z - global_position.z).length()
		if d < best_d:
			best_d = d
			best = n3
	if best != null:
		if diving:
			_end_dive_local()
		model.cancel_attack()
		best.call("board", self)


## The seated commander pose (driven by Sailboat every physics frame
## while the hero sits at the tiller; cleared on disembark).
func _commander_clear() -> void:
	model.sit_pose(false, 0.0, 0.0)


## --- Swimming -------------------------------------------------------------
## Water depth drives the walk/swim border: shallow shelf = wading
## (walk physics, splash FX untouched), deep sea = the swim clip with
## buoyancy. Exiting the water (shore, boarding the flagship, diving
## out of flight) restores the land poses automatically.
func _check_swim_state() -> void:
	if _sail_host != null and sailing:
		swimming = false
		return
	# Seabed probe: walkable layers plus the soft-flora bit — offshore
	# the floor can live on the heightfield alone, so mask everything
	# the terrain uses or the depth reads bogus and swimming never arms.
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(global_position.x, global_position.y + 3.0, global_position.z),
			Vector3(global_position.x, global_position.y - 600.0,
					global_position.z), 1 | 2 | 16)
	# The probe starts above the body and passes straight down through
	# it — without excluding self, the ray "lands" on the hero's own
	# capsule head and the depth gate only passes ~3 m underwater.
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	# No seabed within 600 m = open deep water (the shelf falls away
	# into bottomless sea past the heightfield) — treat depth as very
	# deep so the swim state arms at the surface out there.
	var floor_y: float = (hit.position as Vector3).y \
			if not hit.is_empty() else water_y - 99.0
	var depth := water_y - floor_y
	# Chest-deep gate: keyed on a band ABOVE the waterline (not the
	# body line itself), so a buoyant swimmer bobbing at the surface
	# never flickers back to walk physics mid-stroke. Exiting to land
	# still works: the seabed rises, depth fails the gate.
	swimming = global_position.y < water_y + 1.0 and depth > swim_depth \
			and not flying
	# Seabed unstick: floor snap would pin the swimmer to the bottom.
	floor_snap_length = 0.0 if swimming else _floor_snap_default


func _toggle_fly() -> void:
	if model.is_attacking():
		return
	if diving:
		# Toggling out of flight cancels an active dive.
		_end_dive_local()
	# A swing caught mid-throw dies with the flight (see cancel_attack).
	model.cancel_attack()
	flying = not flying
	if flying:
		crouching = false
		model.stop_crouch()
		wing_flapping = false
		_fly_attack_is_throw = false  # fresh flight opens with the dive
		model.play_fly()
		# A little wing-beat to get airborne.
		velocity.y = jump_height * 0.6
	else:
		# Landing/toggle-off spends the whole bank.
		dive_energy = 0.0
		_fly_attack_is_throw = false
		model.stop_flying()


## Swim physics: the vertical axis is target-driven — buoyancy lifts
## the swimmer off the seabed and holds him at the surface line (a
## gentle bob around it), jump paddles up to a breach, crouch dives.
func _swim_physics(delta: float) -> void:
	# Idle float target: slightly BELOW the waterline so the surface
	# plane cuts through the body — the swimmer rides IN the sea, not
	# perched on top of it (player: "looks like hes swimming above
	# the water"). Holding jump still breaches well clear of it.
	var surface_band := water_y - 0.15
	var target_vy := 0.0
	if Input.is_action_pressed("jump"):
		target_vy = swim_paddle_up
		# Held jump can't launch the swimmer out of the sea: once the
		# chest is clear of the line, the breach tops out.
		if global_position.y > surface_band + 0.9:
			target_vy = 0.5
	elif Input.is_action_pressed("crouch"):
		target_vy = -swim_dive_down
	elif global_position.y < surface_band:
		target_vy = swim_buoy_rise
	var accel := swim_up_accel if target_vy > velocity.y \
			else swim_down_accel
	velocity.y = move_toward(velocity.y, target_vy, accel * delta)
	velocity.y = clampf(velocity.y, -4.0, 3.0)


func _walk_physics(delta: float) -> void:
	if is_on_floor():
		if velocity.y < 0:
			velocity.y = 0

		if Input.is_action_just_pressed("jump"):
			velocity.y = jump_height * (crouch_jump_multiplier if crouching else 1.0)
			crouching = false
			model.stop_crouch()
			model.start_jump()
		else:
			crouching = (Input.is_action_pressed("crouch")
					and not model.is_attacking() and not model.is_jumping())
	else:
		velocity.y -= gravity * delta
		# Airborne under walk physics: the fall clock runs here too.
		_fall_air_time += delta


func _fly_physics(delta: float) -> void:
	if is_on_floor() and velocity.y <= 0.0:
		# Touched down: land and leave flight mode. from_flight tells
		# the touchdown grader this fall came out of the air under
		# flight physics.
		if diving:
			_end_dive_local()
		_toggle_fly()
		return
	if diving:
		_dive_physics(delta)
		return
	wing_flapping = Input.is_action_pressed("jump")
	if wing_flapping:
		velocity.y += fly_thrust * delta
		# Flapping spends the bank: climb power is not free speed.
		dive_energy = maxf(0.0, dive_energy \
				- glide_energy_flap_decay * delta)
	else:
		# Glide: wings out, partial lift against gravity.
		velocity.y -= gravity * (1.0 - fly_lift) * delta
		# Gliding charges the bank: every meter of sink converts into
		# bonus horizontal speed (glide_energy_gain 0.3 = 10 m of sink
		# adds 3 m/s of carry), capped at glide_energy_max.
		dive_energy = minf(glide_energy_max, dive_energy \
				+ maxf(0.0, -velocity.y) * glide_energy_gain * delta)
	# Ease vertical speed so flap bursts feel smooth instead of jerky.
	velocity.y = lerpf(velocity.y, 0.0, minf(1.0, fly_damping * delta * 0.5))
	velocity.y = clampf(velocity.y, -25.0, 12.0)


## Dive-bomb physics: fold into a fast downward strike. The wings tuck,
## so lift is gone — the plunge accelerates to terminal speed while the
## horizontal speed bleeds away, ending on ground contact.
func _dive_physics(delta: float) -> void:
	velocity.y = move_toward(velocity.y, -dive_terminal_speed,
			dive_accel * delta)


## Mid-flight fireball: plays the attack swing in the air and lets the
## normal strike-moment pipeline sling it (same cast, same camera aim
## as a ground swing). Returns false when the model refuses (a swing or
## dive already owns the pose) — the alternation flag then stays put so
## the next press still gets the throw.
func _fly_throw() -> bool:
	if not model.play_attack():
		return false
	# Face the camera direction instantly, like a ground swing.
	rotation.y = head.rot.y
	head.sync_body_yaw(rotation.y)
	attacked.emit()
	return true


## Starts the dive-bomb strike. Only meaningful while flying.
func _start_dive() -> void:
	if not model.start_dive():
		return
	diving = true
	wing_flapping = false
	dive_started.emit()


## Ends an active dive without landing (pull-out, flight toggle, impact).
func _end_dive_local() -> void:
	if not diving:
		return
	diving = false
	model.finish_dive()


func _update_model(delta: float) -> void:
	# Report motion to the model's additive torso lean. Forward speed is
	# projected on the body's own forward axis so backpedaling leans back.
	var forward_speed := -(velocity.x * transform.basis.z.x
			+ velocity.z * transform.basis.z.z)
	var yaw_rate := angle_difference(_prev_yaw, rotation.y) \
			/ maxf(delta, 0.0001)
	_prev_yaw = rotation.y
	var up_accel := 0.0
	if not is_on_floor() and velocity.y > 0.0 and not flying:
		up_accel = gravity  # takeoff frame
	model.set_motion_state(forward_speed, yaw_rate,
			not is_on_floor() and not flying, up_accel,
			sprinting and not flying, crouching and not flying)

	if swimming:
		# The swim clip owns the pose; the body faces the stroke
		# direction like a land walk.
		var move_dir := Vector3(velocity.x, 0.0, velocity.z)
		var spd := move_dir.length()
		if spd > 0.5 and not model.is_attacking() and not head.is_free_looking() \
				and not head.is_first_person():
			rotation.y = lerp_angle(rotation.y, atan2(-move_dir.x, -move_dir.z),
					minf(1.0, yaw_turn_speed * delta))
			head.sync_body_yaw(rotation.y)
			head.set_body_moving(true)
		else:
			head.set_body_moving(false)
		model.play_swim(spd, Input.is_action_pressed("crouch"))
		return

	if flying:
		# Bird-like attitude: vertical speed pitches the body, yaw rate
		# banks it into the turn (the dive overrides both in the model).
		# The throw swing rides the flight attitude instead of standing
		# the body upright mid-air.
		model.set_flight_attitude(velocity.y, yaw_rate)
		# While diving, the dive clip owns the character (and the body yaw
		# is frozen at the strike direction). During a mid-flight throw,
		# the swing clip owns the pose but yaw stays steerable.
		if not model.is_attacking() and not model.is_diving():
			var move_dir := Vector3(velocity.x, 0.0, velocity.z)
			if move_dir.length() > 0.5:
				rotation.y = lerp_angle(rotation.y, atan2(-move_dir.x, -move_dir.z),
						minf(1.0, yaw_turn_speed * delta))
				head.sync_body_yaw(rotation.y)
				head.set_body_moving(true)
			else:
				head.set_body_moving(false)
			model.play_fly(move_dir.length(), wing_flapping)
		return

	if model.is_jumping():
		head.set_body_moving(false)
		return  # The jump clip owns the character until landing.

	if model.absorbing_landing():
		head.set_body_moving(false)
		return  # The absorb crouch owns the pose until it eases out.

	if Input.is_action_just_pressed("attack") and is_on_floor() and can_attack():
		if model.play_attack():
			attacked.emit()
			# Face the camera direction instantly during the swing.
			rotation.y = head.rot.y
			head.sync_body_yaw(rotation.y)

	var ground_speed := Vector2(velocity.x, velocity.z).length()
	var moving := is_on_floor() and ground_speed > 0.5

	if crouching:
		# The crouch speed cap is applied in accelerate(); the animation gets
		# the real ground speed so its stride matches the actual movement.
		model.play_crouch(ground_speed if ground_speed > crouch_idle_speed else 0.0)
		head.set_body_moving(false)
	elif moving:
		_run_requested = sprinting
		var move_dir := Vector3(velocity.x, 0.0, velocity.z).normalized()
		if not model.is_attacking() and not head.is_free_looking() \
				and not head.is_first_person():
			# Turn the body towards the actual movement direction. Suppressed
			# while free-looking so strafing keeps the camera decoupled.
			rotation.y = lerp_angle(rotation.y, atan2(-move_dir.x, -move_dir.z),
					minf(1.0, yaw_turn_speed * delta))
			head.sync_body_yaw(rotation.y)
		# Backpedal = moving towards the camera: the camera should not
		# swing around to the front in that case.
		var to_cam: Vector3 = head.cam.global_position - global_position
		to_cam.y = 0.0
		var backpedaling := move_dir.dot(to_cam.normalized()) > 0.6
		head.set_body_moving(true, backpedaling)
		# Pick the locomotion clip whose natural stride best matches the
		# ground speed, so footfalls stay in rhythm with actual movement.
		if _run_requested:
			model.play_run(ground_speed)
		else:
			model.play_walk(ground_speed)
	else:
		model.play_idle()
		head.set_body_moving(false)


func direction_input() -> void:
	direction = Vector3()
	# Movement is relative to the camera, not the body.
	var aim: Basis = head.global_transform.basis
	direction = -aim.z * input_axis.x + aim.x * input_axis.y
	direction.y = 0
	direction = direction.normalized()


func accelerate(delta: float) -> void:
	# Using only the horizontal velocity, interpolate towards the input.
	var temp_vel := velocity
	temp_vel.y = 0

	var temp_accel: float
	var target_speed := fly_speed if flying else _speed
	if swimming:
		# A real crossing pace — no running on water.
		target_speed = swim_speed
	var target: Vector3 = direction * target_speed
	if crouching:
		target *= crouch_speed_multiplier

	if flying:
		target *= sprint_boost
		# The dive-glide bank: the charged bonus joins the speed target,
		# scaling with how much stick you're giving (full stick spends it
		# into your heading; released stick coasts on stored speed).
		if dive_energy > 0.0:
			var stick := direction.length()
			if stick > 0.1:
				target += direction * (dive_energy * clampf(stick, 0.0, 1.0))
			else:
				# Stick released: don't brake a swoop with zero input —
				# hold the current speed so the bird coasts on its bank.
				target = temp_vel

	if direction.dot(temp_vel) > 0:
		temp_accel = acceleration
	else:
		temp_accel = deceleration

	if not is_on_floor():
		temp_accel *= air_control

	temp_vel = temp_vel.lerp(target, temp_accel * delta)

	velocity.x = temp_vel.x
	velocity.z = temp_vel.z

	# Bank decay while coasting with no stick input (the decay lives
	# here because that's where stick state is known). Flap decay runs
	# in _fly_physics; landing resets the bank in _toggle_fly.
	if flying and direction.length() <= 0.1:
		dive_energy = maxf(0.0, dive_energy - glide_energy_coast_decay * delta)
