extends Node3D
## Spawns fireballs at the attack clip's strike moment (hooked via
## MovementController on PlayerModel.attack_cast). The balls live in a
## world-fixed FX layer under the scene root, so they keep flying — and
## their ember trails stay put — independently of the player's movement.

const FIREBALL := preload("res://Player/Fireball.gd")

@export var fireball_speed := 18.0
## Minimum time between shots (s); the attack swing paces shots anyway.
@export var cooldown := 0.45
## Maximum fireballs alive at once (extra shots are dropped).
@export var max_alive := 8
## When the cap is full, a ball farther than this from the caster is
## silently fizzled to make room (oldest first). Without this, a few
## shots at the horizon — balls that fly until they hit something —
## fill the cap forever and lock the weapon (found by a 90 s spam
## stress test: 17 shots, then blocked for the rest of the session).
@export var evict_distance := 80.0
## Physics layers the fireballs collide and detonate against: world
## geometry (1) + the viking wanderers (4), so shots hit and kill them.
@export var collision_mask := 1 | 4

## Number of fireballs launched this session (diagnostics/tests).
var play_count := 0

var _fx_root: Node3D
var _cooldown_left := 0.0


func _ready() -> void:
	_fx_root = get_tree().root.get_node_or_null("FireballFX") as Node3D
	if _fx_root == null:
		_fx_root = Node3D.new()
		_fx_root.name = "FireballFX"
		# Deferred: _ready runs while the tree may be setting up children.
		get_tree().root.add_child.call_deferred(_fx_root)


func _physics_process(delta: float) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)


## Launch a fireball from `origin` travelling along `dir` (both in world
## space). `inherit` adds the caster's momentum. Returns false when the
## shot is blocked (cooldown, alive cap, or the FX layer isn't ready yet).
func cast(origin: Vector3, dir: Vector3, inherit := Vector3.ZERO) -> bool:
	if _fx_root == null or not _fx_root.is_inside_tree():
		return false
	if _cooldown_left > 0.0:
		return false
	if _count_alive() >= max_alive and not _evict_far(origin):
		return false
	_cooldown_left = cooldown
	var fb: Area3D = FIREBALL.new()
	fb.collision_mask = collision_mask
	fb.speed = fireball_speed
	_fx_root.add_child(fb)
	fb.launch(origin, dir, inherit)
	play_count += 1
	return true


func _count_alive() -> int:
	var n := 0
	for c in _fx_root.get_children():
		if c is Area3D:
			n += 1
	return n


## Cap full: fizzle the oldest ball clearly out of the fight (>80 m —
## a dot in the world at that range) so a fresh shot always fits.
## Nearby balls are never touched, so active combat volleys behave
## exactly like before. Returns false when every live ball is close.
func _evict_far(origin: Vector3) -> bool:
	for c in _fx_root.get_children():
		# Only fireball balls are evictable — the FX layer also hosts
		# the balls' world-fixed ember puffs (MeshInstance3D), which
		# expire on their own and know nothing about fizzling.
		if c is Area3D:
			var fb := c as Node3D
			if fb.global_position.distance_to(origin) > evict_distance:
				c.call("fizzle")
				return true
	return false
