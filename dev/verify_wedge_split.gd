@tool
extends SceneTree
## Targets angled (tilted-plane) SPLITTING. Wedge A's hypotenuse is half-covered
## by the shorter wedge B and must be split, keeping the upper half. If the split
## silently fails the face is kept whole, so the area drop distinguishes the two.

const MAP_FILE := "res://dev/maps/wedge_split.map"
const HYP_HALF := 5.65685  # sqrt(4^2+4^2) * 1  (half-height of the diagonal face)

func _init() -> void:
	var stock := _stats(FuncGodotMap.new(), false)
	var kajmak := _stats(KajmakMap.new(), true)

	print("\n==== KAJMAK WEDGE-SPLIT VERIFY ====")
	print("stock : surfaces %d, verts %d, area %.3f" % [stock.surfaces, stock.verts, stock.area])
	print("kajmak: surfaces %d, verts %d, area %.3f" % [kajmak.surfaces, kajmak.verts, kajmak.area])

	var drop: float = stock.area - kajmak.area
	# Expected: B hyp removed (HYP_HALF) + A hyp split, dropping its lower half (HYP_HALF).
	var both := absf(drop - 2.0 * HYP_HALF) <= 0.1
	var only_removed := absf(drop - HYP_HALF) <= 0.1
	print("area drop: %.3f" % drop)
	print("  expect %.3f if angled split works; %.3f if split silently skipped" % [2.0 * HYP_HALF, HYP_HALF])
	var verdict := "PASS (angled split works)" if both else ("SPLIT FAILED (face kept whole)" if only_removed else "UNEXPECTED")
	print("RESULT: %s" % verdict)
	print("===================================\n")
	quit(0 if both else 1)

func _stats(map: FuncGodotMap, cull: bool) -> Dictionary:
	if map is KajmakMap:
		(map as KajmakMap).cull_hidden_faces = cull
		(map as KajmakMap).debug_log_pairs = true
	map.local_map_file = MAP_FILE
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
					result.area += 0.5 * (verts[indices[i + 1]] - verts[indices[i]]).cross(verts[indices[i + 2]] - verts[indices[i]]).length()
	map.queue_free()
	return result

func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out
