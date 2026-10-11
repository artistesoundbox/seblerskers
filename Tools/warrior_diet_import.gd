@tool
extends EditorScenePostImport

## Import diet for the oversized warrior GLBs AND the 46.6 MB
## old_lighthouse megamesh (787,747 triangles in 8 submeshes, 4 UV
## sets + tangents apiece — the same bloat pattern; 2 corner towers
## place per island). The game uses albedo textures only and no
## normal maps, so:  - TEXCOORD_1..3 are dead weight;  - TANGENT is
## only consumed by normal mapping (absent here);  - shadow meshes
## duplicate every triangle;  - LODs add copies the island never
## sells (they sparkle past 40 m behind fog). Everything else —
## geometry, materials, node structure — is left exactly as imported.


func post_import(scene: Node) -> Node:
	var trimmed_uvs := 0
	var dropped_tangents := 0
	var dieted := 0
	var stack: Array = [scene]
	while stack.size() > 0:
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			var original: Mesh = mi.mesh
			if original is ArrayMesh:
				var src := original as ArrayMesh
				var diet := ArrayMesh.new()
				for s in src.get_surface_count():
					var arrays := src.surface_get_arrays(s)
					# Drop UV1..UV3 (no materials use them) and tangents
					# (no normal maps in this pack — Godot regenerates
					# tangents on the GPU when they are ever needed).
					arrays[7] = null
					arrays[8] = null
					arrays[9] = null
					arrays[Mesh.ARRAY_TANGENT] = null
					diet.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
					diet.surface_set_material(s, src.surface_get_material(s))
					dropped_tangents += 1
					trimmed_uvs += 3
				diet.set_lightmap_size_hint(src.get_lightmap_size_hint())
				mi.mesh = diet
				# These models never cast shadows at world scale; skip
				# the engine's shadow-mesh duplicates entirely.
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				dieted += 1
	print("warrior_diet: %d meshes dieted (uv sets dropped: %d, tangents dropped: %d)" %
			[dieted, trimmed_uvs, dropped_tangents])
	return scene
