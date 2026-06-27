@tool
extends SceneTree
## Real-geometry smoke test: build the bundled test maps with stock func_godot
## and with KajmakMap (culling on), and confirm the build completes and culling
## never increases visible surface area (it only removes hidden geometry).
##
## Run:
##   godot --headless --path external/func_godot_test_project \
##         --script res://dev/verify_maps.gd

const MAPS := ["res://maps/test1.map", "res://maps/test2.map", "res://maps/test3.map"]
const AREA_SLACK := 0.01  # allow tiny float noise

func _init() -> void:
	var all_ok := true
	print("\n==== KAJMAK MAP SMOKE TEST ====")
	for map_file in MAPS:
		var stock := _stats(FuncGodotMap.new(), map_file, false)
		var kajmak := _stats(KajmakMap.new(), map_file, true)
		var area_ok: bool = kajmak.area <= stock.area + AREA_SLACK
		all_ok = all_ok and area_ok
		print("%s" % map_file)
		print("  stock : surfaces %d, verts %d, area %.2f" % [stock.surfaces, stock.verts, stock.area])
		print("  kajmak: surfaces %d, verts %d, area %.2f  (area %s)" % [
			kajmak.surfaces, kajmak.verts, kajmak.area,
			"OK" if area_ok else "INCREASED!",
		])
	print("RESULT: %s" % ("PASS" if all_ok else "FAIL"))
	print("===============================\n")
	quit(0 if all_ok else 1)

func _stats(map: FuncGodotMap, map_file: String, cull: bool) -> Dictionary:
	if map is KajmakMap:
		(map as KajmakMap).cull_hidden_faces = cull
	map.local_map_file = map_file
	get_root().add_child(map)
	map.build()

	var result := {"surfaces": 0, "verts": 0, "area": 0.0}
	for node in _walk(map):
		if node is MeshInstance3D and node.mesh != null:
			var mesh: Mesh = node.mesh
			result.surfaces += mesh.get_surface_count()
			for s in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(s)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				result.verts += verts.size()
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
