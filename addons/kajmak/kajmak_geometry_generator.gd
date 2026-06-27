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
## Current stages implemented (see RESEARCH.md task breakdown):
##   #2 coplanar/opposite face-pair detection (logged when debug_log_pairs)
##   #3 full-overlap cull: remove faces entirely covered by an opposite coplanar face

## When false, builds identically to stock func_godot (regression escape hatch).
var enable_cull: bool = true
## When true, prints every detected coplanar/opposite overlapping pair.
var debug_log_pairs: bool = false

# Coverage is considered "full" when the covered area is within this fraction of
# the face area. Overlaps below _OVERLAP_EPSILON of the face area are ignored.
const _FULL_COVERAGE_EPSILON := 1.0e-3
const _OVERLAP_EPSILON := 1.0e-4
const _COPLANAR_TOLERANCE := 0.001

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

## Global pre-pass: find faces that are entirely covered by an opposite-facing
## coplanar face (from any brush/entity/texture) and remove them. Faces are
## bucketed by plane so each face only compares against the few faces on its
## opposite plane, avoiding an O(n^2) sweep.
func cull_hidden_faces() -> void:
	# Gather candidate faces and bucket them by plane lookup key.
	var records: Array = []
	var bucket: Dictionary = {}  # Vector4i -> Array[record]
	for entity_index in entity_data.size():
		var entity: _EntityData = entity_data[entity_index]
		if not entity or entity.brushes.is_empty():
			continue
		for brush in entity.brushes:
			for face in brush.faces:
				if face.vertices.size() < 3:
					continue
				if is_skip(face) or is_origin(face):
					continue
				var record := {
					"id": records.size(),
					"entity": entity_index,
					"brush": brush,
					"face": face,
				}
				records.append(record)
				var key := get_plane_lookup_key(face.plane)
				if bucket.has(key):
					bucket[key].append(record)
				else:
					bucket[key] = [record]

	# Detect overlapping opposite coplanar pairs; mark fully-covered faces.
	var to_remove: Array = []  # [brush, face]
	var pair_count: int = 0
	for record in records:
		var face: _FaceData = record["face"]

		var opposite := Plane(face.plane)
		opposite.normal = -opposite.normal
		opposite.d = -opposite.d
		var opposite_key := get_plane_lookup_key(opposite)
		if not bucket.has(opposite_key):
			continue

		# Project this face to 2D once, using a basis derived from its plane.
		var basis := _plane_uv_basis(face.plane.normal)
		var u: Vector3 = basis[0]
		var v: Vector3 = basis[1]
		var origin: Vector3 = face.plane.get_center()
		var face_2d := _project_2d(face.vertices, origin, u, v)
		if _signed_area_2d(face_2d) < 0.0:
			face_2d.reverse()
		var face_area := absf(_signed_area_2d(face_2d))
		if face_area <= _OVERLAP_EPSILON:
			continue

		for other in bucket[opposite_key]:
			var other_face: _FaceData = other["face"]
			if other_face == face:
				continue
			# Confirm precise coplanar-opposite relationship (key match is coarse).
			if not (-face.plane.normal).is_equal_approx(other_face.plane.normal):
				continue
			if not other_face.plane.has_point(face.plane.get_center(), _COPLANAR_TOLERANCE):
				continue

			var other_2d := _project_2d(other_face.vertices, origin, u, v)
			if _signed_area_2d(other_2d) < 0.0:
				other_2d.reverse()

			var overlap := _intersection_area_2d(face_2d, other_2d)
			if overlap <= face_area * _OVERLAP_EPSILON:
				continue

			var fully_covered := overlap >= face_area * (1.0 - _FULL_COVERAGE_EPSILON)

			if debug_log_pairs and record["id"] < other["id"]:
				pair_count += 1
				print("[KAJMAK] pair  e%d '%s'  <->  e%d '%s'   overlap=%.1f%% of F   %s" % [
					record["entity"], face.texture,
					other["entity"], other_face.texture,
					100.0 * overlap / face_area,
					"FULL (F covered)" if fully_covered else "PARTIAL",
				])

			if fully_covered:
				to_remove.append([record["brush"], face])
				break

	# Apply removals. Collision is built from brush.planes, so it is unaffected.
	for pair in to_remove:
		var brush: _BrushData = pair[0]
		brush.faces.erase(pair[1])

	if debug_log_pairs:
		print("[KAJMAK] detected %d overlapping coplanar pair(s); removed %d fully-covered face(s)" % [
			pair_count, to_remove.size(),
		])

# Orthonormal in-plane basis [u, v] for a plane with the given normal.
func _plane_uv_basis(normal: Vector3) -> Array:
	var reference := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := normal.cross(reference).normalized()
	var v := normal.cross(u).normalized()
	return [u, v]

# Project 3D coplanar points onto a 2D plane basis anchored at origin.
func _project_2d(vertices: PackedVector3Array, origin: Vector3, u: Vector3, v: Vector3) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in vertices:
		var d := p - origin
		out.append(Vector2(d.dot(u), d.dot(v)))
	return out

# Signed area of a 2D polygon (positive = counter-clockwise).
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

#endregion
