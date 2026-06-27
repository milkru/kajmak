@tool
class_name KajmakGeometryGenerator extends FuncGodotGeometryGenerator
## func_godot geometry generator with import-time hidden-face culling.
##
## Subclasses [FuncGodotGeometryGenerator] to add a global, CSG-style hidden-face
## culling pre-pass that reproduces qbsp/vbsp visible-surface behaviour at import
## time, without modifying func_godot.
##
## The pre-pass runs after faces are wound (so windings exist) and before surface
## generation. Because per-entity origin/OpenGL transforms are only applied later
## (inside surface generation), every face's [code]vertices[/code]/[code]plane[/code]
## are still in shared id-space here, so faces can be compared across brushes,
## entities and textures directly.
##
## What it does:
##   - Only renderable, solid brush faces participate (triggers, point entities,
##     and skip/clip/origin faces are ignored as occluders and never culled).
##   - Faces fully buried inside another solid brush volume are removed (handles
##     flush back-to-back faces and fully-embedded brushes).
##   - Faces partially covered by opposite coplanar faces are split: covered
##     regions are subtracted in 2D and the visible remainder is re-triangulated.
##
## Not yet handled (see RESEARCH.md): T-junction welding, so split faces may leave
## hairline cracks against un-split neighbours. Illusionary/liquid brushes that
## render but should not occlude are currently treated as occluders.

## When false, builds identically to stock func_godot (regression escape hatch).
var enable_cull: bool = true
## When true, prints per-face cull/split decisions.
var debug_log_pairs: bool = false

# A face is fully removed when its remaining area drops below this fraction of its
# original area, and left untouched when coverage is below _OVERLAP_EPSILON.
const _FULL_COVERAGE_EPSILON := 1.0e-3
const _OVERLAP_EPSILON := 1.0e-4
const _COPLANAR_TOLERANCE := 0.001
const _DEDUP_PRECISION := 1024.0
# Distance tolerance (Godot units) for point-in-brush-volume tests.
const _VOLUME_TOLERANCE := 0.001

# Copy of [method FuncGodotGeometryGenerator.build] that inserts the hidden-face
# culling pre-pass between face winding and surface generation. Kept close to the
# original so it stays easy to diff against func_godot when upstream changes.
func build(build_flags: int, entities: Array[_EntityData]) -> Error:
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

	# KAJMAK: global hidden-face culling pre-pass (runs single-threaded here, after
	# all faces are wound and before parallel surface generation reads them).
	if enable_cull:
		declare_step.emit("Culling hidden faces")
		cull_hidden_faces()

	declare_step.emit("Generating surfaces")
	task_id = WorkerThreadPool.add_group_task(generate_entity_surfaces, entity_count, -1, false, "Generate Surfaces")
	WorkerThreadPool.wait_for_group_task_completion(task_id)

	if build_flags & FuncGodotMap.BuildFlags.UNWRAP_UV2:
		declare_step.emit("Unwrapping UV2s")
		var texel_size: float = map_settings.uv_unwrap_texel_size * map_settings.scale_factor
		for entity_index in entity_count:
			unwrap_uv2s(entity_index, texel_size)

	declare_step.emit("Geometry generation complete")
	return OK

#region HIDDEN-FACE CULLING

## Global pre-pass. Builds the set of solid occluder brushes and renderable
## candidate faces, removes faces buried inside another solid, and splits faces
## partially covered by opposite coplanar faces.
func cull_hidden_faces() -> void:
	var occluders: Array = []   # {brush, aabb, centroid}
	var records: Array = []     # {entity, brush, face}
	var bucket: Dictionary = {} # Vector4i -> Array[record]

	for entity_index in entity_data.size():
		var entity: _EntityData = entity_data[entity_index]
		if not _entity_renders(entity):
			continue
		for brush in entity.brushes:
			if _brush_has_visual_face(brush):
				var bounds := _brush_bounds(brush)
				occluders.append({"brush": brush, "aabb": bounds[0], "centroid": bounds[1]})
			for face in brush.faces:
				if not _is_visual_face(face):
					continue
				var record := {"entity": entity_index, "brush": brush, "face": face}
				records.append(record)
				var key := _plane_key(face.plane)
				if bucket.has(key):
					bucket[key].append(record)
				else:
					bucket[key] = [record]

	var to_remove: Array = []      # [brush, face]
	var removed: Dictionary = {}   # face -> true
	var split_count: int = 0

	# Pass 1: remove faces fully buried inside another solid brush volume.
	for record in records:
		var face: _FaceData = record["face"]
		if _face_buried(face.vertices, record["brush"], occluders):
			to_remove.append([record["brush"], face])
			removed[face] = true
			if debug_log_pairs:
				print("[KAJMAK] e%d '%s' buried -> removed" % [record["entity"], face.texture])

	# Pass 2: split faces partially covered by opposite coplanar faces.
	for record in records:
		var face: _FaceData = record["face"]
		if removed.has(face):
			continue

		var opposite := Plane(face.plane)
		opposite.normal = -opposite.normal
		opposite.d = -opposite.d
		var opposite_key := _plane_key(opposite)
		if not bucket.has(opposite_key):
			continue

		# In-plane basis matching func_godot's winding frame (v = u x normal) so
		# rebuilt triangles keep the same front-facing orientation.
		var u := _plane_tangent(face.plane.normal)
		var v := u.cross(face.plane.normal).normalized()
		var origin: Vector3 = face.plane.get_center()
		var face_2d := _project_2d(face.vertices, origin, u, v)
		var face_area := absf(_signed_area_2d(face_2d))
		if face_area <= _OVERLAP_EPSILON:
			continue

		var covers: Array = []
		for other in bucket[opposite_key]:
			var other_face: _FaceData = other["face"]
			if other_face == face:
				continue
			if not (-face.plane.normal).is_equal_approx(other_face.plane.normal):
				continue
			if not other_face.plane.has_point(face.plane.get_center(), _COPLANAR_TOLERANCE):
				continue
			var other_2d := _project_2d(other_face.vertices, origin, u, v)
			if _intersection_area_2d(face_2d, other_2d) <= face_area * _OVERLAP_EPSILON:
				continue
			covers.append(other_2d)

		if covers.is_empty():
			continue

		# Merge covers that overlap each other so the subtraction stays robust.
		covers = _merge_overlapping(covers)

		var remainder := _subtract(face_2d, covers)
		var remaining_area := _region_area(remainder)

		if remaining_area <= face_area * _FULL_COVERAGE_EPSILON:
			to_remove.append([record["brush"], face])
			removed[face] = true
			continue

		if remaining_area >= face_area * (1.0 - _FULL_COVERAGE_EPSILON):
			continue  # negligible overlap; leave the face untouched

		var triangles := _triangulate_region(remainder)
		if triangles.is_empty():
			continue  # triangulation failed; keep the whole face rather than corrupt it
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

#endregion

#region OCCLUDER / FACE CLASSIFICATION

# Mirrors func_godot's surface-generation gate: a face renders only when its
# entity has brushes and is a solid class that builds visuals (or has no solid
# definition, which func_godot treats as a default visual solid).
func _entity_renders(entity: _EntityData) -> bool:
	if not entity or entity.brushes.is_empty():
		return false
	var def := entity.definition
	if def is FuncGodotFGDSolidClass:
		return def.build_visuals
	return true

func _is_visual_face(face: _FaceData) -> bool:
	return (face.vertices.size() >= 3
			and not is_skip(face)
			and not is_clip(face)
			and not is_origin(face))

func _brush_has_visual_face(brush: _BrushData) -> bool:
	for face in brush.faces:
		if _is_visual_face(face):
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

# True when every point lies inside (or on) a convex brush volume. Works for
# either plane-normal orientation by comparing each point against the side the
# brush centroid is on.
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

# True when a face is entirely contained in some occluder brush other than its own.
func _face_buried(vertices: PackedVector3Array, own_brush: _BrushData, occluders: Array) -> bool:
	var face_aabb := _aabb_of(vertices)
	for occluder in occluders:
		if occluder["brush"] == own_brush:
			continue
		var occ_aabb: AABB = occluder["aabb"]
		if not occ_aabb.grow(_VOLUME_TOLERANCE).intersects(face_aabb):
			continue
		if _points_inside_brush(vertices, occluder["brush"].planes, occluder["centroid"]):
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

# Replace a face's geometry with the given list of 2D triangles (flat triples in
# the (u, v) plane), lifted back to 3D. Rebuilds vertices, indices, normals and
# tangents; UVs are recomputed from position during surface generation.
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

# Total area of the intersection of two 2D polygons.
func _intersection_area_2d(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var area := 0.0
	for poly in Geometry2D.intersect_polygons(a, b):
		area += absf(_signed_area_2d(poly))
	return area

# Union together any cover polygons that overlap each other, so the later
# subtraction sees (effectively) disjoint covers.
func _merge_overlapping(covers: Array) -> Array:
	var result: Array = covers.duplicate()
	var merged_any := true
	while merged_any:
		merged_any = false
		var i := 0
		while i < result.size():
			var j := i + 1
			while j < result.size():
				if _intersection_area_2d(result[i], result[j]) > _OVERLAP_EPSILON:
					var merged: Array = []
					for poly in Geometry2D.merge_polygons(result[i], result[j]):
						if not Geometry2D.is_polygon_clockwise(poly):
							merged.append(poly)
					result.remove_at(j)
					if merged.size() > 0:
						result[i] = merged[0]
						for k in range(1, merged.size()):
							result.append(merged[k])
					merged_any = true
				else:
					j += 1
			i += 1
	return result

# Subtract a set of clip polygons from a subject polygon. Returns
# {outers: Array[PackedVector2Array], holes: Array[PackedVector2Array]}.
# Only solid outer rings are fed back into successive subtractions; holes are
# accumulated for later hole-aware triangulation.
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

# Triangulate a {outers, holes} region into a flat list of 2D triangle triples,
# each enforced counter-clockwise so lifted triangles stay front-facing.
func _triangulate_region(region: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for outer in region["outers"]:
		var ring: PackedVector2Array = outer
		# Bridge any holes contained in this outer into a single simple ring.
		for hole in region["holes"]:
			if hole.size() < 3:
				continue
			if Geometry2D.is_point_in_polygon(hole[0], outer):
				ring = _bridge_hole(ring, hole)
		var indices := Geometry2D.triangulate_polygon(ring)
		if indices.is_empty():
			continue
		for i in range(0, indices.size(), 3):
			var a := ring[indices[i]]
			var b := ring[indices[i + 1]]
			var c := ring[indices[i + 2]]
			if _triangle_signed_area(a, b, c) < 0.0:
				var swap := b
				b = c
				c = swap
			out.append(a)
			out.append(b)
			out.append(c)
	return out

func _triangle_signed_area(a: Vector2, b: Vector2, c: Vector2) -> float:
	return ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) * 0.5

# Merge a hole into an outer ring by connecting them with a (zero-width) bridge,
# producing a single weakly-simple polygon that triangulate_polygon can handle.
func _bridge_hole(outer: PackedVector2Array, hole: PackedVector2Array) -> PackedVector2Array:
	# Bridge from the hole's right-most vertex to the nearest visible outer vertex.
	var m := 0
	for i in hole.size():
		if hole[i].x > hole[m].x:
			m = i
	var mp := hole[m]

	var best := -1
	var best_dist := INF
	for i in outer.size():
		if not _bridge_visible(mp, outer[i], outer, hole):
			continue
		var d := mp.distance_squared_to(outer[i])
		if d < best_dist:
			best_dist = d
			best = i
	if best == -1:
		return outer  # no clear bridge found; leave hole (degrades to over-keeping)

	var ring := PackedVector2Array()
	for i in best + 1:
		ring.append(outer[i])
	for k in hole.size():
		ring.append(hole[(m + k) % hole.size()])
	ring.append(hole[m])
	ring.append(outer[best])
	for i in range(best + 1, outer.size()):
		ring.append(outer[i])
	return ring

# True when segment p->q does not properly cross any edge of outer or hole.
func _bridge_visible(p: Vector2, q: Vector2, outer: PackedVector2Array, hole: PackedVector2Array) -> bool:
	return _ring_clear(p, q, outer) and _ring_clear(p, q, hole)

func _ring_clear(p: Vector2, q: Vector2, ring: PackedVector2Array) -> bool:
	var n := ring.size()
	for i in n:
		if _segments_cross(p, q, ring[i], ring[(i + 1) % n]):
			return false
	return true

# Proper segment intersection test (shared endpoints / collinear touches ignored).
func _segments_cross(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	var d1 := _orient(p3, p4, p1)
	var d2 := _orient(p3, p4, p2)
	var d3 := _orient(p1, p2, p3)
	var d4 := _orient(p1, p2, p4)
	return (((d1 > 0.0 and d2 < 0.0) or (d1 < 0.0 and d2 > 0.0))
			and ((d3 > 0.0 and d4 < 0.0) or (d3 < 0.0 and d4 > 0.0)))

func _orient(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)

#endregion
