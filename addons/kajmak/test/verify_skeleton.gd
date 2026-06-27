@tool
extends SceneTree
## Headless equivalence check for the Kajmak skeleton (task #1).
##
## Builds the same map twice — once with stock [FuncGodotMap], once with
## [KajmakMap] — and compares the resulting mesh surface/vertex counts. At the
## skeleton stage (no culling overrides yet) the output must be identical.
##
## Run:
##   godot --headless --path external/func_godot_test_project \
##         --script res://addons/kajmak/test/verify_skeleton.gd

const MAP_FILE := "res://maps/test1.map"

func _init() -> void:
	var stock := _build_and_measure(FuncGodotMap.new())
	var kajmak := _build_and_measure(KajmakMap.new())

	print("\n==== KAJMAK SKELETON VERIFY ====")
	print("map           : ", MAP_FILE)
	print("stock  meshes : %d, surfaces: %d, vertices: %d" % stock)
	print("kajmak meshes : %d, surfaces: %d, vertices: %d" % kajmak)

	var match_ok := stock == kajmak
	print("RESULT        : ", "IDENTICAL ✓" if match_ok else "MISMATCH ✗")
	print("================================\n")
	quit(0 if match_ok else 1)

# Returns [mesh_count, surface_count, vertex_count].
func _build_and_measure(map: FuncGodotMap) -> Array:
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
