@tool
extends SceneTree
## Volume-based (embedded) culling regression: a box interpenetrates a wall, with
## no face coplanar to the wall surface. The wall's "wallt" surface must still
## lose the box footprint (2x2 = 4 u^2).

const MAP_FILE := "res://dev/maps/embedded_wall.map"
const EXPECTED_WALL_DROP := 4.0
const TOL := 0.05

func _init() -> void:
	var stock := _wall_area(FuncGodotMap.new(), false)
	var kajmak := _wall_area(KajmakMap.new(), true)
	var drop := stock - kajmak
	var ok: bool = absf(drop - EXPECTED_WALL_DROP) <= TOL
	print("\n==== EMBEDDED-WALL VERIFY ====")
	print("wallt area  stock %.3f  kajmak %.3f  drop %.3f (expect %.1f)" % [stock, kajmak, drop, EXPECTED_WALL_DROP])
	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	print("==============================\n")
	quit(0 if ok else 1)

# Total area of surfaces whose name contains "wallt".
func _wall_area(map: FuncGodotMap, cull: bool) -> float:
	if map is KajmakMap:
		(map as KajmakMap).cull_hidden_faces = cull
	map.local_map_file = MAP_FILE
	get_root().add_child(map)
	map.build()
	var area := 0.0
	for node in _walk(map):
		if node is MeshInstance3D and node.mesh != null:
			var mesh: Mesh = node.mesh
			for s in mesh.get_surface_count():
				if not String(mesh.surface_get_name(s)).contains("wallt"):
					continue
				var arrays := mesh.surface_get_arrays(s)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				for i in range(0, indices.size(), 3):
					area += 0.5 * (verts[indices[i + 1]] - verts[indices[i]]).cross(verts[indices[i + 2]] - verts[indices[i]]).length()
	map.queue_free()
	return area

func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out
