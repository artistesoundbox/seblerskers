class_name RaidManager
extends Node3D
## Night raids: when the sun sets, sails show on the dark horizon and a squad of
## vikings marches on the village. Each raider is a REAL wanderer
## drafted into the raid (their stroll state machine is hijacked by
## `begin_raid`); they march to an assigned house, stand beside it and
## ransack it. Every house has health — ransacking grinds it down,
## and a destroyed house is gone for the night. The player defends the
## village until dawn: fireballs kill raiders permanently (they stay
## buried while the raid is on — every kill thins the assault). At
## dawn (night gate falling), survivors walk home and life resumes.
##
## Driven entirely by the DayNight clock: one raid per night, armed
## shortly after full nightfall, called off at dawn. No horn, no siren —
## the warning is what the player SEES: the announce banner and the
## sails themselves coming round the point.

signal raid_started(night: int)
signal raid_ended(result: String)  # "defended" | "sacks" | "wiped"

## Gate value that counts as full night (raids arm at/above this).
const NIGHT_ARM := 0.85
## Gate value at/below which dawn calls the raid off.
const DAWN_GATE := 0.15
## Seconds at full night before the raid is announced.
const WARN_DELAY := 8.0
## House health (ransack points).
const HOUSE_HP := 120.0
## Damage per ransacking raider per second.
const RANSACK_DPS := 3.0
## A raider within (1.2 + house_radius) of the house CENTRE counts as
## ransacking — the range must cover the building's own footprint or
## marchers grind forever against its wall.
const RANSACK_RANGE := 1.2
## Squad size grows with each survived night.
const SQUAD_BASE := 4
const SQUAD_NIGHT_BONUS := 1
const SQUAD_MAX := 7
## Proximity-damage poll period (s).
const POLL := 0.25
## Only houses within this radius of the village centre are defended.
## The island's cottages are scattered wide, so this hug is generous —
## a defence of two or three buildings is a siege, not a hike.
const VILLAGE_R := 100.0

var _center := Vector3.ZERO
var _houses: Array[Node3D] = []
var _house_pos: Array[Vector3] = []
var _hp: Array[float] = []
var _house_dead: Array[bool] = []
var _house_r: Array[float] = []
var _seed := 0

var _rng := RandomNumberGenerator.new()
var _ctrl: DayNight = null
var _phase_key := 1  # 1 = day half, 0 = night half (phase 0.5..1.0)
var _state := 0  # 0 idle, 1 warn, 2 march, 3 ransack/hold, 4 retreat
var _warn_left := 0.0
var _night := 0
var _poll_left := 0.0
var _retreat_left := 0.0
## The landing beach: the squad beaches here when the raid begins.
var _beach := Vector3.ZERO
var _t := 0.0
## Raider instance-id -> assigned house index.
var _assign := {}
var _raiders: Array = []
## The last raid's outcome ("defended" | "sacks" | "wiped") — the
## quest board reads this for the Shield of the Village errand.
var _last_result := ""


## HUD
var _hud: CanvasLayer
var _status: Label
var _msg_label: Label
var _house_labels: Array[Label] = []


## PropScatter hands in the village centre, the placed house nodes,
## their footprint radii (m), and the war band's landing BEACH — the
## squad beaches there when the raid begins, then marches in (a shore
## party arriving, not a teleport).
func setup(center: Vector3, houses: Array, radii: Array,
		beach: Vector3, rng_seed: int) -> void:
	_center = center
	_seed = rng_seed
	_rng.seed = rng_seed
	_beach = beach
	# Only houses near the raid centre are defended: assignments to
	# cottages 200 m across the island turn a siege into a hike.
	for hi in houses.size():
		var n := houses[hi] as Node3D
		if n == null:
			continue
		if n.global_position.distance_to(center) > VILLAGE_R:
			continue
		_houses.append(n)
		_house_pos.append(n.global_position + Vector3(0, 0.2, 0))
		_house_r.append(maxf(1.0, radii[hi] as float))
	# Fallback: if the cluster filter starved the defence, take all.
	if _houses.size() < 2:
		_houses.clear()
		_house_pos.clear()
		_house_r.clear()
		for h in houses:
			var n2 := h as Node3D
			if n2 == null:
				continue
			_houses.append(n2)
			_house_pos.append(n2.global_position + Vector3(0, 0.2, 0))
		for r in radii:
			_house_r.append(maxf(r as float, 1.0))
	_hp.resize(_houses.size())
	_house_dead.resize(_houses.size())
	for i in _houses.size():
		_hp[i] = HOUSE_HP
		_house_dead[i] = false


func _ready() -> void:
	add_to_group("raid_manager")
	for n in get_tree().get_nodes_in_group("daynight"):
		_ctrl = n as DayNight
		break
	if _ctrl == null:
		push_warning("RaidManager: no DayNight found; raids disabled")
		return
	# Start already inside the night half? (boot after sunset) — key
	# accordingly so the next day->night edge arms tonight's raid.
	_phase_key = _key_of(_ctrl.phase
			if _ctrl != null else 0.25)
	# Ransack spots must sit at the TERRAIN surface beside each house
	# (the house node's origin can ride metres above the ground for
	# tall models — raiders standing on the soil would never come
	# within ransack range of an origin-anchored spot).
	var space := get_world_3d().direct_space_state
	for i in _house_pos.size():
		var p: Vector3 = _house_pos[i]
		var params := PhysicsRayQueryParameters3D.create(
				Vector3(p.x, p.y + 30.0, p.z),
				Vector3(p.x, p.y - 60.0, p.z), 1)
		var hit := space.intersect_ray(params)
		if not hit.is_empty():
			_house_pos[i] = Vector3(p.x,
					(hit.position as Vector3).y + 0.2, p.z)


func _process(delta: float) -> void:
	_t += delta
	if _ctrl == null:
		return
	var pk := _key_of(_ctrl.phase)
	if pk != _phase_key:
		# Day -> night edge: a fresh night arms one raid.
		if pk == 0:
			_night += 1
		_phase_key = pk
	var gate: float = _ctrl.night_gate()
	match _state:
		0:
			# Armed once the night is deep and stable.
			if pk == 0 and gate >= NIGHT_ARM:
				_warn_left -= delta
				if _warn_left <= 0.0:
					_warn_left = WARN_DELAY
					_start_raid()
			else:
				_warn_left = WARN_DELAY
		1, 2, 3:
			_poll_left -= delta
			if _poll_left <= 0.0:
				_poll_left = POLL
				_poll()
			# Dawn — or the whole village lost — calls it off.
			if gate <= DAWN_GATE or _all_houses_dead():
				_end_raid("sacks" if _all_houses_dead() else "defended")
		4:
			# Retreat grace: the result banner holds, survivors visibly
			# walk home, THEN the manager re-arms for the next night.
			_retreat_left -= delta
			if _retreat_left <= 0.0:
				_state = 0
				_warn_left = WARN_DELAY


func _key_of(p: float) -> int:
	return 0 if p >= 0.5 and p < 1.0 else 1


# --- raid lifecycle ---------------------------------------------------------

func _start_raid() -> void:
	var squad := _draft_squad()
	if squad.is_empty() or _houses.is_empty():
		return
	_raiders = squad
	_assign.clear()
	# A new night: villagers repaired whatever was ransacked — every
	# house stands again with full health.
	for i in _hp.size():
		_hp[i] = HOUSE_HP
		_house_dead[i] = false
	# Assignment: spread the squad across the alive houses.
	var alive: Array[int] = []
	for i in _houses.size():
		if not _house_dead[i]:
			alive.append(i)
	var ai := 0
	for r in _raiders:
		var idx: int = alive[ai % alive.size()]
		ai += 1
		var rp: Vector3 = _house_pos[idx]
		# Ring the house: a personal spot just OUTSIDE its wall (the
		# footprint radius + a shoulder) so the squad surrounds the
		# building instead of stacking into one body pile — and every
		# spot stays within ransack range of the centre.
		var a := _rng.randf() * TAU
		var ringing := _house_r[idx] + _rng.randf_range(0.7, 1.5)
		rp += Vector3(cos(a) * ringing, 0.0,
					sin(a) * ringing)
		_assign[r.get_instance_id()] = idx
		r.raid_no_respawn = true
		# BEACHING: drop the raider on the landing beach (wet boots,
		# shore-party arrival) and hand them the march order. The spot
		# is ground-validated (a pinch under the terrain freezes a
		# CharacterBody forever — measured), with a small jitter and a
		# clean drop from above the surface.
		var space := get_world_3d().direct_space_state
		var bx: float = _beach.x + _rng.randf_range(-1.2, 1.2)
		var bz: float = _beach.z + _rng.randf_range(-1.2, 1.2)
		var q := PhysicsRayQueryParameters3D.create(
				Vector3(bx, _beach.y + 8.0, bz),
				Vector3(bx, _beach.y - 12.0, bz), 1)
		var bh := space.intersect_ray(q)
		var by: float = _beach.y + 1.0 if bh.is_empty() \
				else (bh.position as Vector3).y + 0.8
		r.global_position = Vector3(bx, by, bz)
		r.velocity = Vector3.ZERO
		r.begin_raid(rp)
	_state = 2
	raid_started.emit(_night)
	_ensure_hud()
	_status.visible = true
	_announce("SAILS ON THE DARK HORIZON — RAIDERS COME ASHORE...", 3.5)
	for i in _houses.size():
		_house_labels[i].visible = not _house_dead[i]


func _draft_squad() -> Array:
	var cands: Array = []
	for v in get_tree().get_nodes_in_group("viking"):
		var w := v as VikingWanderer
		if w == null or w.dead or w.raiding:
			continue
		cands.append(w)
	if cands.is_empty():
		return []
	# Nearest to the village first: the horn calls the closest kin.
	cands.sort_custom(func(a: VikingWanderer, b: VikingWanderer) -> bool:
		return a.global_position.distance_to(_center) \
				< b.global_position.distance_to(_center))
	var want: int = clampi(SQUAD_BASE + SQUAD_NIGHT_BONUS * (_night - 1)
			+ _rng.randi_range(0, 1), 4, SQUAD_MAX)
	return cands.slice(0, mini(want, cands.size()))


func _poll() -> void:
	if _state < 2:
		return
	var ransacking := 0
	var alive := 0
	for r in _raiders:
		if not is_instance_valid(r):
			continue
		if r.dead or not r.raiding:
			continue
		alive += 1
		var idx: int = _assign.get(r.get_instance_id(), -1)
		if idx < 0 or _house_dead[idx]:
			continue
		if r.global_position.distance_to(_house_pos[idx]) \
				<= RANSACK_RANGE + _house_r[idx]:
			ransacking += 1
			_hp[idx] = maxf(_hp[idx] - RANSACK_DPS * POLL, 0.0)
			if _hp[idx] <= 0.0:
				_house_dead[idx] = true
				_announce("A HOUSE HAS BEEN RANSACKED!", 3.0)
	# Raiders all dead: the night is won — no respawn until dawn.
	if alive == 0 and _state >= 2:
		_end_raid("wiped")
		return
	if _state == 2:
		_state = 3  # march -> hold/ransack (the poll owns damage from here)
	_update_house_labels()


func _end_raid(result: String) -> void:
	if _state >= 4:
		return
	_state = 4
	_retreat_left = 12.0
	for r in _raiders:
		if is_instance_valid(r) and r.raiding:
			r.end_raid()
	_raiders = []
	_assign.clear()
	raid_ended.emit(result)
	_last_result = result
	if result == "defended":
		_announce("DAWN - THE VILLAGE STANDS. THEY RETREAT.", 4.0)
	elif result == "wiped":
		_announce("THE RAIDING PARTY IS BROKEN. THE NIGHT IS YOURS.", 4.0)
	else:
		_announce("THE VILLAGE HAS BEEN SACKED...", 4.0)
	_hud_house_vis(false)


func _all_houses_dead() -> bool:
	for d in _house_dead:
		if not d:
			return false
	return not _houses.is_empty()


# --- HUD ---------------------------------------------------------------------

func _ensure_hud() -> void:
	if _hud != null:
		return
	_hud = CanvasLayer.new()
	_hud.name = "RaidHUD"
	add_child(_hud)
	var vb := VBoxContainer.new()
	vb.position = Vector2(24, 150)
	_hud.add_child(vb)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 20)
	_status.text = "RAID"
	vb.add_child(_status)
	_msg_label = Label.new()
	_msg_label.add_theme_font_size_override("font_size", 16)
	vb.add_child(_msg_label)
	for i in _houses.size():
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 14)
		vb.add_child(l)
		_house_labels.append(l)
	_status.visible = false
	for l in _house_labels:
		l.visible = false


func _update_house_labels() -> void:
	for i in _house_labels.size():
		var l := _house_labels[i]
		if _house_dead[i]:
			l.text = "house %d — ransacked" % (i + 1)
			l.visible = true
			continue
		var filled := int(round(_hp[i] / HOUSE_HP * 8.0))
		l.text = "house %d  %s" % [i + 1,
				"|".repeat(filled) + "·".repeat(8 - filled)]
		l.visible = true


func _hud_house_vis(_off: bool) -> void:
	# Labels clear with the raid; ransacked houses stay silently dead
	# until the next dusk rebuilds their health bars.
	for i in _house_labels.size():
		_house_labels[i].visible = false


func _announce(text: String, secs: float) -> void:
	_ensure_hud()
	_msg_label.text = text
	get_tree().create_timer(secs).timeout.connect(func() -> void:
		if is_instance_valid(_msg_label) and _msg_label.text == text:
			_msg_label.text = "")


# --- diagnostics ---------------------------------------------------------------

func raid_state() -> int:
	return _state


func raider_count() -> int:
	var n := 0
	for r in _raiders:
		if is_instance_valid(r) and not r.dead and r.raiding:
			n += 1
	return n


func house_hp(i: int) -> float:
	return _hp[i]


func house_count() -> int:
	return _houses.size()


func house_dead(i: int) -> bool:
	return _house_dead[i]
