@tool
extends SceneTree
## BSP rewrite, phase 1 harness. Builds a KajmakBSP from each map's occluder
## brushes (via the generator's bsp_debug hook) and reports tree stats. Phase 1
## does not change geometry, so this only sanity-checks that the tree builds:
## every map must produce a non-empty tree and must not trip a build guard.
##
## Run:
##   godot --headless --path external/func_godot_test_project \
##         --script res://dev/verify_bsp.gd

const MAPS := [
	"res://dev/maps/embedded.map",
	"res://dev/maps/multi_brush.map",
	"res://dev/maps/clip_occluder.map",
	"res://dev/maps/far_origin.map",
	"res://dev/maps/skip_cover.map",
	"res://dev/maps/floor_boxes.map",
	"res://dev/maps/window.map",
	"res://dev/maps/first_test.map",  # user's combined case, present only locally
]

func _init() -> void:
	var all_ok := true
	print("\n==== KAJMAK BSP PHASE 1 ====")
	for map_file in MAPS:
		if not ResourceLoader.exists(map_file) and not FileAccess.file_exists(map_file):
			print("%s  -> SKIP (not present)" % map_file.get_file())
			continue

		var map := KajmakMap.new()
		map.bsp_debug = true
		map.local_map_file = map_file
		get_root().add_child(map)
		map.build()

		var bsp: Variant = map.bsp_last
		var ok: bool = bsp != null and bsp.leaf_count > 0 and not bsp.aborted
		var mism := -1
		if bsp != null:
			mism = _solidity_mismatches(bsp)
			ok = ok and mism == 0
		all_ok = all_ok and ok
		if bsp == null:
			print("%s  -> FAIL (no tree)" % map_file.get_file())
		else:
			print("%s  -> %s  %s  solidity-mismatch %d" % [
				map_file.get_file(), "PASS" if ok else "FAIL", bsp.stats_string(), mism])
		map.queue_free()

	print("RESULT: %s" % ("PASS" if all_ok else "FAIL"))
	print("============================\n")
	quit(0 if all_ok else 1)

# Sample a jittered grid across the map bounds and compare the tree's leaf
# solidity against the direct point-in-brush ground truth. The jitter keeps
# sample points off grid-aligned brush planes so boundary ties do not register
# as false mismatches.
func _solidity_mismatches(bsp) -> int:
	var box: AABB = bsp.bounds
	var n := 12
	var mismatches := 0
	for ix in n:
		for iy in n:
			for iz in n:
				var t := Vector3(
					(ix + 0.317) / float(n),
					(iy + 0.523) / float(n),
					(iz + 0.731) / float(n))
				var p := box.position + Vector3(box.size.x * t.x, box.size.y * t.y, box.size.z * t.z)
				if bsp.is_solid(p) != bsp.is_solid_bruteforce(p):
					mismatches += 1
	return mismatches
