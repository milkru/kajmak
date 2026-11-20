@tool
extends SceneTree
## T-junction weld and closed surfaces. Culling leaves the boundary of the union of
## static solid brushes: with the weld every edge of it is shared by two triangles (no
## T-junction, no open edge), so no hairline crack can let light through, and every
## triangle of a face faces the way the face does (none flipped). Built without the
## weld, the splits leave T-junctions (proving the check sees them).
##
## Run:
##   godot --headless --path external/func_godot_test_project \
##         --script res://dev/verify_weld.gd

# Maps whose faces are all rendered (no clip, skip or exterior culling).
const MAPS := [
	"res://dev/maps/embedded.map", "res://dev/maps/multi_brush.map",
	"res://dev/maps/far_origin.map", "res://dev/maps/floor_boxes.map",
	"res://dev/maps/window.map", "res://dev/maps/wedge.map", "res://dev/maps/wedge_split.map",
	"res://dev/maps/small_cover.map", "res://dev/maps/pillar_slab.map",
	"res://dev/maps/flush_overlap.map", "res://dev/maps/flush_nested.map",
	"res://dev/maps/mover.map",
]
const MERGE := 1.0 / 8192.0  # Godot units: corners closer than this are one
const ON_EDGE := 1.0 / 4096.0

func _init() -> void:
	var all_ok := true
	var unwelded_t := 0
	print("\n==== KAJMAK WELD ====")
	for map_file in MAPS:
		var welded := _seams(map_file, true)
		unwelded_t += _seams(map_file, false)["t_junctions"]
		var ok: bool = welded["t_junctions"] == 0 and welded["open_edges"] == 0 and welded["flipped"] == 0
		all_ok = all_ok and ok
		print("%s  T-junctions %d, open edges %d, flipped %d -> %s" % [
			map_file.get_file(), welded["t_junctions"], welded["open_edges"], welded["flipped"],
			"PASS" if ok else "FAIL"])
	var seen: bool = unwelded_t > 0
	all_ok = all_ok and seen
	print("without the weld: %d T-junction(s) -> %s" % [unwelded_t, "PASS" if seen else "FAIL (check blind?)"])
	print("RESULT: %s" % ("PASS" if all_ok else "FAIL"))
	print("=====================\n")
	quit(0 if all_ok else 1)

func _seams(map_file: String, weld: bool) -> Dictionary:
	var map := KajmakMap.new()
	map.weld_t_junctions = weld
	map.local_map_file = map_file
	get_root().add_child(map)
	map.build()
	var points: Array = []
	var ids: Dictionary = {}
	var edges: Dictionary = {}
	var flipped := 0
	for node in _walk(map):
		if not (node is MeshInstance3D and node.mesh != null):
			continue
		var xf := _to_map(node, map)
		var mesh: Mesh = node.mesh
		for s in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for t in range(0, idx.size(), 3):
				# Flat faces: the vertex normal is the face's. Godot's front faces wind
				# clockwise, so their cross product points against it.
				var a := v[idx[t]]
				if (v[idx[t + 1]] - a).cross(v[idx[t + 2]] - a).dot(n[idx[t]]) > 0.0:
					flipped += 1
				var c: Array = []
				for k in 3:
					var p: Vector3 = xf * v[idx[t + k]]
					var key := Vector3i((p / MERGE).round())
					if not ids.has(key):
						ids[key] = points.size()
						points.append(p)
					c.append(ids[key])
				for k in 3:
					var e := Vector2i(mini(c[k], c[(k + 1) % 3]), maxi(c[k], c[(k + 1) % 3]))
					if e.x != e.y:
						edges[e] = edges.get(e, 0) + 1
	var t_junctions := 0
	var open_edges := 0
	for e: Vector2i in edges:
		if edges[e] % 2 == 1:
			open_edges += 1
		if edges[e] == 1 and _corner_on(e, points):
			t_junctions += 1
	map.queue_free()
	return {"t_junctions": t_junctions, "open_edges": open_edges, "flipped": flipped}

# A node's transform relative to the map (the map is not in the tree when built here).
func _to_map(node: Node, map: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n := node
	while n != map and n is Node3D:
		xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf

# A corner lying inside edge e (brute force: the maps are small).
func _corner_on(e: Vector2i, points: Array) -> bool:
	var a: Vector3 = points[e.x]
	var b: Vector3 = points[e.y]
	var length := a.distance_to(b)
	var dir := (b - a) / length
	for p: Vector3 in points:
		var rel := p - a
		var t := rel.dot(dir)
		if t > ON_EDGE and t < length - ON_EDGE and (rel - dir * t).length() <= ON_EDGE:
			return true
	return false

func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out
