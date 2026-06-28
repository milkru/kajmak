@tool
extends SceneTree
## Window-frame island regression. A 4 bar frame on a wall must cull only the ring
## footprint from the wall, leaving the center island (window opening). The wall
## surface area should drop by the ring (12 u^2), not the whole square (16 u^2).

const MAP_FILE := "res://dev/maps/window.map"
const EXPECTED_DROP := 12.0
const TOL := 0.05

func _init() -> void:
	var stock := _wall_area(FuncGodotMap.new(), false)
	var kajmak := _wall_area(KajmakMap.new(), true)
	var drop := stock - kajmak
	var ok: bool = absf(drop - EXPECTED_DROP) <= TOL
	print("\n==== WINDOW ISLAND VERIFY ====")
	print("wall area stock %.3f kajmak %.3f drop %.3f (expect %.1f = ring only)" % [stock, kajmak, drop, EXPECTED_DROP])
	print("RESULT: %s" % ("PASS" if ok else "FAIL (island wrongly culled if drop ~16)"))
	print("==============================\n")
	quit(0 if ok else 1)

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
				if not String(mesh.surface_get_name(s)).contains("wall"):
					continue
				var arr := mesh.surface_get_arrays(s)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
				for i in range(0, idx.size(), 3):
					area += 0.5 * (v[idx[i + 1]] - v[idx[i]]).cross(v[idx[i + 2]] - v[idx[i]]).length()
	map.queue_free()
	return area

func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out
