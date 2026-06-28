@tool
class_name KajmakBSP extends RefCounted
## Solid-leaf BSP tree built from brush volumes.
##
## Foundation for the BSP-based culling rewrite. The tree partitions space with
## brush face planes and stops as soon as a cell is homogeneous: fully inside a
## brush (a SOLID leaf) or outside every brush (an EMPTY leaf). That pruning is
## what keeps the tree proportional to the surface complexity instead of blowing
## up into the full plane arrangement.
##
## Each cell is represented purely as a list of half-space planes with INWARD
## normals, so a point is inside the cell when [code]plane.distance_to(point) >=
## -EPS[/code] for every cell plane. A cell's convex vertices are enumerated on
## demand from those planes, giving exact plane-vs-cell classification and an
## exact interior sample point without any global grid or fragile ray sampling.
##
## Brushes are passed with an interior point so the builder can orient each brush
## plane to point outward (interior on the back side) regardless of the source
## winding convention.

const EPS := 0.001
const _MAX_DEPTH := 256
const _MAX_NODES := 1 << 18

# Where a query plane sits relative to a convex cell, and how a brush sits.
enum { _FRONT, _BACK, _STRADDLE }
enum { _OUTSIDE, _INSIDE, _CROSS }

## A node in the tree. Internal nodes carry a splitting [member plane] and two
## children. Leaf nodes carry [member solid].
class BSPNode extends RefCounted:
	var plane: Plane          # splitting plane (internal nodes only)
	var front: BSPNode = null    # cell on the positive side of plane
	var back: BSPNode = null     # cell on the negative side of plane
	var is_leaf: bool = false
	var solid: bool = false   # leaf only
	var depth: int = 0

## One convex brush: outward-oriented half-space planes plus a known interior point.
class Brush extends RefCounted:
	var planes: Array[Plane] = []  # oriented so interior is the back (negative) side
	var inside: Vector3

var root: BSPNode = null
var _brushes: Array[Brush] = []

# Stats, filled by build().
var node_count: int = 0
var leaf_count: int = 0
var solid_leaf_count: int = 0
var empty_leaf_count: int = 0
var internal_count: int = 0
var max_depth: int = 0
var build_msec: float = 0.0
var aborted: bool = false


## Build the tree. [param brushes] is an array of either [Brush] objects or
## dictionaries [code]{planes: Array[Plane], inside: Vector3}[/code].
## [param world_aabb] bounds the map; the root cell is this box grown slightly.
func build(brushes: Array, world_aabb: AABB) -> void:
	var start := Time.get_ticks_usec()
	_ingest_brushes(brushes)

	var grown := world_aabb.grow(maxf(1.0, world_aabb.size.length() * 0.01))
	var cell := _aabb_cell(grown)
	var indices := PackedInt32Array()
	for i in _brushes.size():
		indices.append(i)

	node_count = 0
	leaf_count = 0
	solid_leaf_count = 0
	empty_leaf_count = 0
	internal_count = 0
	max_depth = 0
	aborted = false
	root = _build_node(cell, indices, 0)
	build_msec = (Time.get_ticks_usec() - start) / 1000.0


func _ingest_brushes(brushes: Array) -> void:
	_brushes.clear()
	for item in brushes:
		var b := Brush.new()
		var raw_planes: Array
		if item is Brush:
			b.inside = item.inside
			raw_planes = item.planes
		else:
			b.inside = item["inside"]
			raw_planes = item["planes"]
		# Orient every plane so the interior point is on the back (negative) side.
		var oriented: Array[Plane] = []
		for plane in raw_planes:
			if plane.distance_to(b.inside) > 0.0:
				oriented.append(Plane(-plane.normal, -plane.d))
			else:
				oriented.append(plane)
		b.planes = oriented
		_brushes.append(b)


func _build_node(cell: Array, brush_indices: PackedInt32Array, depth: int) -> BSPNode:
	node_count += 1
	if depth > max_depth:
		max_depth = depth

	var verts := _cell_vertices(cell)
	if verts.is_empty():
		return _make_leaf(false, depth)  # degenerate sliver: treat as empty

	# Classify each candidate brush against this cell. If the cell is fully inside
	# any brush it is solid; brushes that miss the cell are dropped; the rest cross
	# the cell boundary and keep it alive for splitting.
	var crossing := PackedInt32Array()
	for bi in brush_indices:
		match _classify_brush(_brushes[bi], verts):
			_INSIDE:
				return _make_leaf(true, depth)
			_CROSS:
				crossing.append(bi)
			# _OUTSIDE: drop

	if crossing.is_empty():
		return _make_leaf(false, depth)

	if depth >= _MAX_DEPTH or node_count >= _MAX_NODES:
		aborted = true
		return _make_leaf(false, depth)

	var split := _pick_split(crossing, verts)
	if split == null:
		return _make_leaf(false, depth)  # no plane actually cuts the cell

	var front_cell := cell.duplicate()
	front_cell.append(split)
	var back_cell := cell.duplicate()
	back_cell.append(Plane(-split.normal, -split.d))

	var node := BSPNode.new()
	node.plane = split
	node.depth = depth
	internal_count += 1
	node.front = _build_node(front_cell, crossing, depth + 1)
	node.back = _build_node(back_cell, crossing, depth + 1)
	return node


func _make_leaf(solid: bool, depth: int) -> BSPNode:
	var node := BSPNode.new()
	node.is_leaf = true
	node.solid = solid
	node.depth = depth
	leaf_count += 1
	if solid:
		solid_leaf_count += 1
	else:
		empty_leaf_count += 1
	return node


# A brush's interior is the back side of all its (outward) planes. So the cell is
# OUTSIDE the brush if any plane has the whole cell on its front side; INSIDE if
# the whole cell is behind every plane; otherwise the boundary CROSSes the cell.
func _classify_brush(brush: Brush, verts: PackedVector3Array) -> int:
	var inside_all := true
	for plane in brush.planes:
		match _classify(plane, verts):
			_FRONT:
				return _OUTSIDE
			_STRADDLE:
				inside_all = false
	return _INSIDE if inside_all else _CROSS


# Choose a splitting plane from the crossing brushes' faces. Phase-1 heuristic:
# among the brush planes that actually cut this cell, take the one passing closest
# to the cell centroid, which tends to halve it. Fragment-aware scoring lands in a
# later phase. Returns null if somehow none cut the cell.
func _pick_split(crossing: PackedInt32Array, verts: PackedVector3Array) -> Variant:
	var centroid := Vector3.ZERO
	for v in verts:
		centroid += v
	centroid /= float(verts.size())

	var best: Variant = null
	var best_dist := INF
	var seen: Dictionary = {}
	for bi in crossing:
		for plane in _brushes[bi].planes:
			if _classify(plane, verts) != _STRADDLE:
				continue
			var key := _plane_key(plane)
			if seen.has(key):
				continue
			seen[key] = true
			var d := absf(plane.distance_to(centroid))
			if d < best_dist:
				best_dist = d
				best = plane
	return best


#region GEOMETRY PRIMITIVES (reused by later phases)

# Six inward-pointing half-space planes of an AABB.
func _aabb_cell(box: AABB) -> Array:
	var mn := box.position
	var mx := box.position + box.size
	var cell: Array = []
	cell.append(Plane(Vector3.RIGHT, mn.x))      # x >= mn.x
	cell.append(Plane(Vector3.LEFT, -mx.x))      # x <= mx.x
	cell.append(Plane(Vector3.UP, mn.y))         # y >= mn.y
	cell.append(Plane(Vector3.DOWN, -mx.y))      # y <= mx.y
	cell.append(Plane(Vector3.BACK, mn.z))       # z >= mn.z
	cell.append(Plane(Vector3.FORWARD, -mx.z))   # z <= mx.z
	return cell


# Enumerate the convex vertices of a cell given as inward-normal half-spaces.
# Every triple of planes is intersected and the point kept when it lies inside
# (or on) all planes. Small per cell, so the O(n^3) triple scan is cheap.
func _cell_vertices(cell: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := cell.size()
	for a in range(n):
		for b in range(a + 1, n):
			for c in range(b + 1, n):
				var p = cell[a].intersect_3(cell[b], cell[c])
				if p == null:
					continue
				var point: Vector3 = p
				if _inside_cell(point, cell):
					out.append(point)
	return out


func _inside_cell(point: Vector3, cell: Array) -> bool:
	for plane in cell:
		if plane.distance_to(point) < -EPS:
			return false
	return true


# Classify a query plane against a set of cell vertices.
func _classify(plane: Plane, verts: PackedVector3Array) -> int:
	var has_front := false
	var has_back := false
	for v in verts:
		var d := plane.distance_to(v)
		if d > EPS:
			has_front = true
		elif d < -EPS:
			has_back = true
		if has_front and has_back:
			return _STRADDLE
	if has_back:
		return _BACK
	return _FRONT  # all in front, or all coplanar (degenerate): treat as front


func _plane_key(plane: Plane) -> Vector4i:
	# Fold a plane and its flip together so opposite coplanar faces share a key.
	var n := plane.normal
	var d := plane.d
	if (n.x < -EPS
			or (absf(n.x) <= EPS and n.y < -EPS)
			or (absf(n.x) <= EPS and absf(n.y) <= EPS and n.z < 0.0)):
		n = -n
		d = -d
	const P := 16.0
	return Vector4i(roundi(n.x * P), roundi(n.y * P), roundi(n.z * P), roundi(d * P))

#endregion


## One-line stats summary for logging.
func stats_string() -> String:
	return ("nodes %d (leaves %d: %d solid, %d empty; internal %d) depth %d %.1f ms%s" % [
		node_count, leaf_count, solid_leaf_count, empty_leaf_count, internal_count,
		max_depth, build_msec, "  ABORTED(guard)" if aborted else "",
	])
