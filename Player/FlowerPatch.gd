extends Node3D
## One procedural flower patch that vikings can pick from: each
## take_bloom() hides one flower (the plucker "carries it away") and
## when the patch is stripped bare a regrow clock pops every bloom
## back after a quiet while. PropScatter attaches this script to every
## flower patch it builds; wandering vikings find patches through the
## "flower_patch" group.

## Seconds until a fully stripped patch regrows (± jitter).
@export var regrow_time := 55.0

var _blooms: Array[Node3D] = []
var _regrow_left := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group("flower_patch")
	_rng.seed = hash(global_position)
	for c in get_children():
		if c is Node3D:
			_blooms.append(c)


## Visible blooms right now (0 = fully picked).
func bloom_count() -> int:
	var n := 0
	for b in _blooms:
		if b.visible:
			n += 1
	return n


## A viking plucked a flower: hide one bloom; start the regrow clock
## when the last one goes. Returns false when already bare.
func take_bloom() -> bool:
	for b in _blooms:
		if b.visible:
			b.visible = false
			if bloom_count() == 0:
				_regrow_left = regrow_time * _rng.randf_range(0.85, 1.25)
			return true
	return false


func _process(delta: float) -> void:
	if _regrow_left <= 0.0:
		return
	_regrow_left -= delta
	if _regrow_left <= 0.0:
		for b in _blooms:
			b.visible = true
			b.scale = Vector3.ONE * 0.2
			var tw := b.create_tween()
			tw.tween_property(b, "scale", Vector3.ONE, 0.6) \
					.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
