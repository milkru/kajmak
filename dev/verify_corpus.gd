@tool
extends SceneTree
## Edge-case corpus for task #6 robustness. Each map isolates one case; we build
## it with stock func_godot and with KajmakMap and assert the expected change in
## total visible surface area and surface count.
##
## Run:
##   godot --headless --path external/func_godot_test_project \
##         --script res://dev/verify_corpus.gd

const AREA_TOLERANCE := 0.05

# map -> {drop: expected area drop, surf: expected surface-count delta, note}
const CASES := {
	"res://dev/maps/embedded.map":      {"drop": 6.0, "surf": -1, "note": "embedded box fully buried -> removed"},
	"res://dev/maps/multi_brush.map":   {"drop": 4.0, "surf": 0,  "note": "two covers -> two bottoms removed + top split (2 holes)"},
	"res://dev/maps/clip_occluder.map": {"drop": 0.0, "surf": 0,  "note": "clip must NOT occlude"},
	"res://dev/maps/far_origin.map":    {"drop": 8.0, "surf": -1, "note": "cull+split far from origin"},
	"res://dev/maps/skip_cover.map":    {"drop": 4.0, "surf": 0,  "note": "skip face IS an occluder -> wall behind it splits"},
	"res://dev/maps/floor_boxes.map":   {"drop": 16.0, "surf": 0, "note": "big floor + small boxes: floor must split (big-face/small-hole)"},
}

func _init() -> void:
	var all_ok := true
	print("\n==== KAJMAK CORPUS ====")
	for map_file in CASES:
		var case: Dictionary = CASES[map_file]
		var stock := _stats(FuncGodotMap.new(), map_file, false)
		var kajmak := _stats(KajmakMap.new(), map_file, true)

		var drop: float = stock.area - kajmak.area
		var surf_delta: int = kajmak.surfaces - stock.surfaces
		var drop_ok: bool = absf(drop - case.drop) <= AREA_TOLERANCE
		var surf_ok: bool = surf_delta == case.surf
		var ok: bool = drop_ok and surf_ok
		all_ok = all_ok and ok

		print("%s  -> %s" % [map_file.get_file(), "PASS" if ok else "FAIL"])
		print("   %s" % case.note)
		print("   area drop %.3f (want %.1f) %s | surface delta %d (want %d) %s" % [
			drop, case.drop, "ok" if drop_ok else "BAD",
			surf_delta, case.surf, "ok" if surf_ok else "BAD",
		])

	print("RESULT: %s" % ("PASS" if all_ok else "FAIL"))
	print("=======================\n")
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
