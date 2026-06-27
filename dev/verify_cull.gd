@tool
extends SceneTree
## Headless check for culling + splitting (tasks #2-#5).
##
## Builds dev/maps/cull_test.map with stock func_godot and with KajmakMap.
## Big box top (texture "ground", area 4x4=16 u^2) has a small box glued to its
## centre. Expected with culling on:
##   - small box bottom face ("hidden_tex", 2x2=4 u^2) is fully covered -> removed
##   - big box top is partially covered -> SPLIT into a frame, dropping the inner
##     2x2=4 u^2 region but keeping the visible border
## So total surface area must drop by exactly 8 u^2 (4 removed + 4 from the split),
## and the "hidden_tex" surface disappears (one fewer surface). An area drop of
## only 4 would mean the split didn't happen; a drop of 20 would mean the whole
## top was wrongly removed.
##
## Run:
##   godot --headless --path external/func_godot_test_project \
##         --script res://dev/verify_cull.gd

const MAP_FILE := "res://dev/maps/cull_test.map"
const EXPECTED_AREA_DROP := 8.0
const AREA_TOLERANCE := 0.05

func _init() -> void:
	var stock := _stats(FuncGodotMap.new(), false)

	var kajmak_map := KajmakMap.new()
	kajmak_map.debug_log_pairs = true
	var kajmak := _stats(kajmak_map, true)

	print("\n==== KAJMAK CULL/SPLIT VERIFY ====")
	print("stock  : surfaces %d, verts %d, tris %d, area %.3f" % [stock.surfaces, stock.verts, stock.tris, stock.area])
	print("kajmak : surfaces %d, verts %d, tris %d, area %.3f" % [kajmak.surfaces, kajmak.verts, kajmak.tris, kajmak.area])

	var surfaces_ok: bool = kajmak.surfaces == stock.surfaces - 1
	var area_drop: float = stock.area - kajmak.area
	var area_ok: bool = absf(area_drop - EXPECTED_AREA_DROP) <= AREA_TOLERANCE
	# A split adds vertices to the top face (frame has more verts than a quad).
	var split_ok: bool = kajmak.tris > stock.tris - 2  # net triangles did not collapse
	var ok: bool = surfaces_ok and area_ok

	print("surfaces      : %d (expect %d)            -> %s" % [kajmak.surfaces, stock.surfaces - 1, "OK" if surfaces_ok else "FAIL"])
	print("area drop     : %.3f (expect %.1f)        -> %s" % [area_drop, EXPECTED_AREA_DROP, "OK" if area_ok else "FAIL"])
	print("RESULT        : %s" % ("PASS" if ok else "FAIL"))
	print("==================================\n")
	quit(0 if ok else 1)

func _stats(map: FuncGodotMap, cull: bool) -> Dictionary:
	if map is KajmakMap:
		(map as KajmakMap).cull_hidden_faces = cull
	map.local_map_file = MAP_FILE
	get_root().add_child(map)
	map.build()

	var result := {"meshes": 0, "surfaces": 0, "verts": 0, "tris": 0, "area": 0.0}
	for node in _walk(map):
		if node is MeshInstance3D and node.mesh != null:
			var mesh: Mesh = node.mesh
			result.meshes += 1
			result.surfaces += mesh.get_surface_count()
			for s in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(s)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				result.verts += verts.size()
				result.tris += indices.size() / 3
				for i in range(0, indices.size(), 3):
					var a := verts[indices[i]]
					var b := verts[indices[i + 1]]
					var c := verts[indices[i + 2]]
					result.area += 0.5 * (b - a).cross(c - a).length()

	map.queue_free()
	return result

func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out
