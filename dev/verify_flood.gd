@tool
extends SceneTree
## Exterior flood correctness. The BSP portal flood must agree with an independent
## voxel flood (the ground truth for "empty space connected to the outer bounds").
## Checked both ways: nothing reachable should be left unflagged (would under-cull,
## leaving void-facing faces) and nothing flagged should be unreachable (would
## over-cull, eating sealed interiors). Run on a sealed room and a leaky one.
##
## Run:
##   godot --headless --path external/func_godot_test_project \
##         --script res://dev/verify_flood.gd

const MAPS := ["res://dev/maps/room.map", "res://dev/maps/roomleak.map"]
const N := 56

func _init() -> void:
	var all_ok := true
	print("\n==== KAJMAK FLOOD VALIDATION ====")
	for mapf in MAPS:
		var m := KajmakMap.new()
		m.bsp_debug = true
		m.local_map_file = mapf
		get_root().add_child(m)
		m.build()
		var res := _check(m.bsp_last)
		var ok: bool = res.reachable_not_flagged == 0 and res.flagged_not_reachable == 0
		all_ok = all_ok and ok
		print("%-16s empty=%d exterior=%d | checked=%d under=%d over=%d -> %s" % [
			mapf.get_file(), res.empty, res.exterior, res.checked,
			res.reachable_not_flagged, res.flagged_not_reachable, "PASS" if ok else "FAIL"])
		m.queue_free()
	print("RESULT: %s" % ("PASS" if all_ok else "FAIL"))
	print("=================================\n")
	quit(0 if all_ok else 1)

func _check(bsp) -> Dictionary:
	var box: AABB = bsp.bounds.grow(bsp.bounds.size.length() * 0.02 + 0.5)
	var step := box.size / float(N)
	var solid := PackedByteArray()
	solid.resize(N * N * N)
	for i in N:
		for j in N:
			for k in N:
				var p := box.position + Vector3((i + 0.5) * step.x, (j + 0.5) * step.y, (k + 0.5) * step.z)
				solid[i * N * N + j * N + k] = 1 if bsp.is_solid_bruteforce(p) else 0

	var reach := PackedByteArray()
	reach.resize(N * N * N)
	var q: Array[int] = []
	for i in N:
		for j in N:
			for k in N:
				var edge := i == 0 or j == 0 or k == 0 or i == N - 1 or j == N - 1 or k == N - 1
				var idx := i * N * N + j * N + k
				if edge and solid[idx] == 0 and reach[idx] == 0:
					reach[idx] = 1
					q.append(idx)
	var dirs: Array[Vector3i] = [
		Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,1,0),
		Vector3i(0,-1,0), Vector3i(0,0,1), Vector3i(0,0,-1)]
	while not q.is_empty():
		var idx: int = q.pop_back()
		var ii := idx / (N * N)
		var jj := (idx / N) % N
		var kk := idx % N
		for d: Vector3i in dirs:
			var ni := ii + d.x
			var nj := jj + d.y
			var nk := kk + d.z
			if ni < 0 or nj < 0 or nk < 0 or ni >= N or nj >= N or nk >= N:
				continue
			var nidx := ni * N * N + nj * N + nk
			if solid[nidx] == 0 and reach[nidx] == 0:
				reach[nidx] = 1
				q.append(nidx)

	var out := {"empty": bsp.empty_leaf_count, "exterior": bsp.exterior_leaf_count,
		"checked": 0, "reachable_not_flagged": 0, "flagged_not_reachable": 0}
	# Sample interior cell points (step in by half a voxel so we avoid faces) and
	# compare. Skip points near boundaries where voxel and BSP disagree on solidity.
	for i in range(1, N, 2):
		for j in range(1, N, 2):
			for k in range(1, N, 2):
				var idx := i * N * N + j * N + k
				if solid[idx] == 1:
					continue
				var p := box.position + Vector3((i + 0.5) * step.x, (j + 0.5) * step.y, (k + 0.5) * step.z)
				var leaf: Variant = bsp.locate_leaf(p)
				if leaf == null or leaf.solid:
					continue
				out.checked += 1
				var vr: bool = reach[idx] == 1
				var pe: bool = leaf.exterior
				if vr and not pe:
					out.reachable_not_flagged += 1
				elif pe and not vr:
					out.flagged_not_reachable += 1
	return out
