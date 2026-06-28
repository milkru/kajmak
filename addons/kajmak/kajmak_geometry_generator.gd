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
## When true, also remove faces whose front side opens onto the exterior void of a
## sealed map (BSP flood from outside). Off by default and independent of culling.
var cull_exterior: bool = false
## When true, prints per-face cull/split decisions.
var debug_log_pairs: bool = false
## Dev hook: when set, build a [KajmakBSP] from the occluder brushes after winding
## and print its stats instead of culling. Used by dev/verify_bsp.gd to evaluate
## the BSP rewrite. Off in normal builds, so it never affects output.
var bsp_debug: bool = false
## Filled by [method _bsp_debug_stats] so a harness can read the result back.
var bsp_last: Variant = null
const _KajmakBSPScript = preload("res://addons/kajmak/kajmak_bsp.gd")

# brush -> [AABB, interior_point], captured from original geometry before culling.
var _brush_orig: Dictionary = {}

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
	# Snapshot each brush's original bounds + interior point now, while every face
	# is still present. Both cull passes need a stable interior point to orient
	# their inside/outside tests; recomputing it after one pass has erased faces
	# would shift it outside the brush and corrupt the other pass.
	if bsp_debug or cull_exterior or enable_cull:
		_snapshot_brushes()

	if bsp_debug:
		declare_step.emit("BSP debug stats")
		_bsp_debug_stats()
	else:
		# Hidden-face culling runs first, then exterior culling trims whatever
		# remains down to its visible (non-void-facing) parts. Both read brush
		# interiors from the snapshot, so the order does not corrupt either one.
		if enable_cull:
			declare_step.emit("Culling hidden faces")
			cull_hidden_faces()
		if cull_exterior:
			declare_step.emit("Culling exterior faces")
			cull_exterior_faces()

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

# Record every solid brush's original AABB and interior point before any face is
# culled, so both passes orient their volume tests from a point guaranteed to be
# inside the brush regardless of which pass runs first.
func _snapshot_brushes() -> void:
	_brush_orig.clear()
	for entity in entity_data:
		if not _entity_renders(entity):
			continue
		for brush in entity.brushes:
			if _brush_has_solid_face(brush):
				_brush_orig[brush] = _brush_bounds(brush)

# Original [AABB, interior] for a brush, falling back to current geometry if it
# was not snapshotted (should not happen for solid brushes).
func _brush_origin_bounds(brush: _BrushData) -> Array:
	return _brush_orig.get(brush, _brush_bounds(brush))

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
			# A brush occludes if it is solid (has any non-clip/non-origin face),
			# which includes skip-textured faces: those are invisible but still
			# solid surfaces that hide geometry behind them.
			if _brush_has_solid_face(brush):
				var bounds := _brush_origin_bounds(brush)
				occluders.append({"brush": brush, "aabb": bounds[0], "centroid": bounds[1]})
			for face in brush.faces:
				# Covers/occluder faces: any solid surface (incl. skip). Snapshot the
				# winding now: splitting later mutates face.vertices in place, and
				# covers must reflect the ORIGINAL geometry, not a half-cut neighbour.
				if _is_solid_face(face):
					var entry := {"face": face, "verts": face.vertices.duplicate()}
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
		if _signed_area_2d(face_2d) < 0.0:
			face_2d.reverse()  # normalise to CCW so boolean ops are orientation-safe
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
			# Project the snapshot (original) winding, not the possibly-mutated live one.
			var other_2d := _project_2d(other["verts"], origin, u, v)
			# Opposite-facing faces project with reversed winding; normalise to CCW
			# so the boolean ops below treat it as a solid region, not a hole.
			if _signed_area_2d(other_2d) < 0.0:
				other_2d.reverse()
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
		if not _split_is_valid(face_2d, face_area, covers, triangles):
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

# Validate a split triangulation without relying on exact boolean areas (which are
# unreliable when covers overlap). Every triangle must lie in the visible region
# (centroid inside the face and outside every cover); the total must not exceed the
# face; and it must cover at least the area that is guaranteed visible (the face
# minus the summed cover area — a safe lower bound). A failure keeps the face whole.
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

# Build a BSP from the original solid occluder brushes (from the snapshot, so a
# prior cull pass erasing faces cannot unseal the world). Each brush is passed
# with its interior point so the BSP can orient its planes consistently.
func _build_occluder_bsp():
	var brushes: Array = []
	var world := AABB()
	var first := true
	for brush in _brush_orig:
		var bounds: Array = _brush_orig[brush]
		brushes.append({"planes": brush.planes, "inside": bounds[1]})
		if first:
			world = bounds[0]
			first = false
		else:
			world = world.merge(bounds[0])

	var bsp := _KajmakBSPScript.new()
	bsp.build(brushes, world)
	return bsp

# Trim faces down to the parts the player can actually see. Builds the BSP, floods
# the empty space connected to the outside, then for each face keeps only the
# fragments whose front faces interior space or solid, dropping the parts that
# front the exterior void. A face fully facing the void is removed; one partly
# outside is split and rebuilt to just its visible region.
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
			# Brush centroid is the reference for "outward" so we never trust a face
			# plane that happens to point the wrong way.
			var brush_centroid: Vector3 = _brush_origin_bounds(brush)[1]
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
				var fragments: Array = []   # visible parts as 2D CCW polygons
				var keep_area := 0.0
				for tri: PackedVector3Array in _face_triangles_3d(face):
					var t2d := _project_2d(tri, origin, u, v)
					total_area += absf(_triangle_signed_area(t2d[0], t2d[1], t2d[2]))
					for frag: PackedVector3Array in bsp.face_visible_fragments(tri, outward):
						var f2d := _project_2d(frag, origin, u, v)
						if f2d.size() < 3:
							continue
						if _signed_area_2d(f2d) < 0.0:
							f2d.reverse()
						var fa := absf(_signed_area_2d(f2d))
						if fa <= 1.0e-9:
							continue
						fragments.append(f2d)
						keep_area += fa

				if total_area <= 0.0:
					continue
				if keep_area <= total_area * 1.0e-4:
					to_remove.append([brush, face])
					if debug_log_pairs:
						print("[KAJMAK] e%d '%s' faces void -> removed" % [entity_index, face.texture])
				elif keep_area < total_area * (1.0 - 1.0e-4):
					# Merge the visible fragments into as few polygons as possible, then
					# triangulate, so a trimmed face does not explode into slivers. Fall
					# back to a per-fragment fan if the merged triangulation looks wrong.
					var tris := _exterior_triangulate(fragments)
					if tris.is_empty() or absf(_tris_area(tris) - keep_area) > keep_area * 0.02:
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

# Merge connected coplanar visible fragments and triangulate each resulting
# polygon with ear clipping, so a trimmed face stays as few triangles as it can.
# Returns flat CCW 2D triangle triples, or empty to signal "use the fallback".
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

# Dev only: build the occluder BSP and leave it in [member bsp_last] for a harness
# to inspect. Does not touch any face, so the build output is unchanged.
func _bsp_debug_stats() -> void:
	var bsp: Variant = _build_occluder_bsp()
	bsp.mark_exterior()
	bsp_last = bsp
	print("[KAJMAK BSP] %s exterior-leaves %d" % [bsp.stats_string(), bsp.exterior_leaf_count])

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

# Union together any cover polygons that are connected (overlapping OR merely
# touching), so the later subtraction produces clean, non-overlapping holes. Two
# covers are merged when their union is a single ring; disjoint covers are kept.
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
				# Only merge when the union is a single hole-free polygon. If merging
				# would create a hole (e.g. four window-frame bars forming a ring), keep
				# the covers separate so the enclosed island of the face survives.
				if merged.size() == 1 and hole_count == 0:
					result[i] = merged[0]
					result.remove_at(j)
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
			var a := tris[t]
			var b := tris[t + 1]
			var c := tris[t + 2]
			if _triangle_signed_area(a, b, c) < 0.0:
				var s := b
				b = c
				c = s
			out.append(a)
			out.append(b)
			out.append(c)
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
