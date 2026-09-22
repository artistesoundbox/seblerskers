class_name VillageNightLights
extends Node3D
## The village at night: warm window glows on the houses and crackling
## torches by the wells. Created by PropScatter after placement; the
## glows/torches attach as children of their own house/well node, so
## the random placement yaw and the solved scale are inherited and the
## panes always hug a real facade. Registers in the "night_lights"
## group so DayNight fades the whole kit in after sunset and out at
## dawn — by day the village reads exactly as before.

## Warm hearth color for the window panes.
const WINDOW_COLOR := Color(1.0, 0.72, 0.35)
## Torch flame color (slightly hotter than the hearths).
const TORCH_COLOR := Color(1.0, 0.58, 0.22)
## Panes sit this far off the wall (local metres, pre-scale) so they
## never z-fight the facade geometry.
const PANE_OUT := 0.06
## Torch post/flame heights (local metres, pre-scale of the well).
const TORCH_H := 1.7

var _panes: Array[MeshInstance3D] = []
var _panes_mat: StandardMaterial3D
## Per-torch rig: { light, flame, phase } for the flicker pass.
var _torches: Array = []
var _flames_mat: StandardMaterial3D
var _gate := 0.0
var _t := 0.0
var _rng := RandomNumberGenerator.new()


func setup(win_descs: Array, torch_descs: Array, rng_seed: int) -> void:
	_rng.seed = rng_seed
	_panes_mat = _make_pane_mat()
	_flames_mat = _make_flame_mat()
	for d in win_descs:
		_dress_house(d.node as Node3D, d.ab as AABB)
	for d in torch_descs:
		_dress_well(d.node as Node3D, d.ab as AABB)


func _ready() -> void:
	# Join the night-light kit: DayNight broadcasts the gate every
	# frame, so late registration is handled automatically.
	add_to_group("night_lights")
	set_process(false)
	_apply_gate()


func on_night_register(_ctrl: Node) -> void:
	pass  # Late joiners handled by the per-frame group broadcast.


func on_night_gate(g: float) -> void:
	_gate = clampf(g, 0.0, 1.0)
	_apply_gate()


func _apply_gate() -> void:
	var active := _gate > 0.001
	set_process(active)
	for p in _panes:
		p.visible = active
	for t in _torches:
		(t.flame as MeshInstance3D).visible = active
		(t.light as OmniLight3D).visible = active
	for l in _lights_glow:
		l.visible = active


func _process(delta: float) -> void:
	_t += delta
	for t in _torches:
		# Torch flicker: fast layered sines — fire, not neon.
		var ph: float = t.phase
		var f := 0.78 + 0.16 * sin(_t * 11.0 + ph) \
				+ 0.06 * sin(_t * 23.0 + ph * 2.7)
		var l := t.light as OmniLight3D
		l.light_energy = 1.6 * f * _gate
		var fl := t.flame as MeshInstance3D
		fl.scale = Vector3(1.0, 1.0 + 0.18 * sin(_t * 17.0 + ph * 1.3), 1.0)


## Panes + (sometimes) a hearth light on one house, attached to the
## house node so yaw/scale are inherited. `ab` is the model's RAW
## (pre-scale) AABB: local ground sits at y = ab.position.y.
func _dress_house(house: Node3D, ab: AABB) -> void:
	var cx := ab.position.x + ab.size.x * 0.5
	var y := ab.position.y + ab.size.y * 0.62
	var pane_w := clampf(ab.size.x * 0.18, 0.35, 1.6)
	var pane_h := clampf(ab.size.y * 0.2, 0.4, 1.3)
	# Two panes on opposing facades (+Z and -Z in local space).
	var spots := [
		{"pos": Vector3(cx * 0.8, y, ab.end.z + PANE_OUT), "yaw": 0.0},
		{"pos": Vector3(cx * 1.2, y, ab.position.z - PANE_OUT),
				"yaw": PI},
	]
	for sp in spots:
		var pane := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(pane_w, pane_h)
		pane.mesh = quad
		pane.material_override = _panes_mat
		pane.position = sp.pos
		pane.rotation.y = sp.yaw
		pane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pane.visible = false
		house.add_child(pane)
		_panes.append(pane)
	# A hearth light on ~40% of houses: a cheap warm glow spilling on
	# the ground around lit homes, not a light per window.
	if _rng.randf() < 0.4:
		var hl := OmniLight3D.new()
		hl.light_color = WINDOW_COLOR
		hl.omni_range = 7.0
		hl.light_energy = 1.1
		hl.shadow_enabled = false
		hl.position = Vector3(cx, y + 0.5, 0.0)
		hl.visible = false
		house.add_child(hl)
		_lights_glow.append(hl)


var _lights_glow: Array[OmniLight3D] = []


## A crackling torch beside one well: post + billboard flame + light,
## attached to the well node so placement yaw/scale are inherited.
func _dress_well(well: Node3D, ab: AABB) -> void:
	# Local ground is y = ab.position.y; the well's centre in xz:
	var cx := ab.position.x + ab.size.x * 0.5
	var cz := ab.position.z + ab.size.z * 0.5
	var gy := ab.position.y
	var ang := _rng.randf() * TAU
	var r := maxf(ab.size.x, ab.size.z) * 0.5 + 1.1
	var torch := Node3D.new()
	torch.position = Vector3(cx + cos(ang) * r, gy, cz + sin(ang) * r)
	var post := MeshInstance3D.new()
	var post_mesh := CylinderMesh.new()
	post_mesh.top_radius = 0.045
	post_mesh.bottom_radius = 0.055
	post_mesh.height = TORCH_H
	post.mesh = post_mesh
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = Color(0.32, 0.22, 0.13)
	post.material_override = post_mat
	post.position.y = TORCH_H * 0.5
	post.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	torch.add_child(post)
	var flame := MeshInstance3D.new()
	var fmesh := QuadMesh.new()
	fmesh.size = Vector2(0.42, 0.6)
	flame.mesh = fmesh
	flame.material_override = _flames_mat
	flame.position.y = TORCH_H + 0.28
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flame.visible = false
	torch.add_child(flame)
	var light := OmniLight3D.new()
	light.light_color = TORCH_COLOR
	light.omni_range = 8.0
	light.light_energy = 1.6
	light.shadow_enabled = false
	light.position.y = TORCH_H + 0.3
	light.visible = false
	torch.add_child(light)
	_torches.append({"light": light, "flame": flame,
			"phase": _rng.randf() * TAU})
	well.add_child(torch)


func _make_pane_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	m.albedo_color = WINDOW_COLOR
	m.albedo_color.a = 0.72
	m.emission_enabled = true
	m.emission = WINDOW_COLOR
	m.emission_energy_multiplier = 1.6
	m.disable_receive_shadows = true
	return m


func _make_flame_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	# Billboard: the flame reads as fire from every direction.
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = TORCH_COLOR
	m.albedo_color.a = 0.85
	m.emission_enabled = true
	m.emission = TORCH_COLOR
	m.emission_energy_multiplier = 2.2
	m.disable_receive_shadows = true
	return m
