class_name AttractCam
extends Camera3D
## The title screen's living backdrop: a slow crane orbit over the real
## island, circling the hero where he stands (frozen under the menu).
## On Set Sail, begin_handover() glides this camera — position and
## rotation blended on a smoothstep — down into the hero's own
## over-the-shoulder rig, then hands "current" back to his head camera.
## One continuous shot from menu to play; no scene change, no load.
##
## Spawned and driven by Title.gd's overlay mode.

## Fired when the glide lands on the hero's rig; the menu unfreezes
## the player and removes itself.
signal handed_over

const ORBIT_R := 92.0   # radius around the hero (m)
const HELM_H := 34.0    # crane height above him (m)
const WHEEL_S := 0.055  # drift speed (rad/s) — a lap every ~114 s
const SWAP_S := 2.1     # Set Sail glide length (s)
## The hero's walk-camera boom behind his back (matches Head defaults:
## shoulder offset x, spring length z).
const END_OFFS := Vector3(0.65, 0.0, 4.0)

var _hero: Node3D = null
var _center := Vector3.ZERO
var _ang := 0.0
var _t := 0.0
var _leaving := false
var _swap_t := 0.0
var _from_xf := Transform3D()
var _head_cam: Camera3D = null


## Start drifting around `hero`. Grounds the orbit on the real terrain
## (raycast, mask 1) so the crane height reads against the island.
func begin(hero: Node3D) -> void:
	_hero = hero
	_center = hero.global_position
	await get_tree().physics_frame
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
			_center + Vector3(0, 400, 0), _center + Vector3(0, -200, 0), 1)
	var hit := space.intersect_ray(q)
	if hit.has("position"):
		_center.y = hit["position"].y
	_ang = randf() * TAU
	current = true
	_place()
	set_physics_process(true)


## Set Sail: capture where we are, then glide into the hero's rig.
func begin_handover() -> void:
	if _leaving or _hero == null or not is_instance_valid(_hero):
		return
	_leaving = true
	_swap_t = 0.0
	_from_xf = global_transform
	var head: Node3D = _hero.get_node_or_null("Head")
	if head != null:
		_head_cam = head.get("cam")


func _physics_process(delta: float) -> void:
	if _hero == null or not is_instance_valid(_hero):
		return
	if not _leaving:
		_t += delta
		_ang += WHEEL_S * delta
		_place()
		return
	# Glide down into the hero's rig, tracking him as he settles.
	_swap_t = minf(_swap_t + delta, SWAP_S)
	var s := _swap_t / SWAP_S
	var e := s * s * (3.0 - 2.0 * s)
	var dest := _rig_transform()
	global_position = _from_xf.origin.lerp(dest.origin, e)
	global_transform.basis = _from_xf.basis.slerp(dest.basis, e) \
			.orthonormalized()
	if s >= 1.0:
		_finish()


## The hero's own camera transform right now (over-the-shoulder boom
## behind his back, looking at him) — the glide's destination.
func _rig_transform() -> Transform3D:
	var head: Node3D = _hero.get_node_or_null("Head")
	if head == null:
		head = _hero
	var xf := head.global_transform
	return Transform3D(xf.basis, xf.origin + xf.basis * END_OFFS)


func _finish() -> void:
	set_physics_process(false)
	if _head_cam != null and is_instance_valid(_head_cam):
		_head_cam.current = true
	handed_over.emit()
	queue_free()


## One frame of the drift: a breathing crane orbit with a slow lateral
## lead so the gaze pans across the island as we circle.
func _place() -> void:
	var r := ORBIT_R + 9.0 * sin(_t * 0.045)
	var h := HELM_H + 5.0 * sin(_t * 0.031 + 1.0)
	global_position = _center + Vector3(cos(_ang) * r, h, sin(_ang) * r)
	var lead := _center + Vector3(sin(_ang + 0.7), 0.0,
			cos(_ang + 0.7)) * 10.0
	lead.y = _center.y + 2.0
	look_at(lead, Vector3.UP)
