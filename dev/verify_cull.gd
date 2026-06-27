@tool
extends SceneTree
## Headless check for the full-overlap cull (tasks #2 + #3).
##
## Builds dev/maps/cull_test.map with stock func_godot and with KajmakMap (cull
## on). The small box's bottom face is flush against and fully inside the big
## box's top face, with a different texture, so it must be culled — proving
## cross-texture, cross-brush full-overlap culling. The partially-covered big top
## face must survive (splitting it is task #4).
##
## Run:
##   godot --headless --path external/func_godot_test_project \
##         --script res://dev/verify_cull.gd

const MAP_FILE := "res://dev/maps/cull_test.map"

func _init() -> void:
	var stock := _build_and_measure(FuncGodotMap.new(), false, false)

	var kajmak_map := KajmakMap.new()
	kajmak_map.debug_log_pairs = true
	var kajmak := _build_and_measure(kajmak_map, true, true)

	print("\n==== KAJMAK CULL VERIFY ====")
	print("map           : ", MAP_FILE)
	print("stock  meshes : %d, surfaces: %d, vertices: %d" % stock)
	print("kajmak meshes : %d, surfaces: %d, vertices: %d" % kajmak)

	# The single fully-covered face (its own texture surface) should be removed:
	# one fewer surface, and four fewer vertices (one quad).
	var surfaces_ok: bool = kajmak[1] == stock[1] - 1
	var verts_ok: bool = kajmak[2] == stock[2] - 4
	var ok: bool = surfaces_ok and verts_ok

	print("surface delta : %d (expect -1)  -> %s" % [int(kajmak[1]) - int(stock[1]), "OK" if surfaces_ok else "FAIL"])
	print("vertex delta  : %d (expect -4)  -> %s" % [int(kajmak[2]) - int(stock[2]), "OK" if verts_ok else "FAIL"])
	print("RESULT        : ", "PASS" if ok else "FAIL")
	print("============================\n")
	quit(0 if ok else 1)

# Returns [mesh_count, surface_count, vertex_count].
func _build_and_measure(map: FuncGodotMap, _is_kajmak: bool, cull: bool) -> Array:
	if map is KajmakMap:
		(map as KajmakMap).cull_hidden_faces = cull
	map.local_map_file = MAP_FILE
	get_root().add_child(map)
	map.build()

	var meshes := 0
	var surfaces := 0
	var vertices := 0
	for node in _walk(map):
		if node is MeshInstance3D and node.mesh != null:
			var mesh: Mesh = node.mesh
			meshes += 1
			surfaces += mesh.get_surface_count()
			for s in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(s)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				vertices += verts.size()

	map.queue_free()
	return [meshes, surfaces, vertices]

func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out
