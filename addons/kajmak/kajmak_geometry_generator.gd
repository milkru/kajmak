@tool
class_name KajmakGeometryGenerator extends FuncGodotGeometryGenerator
## func_godot geometry generator with import-time visible-surface culling.
##
## Adds a global hidden-face cull pre-pass (qbsp/vbsp-style) without touching
## func_godot. It runs after winding and before surface generation, while faces are
## still in shared id-space, so they compare directly across brushes and textures.
## Buried faces are removed; faces partly covered by an opposite coplanar face, or
## partly inside another brush, are split and the visible remainder re-triangulated.
##
## A last pass welds T-junctions (a corner of one face on another face's edge), so
## neighbouring faces share their corners and leave no hairline cracks.
##
## Not handled (see RESEARCH.md): illusionary/liquid brushes are treated as occluders.

## When false (with [member cull_exterior] and [member weld_t_junctions] off), builds
## identically to stock func_godot (regression escape hatch).
var enable_cull: bool = true
## When true, also remove faces whose front side opens onto the exterior void of a
## sealed map (BSP flood from outside). Off by default and independent of culling.
var cull_exterior: bool = false
## When true, weld T-junctions after culling (see [method weld_t_junction_faces]).
var weld_t_junctions: bool = true
## Classnames of static brush entities. Their brushes hide each other's faces. Any other
## brush entity (a door, a lift) may move, so only its own brushes hide its faces and its
## brushes hide nothing else, as qbsp works per entity.
var static_classes: PackedStringArray = ["worldspawn", "func_detail", "func_group"]
var _entity_static: Array = []  # per entity index: in static_classes
## Classnames of see-through brush entities (alpha cutouts: a railing panel, foliage). Their
## brushes hide no face, not even each other's; solid brushes still hide their faces.
var see_through_classes: PackedStringArray = []
## When true, prints per-face cull/split decisions.
var debug_log_pairs: bool = false
## Dev hook (dev/verify_bsp.gd): build the occluder BSP and print stats instead of
## culling. Off in normal builds, so output is unchanged.
var bsp_debug: bool = false
## Filled by [method _bsp_debug_stats] for a harness to read back.
var bsp_last: Variant = null
## Optional [KajmakMap.BuildState]; set its cancelled flag to abort the build early.
var cancel_state: Variant = null
const _KajmakBSPScript = preload("res://addons/kajmak/kajmak_bsp.gd")

func _cancelled() -> bool:
	return cancel_state != null and cancel_state.cancelled

# brush -> [AABB, interior_point], snapshotted from original geometry before culling.
var _brush_orig: Dictionary = {}
var _see_through: Dictionary = {}  # snapshotted brushes of see_through_classes: they seal nothing

# Below this area (in the geometry's units, squared) a face is degenerate and left alone.
const _OVERLAP_EPSILON := 1.0e-4
# How far (map units) a brush must reach in front of a face to bury the part of it
# inside: above float noise, below the thinnest brush TrenchBroom's grid makes (1/8).
const _VOLUME_PROBE := 1.0 / 64.0
# Float noise, not geometry: an area up to a strip this wide (map units, scaled like
# the geometry) along a face's outline. Covers, remainders and trims below it are
# ignored. It scales with the outline, not the area: a fraction of the area let a big
# face ignore real brushes on it (a 4x16 skirting on a 1120x576 floor is under 1e-4 of
# it), and the floor under them stayed, lit through the hollow brushes and bleeding
# into the visible floor's lightmap.
const _NOISE_WIDTH := 1.0 / 1024.0
const _COPLANAR_TOLERANCE := 0.001
const _DEDUP_PRECISION := 1024.0
const _VOLUME_TOLERANCE := 0.001  # point-in-brush distance tolerance (Godot units)
# Exterior pass: _DEGENERATE_AREA drops slivers (in the geometry's units, squared).
const _DEGENERATE_AREA := 1.0e-9
# Reject a merged exterior triangulation (use the fan fallback) when its area drifts
# from the kept area by more than this fraction.
const _TRIANGULATION_AREA_TOLERANCE := 0.02

# Full synchronous build (runtime, headless). The editor calls the three phases
# separately so only the cull runs on a worker thread.
func build(build_flags: int, entities: Array[_EntityData]) -> Error:
	var err := generate_pre_cull(entities)
	if err != OK:
		return err
	err = cull_step()
	if err != OK:
		return err
	return generate_post_cull(build_flags)

## Phase 1 (MAIN thread): materials + brush vertices + origins + winding. Touches
## resources (textures/materials) and so must not run on a worker thread.
func generate_pre_cull(entities: Array[_EntityData]) -> Error:
	var entity_count: int = entities.size()
	declare_step.emit("Preparing %s %s" % [entity_count, "entity" if entity_count == 1 else "entities"])
	entity_data = entities

	declare_step.emit("Gathering materials")
	var texture_map: Array[Dictionary] = FuncGodotUtil.build_texture_map(entity_data, map_settings)
	texture_materials = texture_map[0]
	texture_sizes = texture_map[1]

	var task_id: int
	declare_step.emit("Generating brush vertices")
	task_id = WorkerThreadPool.add_group_task(generate_entity_vertices, entity_count, -1, false, "Generate Brush Vertices")
	WorkerThreadPool.wait_for_group_task_completion(task_id)

	declare_step.emit("Determining solid entity origins")
	task_id = WorkerThreadPool.add_group_task(determine_entity_origins, entity_count, -1, false, "Determine Entity Origins")
	WorkerThreadPool.wait_for_group_task_completion(task_id)

	declare_step.emit("Winding faces")
	task_id = WorkerThreadPool.add_group_task(wind_entity_faces, entity_count, -1, false, "Wind Brush Faces")
	WorkerThreadPool.wait_for_group_task_completion(task_id)
	return OK

## Phase 2 (any thread): hidden-face and exterior culling. Pure face math, no
## resources or scene access, so the editor runs it off the main thread.
func cull_step() -> Error:
	if _cancelled():
		return FAILED

	# Snapshot each brush's bounds + interior point before culling: both passes need
	# a stable interior point, and recomputing it after one pass erased faces would
	# corrupt the other.
	if bsp_debug or cull_exterior or enable_cull:
		_snapshot_brushes()

	if bsp_debug:
		declare_step.emit("BSP debug stats")
		_bsp_debug_stats()
	else:
		# Hidden faces first, then exterior trims whatever remains to its visible parts.
		if enable_cull:
			declare_step.emit("Culling hidden faces")
			cull_hidden_faces()
		if cull_exterior:
			declare_step.emit("Culling exterior faces")
			cull_exterior_faces()
		# Last: culling and splitting leave the outlines that need welding.
		if weld_t_junctions and not _cancelled():
			declare_step.emit("Welding T-junctions")
			weld_t_junction_faces()

	if _cancelled():
		return FAILED
	return OK

## Phase 3 (MAIN thread): surface generation + UV2 unwrap (creates mesh resources).
func generate_post_cull(build_flags: int) -> Error:
	var entity_count: int = entity_data.size()
	declare_step.emit("Generating surfaces")
	var task_id := WorkerThreadPool.add_group_task(generate_entity_surfaces, entity_count, -1, false, "Generate Surfaces")
	WorkerThreadPool.wait_for_group_task_completion(task_id)

	if build_flags & FuncGodotMap.BuildFlags.UNWRAP_UV2:
		declare_step.emit("Unwrapping UV2s")
		var texel_size: float = map_settings.uv_unwrap_texel_size * map_settings.scale_factor
		for entity_index in entity_count:
			unwrap_uv2s(entity_index, texel_size)

	declare_step.emit("Geometry generation complete")
	return OK

#region HIDDEN-FACE CULLING

# Record each solid brush's AABB + interior point before culling, so both passes
# orient their volume tests from a point that is inside whichever runs first.
func _snapshot_brushes() -> void:
	_brush_orig.clear()
	_see_through.clear()
	for entity in entity_data:
		if not _entity_renders(entity):
			continue
		var hides := _entity_hides(entity)
		for brush in entity.brushes:
			if _brush_has_solid_face(brush):
				_brush_orig[brush] = _brush_bounds(brush)
				if not hides:
					_see_through[brush] = true

# Snapshotted [AABB, interior] for a brush, falling back to live geometry.
func _brush_origin_bounds(brush: _BrushData) -> Array:
	return _brush_orig.get(brush, _brush_bounds(brush))

## Remove faces buried inside another solid brush, and split faces partly covered
## (by an opposite coplanar face, by another brush's volume, or by a later brush's flush
## face) down to their visible remainder.
func cull_hidden_faces() -> void:
	var occluders: Array = []   # {brush, entity, aabb, centroid, points}
	var order: Dictionary = {}  # brush -> its place in the map (later brushes win ties)
	var records: Array = []     # {entity, brush, face}
	var bucket: Dictionary = {} # Vector4i -> Array[{face, brush, entity, verts}]

	_entity_static.clear()
	for entity in entity_data:
		_entity_static.append(entity != null and String(entity.properties.get("classname", "")) in static_classes)

	for entity_index in entity_data.size():
		var entity: _EntityData = entity_data[entity_index]
		if not _entity_renders(entity):
			continue
		var hides := _entity_hides(entity)
		for brush in entity.brushes:
			# Solid (any non-clip/non-origin face, including skip) brushes occlude, unless see-through.
			if hides and _brush_has_solid_face(brush):
				var bounds := _brush_origin_bounds(brush)
				var points := PackedVector3Array()
				for f in brush.faces:
					points.append_array(f.vertices)
				order[brush] = occluders.size()
				occluders.append({"brush": brush, "entity": entity_index, "aabb": bounds[0],
					"centroid": bounds[1], "points": points})
			for face in brush.faces:
				# Snapshot the cover winding now: splitting mutates face.vertices, and
				# covers must reflect the original geometry, not a half-cut neighbour.
				if hides and _is_solid_face(face):
					var entry := {"face": face, "brush": brush, "entity": entity_index,
						"verts": face.vertices.duplicate()}
					var key := _plane_key(face.plane)
					if bucket.has(key):
						bucket[key].append(entry)
					else:
						bucket[key] = [entry]
				# Candidates that can be culled/split: only rendered faces.
				if _is_visual_face(face):
					records.append({"entity": entity_index, "brush": brush, "face": face})

	var to_remove: Array = []      # [brush, face]
	var removed: Dictionary = {}   # face -> true
	var split_count: int = 0
	var grid := _occluder_grid(occluders)

	# Pass 1: remove faces fully buried inside another solid brush volume.
	for record in records:
		if _cancelled():
			return
		var face: _FaceData = record["face"]
		var near := _occluders_near(grid, occluders, _aabb_of(face.vertices))
		if _face_buried(face, record["brush"], record["entity"], near):
			to_remove.append([record["brush"], face])
			removed[face] = true
			if debug_log_pairs:
				print("[KAJMAK] e%d '%s' buried -> removed" % [record["entity"], face.texture])

	# Pass 2: split faces partly covered by opposite coplanar faces or partly inside
	# other solid brushes.
	for record in records:
		if _cancelled():
			return
		var face: _FaceData = record["face"]
		if removed.has(face):
			continue

		var opposite := Plane(face.plane)
		opposite.normal = -opposite.normal
		opposite.d = -opposite.d
		var opposite_key := _plane_key(opposite)

		# In-plane basis matching func_godot's winding frame (v = u x normal) so
		# rebuilt triangles keep the same front-facing orientation.
		var u := _plane_tangent(face.plane.normal)
		var v := u.cross(face.plane.normal).normalized()
		var origin: Vector3 = face.plane.get_center()
		var face_2d := _project_2d(face.vertices, origin, u, v)
		if _signed_area_2d(face_2d) < 0.0:
			face_2d.reverse()  # normalise to CCW so boolean ops are orientation-safe
		var face_area := absf(_signed_area_2d(face_2d))
		if face_area <= _OVERLAP_EPSILON:
			continue
		var noise := _map_units(_NOISE_WIDTH) * _perimeter_2d(face_2d)

		var covers: Array = []
		for other in bucket.get(opposite_key, []):
			var other_face: _FaceData = other["face"]
			if other_face == face:
				continue
			if not (-face.plane.normal).is_equal_approx(other_face.plane.normal):
				continue
			if not other_face.plane.has_point(face.plane.get_center(), _COPLANAR_TOLERANCE):
				continue
			if not _may_cover(other["entity"], record["entity"]):
				continue
			# Project the snapshot (original) winding, not the possibly-mutated live one.
			var other_2d := _project_2d(other["verts"], origin, u, v)
			# Opposite-facing faces project with reversed winding; normalise to CCW
			# so the boolean ops below treat it as a solid region, not a hole.
			if _signed_area_2d(other_2d) < 0.0:
				other_2d.reverse()
			if _intersection_area_2d(face_2d, other_2d) <= noise:
				continue
			covers.append(other_2d)
		var near := _occluders_near(grid, occluders, _aabb_of(face.vertices))
		for cover in _volume_covers(face, record["brush"], record["entity"], near, origin, u, v):
			if absf(_signed_area_2d(cover)) > noise:
				covers.append(cover)
		# Overlapping faces flush on one plane, facing the same way (stacked steps' sides):
		# both would draw and z-fight. As in qbsp, the later brush keeps its face.
		var own_order: int = order.get(record["brush"], -1)
		for other in bucket.get(_plane_key(face.plane), []):
			var other_face: _FaceData = other["face"]
			# A face pass 1 removed keeps nothing: the region stays this face's.
			if other_face == face or removed.has(other_face) or not _is_visual_face(other_face):
				continue
			if order.get(other["brush"], -1) <= own_order:
				continue
			if not _may_cover(other["entity"], record["entity"]):
				continue
			if not face.plane.normal.is_equal_approx(other_face.plane.normal):
				continue
			if not other_face.plane.has_point(face.plane.get_center(), _COPLANAR_TOLERANCE):
				continue
			var other_2d := _project_2d(other["verts"], origin, u, v)
			if _signed_area_2d(other_2d) < 0.0:
				other_2d.reverse()
			if _intersection_area_2d(face_2d, other_2d) <= noise:
				continue
			covers.append(other_2d)

		if covers.is_empty():
			continue

		# Merge covers that overlap each other so the subtraction stays robust.
		covers = _merge_overlapping(covers)

		var remainder := _subtract(face_2d, covers)
		var remaining_area := _region_area(remainder)

		if remaining_area <= noise:
			to_remove.append([record["brush"], face])
			removed[face] = true
			continue

		if remaining_area >= face_area - noise:
			continue  # negligible overlap; leave the face untouched

		var triangles := _drop_slivers(_triangulate_region(remainder))
		if not _split_is_valid(face_2d, face_area, covers, triangles):
			if debug_log_pairs:
				print("[KAJMAK] e%d '%s' split rejected (%d triangles, %d covers, %.1f%% remains) -> kept whole: %s" % [
					record["entity"], face.texture, triangles.size() / 3, covers.size(),
					100.0 * remaining_area / face_area, _split_problem(face_2d, face_area, covers, triangles)])
			continue  # keep the whole face — a missed cull is fine, corruption is not
		_rebuild_face(face, triangles, origin, u, v)
		split_count += 1
		if debug_log_pairs:
			print("[KAJMAK] e%d '%s' partially covered -> split (%.1f%% remains)" % [
				record["entity"], face.texture, 100.0 * remaining_area / face_area,
			])

	for pair in to_remove:
		var brush: _BrushData = pair[0]
		brush.faces.erase(pair[1])

	if debug_log_pairs:
		print("[KAJMAK] removed %d face(s), split %d face(s)" % [to_remove.size(), split_count])

# Validate a split without trusting boolean areas (unreliable when covers overlap):
# every triangle centroid must be inside the face and outside all covers, the total
# must not exceed the face, and must cover at least (face - summed covers). On
# failure the face is kept whole.
func _split_is_valid(face_2d: PackedVector2Array, face_area: float, covers: Array, triangles: PackedVector2Array) -> bool:
	if triangles.is_empty():
		return false
	var tri_area := 0.0
	for t in range(0, triangles.size(), 3):
		var a := triangles[t]
		var b := triangles[t + 1]
		var c := triangles[t + 2]
		tri_area += absf(_triangle_signed_area(a, b, c))
		var centroid := (a + b + c) / 3.0
		if not Geometry2D.is_point_in_polygon(centroid, face_2d):
			return false
		for cover in covers:
			if Geometry2D.is_point_in_polygon(centroid, cover):
				return false
	if tri_area > face_area * 1.01 + 1.0e-5:
		return false
	var summed_cover := 0.0
	for cover in covers:
		summed_cover += _intersection_area_2d(cover, face_2d)
	if tri_area < face_area - summed_cover - face_area * 0.01 - 1.0e-5:
		return false
	return true

# Triangles thinner than the noise width: clipping leaves near-duplicate corners (float noise),
# and the triangulation can turn them into slivers of no area whose centroid lies on a cover's
# edge, which `_split_is_valid` would count as inside the cover and refuse the split. They draw
# nothing; the weld pass closes the seam they leave.
func _drop_slivers(triangles: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var width := _map_units(_NOISE_WIDTH)
	for t in range(0, triangles.size(), 3):
		var a := triangles[t]
		var b := triangles[t + 1]
		var c := triangles[t + 2]
		var longest := maxf(a.distance_to(b), maxf(b.distance_to(c), c.distance_to(a)))
		if longest > 0.0 and 2.0 * absf(_triangle_signed_area(a, b, c)) / longest < width:
			continue
		out.append(a)
		out.append(b)
		out.append(c)
	return out

# Why `_split_is_valid` turned a split down (debug log only).
func _split_problem(face_2d: PackedVector2Array, face_area: float, covers: Array, triangles: PackedVector2Array) -> String:
	if triangles.is_empty():
		return "no triangles"
	var tri_area := 0.0
	for t in range(0, triangles.size(), 3):
		var a := triangles[t]
		var b := triangles[t + 1]
		var c := triangles[t + 2]
		var area := absf(_triangle_signed_area(a, b, c))
		tri_area += area
		var centroid := (a + b + c) / 3.0
		if not Geometry2D.is_point_in_polygon(centroid, face_2d):
			return "triangle %s %s %s (area %.4f) outside the face" % [a, b, c, area]
		for cover in covers:
			if Geometry2D.is_point_in_polygon(centroid, cover):
				return "triangle %s %s %s (area %.4f) inside a cover" % [a, b, c, area]
	var summed_cover := 0.0
	for cover in covers:
		summed_cover += _intersection_area_2d(cover, face_2d)
	return "triangles %.2f, face %.2f, covers %.2f" % [tri_area, face_area, summed_cover]

# BSP over the snapshotted occluder brushes (so a prior pass erasing faces cannot
# unseal the world), each with its interior point for consistent plane orientation.
func _build_occluder_bsp():
	var brushes: Array = []
	var world := AABB()
	var first := true
	for brush in _brush_orig:
		if _see_through.has(brush):
			continue  # see-through brushes seal nothing
		var bounds: Array = _brush_orig[brush]
		brushes.append({"planes": brush.planes, "inside": bounds[1]})
		if first:
			world = bounds[0]
			first = false
		else:
			world = world.merge(bounds[0])

	var bsp := _KajmakBSPScript.new()
	bsp.cancel_state = cancel_state
	bsp.build(brushes, world)
	return bsp

# Trim faces to their visible parts: flood the outside void, then per face keep only
# the fragments fronting interior space or solid. Fully void-facing -> removed,
# partly outside -> rebuilt to its visible region.
func cull_exterior_faces() -> void:
	var bsp: Variant = _build_occluder_bsp()
	bsp.mark_exterior()

	var to_remove: Array = []
	var rebuilds: Array = []   # [face, triangles_2d, origin, u, v]
	var trimmed := 0
	for entity_index in entity_data.size():
		var entity: _EntityData = entity_data[entity_index]
		if not _entity_renders(entity):
			continue
		for brush in entity.brushes:
			# Outward is judged against the brush centroid, not the face plane's sign.
			var brush_centroid: Vector3 = _brush_origin_bounds(brush)[1]
			if _cancelled():
				return
			for face in brush.faces:
				if not _is_visual_face(face):
					continue
				var outward := face.plane.normal
				if (face.get_centroid() - brush_centroid).dot(outward) < 0.0:
					outward = -outward

				# In-plane basis matching the winding frame so rebuilt triangles stay
				# front-facing (same convention as the hidden-face split).
				var u := _plane_tangent(face.plane.normal)
				var v := u.cross(face.plane.normal).normalized()
				var origin := face.plane.get_center()

				var total_area := 0.0
				var noise := 0.0   # over the triangles' outlines: at most a few times the face's
				var fragments: Array = []   # visible parts as 2D CCW polygons
				var keep_area := 0.0
				for tri: PackedVector3Array in _face_triangles_3d(face):
					var t2d := _project_2d(tri, origin, u, v)
					total_area += absf(_triangle_signed_area(t2d[0], t2d[1], t2d[2]))
					noise += _map_units(_NOISE_WIDTH) * _perimeter_2d(t2d)
					for frag: PackedVector3Array in bsp.face_visible_fragments(tri, outward):
						var f2d := _project_2d(frag, origin, u, v)
						if f2d.size() < 3:
							continue
						if _signed_area_2d(f2d) < 0.0:
							f2d.reverse()
						var fa := absf(_signed_area_2d(f2d))
						if fa <= _DEGENERATE_AREA:
							continue
						fragments.append(f2d)
						keep_area += fa

				if total_area <= 0.0:
					continue
				if keep_area <= noise:
					to_remove.append([brush, face])
					if debug_log_pairs:
						print("[KAJMAK] e%d '%s' faces void -> removed" % [entity_index, face.texture])
				elif keep_area < total_area - noise:
					# Merge the fragments before triangulating so a trim doesn't shatter
					# into slivers; fall back to a fan if the merge looks wrong.
					var tris := _exterior_triangulate(fragments)
					if tris.is_empty() or absf(_tris_area(tris) - keep_area) > keep_area * _TRIANGULATION_AREA_TOLERANCE:
						tris = _fan_triangulate(fragments)
					rebuilds.append([face, tris, origin, u, v])
					trimmed += 1

	for r in rebuilds:
		_rebuild_face(r[0], r[1], r[2], r[3], r[4])
	for pair in to_remove:
		var brush: _BrushData = pair[0]
		brush.faces.erase(pair[1])

	if debug_log_pairs:
		print("[KAJMAK] exterior pass: %d leaves outside, removed %d, trimmed %d face(s)" % [
			bsp.exterior_leaf_count, to_remove.size(), trimmed])

# Triangles of a face as 3D vertex triples, from its index buffer if present,
# otherwise a fan over its wound vertices.
func _face_triangles_3d(face: _FaceData) -> Array:
	var out: Array = []
	var verts := face.vertices
	if verts.size() < 3:
		return out
	if face.indices.size() >= 3:
		var idx := face.indices
		for i in range(0, idx.size(), 3):
			out.append(PackedVector3Array([verts[idx[i]], verts[idx[i + 1]], verts[idx[i + 2]]]))
	else:
		for i in range(1, verts.size() - 1):
			out.append(PackedVector3Array([verts[0], verts[i], verts[i + 1]]))
	return out

# Above this many fragments, merging is not worth the cost; fall back to a fan.
const _MERGE_FRAGMENT_CAP := 48

# Merge connected fragments and ear-clip each, keeping a trimmed face to few
# triangles. Returns flat CCW triangle triples, or empty to signal the fallback.
func _exterior_triangulate(fragments: Array) -> PackedVector2Array:
	if fragments.size() > _MERGE_FRAGMENT_CAP:
		return PackedVector2Array()

	# Fold each fragment into an accumulator of disjoint merged polygons. Only fuse
	# when the union is one hole-free ring; a hole or separate patch stays its own.
	var acc: Array = []
	for frag: PackedVector2Array in fragments:
		var cur := frag
		var i := 0
		while i < acc.size():
			var res := Geometry2D.merge_polygons(cur, acc[i])
			if res.size() == 1 and not Geometry2D.is_polygon_clockwise(res[0]):
				cur = res[0]
				acc.remove_at(i)
				i = 0  # cur grew; re-test against everything once more
			else:
				i += 1
		acc.append(cur)

	var out := PackedVector2Array()
	for poly: PackedVector2Array in acc:
		if poly.size() < 3:
			continue
		var tris := _earcut(poly, [])
		for t in range(0, tris.size(), 3):
			_append_ccw(out, tris[t], tris[t + 1], tris[t + 2])
	return out

# Per-fragment fan triangulation, used as a robust fallback.
func _fan_triangulate(fragments: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for poly: PackedVector2Array in fragments:
		for i in range(1, poly.size() - 1):
			_append_ccw(out, poly[0], poly[i], poly[i + 1])
	return out

func _append_ccw(out: PackedVector2Array, a: Vector2, b: Vector2, c: Vector2) -> void:
	if _triangle_signed_area(a, b, c) < 0.0:
		var s := b
		b = c
		c = s
	out.append(a)
	out.append(b)
	out.append(c)

func _tris_area(tris: PackedVector2Array) -> float:
	var area := 0.0
	for t in range(0, tris.size(), 3):
		area += absf(_triangle_signed_area(tris[t], tris[t + 1], tris[t + 2]))
	return area

# Dev only: build the occluder BSP into [member bsp_last] for a harness; touches no face.
func _bsp_debug_stats() -> void:
	var bsp: Variant = _build_occluder_bsp()
	bsp.mark_exterior()
	bsp_last = bsp
	print("[KAJMAK BSP] %s exterior-leaves %d" % [bsp.stats_string(), bsp.exterior_leaf_count])

#endregion

#region T-JUNCTION WELD

# Map units (scaled like the geometry when used). Corners closer than _WELD_MERGE are
# one corner (float noise from plane intersections); a corner within _WELD_EPSILON of an
# edge, and further than that from its ends, lies on the edge. _WELD_CELL is the spatial
# hash cell for the edge search.
const _WELD_MERGE := 1.0 / 256.0
const _WELD_EPSILON := 1.0 / 128.0
const _WELD_CELL := 64.0
var _weld_merge := 0.0
var _weld_epsilon := 0.0
var _weld_cell_size := 0.0
const _WELD_MAX_CELLS := 4096  # above this, an edge is searched cell by cell along it

## Weld T-junctions, as qbsp's tjunc pass does. Wherever a corner of one face lies on
## the outline of another, the second face gets that corner too, so neighbours share
## their corners exactly: no hairline cracks for light to leak through (culling makes
## brushes hollow, so a crack opens onto whatever lies behind). Corners that differ
## only by float noise are merged first. A triangle that gains corners on one side is
## fanned from the opposite corner, otherwise from a new point at its centre; faces keep
## their winding. Only the outline is welded: a corner inside a face covers no crack.
func weld_t_junction_faces() -> void:
	_weld_merge = _map_units(_WELD_MERGE)
	_weld_epsilon = _map_units(_WELD_EPSILON)
	_weld_cell_size = _map_units(_WELD_CELL)
	var faces: Array = []
	var brushes: Array = []         # the brush of each face
	for entity in entity_data:
		if not _entity_renders(entity):
			continue
		for brush in entity.brushes:
			for face in brush.faces:
				if _is_visual_face(face):
					faces.append(face)
					brushes.append(brush)

	# One id per corner, float noise merged.
	var points: Array = []          # id -> Vector3
	var merge_grid: Dictionary = {} # Vector3i -> Array of ids
	var face_ids: Array = []        # per face: corner id per vertex
	for face: _FaceData in faces:
		var ids := PackedInt32Array()
		for p in face.vertices:
			ids.append(_weld_point_id(p, points, merge_grid))
		face_ids.append(ids)

	var grid: Dictionary = {}       # Vector3i -> Array of ids, for the edge search
	for id in points.size():
		var cell := _weld_cell(points[id])
		if grid.has(cell):
			grid[cell].append(id)
		else:
			grid[cell] = [id]

	var edge_cache: Dictionary = {} # Vector2i(lo, hi) -> ids on the edge, ordered lo to hi
	var welded := 0
	var added := 0
	var collapsed := 0
	for f in faces.size():
		if _cancelled():
			return
		var face: _FaceData = faces[f]
		var ids: PackedInt32Array = face_ids[f]
		var tris := _weld_face_triangles(face, ids)

		# Triangles the merge collapsed go first, so the outline is counted without them.
		var changed := false
		var kept := PackedInt32Array()
		for t in range(0, tris.size(), 3):
			if tris[t] == tris[t + 1] or tris[t + 1] == tris[t + 2] or tris[t + 2] == tris[t]:
				changed = true
				collapsed += 1
			else:
				for k in 3:
					kept.append(tris[t + k])

		# The outline: edges used by one triangle of the face only.
		var edge_use: Dictionary = {}
		for t in range(0, kept.size(), 3):
			for k in 3:
				var key := _weld_edge_key(kept[t + k], kept[t + (k + 1) % 3])
				edge_use[key] = edge_use.get(key, 0) + 1

		var out_tris: Array = []    # triples of corner ids; negative = a centre point
		var centres: Array = []     # Vector3 per new centre point, in order of use
		# The way the face's triangles face, from its own winding before the merge: merging
		# corners can flip a sliver, so a triangle's merged corners can't be trusted for it.
		var facing := _weld_facing(face)
		for t in range(0, kept.size(), 3):
			var c := [kept[t], kept[t + 1], kept[t + 2]]
			if _weld_normal(c, points, centres).dot(facing) < 0.0:
				c = [c[0], c[2], c[1]]  # a sliver the merge flipped: wind it back
				changed = true
			var sides: Array = []   # corners on each side c[k] -> c[k+1], in that order
			var with_points := 0
			var side_with_points := -1
			var gained := 0
			for k in 3:
				var a: int = c[k]
				var b: int = c[(k + 1) % 3]
				var key := _weld_edge_key(a, b)
				var on: Array = []
				if edge_use[key] == 1:
					if not edge_cache.has(key):
						edge_cache[key] = _weld_edge_points(key.x, key.y, points, grid)
					on = edge_cache[key]
					if a != key.x:
						on = on.duplicate()
						on.reverse()
				sides.append(on)
				if not on.is_empty():
					with_points += 1
					side_with_points = k
					gained += on.size()
			if with_points == 0:
				out_tris.append_array(c)
				continue
			# The triangle's outline with its new corners, in winding order.
			var ring: Array = []
			for k in 3:
				ring.append(c[k])
				ring.append_array(sides[k])
			var fan: Array = []
			if with_points == 1:
				# Fan from the corner opposite the side that gained corners.
				var start := ring.find(c[(side_with_points + 2) % 3])
				var r: Array = ring.slice(start) + ring.slice(0, start)
				for i in range(1, r.size() - 1):
					fan.append_array([r[0], r[i], r[i + 1]])
			if fan.is_empty() or not _weld_fan_faces(fan, facing, points, centres):
				# Fan from a new point at the centre: no fan corner sits on a split side.
				var centre := -1 - centres.size()
				centres.append((points[c[0]] + points[c[1]] + points[c[2]]) / 3.0)
				fan = []
				for i in ring.size():
					fan.append_array([centre, ring[i], ring[(i + 1) % ring.size()]])
				if not _weld_fan_faces(fan, facing, points, centres):
					# A sliver thinner than the weld tolerance: any fan flips a triangle,
					# which is worse than the hairline it would close. Leave it whole.
					centres.pop_back()
					out_tris.append_array(c)
					continue
			changed = true
			added += gained
			out_tris.append_array(fan)

		if changed and out_tris.is_empty():
			(brushes[f] as _BrushData).faces.erase(face)  # every triangle collapsed
		elif changed:
			welded += 1
			_weld_rebuild_face(face, out_tris, points, centres)
		else:
			# Same triangles; the corners take their merged positions.
			var verts := face.vertices
			for i in verts.size():
				verts[i] = points[ids[i]]
			face.vertices = verts

	if debug_log_pairs:
		print("[KAJMAK] T-junction weld: %d corner(s) added, %d collapsed triangle(s) dropped, %d face(s) rebuilt" % [
			added, collapsed, welded])

# The id of the merged corner at p, adding p when no corner lies within _WELD_MERGE.
func _weld_point_id(p: Vector3, points: Array, merge_grid: Dictionary) -> int:
	var key := Vector3i((p / _weld_merge).round())
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var near := key + Vector3i(dx, dy, dz)
				if merge_grid.has(near):
					for id in merge_grid[near]:
						if (points[id] as Vector3).distance_to(p) <= _weld_merge:
							return id
	var id := points.size()
	points.append(p)
	if merge_grid.has(key):
		merge_grid[key].append(id)
	else:
		merge_grid[key] = [id]
	return id

func _weld_cell(p: Vector3) -> Vector3i:
	return Vector3i((p / _weld_cell_size).floor())

func _weld_edge_key(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))

# A face's triangles as corner ids: its index buffer, or a fan over its vertices.
func _weld_face_triangles(face: _FaceData, ids: PackedInt32Array) -> PackedInt32Array:
	var tris := PackedInt32Array()
	if face.indices.size() >= 3:
		for i in face.indices:
			tris.append(ids[i])
	else:
		for i in range(1, ids.size() - 1):
			for id in [ids[0], ids[i], ids[i + 1]]:
				tris.append(id)
	return tris

# The corners lying on edge a-b (strictly between its ends), ordered from a to b.
func _weld_edge_points(a: int, b: int, points: Array, grid: Dictionary) -> Array:
	var pa: Vector3 = points[a]
	var pb: Vector3 = points[b]
	var length := pa.distance_to(pb)
	if length <= 2.0 * _weld_epsilon:
		return []
	var dir := (pb - pa) / length

	var cells: Array = []
	var lo := _weld_cell(pa.min(pb) - Vector3.ONE * _weld_epsilon)
	var hi := _weld_cell(pa.max(pb) + Vector3.ONE * _weld_epsilon)
	var span := hi - lo + Vector3i.ONE
	if span.x * span.y * span.z <= _WELD_MAX_CELLS:
		for x in range(lo.x, hi.x + 1):
			for y in range(lo.y, hi.y + 1):
				for z in range(lo.z, hi.z + 1):
					cells.append(Vector3i(x, y, z))
	else:
		# Long diagonal edge: sample it every half cell; a corner near the edge is then
		# in a sample's cell or a neighbour of it.
		var seen: Dictionary = {}
		var steps := ceili(length / (_weld_cell_size * 0.5))
		for s in steps + 1:
			var cell := _weld_cell(pa.lerp(pb, float(s) / steps))
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					for dz in range(-1, 2):
						seen[cell + Vector3i(dx, dy, dz)] = true
		cells = seen.keys()

	var found: Array = []  # [distance from a, id]
	for cell in cells:
		if not grid.has(cell):
			continue
		for id in grid[cell]:
			if id == a or id == b:
				continue
			var rel: Vector3 = points[id] - pa
			var t := rel.dot(dir)
			if t <= _weld_epsilon or t >= length - _weld_epsilon:
				continue
			if (rel - dir * t).length_squared() > _weld_epsilon * _weld_epsilon:
				continue
			found.append([t, id])
	found.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	var out: Array = []
	for entry in found:
		out.append(entry[1])
	return out

# A corner's position: a merged corner, or (negative id) one of the face's centre points.
func _weld_pos(id: int, points: Array, centres: Array) -> Vector3:
	return points[id] if id >= 0 else centres[-1 - id]

# A triangle's (unnormalised) normal, from its corner ids.
func _weld_normal(tri: Array, points: Array, centres: Array) -> Vector3:
	var a := _weld_pos(tri[0], points, centres)
	return (_weld_pos(tri[1], points, centres) - a).cross(_weld_pos(tri[2], points, centres) - a)

# The face's plane normal, signed the way its triangles wind (from its widest triangle,
# on its own corners before the weld moves any).
func _weld_facing(face: _FaceData) -> Vector3:
	var verts := face.vertices
	var idx := face.indices
	if idx.size() < 3:
		idx = PackedInt32Array()
		for i in range(1, verts.size() - 1):
			idx.append(0)
			idx.append(i)
			idx.append(i + 1)
	var best := 0.0
	var sign := 1.0
	for t in range(0, idx.size(), 3):
		var a := verts[idx[t]]
		var d := (verts[idx[t + 1]] - a).cross(verts[idx[t + 2]] - a).dot(face.plane.normal)
		if absf(d) > best:
			best = absf(d)
			sign = signf(d)
	return face.plane.normal * sign

# Whether every triangle of a fan faces the given way.
func _weld_fan_faces(fan: Array, facing: Vector3, points: Array, centres: Array) -> bool:
	for i in range(0, fan.size(), 3):
		if _weld_normal([fan[i], fan[i + 1], fan[i + 2]], points, centres).dot(facing) <= 0.0:
			return false
	return true

# Rebuild a face from corner-id triangles (negative ids: its centre points).
func _weld_rebuild_face(face: _FaceData, tris: Array, points: Array, centres: Array) -> void:
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var local: Dictionary = {}  # corner id -> vertex index
	for id: int in tris:
		if not local.has(id):
			local[id] = vertices.size()
			vertices.append(points[id] if id >= 0 else centres[-1 - id])
		indices.append(local[id])
	_set_face_mesh(face, vertices, indices)

#endregion

#region OCCLUDER / FACE CLASSIFICATION

# Mirrors func_godot's render gate: a solid class that builds visuals, or any
# brush entity without a solid definition (func_godot's default visual solid).
func _entity_renders(entity: _EntityData) -> bool:
	if not entity or entity.brushes.is_empty():
		return false
	var def := entity.definition
	if def is FuncGodotFGDSolidClass:
		return def.build_visuals
	return true

# A face that is actually rendered (and so can be culled or split).
func _is_visual_face(face: _FaceData) -> bool:
	return (face.vertices.size() >= 3
			and not is_skip(face)
			and not is_clip(face)
			and not is_origin(face))

# A solid surface that hides geometry behind it. Includes skip (invisible but
# solid); excludes clip (you see through it) and origin (entity marker).
func _is_solid_face(face: _FaceData) -> bool:
	return (face.vertices.size() >= 3
			and not is_clip(face)
			and not is_origin(face))

# Whether an entity's brushes hide faces: all but the see-through classes
# (see [member see_through_classes]).
func _entity_hides(entity: _EntityData) -> bool:
	return not String(entity.properties.get("classname", "")) in see_through_classes

func _brush_has_solid_face(brush: _BrushData) -> bool:
	for face in brush.faces:
		if _is_solid_face(face):
			return true
	return false

# AABB and centroid of a brush, computed from its face windings.
func _brush_bounds(brush: _BrushData) -> Array:
	var has := false
	var mins := Vector3.ZERO
	var maxs := Vector3.ZERO
	var sum := Vector3.ZERO
	var count := 0
	for face in brush.faces:
		for vertex in face.vertices:
			if not has:
				mins = vertex
				maxs = vertex
				has = true
			else:
				mins = mins.min(vertex)
				maxs = maxs.max(vertex)
			sum += vertex
			count += 1
	var centroid := sum / float(count) if count > 0 else Vector3.ZERO
	return [AABB(mins, maxs - mins), centroid]

# True when every point is inside the convex brush, judging each plane's interior
# side by where the centroid sits (so plane orientation doesn't matter).
func _points_inside_brush(points: PackedVector3Array, planes: Array[Plane], centroid: Vector3) -> bool:
	for plane in planes:
		var centroid_dist := plane.distance_to(centroid)
		for p in points:
			var dist := plane.distance_to(p)
			if centroid_dist < 0.0:
				if dist > _VOLUME_TOLERANCE:
					return false
			else:
				if dist < -_VOLUME_TOLERANCE:
					return false
	return true

# The parts of a face inside other solid brushes (that may cover it, see _may_cover), as
# 2D covers (CCW) in the face's frame: qbsp's CSG step. Stacked or overlapping brushes bury parts of each other's faces where
# no face lines up flush (a stair tread running on under the next step), and a buried
# part left in a hollow brush catches light that bleeds into the visible part's lightmap.
# A brush covers the part of the face inside it only if it reaches in front of the face:
# one the face rests against from behind, or one flush beside it, covers nothing; one
# touching it face to face does.
func _volume_covers(face: _FaceData, own_brush: _BrushData, own_entity: int, occluders: Array, origin: Vector3, u: Vector3, v: Vector3) -> Array:
	var out: Array = []
	var outward := _outward(face, own_brush)
	for occluder in occluders:
		if occluder["brush"] == own_brush or not _may_cover(occluder["entity"], own_entity):
			continue
		if not _reaches_in_front(occluder, face.vertices[0], outward):
			continue
		var poly := face.vertices
		for plane: Plane in occluder["brush"].planes:
			poly = _clip_to_inside(poly, plane, occluder["centroid"])
			if poly.size() < 3:
				break
		if poly.size() < 3:
			continue
		var poly_2d := _project_2d(poly, origin, u, v)
		if _signed_area_2d(poly_2d) < 0.0:
			poly_2d.reverse()
		out.append(poly_2d)
	return out

# Whether brushes of one entity may hide faces of another: within an entity always;
# across entities only between static ones (see [member static_classes]).
func _may_cover(cover_entity: int, face_entity: int) -> bool:
	return cover_entity == face_entity or (_entity_static[cover_entity] and _entity_static[face_entity])

# A face's normal pointing away from its own brush.
func _outward(face: _FaceData, brush: _BrushData) -> Vector3:
	var outward := face.plane.normal
	if (face.get_centroid() - _brush_origin_bounds(brush)[1]).dot(outward) < 0.0:
		outward = -outward
	return outward

# Whether an occluder reaches further than _VOLUME_PROBE in front of a face's plane: only
# then can it bury part of the face. One the face rests against from behind, or one flush
# with it, doesn't (flush faces are settled by brush order).
func _reaches_in_front(occluder: Dictionary, anchor: Vector3, outward: Vector3) -> bool:
	var reach := _map_units(_VOLUME_PROBE)
	for p: Vector3 in occluder["points"]:
		if (p - anchor).dot(outward) > reach:
			return true
	return false

# Map units: the cell of the grid that finds the brushes near a face.
const _OCCLUDER_CELL := 256.0

func _occluder_grid(occluders: Array) -> Dictionary:
	var grid: Dictionary = {}   # Vector3i -> Array of occluder indices
	var cell := _map_units(_OCCLUDER_CELL)
	for i in occluders.size():
		var box: AABB = (occluders[i]["aabb"] as AABB).grow(_VOLUME_TOLERANCE)
		var lo := Vector3i((box.position / cell).floor())
		var hi := Vector3i((box.end / cell).floor())
		for x in range(lo.x, hi.x + 1):
			for y in range(lo.y, hi.y + 1):
				for z in range(lo.z, hi.z + 1):
					var key := Vector3i(x, y, z)
					if grid.has(key):
						grid[key].append(i)
					else:
						grid[key] = [i]
	return grid

# The occluders whose bounds touch `box`, each once.
func _occluders_near(grid: Dictionary, occluders: Array, box: AABB) -> Array:
	var cell := _map_units(_OCCLUDER_CELL)
	box = box.grow(_VOLUME_TOLERANCE)
	var lo := Vector3i((box.position / cell).floor())
	var hi := Vector3i((box.end / cell).floor())
	var seen: Dictionary = {}
	var out: Array = []
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				for i in grid.get(Vector3i(x, y, z), []):
					if seen.has(i):
						continue
					seen[i] = true
					var occluder: Dictionary = occluders[i]
					if (occluder["aabb"] as AABB).grow(_VOLUME_TOLERANCE).intersects(box):
						out.append(occluder)
	return out

# The part of a convex polygon on the inside of a brush plane (the side of `inside`).
func _clip_to_inside(poly: PackedVector3Array, plane: Plane, inside: Vector3) -> PackedVector3Array:
	var side := -1.0 if plane.distance_to(inside) < 0.0 else 1.0
	var out := PackedVector3Array()
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var da := plane.distance_to(a) * side
		var db := plane.distance_to(b) * side
		if da >= 0.0:
			out.append(a)
		if (da >= 0.0) != (db >= 0.0):
			out.append(a.lerp(b, da / (da - db)))
	return out

# True when a face is entirely inside an occluder brush (not its own) that reaches in
# front of it.
func _face_buried(face: _FaceData, own_brush: _BrushData, own_entity: int, occluders: Array) -> bool:
	var outward := _outward(face, own_brush)
	for occluder in occluders:
		if occluder["brush"] == own_brush or not _may_cover(occluder["entity"], own_entity):
			continue
		if not _reaches_in_front(occluder, face.vertices[0], outward):
			continue
		if _points_inside_brush(face.vertices, occluder["brush"].planes, occluder["centroid"]):
			return true
	return false

func _aabb_of(points: PackedVector3Array) -> AABB:
	if points.is_empty():
		return AABB()
	var mins := points[0]
	var maxs := points[0]
	for p in points:
		mins = mins.min(p)
		maxs = maxs.max(p)
	return AABB(mins, maxs - mins)

#endregion

#region MESH REBUILD

# Replace a face's geometry with 2D triangles (flat (u,v) triples) lifted to 3D,
# rebuilding vertices/indices/normals/tangents; UVs come later from position.
func _rebuild_face(face: _FaceData, triangles: PackedVector2Array, origin: Vector3, u: Vector3, v: Vector3) -> void:
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var lookup: Dictionary = {}  # Vector2i -> int
	for p in triangles:
		var key := Vector2i(roundi(p.x * _DEDUP_PRECISION), roundi(p.y * _DEDUP_PRECISION))
		if lookup.has(key):
			indices.append(lookup[key])
		else:
			var index := vertices.size()
			lookup[key] = index
			vertices.append(origin + u * p.x + v * p.y)
			indices.append(index)
	_set_face_mesh(face, vertices, indices)

# Set a face's vertices and triangles, with flat normals and func_godot's tangents.
func _set_face_mesh(face: _FaceData, vertices: PackedVector3Array, indices: PackedInt32Array) -> void:
	face.vertices = vertices
	face.indices = indices
	face.normals = PackedVector3Array()
	face.normals.resize(vertices.size())
	face.normals.fill(face.plane.normal)

	# Match func_godot's per-vertex tangent layout (Y, Z, X, W) from a face tangent.
	face.tangents = PackedFloat32Array()
	var tangent: PackedFloat32Array = FuncGodotUtil.get_face_tangent(face)
	for i in vertices.size():
		face.tangents.append(tangent[1])
		face.tangents.append(tangent[2])
		face.tangents.append(tangent[0])
		face.tangents.append(tangent[3])

#endregion

#region 2D GEOMETRY HELPERS

# Quantized plane key used to bucket coplanar faces. Self-contained so the addon
# does not depend on func_godot internals that vary between versions.
func _plane_key(plane: Plane) -> Vector4i:
	const PLANE_PRECISION := 100.0
	return Vector4i(
		int(round(plane.normal.x * PLANE_PRECISION)),
		int(round(plane.normal.y * PLANE_PRECISION)),
		int(round(plane.normal.z * PLANE_PRECISION)),
		int(round(plane.d * PLANE_PRECISION)),
	)

# An arbitrary unit vector perpendicular to the given plane normal.
func _plane_tangent(normal: Vector3) -> Vector3:
	var reference := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	return normal.cross(reference).normalized()

# Project 3D coplanar points onto a 2D plane basis anchored at origin.
func _project_2d(vertices: PackedVector3Array, origin: Vector3, u: Vector3, v: Vector3) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in vertices:
		var d := p - origin
		out.append(Vector2(d.dot(u), d.dot(v)))
	return out

# Signed area of a 2D polygon (positive = counter-clockwise in the u,v frame).
func _signed_area_2d(poly: PackedVector2Array) -> float:
	var area := 0.0
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	return area * 0.5

# Map units (as in the .map file) in the generator's units: func_godot has scaled them.
func _map_units(x: float) -> float:
	return x * (map_settings.scale_factor if map_settings else 1.0)

# Length of a closed 2D polygon's outline.
func _perimeter_2d(poly: PackedVector2Array) -> float:
	var length := 0.0
	for i in poly.size():
		length += poly[i].distance_to(poly[(i + 1) % poly.size()])
	return length

# Total area of the intersection of two 2D polygons.
func _intersection_area_2d(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var area := 0.0
	for poly in Geometry2D.intersect_polygons(a, b):
		area += absf(_signed_area_2d(poly))
	return area

# Union connected covers (so subtraction yields clean holes), but only when the
# union is a single hole-free ring; disjoint covers stay separate.
func _merge_overlapping(covers: Array) -> Array:
	var result: Array = covers.duplicate()
	var merged_any := true
	while merged_any:
		merged_any = false
		var i := 0
		while i < result.size():
			var j := i + 1
			while j < result.size():
				var merged := Geometry2D.merge_polygons(result[i], result[j])
				var hole_count := 0
				for poly in merged:
					if Geometry2D.is_polygon_clockwise(poly):
						hole_count += 1
				# Merging covers into a ring (e.g. window-frame bars) would create a
				# hole and swallow the enclosed island, so keep those separate.
				if merged.size() == 1 and hole_count == 0:
					result[i] = merged[0]
					result.remove_at(j)
					merged_any = true
				else:
					j += 1
			i += 1
	return result

# Subtract clip polygons from a subject, returning {outers, holes}. Only outer rings
# feed the next subtraction; holes are kept for hole-aware triangulation.
func _subtract(subject: PackedVector2Array, clips: Array) -> Dictionary:
	var outers: Array = [subject]
	var holes: Array = []
	for clip in clips:
		var next_outers: Array = []
		for outer in outers:
			for poly in Geometry2D.clip_polygons(outer, clip):
				if Geometry2D.is_polygon_clockwise(poly):
					holes.append(poly)
				else:
					next_outers.append(poly)
		outers = next_outers
		if outers.is_empty():
			break
	return {"outers": outers, "holes": holes}

# Net area of a {outers, holes} region.
func _region_area(region: Dictionary) -> float:
	var area := 0.0
	for outer in region["outers"]:
		area += absf(_signed_area_2d(outer))
	for hole in region["holes"]:
		area -= absf(_signed_area_2d(hole))
	return maxf(area, 0.0)

# Signed area of a triangle (positive = counter-clockwise in the u,v frame).
func _triangle_signed_area(a: Vector2, b: Vector2, c: Vector2) -> float:
	return ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) * 0.5

func _poly_centroid(poly: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for p in poly:
		sum += p
	return sum / float(poly.size())

# Triangulate a {outers, holes} region into a flat list of 2D triangle triples
# (counter-clockwise in the u,v frame) using ear clipping with hole elimination.
func _triangulate_region(region: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for outer_raw in region["outers"]:
		var outer: PackedVector2Array = outer_raw
		if outer.size() < 3:
			continue
		var my_holes: Array = []
		for hole_raw in region["holes"]:
			var hole: PackedVector2Array = hole_raw
			if hole.size() >= 3 and Geometry2D.is_point_in_polygon(_poly_centroid(hole), outer):
				my_holes.append(hole)
		var tris := _earcut(outer, my_holes)
		for t in range(0, tris.size(), 3):
			_append_ccw(out, tris[t], tris[t + 1], tris[t + 2])
	return out

#endregion

#region EARCUT (ear-clipping triangulation with hole elimination; port of the
# standard mapbox/earcut algorithm, without the z-order acceleration)

class _ECNode:
	var i: int
	var x: float
	var y: float
	var prev: _ECNode = null
	var next: _ECNode = null
	var steiner := false
	func _init(idx: int, px: float, py: float) -> void:
		i = idx
		x = px
		y = py

# Triangulate a simple polygon (outer ring + hole rings) into flat triangle points.
func _earcut(outer: PackedVector2Array, holes: Array) -> PackedVector2Array:
	var data := PackedVector2Array(outer)
	var hole_indices := PackedInt32Array()
	for h in holes:
		hole_indices.append(data.size())
		data.append_array(h)

	var out := PackedVector2Array()
	var outer_node := _ec_linked_list(data, 0, outer.size(), true)
	if outer_node == null or outer_node.next == outer_node.prev:
		return out
	if hole_indices.size() > 0:
		outer_node = _ec_eliminate_holes(data, hole_indices, outer_node)

	var triangles := PackedInt32Array()
	_ec_earcut_linked(outer_node, triangles, 0)
	for idx in triangles:
		out.append(data[idx])
	return out

func _ec_signed_area(data: PackedVector2Array, start: int, end: int) -> float:
	var sum := 0.0
	var j := end - 1
	for i in range(start, end):
		sum += (data[j].x - data[i].x) * (data[i].y + data[j].y)
		j = i
	return sum

func _ec_linked_list(data: PackedVector2Array, start: int, end: int, clockwise: bool) -> _ECNode:
	var last: _ECNode = null
	if clockwise == (_ec_signed_area(data, start, end) > 0.0):
		for i in range(start, end):
			last = _ec_insert(i, data[i], last)
	else:
		for i in range(end - 1, start - 1, -1):
			last = _ec_insert(i, data[i], last)
	if last != null and _ec_equals(last, last.next):
		_ec_remove(last)
		last = last.next
	return last

func _ec_insert(i: int, pt: Vector2, last: _ECNode) -> _ECNode:
	var p := _ECNode.new(i, pt.x, pt.y)
	if last == null:
		p.prev = p
		p.next = p
	else:
		p.next = last.next
		p.prev = last
		last.next.prev = p
		last.next = p
	return p

func _ec_remove(p: _ECNode) -> void:
	p.next.prev = p.prev
	p.prev.next = p.next

func _ec_equals(a: _ECNode, b: _ECNode) -> bool:
	return a.x == b.x and a.y == b.y

func _ec_area(p: _ECNode, q: _ECNode, r: _ECNode) -> float:
	return (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)

func _ec_eliminate_holes(data: PackedVector2Array, hole_indices: PackedInt32Array, outer_node: _ECNode) -> _ECNode:
	var queue: Array = []
	var count := hole_indices.size()
	for i in count:
		var start := hole_indices[i]
		var end := data.size() if i == count - 1 else hole_indices[i + 1]
		var list := _ec_linked_list(data, start, end, false)
		if list == list.next:
			list.steiner = true
		queue.append(_ec_get_leftmost(list))
	queue.sort_custom(func(a: _ECNode, b: _ECNode) -> bool: return a.x < b.x)
	var node := outer_node
	for hole_node in queue:
		node = _ec_eliminate_hole(hole_node, node)
	return node

func _ec_eliminate_hole(hole: _ECNode, outer_node: _ECNode) -> _ECNode:
	var bridge := _ec_find_hole_bridge(hole, outer_node)
	if bridge == null:
		return outer_node
	var bridge_reverse := _ec_split_polygon(bridge, hole)
	_ec_filter_points(bridge_reverse, bridge_reverse.next)
	return _ec_filter_points(bridge, bridge.next)

func _ec_get_leftmost(start: _ECNode) -> _ECNode:
	var p := start.next
	var leftmost := start
	while p != start:
		if p.x < leftmost.x or (p.x == leftmost.x and p.y < leftmost.y):
			leftmost = p
		p = p.next
	return leftmost

func _ec_point_in_triangle(ax: float, ay: float, bx: float, by: float, cx: float, cy: float, px: float, py: float) -> bool:
	return ((cx - px) * (ay - py) - (ax - px) * (cy - py) >= 0.0
			and (ax - px) * (by - py) - (bx - px) * (ay - py) >= 0.0
			and (bx - px) * (cy - py) - (cx - px) * (by - py) >= 0.0)

func _ec_locally_inside(a: _ECNode, b: _ECNode) -> bool:
	if _ec_area(a.prev, a, a.next) < 0.0:
		return _ec_area(a, b, a.next) >= 0.0 and _ec_area(a, a.prev, b) >= 0.0
	return _ec_area(a, b, a.prev) < 0.0 or _ec_area(a, a.next, b) < 0.0

func _ec_find_hole_bridge(hole: _ECNode, outer_node: _ECNode) -> _ECNode:
	var p := outer_node
	var hx := hole.x
	var hy := hole.y
	var qx := -INF
	var m: _ECNode = null
	while true:
		if hy <= p.y and hy >= p.next.y and p.next.y != p.y:
			var x := p.x + (hy - p.y) / (p.next.y - p.y) * (p.next.x - p.x)
			if x <= hx and x > qx:
				qx = x
				m = p if p.x < p.next.x else p.next
				if x == hx:
					return m
		p = p.next
		if p == outer_node:
			break
	if m == null:
		return null

	var stop := m
	var mx := m.x
	var my := m.y
	var tan_min := INF
	p = m
	while true:
		if hx >= p.x and p.x >= mx and hx != p.x:
			var ax: float
			var ay: float
			var cx: float
			var cy: float
			if hy < my:
				ax = hx; ay = hy; cx = qx; cy = hy
			else:
				ax = qx; ay = hy; cx = hx; cy = hy
			if _ec_point_in_triangle(ax, ay, mx, my, cx, cy, p.x, p.y):
				var tan := absf(hy - p.y) / (hx - p.x)
				if _ec_locally_inside(p, hole) and (tan < tan_min or (tan == tan_min and p.x > m.x)):
					m = p
					tan_min = tan
		p = p.next
		if p == stop:
			break
	return m

func _ec_split_polygon(a: _ECNode, b: _ECNode) -> _ECNode:
	var a2 := _ECNode.new(a.i, a.x, a.y)
	var b2 := _ECNode.new(b.i, b.x, b.y)
	var an := a.next
	var bp := b.prev
	a.next = b
	b.prev = a
	a2.next = an
	an.prev = a2
	b2.next = a2
	a2.prev = b2
	bp.next = b2
	b2.prev = bp
	return b2

func _ec_filter_points(start: _ECNode, end: _ECNode) -> _ECNode:
	if start == null:
		return start
	var e := end if end != null else start
	var p := start
	var again := true
	while again or p != e:
		again = false
		if not p.steiner and (_ec_equals(p, p.next) or _ec_area(p.prev, p, p.next) == 0.0):
			_ec_remove(p)
			p = p.prev
			e = p
			if p == p.next:
				break
			again = true
		else:
			p = p.next
	return e

func _ec_is_ear(ear: _ECNode) -> bool:
	var a := ear.prev
	var b := ear
	var c := ear.next
	if _ec_area(a, b, c) >= 0.0:
		return false  # reflex, cannot be an ear
	var p := ear.next.next
	while p != ear.prev:
		if (_ec_point_in_triangle(a.x, a.y, b.x, b.y, c.x, c.y, p.x, p.y)
				and _ec_area(p.prev, p, p.next) >= 0.0):
			return false
		p = p.next
	return true

func _ec_earcut_linked(ear_start: _ECNode, triangles: PackedInt32Array, pass_num: int) -> void:
	if ear_start == null:
		return
	var ear := ear_start
	var stop := ear
	var guard := 0
	var limit := 1000000
	while ear.prev != ear.next:
		guard += 1
		if guard > limit:
			return
		var prev := ear.prev
		var next := ear.next
		if _ec_is_ear(ear):
			triangles.append(prev.i)
			triangles.append(ear.i)
			triangles.append(next.i)
			_ec_remove(ear)
			ear = next.next
			stop = next.next
			continue
		ear = next
		if ear == stop:
			# No ear found in a full loop: try progressively stronger recovery.
			if pass_num == 0:
				_ec_earcut_linked(_ec_filter_points(ear, null), triangles, 1)
			elif pass_num == 1:
				ear = _ec_cure_local_intersections(_ec_filter_points(ear, null), triangles)
				_ec_earcut_linked(ear, triangles, 2)
			elif pass_num == 2:
				_ec_split_earcut(ear, triangles)
			return

func _ec_sign(v: float) -> int:
	return (0 if v == 0.0 else (1 if v > 0.0 else -1))

func _ec_on_segment(p: _ECNode, q: _ECNode, r: _ECNode) -> bool:
	return (minf(p.x, r.x) <= q.x and q.x <= maxf(p.x, r.x)
			and minf(p.y, r.y) <= q.y and q.y <= maxf(p.y, r.y))

func _ec_intersects(p1: _ECNode, q1: _ECNode, p2: _ECNode, q2: _ECNode) -> bool:
	var o1 := _ec_sign(_ec_area(p1, q1, p2))
	var o2 := _ec_sign(_ec_area(p1, q1, q2))
	var o3 := _ec_sign(_ec_area(p2, q2, p1))
	var o4 := _ec_sign(_ec_area(p2, q2, q1))
	if o1 != o2 and o3 != o4:
		return true
	if o1 == 0 and _ec_on_segment(p1, p2, q1):
		return true
	if o2 == 0 and _ec_on_segment(p1, q2, q1):
		return true
	if o3 == 0 and _ec_on_segment(p2, p1, q2):
		return true
	if o4 == 0 and _ec_on_segment(p2, q1, q2):
		return true
	return false

# Resolve self-intersections by clipping off the offending vertex as a triangle.
func _ec_cure_local_intersections(start: _ECNode, triangles: PackedInt32Array) -> _ECNode:
	var p := start
	while true:
		var a := p.prev
		var b := p.next.next
		if (not _ec_equals(a, b) and _ec_intersects(a, p, p.next, b)
				and _ec_locally_inside(a, b) and _ec_locally_inside(b, a)):
			triangles.append(a.i)
			triangles.append(p.i)
			triangles.append(b.i)
			_ec_remove(p)
			_ec_remove(p.next)
			p = b
			start = b
		p = p.next
		if p == start:
			break
	return _ec_filter_points(p, null)

# Split a stuck polygon along a valid diagonal and triangulate each half.
func _ec_split_earcut(start: _ECNode, triangles: PackedInt32Array) -> void:
	var a := start
	while true:
		var b := a.next.next
		while b != a.prev:
			if a.i != b.i and _ec_is_valid_diagonal(a, b):
				var c := _ec_split_polygon(a, b)
				a = _ec_filter_points(a, a.next)
				c = _ec_filter_points(c, c.next)
				_ec_earcut_linked(a, triangles, 0)
				_ec_earcut_linked(c, triangles, 0)
				return
			b = b.next
		a = a.next
		if a == start:
			break

func _ec_intersects_polygon(a: _ECNode, b: _ECNode) -> bool:
	var p := a
	while true:
		if (p.i != a.i and p.next.i != a.i and p.i != b.i and p.next.i != b.i
				and _ec_intersects(p, p.next, a, b)):
			return true
		p = p.next
		if p == a:
			break
	return false

func _ec_middle_inside(a: _ECNode, b: _ECNode) -> bool:
	var p := a
	var inside := false
	var px := (a.x + b.x) / 2.0
	var py := (a.y + b.y) / 2.0
	while true:
		if ((p.y > py) != (p.next.y > py) and p.next.y != p.y
				and px < (p.next.x - p.x) * (py - p.y) / (p.next.y - p.y) + p.x):
			inside = not inside
		p = p.next
		if p == a:
			break
	return inside

func _ec_is_valid_diagonal(a: _ECNode, b: _ECNode) -> bool:
	return (a.next.i != b.i and a.prev.i != b.i and not _ec_intersects_polygon(a, b)
			and ((_ec_locally_inside(a, b) and _ec_locally_inside(b, a) and _ec_middle_inside(a, b)
					and (_ec_area(a.prev, a, b.prev) != 0.0 or _ec_area(a, b.prev, b) != 0.0))
				or (_ec_equals(a, b) and _ec_area(a.prev, a, a.next) > 0.0 and _ec_area(b.prev, b, b.next) > 0.0)))

#endregion
