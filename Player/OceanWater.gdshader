shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley,
		specular_schlick_ggx;

// The island's ocean: an animated, realistic water surface.
// - Vertex swell identical to PropScatter._swell_y (the ships bob on
//   the SAME formula, fed through the swell_t uniform so CPU and GPU
//   share one clock).
// - Procedurally animated wave normals for sparkle and light play.
// - Screen-depth shore fade: water turns clear and shallow-coloured
//   where the sea floor rises, with a drifting foam line at the edge.
// - Synthesized caustics (the classic layered-vortex pattern) that
//   dance strongest over the shallow sea floor.

uniform float swell_t = 0.0;
// Scene depth behind the water (Godot 4: declared, not builtin).
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec3 deep_color : source_color = vec3(0.015, 0.11, 0.22);
uniform vec3 shallow_color : source_color = vec3(0.09, 0.42, 0.47);
uniform vec3 foam_color : source_color = vec3(0.93, 0.98, 1.0);
uniform vec3 caustic_color : source_color = vec3(0.62, 0.92, 1.0);
uniform float wave_height = 0.22;
uniform float wave_period = 5.0;
uniform float wave_crests = 9.0;
uniform float ocean_size = 3600.0;
uniform float alpha_shallow = 0.55;
uniform float alpha_deep = 0.96;
uniform float shore_fade_dist = 2.2;
uniform float foam_width = 1.2;
uniform float caustic_strength = 0.5;

varying vec3 world_pos;

// Must match PropScatter._swell_y exactly (wave_height = SWELL_HEIGHT,
// wave_period = SWELL_PERIOD, wave_crests = SWELL_CRESTS).
float swell(vec2 p, float t) {
	float k = 6.2831853 * wave_crests / ocean_size;
	float w = 6.2831853 / wave_period;
	return wave_height * (sin(k * p.x + w * t)
			+ sin(k * (p.x * 0.7 + p.y) - w * t * 0.8)) * 0.5;
}

void vertex() {
	// The mesh instance sits at the origin with an identity basis, so
	// model space == world space here.
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos = wp;
	VERTEX.y += swell(wp.xz, swell_t);
	// Analytic normal from finite differences of the same field.
	float e = 2.0;
	float hx = swell(wp.xz + vec2(e, 0.0), swell_t)
			- swell(wp.xz - vec2(e, 0.0), swell_t);
	float hz = swell(wp.xz + vec2(0.0, e), swell_t)
			- swell(wp.xz - vec2(0.0, e), swell_t);
	NORMAL = normalize(vec3(-hx / (2.0 * e), 1.0, -hz / (2.0 * e)));
}

// Layered-vortex caustics: two sinusoidal feedback fields min-blended.
// Cheap, seamless, and reads as sunlight focusing through water.
float caustic(vec2 p, float t) {
	vec2 i = p;
	float c = 0.0;
	float inten = 0.005;
	for (int n = 0; n < 4; n++) {
		float ft = t * (1.0 - 3.5 / float(n + 1));
		i = p + vec2(cos(ft - i.x) + sin(ft + i.y),
				sin(ft - i.y) + cos(ft + i.x));
		c += 1.0 / length(vec2(
				p.x / (sin(i.x + ft) / inten),
				p.y / (cos(i.y + ft) / inten)));
	}
	c /= 4.0;
	c = 1.17 - pow(c, 1.4);
	return clamp(pow(abs(c), 8.0), 0.0, 3.0);
}

void fragment() {
	float t = swell_t;
	vec2 p = world_pos.xz;

	// Scene depth behind this fragment -> water depth at this pixel.
	float raw_depth = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV, raw_depth) * 2.0 - 1.0;
	vec4 view_p = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view_p.xyz /= view_p.w;
	float scene_z = -view_p.z;
	float water_z = -VERTEX.z;
	float depth_diff = max(scene_z - water_z, 0.0);

	// Depth colour ramp: teal shallows into deep blue.
	float df = smoothstep(0.0, shore_fade_dist * 7.0, depth_diff);
	vec3 albedo = mix(shallow_color, deep_color, df);

	// Animated wave normals: three crossing sine fields, packed into
	// the tangent-space normal map. Cheap and endless.
	float a1 = sin(p.x * 0.7 + t * 1.3) * cos(p.y * 0.8 - t * 1.1);
	float a2 = sin((p.x + p.y) * 0.35 - t * 0.8);
	float a3 = sin(p.x * 0.11 - t * 0.45) * cos(p.y * 0.13 + t * 0.5);
	vec2 nm = vec2(a1 * 0.20 + a2 * 0.10 + a3 * 0.16,
			a1 * 0.14 - a2 * 0.12 - a3 * 0.10);
	NORMAL_MAP = normalize(vec3(nm, 1.0)) * 0.5 + 0.5;

	// Fresnel: grazing angles mirror the sky.
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL),
			normalize(VIEW)), 0.0, 1.0), 3.0);
	albedo = mix(albedo, vec3(0.85, 0.93, 1.0), fres * 0.30);

	ALBEDO = albedo;
	ALPHA = mix(alpha_shallow, alpha_deep, df);
	ALPHA *= smoothstep(0.0, shore_fade_dist, depth_diff);
	ALPHA = mix(ALPHA, 0.98, fres * 0.45);
	ROUGHNESS = 0.06;
	METALLIC = 0.05;

	// Caustics: strongest where the water is shallow (light focusing
	// on the visible sea floor), faint shimmer out deep.
	float shallow_f = 1.0 - smoothstep(0.0, 8.0, depth_diff);
	float ca = caustic(p * 0.16, t * 0.55);
	EMISSION += caustic_color * ca * caustic_strength
			* (0.30 + 0.70 * shallow_f);

	// Shore foam: a broken white line where the water gets thin.
	float foam_band = 1.0 - smoothstep(0.0, foam_width, depth_diff);
	float foam_noise = 0.55 + 0.45 * sin(p.x * 2.1 + t * 2.2)
			* sin(p.y * 1.7 - t * 1.6);
	EMISSION += foam_color * foam_band * foam_noise
			* smoothstep(0.03, 0.35, depth_diff);
}
