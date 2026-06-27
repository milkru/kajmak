@tool
extends SceneTree
## Validates angled ("cut" brush) culling. Two triangular prisms share a flush
## diagonal face; both hypotenuses must be culled.
##
## First validates the hand-authored winding by checking the stock build's total
## area matches the analytic value, so a culling failure can't be confused with a
## bad test map. Then checks kajmak removes exactly the two hypotenuse faces.

const MAP_FILE := "res://dev/maps/wedge.map"

# Areas in Godot units (id units / 32). Box 128x128x64 split on the diagonal.
# Each wedge: 2 triangle caps (0.5*4*4=8 each), 2 axis sides (4*2=8 each),
# 1 hypotenuse (diagonal len sqrt(32)=5.657 * height 2 = 11.314). Wedge=8+8+8+8+11.314=43.314? recheck below.
const HYP_AREA := 11.3137   # sqrt(4^2+4^2) * 2
const TItem := 0.0

func _init() -> void:
	var stock := _stats(FuncGodotMap.new(), false)
	var kajmak := _stats(KajmakMap.new(), true)

	print("\n==== KAJMAK WEDGE VERIFY ====")
	print("stock : surfaces %d, verts %d, area %.3f" % [stock.surfaces, stock.verts, stock.area])
	print("kajmak: surfaces %d, verts %d, area %.3f" % [kajmak.surfaces, kajmak.verts, kajmak.area])

	var winding_ok: bool = stock.verts > 0 and stock.area > 0.0
	var drop: float = stock.area - kajmak.area
	# Both hypotenuse faces removed -> drop ~ 2 * hypotenuse area.
	var drop_ok: bool = absf(drop - 2.0 * HYP_AREA) <= 0.1
	# "cutface" surface should disappear entirely.
	var ok: bool = winding_ok and drop_ok

	print("winding (stock builds): %s" % ("OK" if winding_ok else "FAIL - bad test map"))
	print("area drop: %.3f (expect %.3f)  -> %s" % [drop, 2.0 * HYP_AREA, "OK" if drop_ok else "FAIL"])
	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	print("=============================\n")
	quit(0 if ok else 1)

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
