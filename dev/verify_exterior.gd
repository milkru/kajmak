@tool
extends SceneTree
## Exterior / void face culling (BSP phase 4).
##
## Three checks:
##   1. Sealed room: the exterior flood must NOT reach the room interior, and must
##      find some outside leaves.
##   2. Leaky room (no ceiling): the flood MUST reach the room interior, proving
##      leaks are detected (and showing why the feature needs a sealed map).
##   3. Culling a sealed room with cull_exterior_faces on removes the outer shell
##      (area and surface count drop) while the interior faces survive.
##
## Run:
##   godot --headless --path external/func_godot_test_project \
##         --script res://dev/verify_exterior.gd

const ROOM := "res://dev/maps/room.map"
const LEAK := "res://dev/maps/roomleak.map"
# Outer span of the room in id-space (-16..272) and inner face edge (0..256).
# func_godot scales vertices before this stage, so the BSP lives in scaled space;
# the harness derives the scale and probe point from the measured geometry.
const OUTER_SPAN := 288.0
const INNER_EDGE := 256.0

func _init() -> void:
	var all_ok := true
	print("\n==== KAJMAK EXTERIOR CULL ====")

	# 1. Sealed room flood.
	var sealed := _flood(ROOM)
	var sealed_ok: bool = sealed.center_exterior == false and sealed.exterior_leaves > 0
	all_ok = all_ok and sealed_ok
	print("sealed room: center_exterior %s exterior_leaves %d -> %s" % [
		sealed.center_exterior, sealed.exterior_leaves, "PASS" if sealed_ok else "FAIL"])

	# 2. Leaky room flood.
	var leak := _flood(LEAK)
	var leak_ok: bool = leak.center_exterior == true
	all_ok = all_ok and leak_ok
	print("leaky room:  center_exterior %s (want true) -> %s" % [
		leak.center_exterior, "PASS" if leak_ok else "FAIL"])

	# 3. Sealed room face removal. Derive the build scale from the stock mesh's
	# measured extent so the interior-area floor is scale independent.
	var stock := _stats(FuncGodotMap.new(), ROOM, false, false)
	var ext := _stats(KajmakMap.new(), ROOM, false, true)
	var scale: float = stock.span / OUTER_SPAN if stock.span > 0.0 else 1.0
	var min_interior: float = 6.0 * (INNER_EDGE * scale) * (INNER_EDGE * scale)
	# Shell removed = meaningful area drop (single-texture maps keep one surface).
	var removed_shell: bool = ext.area < stock.area * 0.95
	var interior_intact: bool = ext.area >= min_interior * 0.99
	var cull_ok: bool = removed_shell and interior_intact and ext.area > 0.0
	all_ok = all_ok and cull_ok
	print("cull: stock area %.2f surf %d | ext area %.2f surf %d (scale %.4f)" % [
		stock.area, stock.surfaces, ext.area, ext.surfaces, scale])
	print("      shell removed %s | interior intact %s (>= %.2f) -> %s" % [
		removed_shell, interior_intact, min_interior, "PASS" if cull_ok else "FAIL"])

	print("RESULT: %s" % ("PASS" if all_ok else "FAIL"))
	print("==============================\n")
	quit(0 if all_ok else 1)

# Build with the BSP debug hook and probe the flood result.
func _flood(map_file: String) -> Dictionary:
	var map := KajmakMap.new()
	map.bsp_debug = true
	map.local_map_file = map_file
	get_root().add_child(map)
	map.build()
	var bsp: Variant = map.bsp_last
	var out := {"center_exterior": false, "exterior_leaves": 0}
	if bsp != null:
		# The interior probe point is the centre of the measured bounds (scaled space).
		var leaf: Variant = bsp.locate_leaf(bsp.bounds.get_center())
		out.center_exterior = leaf != null and not leaf.solid and leaf.exterior
		out.exterior_leaves = bsp.exterior_leaf_count
	map.queue_free()
	return out

func _stats(map: FuncGodotMap, map_file: String, hidden: bool, exterior: bool) -> Dictionary:
	if map is KajmakMap:
		(map as KajmakMap).cull_hidden_faces = hidden
		(map as KajmakMap).cull_exterior_faces = exterior
	map.local_map_file = map_file
	get_root().add_child(map)
	map.build()
	var result := {"surfaces": 0, "area": 0.0, "span": 0.0}
	var mn := Vector3.INF
	var mx := -Vector3.INF
	for node in _walk(map):
		if node is MeshInstance3D and node.mesh != null:
			var mesh: Mesh = node.mesh
			result.surfaces += mesh.get_surface_count()
			for s in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(s)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				for vtx in verts:
					mn = mn.min(vtx)
					mx = mx.max(vtx)
				for i in range(0, indices.size(), 3):
					var a := verts[indices[i]]
					var b := verts[indices[i + 1]]
					var c := verts[indices[i + 2]]
					result.area += 0.5 * (b - a).cross(c - a).length()
	if mx.x > mn.x:
		result.span = mx.x - mn.x
	map.queue_free()
	return result

func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out
