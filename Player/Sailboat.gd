class_name Sailboat
extends Node3D
## The flagship: one of the moored longships converted at placement
## into a sailable vessel. Swim (or wade — this map's sea is a shallow
## shelf) up to the hull and press Space to board; row with WASD / the
## left stick, steer with A/D, back-water with S to brake, and hop off
## anywhere with Space. The hull stops when the bow sounds less than
## DRAFT under the waterline — a longship runs aground instead of
## climbing beaches.
##
## The wrapper (this node) carries the placement scale and the ride:
## yaw steering, a heel into turns, a slight bow-up pitch with speed,
## and the shared swell clock so the flagship bobs exactly like the
## moored ships. The player body is anchored to a deck spot in
## wrapper space (top_level, so no inherited scale ever touches the
## capsule) and inherits the yaw + rock — steering feels physical.

const MAX_SPEED := 5.5            # m/s rowing cruise
const ACCEL := 1.6                # m/s^2 at full stroke
const TURN_RATE := 0.85           # rad/s at full rudder
## Tiller resistance: past 80% of cruise speed the rudder drag
## hardens, easing to this much extra resistance at the boost
## ceiling — the water fights the blade as the hull pulls.
const RUDDER_DRAG := 0.35
const DRAG := 0.55                # water drag (1/s, exponential)
## --- Stern trail (the lingering wake) ------------------------------------
const TRAIL_LIFE := 12.0         # s a foam patch survives (the linger)
const TRAIL_HOLD := 7.0          # s of continuous emission after way dies
const TRAIL_EASE_S := 3.0        # s the emission eases out at the end
const BRAKE := 1.8                # back-water deceleration
const DRAFT := 0.20               # aground when bow ground is above sea-DRAFT
## (This map's shelf bottoms out ~0.28 m below the surface near the
## coast, so the draft must fit under that or the flagship could
## never hug the shoreline.)
const BOARD_REACH := 13.0         # board distance from the ship origin (m)
const AGROUND_DEPTH := 0.25       # bow water shallower than this = aground
## Right-trigger rowing boost (Sprint.gd forwards the trigger while
## sailing): 1.5x cruise, same multiplier as the flight boost.
const BOOST_MULT := 1.5
## The viking crew (built in setup(), once the placement scale is
## known — every deck offset is model units scaled at build time).
const CREW_SCRIPT := preload("res://Player/ShipCrew.gd")
## The water voice: hull wash loop + oar plinks (built in setup()).
const SAIL_AUDIO_SCRIPT := preload("res://Player/SailAudio.gd")
## The three warrior GLBs the crew is dressed from.
const CREW_MODELS := [
	"res://viking_warrior.glb",
	"res://warrior_of_the_north.glb",
	"res://viking_lowpoly.glb",
]
## Deck/oar reference points in MODEL units (scaled by _scl at use):
## hull floor ~1.15 up, rower sits forward of the mast, oar tips reach
## ~9.5 units out along the hull's long axis.
## The bilge floor sits just above the hull bottom (model units).
const BILGE_MODEL_Y := 0.5
const DECK_MODEL_Y := 1.15
const RIDER_MODEL := Vector3(0.0, DECK_MODEL_Y, 1.2)
const OAR_MODEL_Z := 6.0
## The helmsman's bench at the stern (the commander's seat). Sunk by
## the crew's SIT_SINK so the seated hero's hips meet the bench.
const HELM_BENCH := Vector3(0.0, DECK_MODEL_Y - 0.55, -2.6)

## Ride state (the MovementController reads "_sail_host" on itself).
var _rider: Node = null
var _vel := Vector3.ZERO
var _speed := 0.0
var _yaw := 0.0
var _pitch := 0.0
var _roll := 0.0
## Placement data handed in by PropScatter.
var _sea := 0.0
var _bottom_y := 0.037
var _aground_amt := 0.0
var _scl := 1.0
var _swell := Callable()
var _hull: StaticBody3D
## Bilge floor: a shallow wooden deck over the open hull so the sea
## plane no longer glows through the planking at rider eye level
## (the "flooded with water or fog" interior). Built with the hull.
var _bilge: MeshInstance3D
var _prompt: Label
var _creak: AudioStreamPlayer
var _marker_beam: MeshInstance3D
var _last_prompt := ""
var _turn := 0.0
## Eased rudder-drag load 0..1 (the tiller resistance readout).
var _rudder_load := 0.0
## Sprint-trigger rowing boost (eased 0..1 so the surge is smooth).
var _boost := false
var _boost_amt := 0.0
## --- Water FX -----------------------------------------------------------
## Bow wake: two spray emitters at the stem tips (a V of foam trailing
## the hull). Emission rate, particle size and spray speed all scale
## with hull speed; silent at rest.
var _wake: Array[GPUParticles3D] = []
## Oar splashes: one-shot bursts at the oar entries, fired from the
## model's row_stroke signal (synced to the true rowing clip phase).
var _splash: Array[GPUParticles3D] = []
var _splash_active := 0
## Stern foam trail: long-lived world-space emitters at the quarters.
## Particles shed into WORLD space as the hull passes, so the wake
## line lingers behind the ship for many seconds before dissolving.
var _trail: Array[GPUParticles3D] = []
## Lives one hold after the throttle stops, then a short ease-out —
## so the trail lingers, then dissolves instead of popping off.
var _trail_hold := 0.0
var _trail_ease_t := 0.0
## The viking crew (rowers + helmsman) living on the deck.
var _crew: Node = null
## The water voice (wash loop + oar plinks).
var _sail_audio: Node = null
## Chests the crew has already cheered (instance ids).
var _cheered := {}
## Cooldown for the cheap chest-cheer scan.
var _chest_scan := 0.0
## Number of splash bursts fired this session (headless-verifiable:
## GPUParticles3D.emitting doesn't reflect one-shot emission under the
## dummy RenderingServer, so tests count events, not emission state).
var splash_count := 0
## The rider's model while its row_stroke is connected (null otherwise).
var _row_model: Node = null
## Commander mode: the rider is seated at the helm. The model plays a
## seated pose, the boat owns the stroke clock, and the camera rides
## behind the tiller. Toggleable aboard with crouch/C (row bench
## <-> command seat). BOARDING DEFAULTS TO THE OAR BENCH (user
## request): board() starts this FALSE, so the camera lives at the
## rowing bench the moment you hop aboard; C swaps up to the tiller.
var _commander := false
## Boat-side stroke beat (substitute for the seated rider's clip).
var _beat_t := 0.0
var _beat_side := 1
## Current beat effort (from throttle), handed to the stroke event.
var _beat_effort := 0.0
## The turn value fed to the crew each frame (for idle snap-back).
var _crew_turn := 0.0
## --- Ship dressing (rigging, furled sail, lantern) ----------------------
## Rigging stays (the hangers: shield rail, masthead, stern post).
var _rigging: Array[MeshInstance3D] = []
## The furled sail bundle lashed to the yard.
var _sail_bundle: Node3D = null
## --- The unfurled sail (boost state) -------------------------------------
## Holding the sprint trigger unrolls the bundle: the lashes slip off,
## the cloth drops from the yard and billows aft — and furls again
## when the boost ends. State: "furled" | "unfurling" | "unfurled"
## | "furling"; _sail_t runs 0 (furled) .. 1 (unfurled).
var _sail_node: Node3D = null
var _sail_seg: Array[MeshInstance3D] = []
var _sail_lash: Array[MeshInstance3D] = []
var _sail_mat: StandardMaterial3D = null
var _sail_rope_mat: StandardMaterial3D = null
var _sail_state := "furled"
var _sail_t := 0.0
var _sail_wave := 0.0
var _sail_billow := 0.0
## The unfurled cloth hangs SAIL_CLOTH_H below the yard, reaching
## SAIL_CLOTH_W along it (model units; scaled by _scl at use).
const SAIL_YARD_Y := 3.28
const SAIL_YARD_Z := 0.7
const SAIL_CLOTH_H := 1.85
const SAIL_CLOTH_W := 1.7
const SAIL_UNFURL_S := 1.1        # s bundle -> full cloth
const SAIL_FURL_S := 0.9          # s cloth -> bundle
const SAIL_SEGMENTS := 4
## The lantern: a small body, a warm lamp mesh, and its light.
var _lantern_light: OmniLight3D = null
var _lantern_lamp: MeshInstance3D = null
## Lantern swing state (the lamp hangs on a short line from the
## stern post; it sways with the hull's heel and turning).
var _lantern_pivot: Node3D = null
var _lantern_swing := 0.0
## Last night gate fed to the lantern (cached for the flicker).
var _night_gate := 0.0
## The lantern flame gutters while the boost surges: a surge clock
## drives flicker depth and a fast bright jitter, the swing grows
## wide, and the flame bends aft on its line with the ship's speed.
var _gutter_t := 0.0
var _gutter_chaos := 0.0
## The lantern's composed light factor (night gate × flicker ×
## gutter), exposed for tooling/tests — the light chases this.
var _lantern_want := 1.0
## The gutter multiplier alone (1.0 when calm, >1 on surge) —
## separated from the base flicker so tests can read the surge.
var _lantern_gutter := 1.0


## PropScatter hands in the sea level, the model-space hull-bottom Y,
## the solved placement scale and the shared swell-y callable, so the
## flagship rides the exact same water as the shader and the moored
## ships.
func setup(sea: float, bottom_y: float, scl: float, swell: Callable) -> void:
	_sea = sea
	_bottom_y = bottom_y
	_scl = scl
	_swell = swell
	# The crew needs the solved scale (deck offsets are model units),
	# so it is built here rather than in _ready().
	_crew = Node3D.new()
	_crew.set_script(CREW_SCRIPT)
	add_child(_crew)
	_crew.call("build", _scl, CREW_MODELS)
	# The water voice rides the hull too.
	_sail_audio = Node3D.new()
	_sail_audio.set_script(SAIL_AUDIO_SCRIPT)
	add_child(_sail_audio)
	# ... and the stern trail emitters.
	_build_trail()
	# ... and the dressing: rigging, furled sail, lantern.
	_build_dressing()


func _ready() -> void:
	# The boarding scan (MovementController._sail_try_board) finds the
	# flagship through this group.
	add_to_group("sailboat")
	# DayNight broadcasts the night factor here; the lantern obeys.
	add_to_group("night_lights")
	# Hull collision: the ship's own moving StaticBody (layer 1 = the
	# world's "Objects" layer the player mask already includes), so
	# the deck is walkable and fireballs burst on the hull. The shape
	# is built from the model's own meshes right here — a shared static
	# cache, and NO reference to PropScatter (it preloads this script;
	# a back-reference would be a cyclic load and kill the boot).
	var glb := _find_model_child()
	_hull = StaticBody3D.new()
	_hull.name = "Hull"
	_hull.collision_layer = 1
	_hull.collision_mask = 0
	var cs := CollisionShape3D.new()
	if glb != null:
		cs.shape = _hull_shape_for(glb)
		# The shape is model-space (gathered WITHOUT the model root's
		# own transform) — re-apply that local transform here so the
		# hull exactly envelops the visual model (the placement scale
		# lives on the GLB child, not on this wrapper).
		cs.transform = glb.transform
	else:
		var box := BoxShape3D.new()
		box.size = Vector3(3.4, 2.7, 8.0)
		cs.shape = box
		cs.position = Vector3(0.0, 1.35, 0.0)
	_hull.add_child(cs)
	add_child(_hull)
	# Bilge floor: a shallow wooden deck over the open hull so the sea
	# plane cannot glow through the planking at rider eye level (the
	# "flooded with water or fog" interior). Opaque dark wood, model
	# units scaled by the placement scale.
	# Interior liner: a shallow wooden TUB over the open hull — floor
	# plus side walls — so the sea plane cannot glow through the
	# planking at rider eye level (the "flooded with water or fog"
	# interior). Single-sided GLB hulls are invisible from inside
	# (backface culling), so without walls the eye reads straight
	# through the far planking to the water behind it. The tub is
	# free-standing inside the hull: dark planking from inside,
	# occluded from outside, no z-fighting with the model.
	_bilge = MeshInstance3D.new()
	_bilge.name = "BilgeLiner"
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.30, 0.21, 0.12)
	bmat.roughness = 0.95
	for face in _liner_faces():
		var box := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = face[0]
		box.mesh = bm
		box.material_override = bmat
		box.position = face[1]
		box.scale = Vector3.ONE * _scl
		_bilge.add_child(box)
	_bilge.position = Vector3(0.0, BILGE_MODEL_Y * _scl, 0.0)
	add_child(_bilge)
	if _yaw == 0.0:
		_yaw = rotation.y
	# Prompt: one center-bottom Label, visible only within reach.
	_prompt = Label.new()
	_prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.anchor_left = 0.0
	_prompt.anchor_right = 1.0
	_prompt.anchor_top = 1.0
	_prompt.anchor_bottom = 1.0
	_prompt.offset_top = -110.0
	_prompt.offset_bottom = -70.0
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 22)
	_prompt.add_theme_color_override("font_color", Color(0.98, 0.94, 0.82))
	_prompt.add_theme_color_override("font_shadow_color",
			Color(0.0, 0.0, 0.0, 0.85))
	_prompt.add_theme_constant_override("shadow_offset_y", 2)
	_prompt.hide()
	var cl := CanvasLayer.new()
	cl.layer = 10
	cl.add_child(_prompt)
	add_child(cl)
	# Hull creak: a seamless synthesized wood-groan loop whose level
	# follows speed and rudder work — the ship talks when worked hard.
	_creak = AudioStreamPlayer.new()
	_creak.stream = _make_creak_stream()
	_creak.volume_db = -60.0
	add_child(_creak)
	_creak.play()
	# Marker: a soft golden light column over the flagship so the
	# sailable ship is unmistakable from shore (moored fleet has none).
	var beam := MeshInstance3D.new()
	beam.name = "MarkerBeam"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.3
	cyl.bottom_radius = 0.8
	cyl.height = 12.0
	cyl.radial_segments = 14
	cyl.rings = 1
	beam.mesh = cyl
	beam.position = Vector3(0.0, 6.0, 0.0)
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	bm.albedo_color = Color(1.0, 0.85, 0.35, 0.16)
	bm.emission_enabled = true
	bm.emission = Color(1.0, 0.8, 0.3)
	bm.emission_energy_multiplier = 1.4
	bm.cull_mode = BaseMaterial3D.CULL_DISABLED
	bm.no_depth_test = false
	beam.material_override = bm
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(beam)
	_marker_beam = beam
	_build_water_fx()


func _physics_process(delta: float) -> void:
	var thrust := 0.0
	_turn = 0.0
	if _rider != null and is_instance_valid(_rider) \
			and _rider.get("sailing") == true:
		thrust = Input.get_axis("move_back", "move_forward")
		# Screen-right check: the helm camera looks along the bow (+Z
		# local), where world +X sits on the screen's LEFT — so a right
		# rudder input must SUBTRACT from yaw to swing the bow right.
		# Flipping here keeps heel, crew lean and seat lean coherent.
		_turn = -Input.get_axis("move_left", "move_right")
		if _commander:
			# Seated at the tiller, the hero COMMANDS the stroke: the
			# beat effort follows the stick even when held at zero
			# throttle (oars drag, the hull glides on its way).
			_beat_effort = clampf(thrust, 0.0, 1.0)
			thrust = maxf(thrust, 0.0)
	else:
		_rider = null

	# --- Steering with inertia -----------------------------------
	# The sprint trigger surges the rowing (eased in/out; it only
	# means anything while actually pulling forward).
	_boost_amt = lerpf(_boost_amt,
			1.0 if (_boost and thrust > 0.0) else 0.0, 4.0 * delta)
	var max_spd := MAX_SPEED * (1.0 + (BOOST_MULT - 1.0) * _boost_amt)
	if _turn != 0.0:
		# A rudder bites harder with way on: parked turning is slow.
		# Tiller resistance: past 90% of cruise the drag band hardens
		# (full resistance by ~7.7 m/s, well under the boost ceiling)
		# — heavier rudder at speed, eased so it never snaps.
		var load := clampf((_speed - 0.9 * MAX_SPEED) / (0.5 * MAX_SPEED),
				0.0, 1.0)
		_rudder_load = lerpf(_rudder_load, load, minf(1.0, 5.0 * delta))
		_yaw += _turn * TURN_RATE * delta \
				* (0.45 + 0.55 * _speed / MAX_SPEED) \
				* (1.0 - RUDDER_DRAG * _rudder_load)
	else:
		_rudder_load = lerpf(_rudder_load, 0.0, minf(1.0, 5.0 * delta))
	# Seat toggle aboard: crouch / C swaps between the command seat
	# (tiller, boat-owned stroke beat) and the rowing bench (the hero's
	# own rowing clip drives the rhythm like it used to).
	if _rider != null and _rider.get("sailing") == true \
			and Input.is_action_just_pressed("crouch"):
		set_commander(not _commander)
	var fwd := Vector3(0.0, 0.0, 1.0).rotated(Vector3.UP, _yaw)
	# --- Hull contact: the world pushes back -------------------------
	_vel = _hull_contact_slide(delta)
	# --- Shallow-water guard ---------------------------------------
	# Bow seabed too high = aground: forward thrust washes out and a
	# gentle stern drift nudges the hull back toward deeper water, so
	# she can no longer be rowed almost inland.
	var bow_ground := _depth_ahead()
	var deep_ahead := bow_ground < _sea - AGROUND_DEPTH
	_aground_amt = lerpf(_aground_amt, 0.0 if deep_ahead else 1.0,
			minf(1.0, (2.5 if deep_ahead else 4.0) * delta))
	if _aground_amt > 0.01 and thrust > 0.0:
		thrust *= 1.0 - _aground_amt
		_vel -= fwd * _aground_amt * 1.5 * delta
	if thrust > 0.0 and _speed < max_spd and deep_ahead:
		_vel += fwd * thrust * ACCEL * (1.0 + 0.6 * _boost_amt) * delta
	elif thrust < 0.0:
		# Backing water: brake hard, then a gentle astern push, capped.
		_vel *= exp(-BRAKE * delta)
		if _speed < 1.2:
			var v_back := _vel.dot(fwd)
			if v_back > -1.0:
				_vel -= fwd * ACCEL * 0.5 * delta
	else:
		_vel *= exp(-DRAG * delta)
	_speed = Vector2(_vel.x, _vel.z).length()
	position.x += _vel.x * delta
	position.z += _vel.z * delta

	# --- The ride: swell + heel + bow pitch ----------------------
	var sy := 0.0
	if _swell.is_valid():
		sy = _swell.call(position.x, position.z)
	position.y = _sea - 0.15 - _bottom_y + sy
	_pitch = lerpf(_pitch, -_speed * 0.012, 3.0 * delta)
	var heel := clampf(-_turn * (0.22 + 0.16 * _speed / MAX_SPEED),
			-0.35, 0.35)
	_roll = lerpf(_roll, heel, 2.5 * delta)
	rotation = Vector3(_pitch, _yaw, _roll)

	# --- The rower -----------------------------------------------
	if _rider != null:
		_rider.global_transform = rider_xf()
	_update_prompt()
	_update_creak()
	_update_water_fx()
	# The wash loop follows hull speed; plinks fire on stroke events.
	if _sail_audio != null:
		_sail_audio.call("update", _speed)
	# Commander stroke beat: the seated hero commands the oars, so the
	# BOAT keeps the clock that drives crew oars, splashes and plinks.
	_tick_beat(delta)
	_update_dressing(delta)
	_update_sail(delta)
	# Crew reactions: the helmsman leans with the rudder; a chest
	# opened from the hull (the sea hoard!) gets a bounce-and-cheer.
	if _crew != null:
		_crew_turn = _turn
		_crew.call("set_turn", _turn)
		_chest_scan -= delta
		if _chest_scan <= 0.0:
			_chest_scan = 0.5
			_scan_chest_cheers()
	# The marker column: a slow breath of light (brighter with a
	# rider aboard), invisible in daylight glare but readable at dusk
	# and night.
	if _marker_beam != null:
		# Aboard: the beacon has done its job — hide it so it doesn't
		# glare in the helm camera; it relights once she's moored again.
		_marker_beam.visible = _rider == null
		if _rider == null:
			var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 1000.0 * 1.1)
			(_marker_beam.material_override as StandardMaterial3D) \
					.albedo_color.a = 0.16 + 0.08 * pulse


## The liner's five boxes in model units: the floor plate plus four
## side walls, [size, center-offset] pairs. Walls rise to just under
## the rail so no sight line from the benches slips over them to the
## sea plane behind the planking.
func _liner_faces() -> Array:
	return [
		[Vector3(3.8, 0.06, 9.2), Vector3(0.0, 0.0, 0.0)],      # floor
		[Vector3(0.10, 0.85, 9.2), Vector3(-1.85, 0.42, 0.0)],  # port wall
		[Vector3(0.10, 0.85, 9.2), Vector3(1.85, 0.42, 0.0)],   # starboard
		[Vector3(3.8, 0.85, 0.10), Vector3(0.0, 0.42, 4.55)],   # bow wall
		[Vector3(3.8, 0.85, 0.10), Vector3(0.0, 0.42, -4.55)],  # stern wall
	]


## Helm camera surge: how hard the hull is pulling right now,
## normalized 0 (dead in the water) to 1 (full boost). Cruise alone
## reads ~0.67 — the raised helm view uses this to swell its lag and
## handheld drift with speed, so boosting at the tiller feels wilder.
func surge_amount() -> float:
	return clampf(_speed / (MAX_SPEED * BOOST_MULT), 0.0, 1.0)


## Hull speed (m/s) — the helm camera's underway blend reads this.
func speed_now() -> float:
	return _speed


## Tiller resistance readout: eased rudder-drag load 0..1 — 0 in
## normal handling, 1 with full way on. The controller feeds it
## headward (pull-back feel) and to the rumble (the stick fighting
## back through hard turns).
func rudder_load() -> float:
	return _rudder_load


## Transform the rower is anchored to: the deck spot in wrapper
## space (model units scaled by the placement scale). In commander
## mode the rider sits at the helmsman's bench instead.
func rider_xf() -> Transform3D:
	var off := HELM_BENCH if _commander else RIDER_MODEL
	# The hero model faces -Z while the hull's bow is +Z: yaw the seat
	# by PI so the seated hero faces the BOW (tiller aft of his back).
	# Without this, the follow camera hangs at the bow looking aft and
	# every steering input reads mirrored.
	var seat := Basis(Vector3.UP, PI)
	return global_transform * Transform3D(seat, off * _scl)


## Board a player: anchor them to the deck, kill their flight, hand
## them to the MovementController via the "_sail_host" meta-contract.
func board(p: Node) -> void:
	if _rider != null:
		return
	_rider = p
	p.set("sailing", true)
	p.set("flying", false)
	p.set("dive_energy", 0.0)
	p.top_level = true
	p.velocity = Vector3.ZERO
	var mdl: Node = p.get("model")
	if mdl != null:
		mdl.call("stop_flying")
		mdl.call("stop_crouch")
	# Commander mode: seat the hero at the tiller, hide the NPC
	# helmsman, and let the boat own the stroke clock.
	# DEFAULTS TO THE OAR BENCH (user request): the camera rides the
	# rowing bench on boarding — C swaps up to the tiller.
	_commander = false
	if _crew != null:
		_crew.call("set_helm_visible", true)
	p.set("_sail_commander", null)
	p.set("_sail_host", self)
	_hook_rowing(p, true)
	_update_prompt()


## Hop off: place the player over the side (water at the gunwale, or
## the ground when beached), hand the hull's way on as momentum.
func disembark() -> void:
	if _rider == null:
		return
	var p := _rider
	_rider = null
	# Over the stern gunwale: the hull spans about ±4 model units, so
	# this lands just off the transom in the water (world ~8 m aft at
	# the flagship's scale — comfortably inside boarding reach).
	var spot := to_global(Vector3(0.0, 1.2, -4.6) * _scl)
	# If the over-side spot is underground (beached), pop onto the
	# beach surface instead of inside the hull's timbers.
	var g := _ground_at(Vector3(spot.x, spot.y + 8.0, spot.z))
	if not g.is_empty() and g.position.y > _sea + 0.4:
		spot.y = g.position.y + 1.1
	p.global_position = spot
	p.set("sailing", false)
	p.top_level = false
	p.velocity = _vel * 0.8
	p.set("_sail_host", null)
	p.set("_sail_commander", null)
	p.call("_commander_clear")
	_commander = false
	if _crew != null:
		_crew.call("set_helm_visible", true)
	_hook_rowing(p, false)
	_update_prompt()


## Sprint.gd forwards the right trigger while sailing: boost rowing.
func set_boost(on: bool) -> void:
	_boost = on


## Swap between the command seat and the rowing bench. The model's
## pose follows (the controller reads _commander every frame), the
## NPC helmsman gives way only at the tiller, and the prompt refreshes.
func set_commander(on: bool) -> void:
	if _commander == on:
		return
	_commander = on
	if _crew != null:
		_crew.call("set_helm_visible", not on)
	if _rider != null and is_instance_valid(_rider):
		_rider.set("_sail_commander", self if on else null)
		if not on:
			_rider.call("_commander_clear")
	_update_prompt()


## Connect / disconnect the rider model's row_stroke so oar splashes
## fire only while someone is actually aboard.
func _hook_rowing(p: Node, on: bool) -> void:
	var mdl: Node = p.get("model")
	if mdl == null or not mdl.has_signal("row_stroke"):
		return
	if on:
		_row_model = mdl
		if not mdl.row_stroke.is_connected(_oar_stroke):
			mdl.row_stroke.connect(_oar_stroke)
	elif _row_model == mdl and mdl.row_stroke.is_connected(_oar_stroke):
		mdl.row_stroke.disconnect(_oar_stroke)
		_row_model = null


## The flagship never had hull collision (user report: "there is no
## collision on the boats"): she moves by raw position integration,
## so nothing ever stopped her — she ghosted straight through piers,
## bridges, beached hulls and the moored fleet. Before the position
## integration, short rays are cast along the velocity from the bow
## tip and the bow corners; any world contact (layer 1) SLIDES the
## velocity along the contact normal instead of through it. Gentle
## by design: a hull brushes a pier, it does not bounce off it.
## (Backing-water ghosting is left alone on purpose — astern touches
## are rare and the aground guard already owns the beach case.)
func _hull_contact_slide(delta: float) -> Vector3:
	if _vel.length_squared() < 0.0004 or _hull == null:
		return _vel
	var space := get_world_3d().direct_space_state
	var dir := Vector3(_vel.x, 0.0, _vel.z).normalized()
	if dir.length_squared() < 0.5:
		return _vel
	var look := maxf(_speed * delta + 1.6, 1.6) * _scl
	var n := Vector3.ZERO
	# Bow tip and both bow corners: covers head-on approaches and the
	# glancing angles a turn produces. Cast from just inside the bow
	# so the ray always starts in open water ahead of the planking.
	for off in [Vector3(0.0, 0.0, 4.1), Vector3(1.2, 0.0, 3.0),
			Vector3(-1.2, 0.0, 3.0)]:
		var from := to_global(off * _scl) + Vector3.UP * 0.9 \
				- dir * 0.5
		var params := PhysicsRayQueryParameters3D.create(
				from, from + dir * look, 1)
		params.exclude = [_hull.get_rid()]
		var hit := space.intersect_ray(params)
		if not hit.is_empty():
			var hn: Vector3 = hit.normal
			hn.y = 0.0
			if hn.length_squared() > 0.01:
				n = hn.normalized()
				break
	if n == Vector3.ZERO:
		return _vel
	var vn := _vel.dot(n)
	if vn < 0.0:
		_vel -= n * vn
	return _vel


## The bow probe: seabed height a hull-length ahead (-999 = open
## deep water). The thrust gate uses it to run the ship aground at
## the beach instead of rowing up the sand.
func _depth_ahead() -> float:
	var probe := to_global(Vector3(0.0, 2.0, OAR_MODEL_Z) * _scl)
	var g := _ground_at(Vector3(probe.x, probe.y + 6.0, probe.z))
	return (g.position as Vector3).y if not g.is_empty() else -999.0


func _ground_at(from: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(from,
			Vector3(from.x, from.y - 60.0, from.z), 1)
	# Never read our own hull as the seabed — the bow probe would
	# otherwise see "ground" at deck height and refuse to ever sail.
	if _hull != null:
		params.exclude = [_hull.get_rid()]
	return space.intersect_ray(params)


func _update_prompt() -> void:
	var txt := ""
	if _rider != null:
		if _commander:
			txt = "WASD / left stick — command the stroke      A / D — tiller      C — take an oar      Space — hop off"
		else:
			txt = "WASD / left stick — row      A / D — steer      C — take the helm (the raised tiller view)      Space — hop off"
	else:
		var p := _near_player()
		if p != null:
			txt = "Space — board the longship"
		else:
			var any := get_tree().get_first_node_in_group("player")
			if any != null and Vector2(
					any.global_position.x - global_position.x,
					any.global_position.z - global_position.z).length() < 28.0:
				txt = "Swim to the longship and press Space to sail"
	if txt != _last_prompt:
		_last_prompt = txt
		_prompt.text = txt
		_prompt.visible = txt != ""


func _near_player() -> Node:
	var p := get_tree().get_first_node_in_group("player")
	if p == null:
		return null
	var n := p as Node3D
	if n == null:
		return null
	# Vertical band: the board hint only shows when actually AT the
	# hull — a hero on the seabed below or flying overhead gets none,
	# and disembarking far away can never haunt the screen.
	var dy := n.global_position.y - global_position.y
	if dy < -2.2 or dy > 5.0:
		return null
	var d := Vector2(n.global_position.x - global_position.x,
			n.global_position.z - global_position.z).length()
	return p if d < BOARD_REACH else null


func _update_creak() -> void:
	var loud := clampf(_speed / MAX_SPEED, 0.0, 1.0) * 0.65 \
			+ absf(_turn) * 0.35 + _boost_amt * 0.25
	_creak.volume_db = linear_to_db(clampf(loud, 0.0, 1.0)) - 14.0 \
			if loud > 0.02 else -60.0


## --- Water FX (procedural foam, built in code) ---------------------------


## The bow wake (a V of spray from the stem tips) and the oar-splash
## pool. Both use one shared foam look: unshaded soft billboard quads
## with a pale-seafoam ramp, no textures to import.
func _build_water_fx() -> void:
	var quad := _foam_quad()
	for i in 2:
		var w := GPUParticles3D.new()
		w.name = "Wake%d" % i
		w.amount = 42
		w.lifetime = 1.1
		w.local_coords = false
		w.emitting = false
		w.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
		w.visibility_aabb = AABB(Vector3(-3, -1, -6), Vector3(6, 3, 14))
		# One material per side: each stem tip sprays outboard (mirrored
		# x), and _update_water_fx retunes them individually.
		var m := ParticleProcessMaterial.new()
		m.gravity = Vector3(0.0, -1.4, 0.0)
		m.direction = Vector3(0.7 * (-1.0 if i == 0 else 1.0), 0.5, -0.3).normalized()
		m.spread = 14.0
		m.scale_min = 0.35
		m.scale_max = 0.7
		m.damping_min = 1.0
		m.damping_max = 2.0
		m.color_ramp = _foam_ramp()
		w.process_material = m
		w.draw_pass_1 = quad
		# The stem tips: just outside the hull shell at the bow
		# (hull spans +-4 along z, beam +-1.7), at the model-space
		# waterline y=0.15 (the wrapper sits 0.15 below the surface).
		w.position = Vector3(-0.55 if i == 0 else 0.55, 0.15, 4.2) * _scl
		add_child(w)
		_wake.append(w)
	for i in 3:
		var s := GPUParticles3D.new()
		s.name = "OarSplash%d" % i
		s.emitting = false
		s.one_shot = true
		s.amount = 12
		s.lifetime = 0.55
		s.explosiveness = 1.0
		s.local_coords = false
		s.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
		s.visibility_aabb = AABB(Vector3(-2, -1, -2), Vector3(4, 3, 4))
		var sm := ParticleProcessMaterial.new()
		sm.gravity = Vector3(0.0, -6.0, 0.0)
		sm.spread = 55.0
		sm.scale_min = 0.25
		sm.scale_max = 0.5
		sm.damping_min = 0.5
		sm.damping_max = 1.2
		sm.initial_velocity_min = 1.5
		sm.initial_velocity_max = 3.0
		sm.color_ramp = _foam_ramp()
		s.process_material = sm
		s.draw_pass_1 = quad
		add_child(s)
		_splash.append(s)


## --- Stern trail ---------------------------------------------------------

## The lingering wake: two long-lived emitters at the stern quarters
## (outside the hull, just forward of the transom). Particles are born
## in world space and DO NOT move with the ship — they sit on the sea
## where the hull laid them, so the foam line stays behind while the
## ship pulls away, then slowly dissolves.
func _build_trail() -> void:
	for i in 2:
		var tr := GPUParticles3D.new()
		tr.name = "SternTrail%d" % i
		tr.amount = 26
		tr.lifetime = 12.0
		tr.preprocess = 0.1
		tr.local_coords = false
		tr.emitting = false
		tr.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
		tr.visibility_aabb = AABB(Vector3(-4, -1.5, -16), Vector3(8, 3, 32))
		var m := ParticleProcessMaterial.new()
		m.gravity = Vector3.ZERO
		m.initial_velocity_min = 0.15
		m.initial_velocity_max = 0.45
		m.direction = Vector3(0, 0.06, -1.0)
		m.spread = 85.0
		m.scale_min = 0.6
		m.scale_max = 1.05
		m.scale_curve = _foam_grow_curve()
		m.color_ramp = _foam_hold_ramp()
		tr.process_material = m
		tr.draw_pass_1 = _foam_quad()
		# The quarters: outside the hull shell (beam +-1.7), just
		# forward of the transom (stern at z=-4), at the model-space
		# waterline y=0.15 (the wrapper sits 0.15 below the surface).
		tr.position = Vector3(-1.9 if i == 0 else 1.9, 0.15, -3.3) * _scl
		add_child(tr)
		_trail.append(tr)


## Wake follows the hull: emission turns on past a crawl, and spray
## speed + particle size grow with speed so a slow row leaves faint
## ripples while a full-stroke cruise throws visible foam.
func _update_water_fx() -> void:
	var t := clampf(_speed / MAX_SPEED, 0.0, 1.0)
	for w in _wake:
		w.emitting = t > 0.04
		if not w.emitting:
			continue
		w.amount_ratio = clampf(t * 1.15, 0.05, 1.0)
		var m := w.process_material as ParticleProcessMaterial
		m.scale_min = 0.35 * (0.55 + 0.9 * t)
		m.scale_max = 0.7 * (0.55 + 0.9 * t)
		m.initial_velocity_min = 1.3 * (0.55 + 0.85 * t)
		m.initial_velocity_max = 2.2 * (0.55 + 0.85 * t)
	_update_trail(t)


## Drives the stern trail every physics frame from hull speed.
## Emission is continuous underway (duty scales with speed); when the
## way dies the hold counts down, then a short ease-out thins the
## stream before it shuts off — the patches already laid keep fading
## on their own ramp, so the wake line lingers then dissolves.
func _update_trail(t: float) -> void:
	if t > 0.03:
		_trail_hold = TRAIL_HOLD
		_trail_ease_t = 0.0
		for tr in _trail:
			tr.emitting = true
			# Fuller foam line at speed.
			tr.amount_ratio = clampf(0.3 + 0.7 * t, 0.12, 1.0)
			# The V opens up as the channel widens.
			(tr.process_material as ParticleProcessMaterial).spread \
					= 42.0 + 38.0 * t
		return
	# Way has died: a residual trickle while the drift settles (the
	# hold), then a thin ease-out, then off. Patches already laid keep
	# dissolving on their own ramp the whole time.
	var dt := get_physics_process_delta_time()
	var ratio := 0.08
	if _trail_hold > 0.0:
		_trail_hold = maxf(_trail_hold - dt, 0.0)
		if _trail_hold <= 0.0:
			_trail_ease_t = TRAIL_EASE_S
	elif _trail_ease_t > 0.0:
		_trail_ease_t = maxf(_trail_ease_t - dt, 0.0)
		ratio = 0.04
	else:
		ratio = 0.0
	for tr in _trail:
		tr.emitting = ratio > 0.0
		if ratio > 0.0:
			tr.amount_ratio = ratio


## The trail's own foam ramp: born white, holds visible for ~9 s
## (the wake line persists), then slowly dissolves over the rest of
## the 12 s lifetime — the lingering wake.
func _foam_hold_ramp() -> GradientTexture1D:
	var g := Gradient.new()
	g.remove_point(1)   # drop the default end point; rebuild below
	g.set_color(0, Color(0.92, 0.98, 1.0, 0.92))
	g.add_point(0.78, Color(0.9, 0.96, 0.97, 0.72))
	g.add_point(1.0, Color(0.85, 0.93, 0.95, 0.0))
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


## Trail patches swell as they age (the wake spreads behind the
## transom) instead of shrinking like splash droplets.
func _foam_grow_curve() -> CurveTexture:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.45))
	c.add_point(Vector2(1.0, 1.15))
	var t := CurveTexture.new()
	t.curve = c
	return t


## The commander's stroke beat. The seated hero has no rowing clip
## to drive the rhythm, so the boat keeps the clock: at zero way a
## slow idle beat (1.05 s), underway the tempo follows hull speed to
## 0.72 s — the same feel as the clip-based tempo curve. Only runs
## while a commander is seated; never both clocks at once.
func _tick_beat(delta: float) -> void:
	if not _commander or _rider == null:
		_beat_t = 0.0
		return
	var t := clampf(_speed / MAX_SPEED, 0.0, 1.0)
	var period := lerpf(1.05, 0.72, t)
	_beat_t += delta
	if _beat_t >= period:
		_beat_t = fposmod(_beat_t, period)
		_beat_side = -_beat_side
		_oar_stroke(_beat_side, _beat_effort)


## --- Ship dressing -------------------------------------------------------

## Rigging, furled sail and lantern — everything a longship needs to
## read as lived-in. Built in model units (scaled by _scl): the hull
## spans ±4 in z (bow +z), ±1.7 in x, deck ~1.15 up.
func _build_dressing() -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.42, 0.3, 0.18)
	wood.roughness = 0.9
	var rope := StandardMaterial3D.new()
	rope.albedo_color = Color(0.62, 0.52, 0.38)
	rope.roughness = 1.0

	# --- Rigging -------------------------------------------------
	# A short mast stump (the sail is furled for rowing), a stern
	# post for the lantern, and taut stays between them and the
	# shield rail that a crew would trust with their weight.
	var stump := MeshInstance3D.new()
	stump.name = "MastStump"
	var stump_mesh := CylinderMesh.new()
	stump_mesh.top_radius = 0.11
	stump_mesh.bottom_radius = 0.16
	stump_mesh.height = 1.7
	stump_mesh.radial_segments = 7
	stump.mesh = stump_mesh
	stump.material_override = wood
	stump.position = Vector3(0.0, 2.4, 0.7)
	add_child(stump)
	var post := MeshInstance3D.new()
	post.name = "SternPost"
	var post_mesh := CylinderMesh.new()
	post_mesh.top_radius = 0.09
	post_mesh.bottom_radius = 0.13
	post_mesh.height = 1.5
	post_mesh.radial_segments = 7
	post.mesh = post_mesh
	post.material_override = wood
	post.position = Vector3(0.0, 2.2, -3.7)
	add_child(post)
	# The stays: thin stretched cylinders (a helper positions them
	# between two model-space points).
	_rigging.append(_rope_between(Vector3(0.0, 3.2, 0.7),
			Vector3(0.0, 1.55, 3.9), 0.035, rope))   # forestay
	_rigging.append(_rope_between(Vector3(0.0, 3.2, 0.7),
			Vector3(0.0, 1.55, -3.8), 0.035, rope))  # backstay
	for side in [-1.0, 1.0]:
		_rigging.append(_rope_between(Vector3(0.0, 3.1, 0.7),
				Vector3(side * 1.75, 1.5, 2.8), 0.03, rope))
		_rigging.append(_rope_between(Vector3(0.0, 3.1, 0.7),
				Vector3(side * 1.75, 1.5, -2.2), 0.03, rope))
	# The furled sail: a canvas bundle lashed along the yard over
	# the mast stump — four puffy segments with rope bindings.
	_sail_bundle = Node3D.new()
	_sail_bundle.name = "FurledSail"
	add_child(_sail_bundle)
	var canvas := StandardMaterial3D.new()
	canvas.albedo_color = Color(0.78, 0.72, 0.58)
	canvas.roughness = 1.0
	_sail_mat = canvas
	_sail_rope_mat = rope
	for i in 4:
		var seg := MeshInstance3D.new()
		var sm := CapsuleMesh.new()
		sm.radius = 0.17
		sm.height = 1.05
		sm.radial_segments = 6
		sm.rings = 2
		seg.mesh = sm
		seg.material_override = canvas
		seg.rotation_degrees = Vector3(0.0, 0.0, 90.0)
		seg.position = Vector3(-1.6 + i * 1.05, 3.28, 0.7 + 0.06 * (i % 2))
		_sail_bundle.add_child(seg)
		if i < 3:
			var lash := MeshInstance3D.new()
			var lm := TorusMesh.new()
			lm.inner_radius = 0.16
			lm.outer_radius = 0.22
			lash.mesh = lm
			lash.material_override = rope
			lash.rotation_degrees = Vector3(0.0, 0.0, 90.0)
			lash.position = Vector3(-1.05 + i * 1.05, 3.28, 0.7)
			_sail_bundle.add_child(lash)
			_sail_lash.append(lash)

	# --- The unfurled cloth (built ONCE, hidden while furled) ----- 
	# A tall rectangle of canvas hanging from the yard: SAIL_SEGMENTS
	# flat boxes side by side. Boost unrolls the bundle and billows
	# this cloth aft; the boost's end furls it back into the bundle.
	_sail_node = Node3D.new()
	_sail_node.name = "SailCloth"
	add_child(_sail_node)
	for i in SAIL_SEGMENTS:
		var panel := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(SAIL_CLOTH_W * 2.0 / SAIL_SEGMENTS,
				SAIL_CLOTH_H, 0.045)
		panel.mesh = pm
		panel.material_override = canvas
		# The panel's own x anchor: -1 .. +1 across the cloth.
		var panel_x := (float(i) + 0.5) / SAIL_SEGMENTS * 2.0 - 1.0
		panel.set_meta("x", panel_x)
		_sail_node.add_child(panel)
		_sail_seg.append(panel)
	_sail_node.visible = false

	# --- The lantern ----------------------------------------------
	_lantern_pivot = Node3D.new()
	_lantern_pivot.name = "LanternPivot"
	_lantern_pivot.position = Vector3(0.0, 2.9, -3.7)
	add_child(_lantern_pivot)
	# A short rope from the post's arm to the lamp body.
	var hang := MeshInstance3D.new()
	hang.name = "LanternHang"
	var hm := CylinderMesh.new()
	hm.top_radius = 0.025
	hm.bottom_radius = 0.025
	hm.height = 0.5
	hm.radial_segments = 5
	hang.mesh = hm
	hang.material_override = rope
	hang.position = Vector3(0.0, -0.25, 0.0)
	_lantern_pivot.add_child(hang)
	# Iron body: a small capped cylinder with a warm glass core.
	var body := MeshInstance3D.new()
	body.name = "LanternBody"
	var bm := CylinderMesh.new()
	bm.top_radius = 0.14
	bm.bottom_radius = 0.17
	bm.height = 0.3
	bm.radial_segments = 8
	body.mesh = bm
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.16, 0.15, 0.15)
	iron.metallic = 0.6
	iron.roughness = 0.55
	body.material_override = iron
	body.position = Vector3(0.0, -0.62, 0.0)
	_lantern_pivot.add_child(body)
	_lantern_lamp = MeshInstance3D.new()
	_lantern_lamp.name = "LanternLamp"
	var lm2 := SphereMesh.new()
	lm2.radius = 0.11
	lm2.height = 0.22
	lm2.radial_segments = 8
	lm2.rings = 4
	_lantern_lamp.mesh = lm2
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lamp_mat.albedo_color = Color(1.0, 0.72, 0.32)
	lamp_mat.emission_enabled = true
	lamp_mat.emission = Color(1.0, 0.6, 0.22)
	lamp_mat.emission_energy_multiplier = 0.4   # day: a dark lamp glass
	_lantern_lamp.material_override = lamp_mat
	_lantern_lamp.position = Vector3(0.0, -0.62, 0.0)
	_lantern_pivot.add_child(_lantern_lamp)
	_lantern_light = OmniLight3D.new()
	_lantern_light.name = "LanternLight"
	_lantern_light.omni_range = 6.5 * _scl
	_lantern_light.light_color = Color(1.0, 0.72, 0.38)
	_lantern_light.light_energy = 0.0   # day: off; the night gate owns it
	_lantern_light.shadow_enabled = false
	_lantern_light.position = Vector3(0.0, -0.62, 0.0)
	_lantern_pivot.add_child(_lantern_light)


## A taut stay between two model-space points: a thin cylinder
## stretched along the segment.
func _rope_between(a: Vector3, b: Vector3, radius: float,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = 1.0
	cm.radial_segments = 5
	cm.cap_top = false
	cm.cap_bottom = false
	mi.mesh = cm
	mi.material_override = mat
	mi.scale = Vector3.ONE * _scl
	var wa := a * _scl
	var wb := b * _scl
	var mid := (wa + wb) * 0.5
	var dir := (wb - wa)
	var len := dir.length()
	mi.position = mid
	if len > 0.001:
		dir = dir / len
		# A cylinder's axis is +Y; rotate it onto the segment direction.
		mi.basis = Basis(cross_to_quat(Vector3.UP, dir)) * \
				Basis.from_scale(Vector3(1.0, len, 1.0))
	add_child(mi)
	return mi


## Rotation quaternion carrying Vector3.UP onto `dir` (shortest arc).
func cross_to_quat(up: Vector3, dir: Vector3) -> Quaternion:
	var axis := up.cross(dir)
	if axis.length_squared() < 1e-8:
		return Quaternion.IDENTITY
	axis = axis.normalized()
	return Quaternion(axis, up.angle_to(dir))


## Per-frame dressing life: the lantern's night gate (registered in
## the night_lights group) plus a subtle flame flicker, and the lamp
## swinging gently with the hull's heel and turning.
func _update_dressing(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	# --- The surge gutter --------------------------------------------
	# While the boost surges, the flame gutters: deeper flicker, a
	# fast bright jitter, and the swing growing wide — all scaled by
	# the boost's eased amount, so they swell with the surge and calm
	# as it eases off.
	if _boost_amt > 0.05:
		_gutter_t += delta * (2.4 + 2.2 * _boost_amt)
		_gutter_chaos = lerpf(_gutter_chaos, _boost_amt, 6.0 * delta)
	else:
		_gutter_chaos = lerpf(_gutter_chaos, 0.0, 4.0 * delta)
	var surge := _gutter_chaos
	# --- Base flicker + surge gutter (depth and brightness) ----------
	var flicker := 1.0 + 0.10 * sin(now * 13.0) \
			+ 0.06 * sin(now * 29.0 + 1.7)
	var gutter := 1.0 + surge * (0.16 * sin(_gutter_t * 9.0) \
			+ 0.10 * sin(_gutter_t * 23.0 + 0.9) \
			+ 0.14 * sin(now * 47.0 + 2.2))
	var want := _night_gate * flicker * gutter
	_lantern_want = want
	_lantern_gutter = gutter
	if _lantern_light != null:
		_lantern_light.light_energy = lerpf(
				_lantern_light.light_energy, 1.35 * want, 5.0 * delta)
	if _lantern_lamp != null:
		(_lantern_lamp.material_override as StandardMaterial3D) \
				.emission_energy_multiplier = lerpf(0.4, 2.6, want)
	# --- The swing -----------------------------------------------------
	# Pendulum with the hull's roll, WIDENED by the surge; the flame
	# also bends aft (x tilt) with the wind of the ship's own speed
	# and carries a fast tremble while surging.
	if _lantern_pivot != null:
		var wide := 1.0 + 2.6 * surge
		_lantern_swing = lerpf(_lantern_swing, -_roll * 1.6 * wide,
				3.0 * delta)
		_lantern_pivot.rotation.z = _lantern_swing \
				+ wide * 0.03 * sin(now * 1.3) \
				+ surge * 0.05 * sin(now * 31.0)
		_lantern_pivot.rotation.x = _pitch * 1.2 \
				+ 0.02 * sin(now * 0.9) \
				+ surge * 0.10 * sin(_gutter_t * 7.0) \
				+ clampf(_speed / MAX_SPEED, 0.0, 1.6) * 0.12


## DayNight broadcasts the night factor to this group every frame.
func on_night_gate(g: float) -> void:
	_night_gate = g


func on_night_gate_group(g: float) -> void:
	on_night_gate(g)


## One oar-dip burst. Fired by the rower's row_stroke signal (standing
## mode) or the boat's own beat clock (commander mode): `side` -1/+1
## picks the oar entry point, `effort` (0..1 throttle) scales the
## burst. Fired at the water surface so foam sits ON the sea.
func _oar_stroke(side: int, effort: float) -> void:
	# The crew rows and the water plinks on the same beat as the
	# splash bursts.
	if _crew != null:
		_crew.call("on_stroke", side, effort)
	if _sail_audio != null:
		_sail_audio.call("plink", effort)
	# The helm camera dips with the pull (the seated helmsman's view
	# rides the rowing rhythm; the head gates boom/eyes itself).
	if _rider != null and is_instance_valid(_rider):
		var hd: Node = _rider.get_node_or_null("Head")
		if hd != null:
			hd.call("helm_stroke", side, effort)
	# Oar entries just outside the gunwale, amidships beside the rower.
	var pos := to_global(Vector3(1.9 * side, 0.15, 1.6) * _scl)
	var sy := _sea
	if _swell.is_valid():
		sy += _swell.call(pos.x, pos.z)
	_burst_splash(Vector3(pos.x, sy, pos.z), 0.35 + 0.65 * clampf(effort, 0.0, 1.0))


## Fires a one-shot foam burst at `pos` (round-robin so overlapping
## strokes never cut each other short).
func _burst_splash(pos: Vector3, strength: float) -> void:
	if _splash.is_empty():
		return
	splash_count += 1
	var s := _splash[_splash_active]
	_splash_active = (_splash_active + 1) % _splash.size()
	var m := s.process_material as ParticleProcessMaterial
	m.initial_velocity_min = 1.5 * strength
	m.initial_velocity_max = 3.0 * strength
	s.global_position = pos + Vector3.UP * 0.05
	s.restart()
	s.emitting = true


## A sunken chest opened from (or beside) the hull: the crew cheers.
func _scan_chest_cheers() -> void:
	if _crew == null:
		return
	for c in get_tree().get_nodes_in_group("sunken_chest"):
		var n3 := c as Node3D
		if n3 == null or _cheered.has(c.get_instance_id()):
			continue
		if bool(c.call("is_open")) \
				and n3.global_position.distance_to(global_position) < 9.0:
			_cheered[c.get_instance_id()] = true
			_crew.call("cheer")


func _foam_quad() -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(0.5, 0.5)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _foam_dot()
	q.material = mat
	return q


func _foam_ramp() -> GradientTexture1D:
	var g := Gradient.new()
	g.set_color(0, Color(0.92, 0.98, 1.0, 0.9))
	g.set_color(1, Color(0.85, 0.93, 0.95, 0.0))
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


func _foam_dot() -> GradientTexture2D:
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


## The placed GLB child (visuals + yaw), found by path length — the
## wrapper owns exactly one child subtree.
func _find_model_child() -> Node3D:
	for c in get_children():
		if c is Node3D and (c as Node3D).scene_file_path != "":
			return c
	return null


## Model-space collision shape for the hull, built from the GLB's own
## meshes (trimesh under the face cap, convex hull above). Deliberately
## self-contained — PropScatter preloads this script, so a reference
## back to it would be a cyclic load.
static func _hull_shape_for(n: Node3D) -> Shape3D:
	var faces := _gather_faces(n, Transform3D.IDENTITY)
	if faces.size() < 12:
		var box := BoxShape3D.new()
		box.size = Vector3(3.4, 2.7, 8.0)
		return box
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = faces
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if faces.size() / 3 > 200000:
		return mesh.create_convex_shape()
	return mesh.create_trimesh_shape()


static func _gather_faces(n: Node, xf: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for c in n.get_children():
		var c3d := c as Node3D
		var cxf := xf * (c3d.transform if c3d != null \
				else Transform3D.IDENTITY)
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null:
			var mf := mi.mesh.get_faces()
			for i in mf.size():
				out.append(cxf * mf[i])
		out.append_array(_gather_faces(c, cxf))
	return out


## A seamless wood-groan loop: two phase-continuous carriers (a low
## hull groan and a higher line squeak) whose wobbling frequencies
## integrate to whole cycles over the loop, plus grain noise faded to
## zero at the seam.
static func _make_creak_stream() -> AudioStreamWAV:
	var rate := 11025
	var t_len := 2.0
	var n := int(rate * t_len)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		var t := float(i) / rate
		var env := 0.5 + 0.5 * sin(TAU * 2.0 * t / t_len)
		var groan := sin(TAU * (58.0 + 22.0 * sin(TAU * 1.5 * t)) * t)
		var squeak := 0.32 * sin(TAU * (331.0 + 44.0 * sin(TAU * 0.5 * t)) * t)
		var grain_w := 0.5 - 0.5 * cos(TAU * t / t_len)
		var grain := (randf() * 2.0 - 1.0) * 0.06 * grain_w
		var v := clampf((groan * 0.7 + squeak) * env * 0.55 + grain,
				-1.0, 1.0)
		bytes.encode_s16(i * 2, int(v * 32000.0))
	var ws := AudioStreamWAV.new()
	ws.format = AudioStreamWAV.FORMAT_16_BITS
	ws.mix_rate = rate
	ws.stereo = false
	ws.loop_mode = AudioStreamWAV.LOOP_FORWARD
	ws.loop_begin = 0
	ws.loop_end = n
	ws.data = bytes
	return ws


## --- The unfurled sail (a boost-driven unroll/furl cycle) ---------------
## While furled, the bundle of canvas sits lashed on the yard and the
## cloth is hidden. Holding the sprint trigger unrolls the bundle: the
## rope lashes slide off one by one, the bundle shrinks up the yard,
## and the cloth drops from it — then billows AFT, belly deepening and
## breath rippling downwind with hull speed. Release: the cloth climbs
## back up, the bundle reappears, and the lashes slip home.
func _update_sail(delta: float) -> void:
	if _sail_node == null:
		return
	# THE SAIL BLOCKED THE VIEW FROM THE OAR BENCH (user report): the
	# cloth unrolls on boost straight ahead of the rower's eyes. While
	# the hero rows (aboard but NOT at the tiller) the crew keeps the
	# canvas furred — boost still surges the hull, the cloth just
	# never drops into the view. The sail is code-built, so this is a
	# one-line guard, no re-modeling.
	var rowing := _rider != null and is_instance_valid(_rider) \
			and bool(_rider.get("sailing") == true) \
			and _rider.get("_sail_commander") == null
	var boosting := _boost_amt > 0.35 and not rowing
	match _sail_state:
		"furled":
			if boosting:
				_sail_state = "unfurling"
				_sail_node.visible = true
				_sail_t = 0.0
		"unfurling":
			_sail_t = minf(1.0, _sail_t + delta / SAIL_UNFURL_S)
			if not boosting and _sail_t < 0.6:
				_sail_state = "furling"
			elif _sail_t >= 1.0:
				_sail_state = "unfurled"
				_sail_bundle.visible = false
		"unfurled":
			if not boosting:
				_sail_state = "furling"
				_sail_bundle.visible = true
		"furling":
			_sail_t = maxf(0.0, _sail_t - delta / SAIL_FURL_S)
			if boosting:
				_sail_state = "unfurling"
				_sail_bundle.visible = false
			elif _sail_t <= 0.0:
				_sail_state = "furled"
				_sail_node.visible = false

	_sail_wave += delta * (2.0 + 4.0 * _speed)
	_sail_billow = lerpf(_sail_billow,
			_sail_t * (0.30 + 0.75 * _speed / MAX_SPEED), 3.5 * delta)
	_apply_sail_pose(delta)


## Per-frame cloth placement (all model units scaled by _scl here).
## The cloth stays anchored along the yard; progress slides the
## panels DOWN out of the rolled bundle and the billow pushes their
## belly aft with a downwind breath ripple. The lashes roll away and
## the bundle rolls up as the cloth drops.
func _apply_sail_pose(_delta: float) -> void:
	var t := _sail_t
	var drop := t * t	# ease-in: the canvas hesitates, then drops
	var reveal := clampf(t * 1.35, 0.0, 1.0)
	for p in _sail_seg:
		var x: float = p.get_meta("x")
		p.visible = reveal > 0.02
		if not p.visible:
			continue
		# The panel's upper edge hangs from the yard; the panel slides
		# down as the unroll proceeds (each panel drops over its own
		# height, so the cloth grows downward like a dropped bedsheet).
		var top_y := (SAIL_YARD_Y - 0.12 * drop) * _scl
		var w := SAIL_CLOTH_H * _scl
		p.scale = Vector3(1.0, reveal, 1.0)
		# Panel center: the top edge is fixed at the yard; the bottom
		# hangs below. Reveal scales the height around the TOP edge.
		p.position = Vector3(
			x * SAIL_CLOTH_W * _scl,
			top_y - w * reveal * 0.5,
			(SAIL_YARD_Z - 0.10 - _sail_billow * 0.85 * (0.55 + 0.45 * x))
					* _scl)
		# Billow: belly depth aft, deeper at the cloth's center; plus a
		# breath ripple running down the cloth (phase by panel x).
		p.rotation.x = 0.42 * _sail_billow * (0.55 + 0.45 * x) \
				+ 0.07 * _sail_billow * sin(_sail_wave + x * 2.2)
		p.rotation.z = 0.05 * _sail_billow * sin(_sail_wave * 0.8 + x * 1.6)
	# The bundle rolls itself up as the cloth takes the wind (and
	# back out on furl) — the two never occupy the same air.
	if _sail_bundle != null:
		_sail_bundle.scale = Vector3(1.0, 1.0, 0.45 + 0.55 * (1.0 - t))
		# The bundle's children sit at absolute model heights, so its
		# own origin stays at 0 — only a small DELTA rides up as the
		# cloth takes the wind (and settles back on furl).
		_sail_bundle.position.y = _scl * 0.55 * t
	# Lashes: hide progressively as the unroll proceeds.
	for i in _sail_lash.size():
		var thr := 0.16 + 0.24 * float(i)
		_sail_lash[i].visible = t < thr
		if _sail_lash[i].visible:
			_sail_lash[i].position.z = _scl * (0.7 + 0.5 * (t / thr))
