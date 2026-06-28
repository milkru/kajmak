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
	var exterior: bool = false # leaf only: empty and reachable from the outside void
	var cell: Array = []      # leaf only: inward-normal half-spaces of the cell
	var neighbors: Array = [] # leaf only: leaves sharing a portal (built on demand)
	var depth: int = 0

## One convex brush: outward-oriented half-space planes plus a known interior point.
class Brush extends RefCounted:
	var planes: Array[Plane] = []  # oriented so interior is the back (negative) side
	var inside: Vector3

var root: BSPNode = null
var bounds: AABB             # the world AABB passed to build()
var leaves: Array[BSPNode] = []
var exterior_leaf_count: int = 0
var _brushes: Array[Brush] = []
var _root_cell: Array = []   # the grown root cell, kept for portalization
var _grown: AABB             # the grown world bounds (root cell extent)

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
	bounds = world_aabb
	_ingest_brushes(brushes)

	var grown := world_aabb.grow(maxf(1.0, world_aabb.size.length() * 0.01))
	_grown = grown
	var cell := _aabb_cell(grown)
	_root_cell = cell
	var indices := PackedInt32Array()
	for i in _brushes.size():
		indices.append(i)

	node_count = 0
	leaf_count = 0
	solid_leaf_count = 0
	empty_leaf_count = 0
	exterior_leaf_count = 0
	internal_count = 0
	max_depth = 0
	aborted = false
	leaves.clear()
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
		return _make_leaf(false, depth, cell)  # degenerate sliver: treat as empty

	# Classify each candidate brush against this cell. If the cell is fully inside
	# any brush it is solid; brushes that miss the cell are dropped; the rest cross
	# the cell boundary and keep it alive for splitting.
	var crossing := PackedInt32Array()
	for bi in brush_indices:
		match _classify_brush(_brushes[bi], verts):
			_INSIDE:
				return _make_leaf(true, depth, cell)
			_CROSS:
				crossing.append(bi)
			# _OUTSIDE: drop

	if crossing.is_empty():
		return _make_leaf(false, depth, cell)

	if depth >= _MAX_DEPTH or node_count >= _MAX_NODES:
		aborted = true
		return _make_leaf(false, depth, cell)

	var split := _pick_split(crossing, verts)
	if split == null:
		return _make_leaf(false, depth, cell)  # no plane actually cuts the cell

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


func _make_leaf(solid: bool, depth: int, cell: Array) -> BSPNode:
	var node := BSPNode.new()
	node.is_leaf = true
	node.solid = solid
	node.cell = cell
	node.depth = depth
	leaf_count += 1
	if solid:
		solid_leaf_count += 1
	else:
		empty_leaf_count += 1
	leaves.append(node)
	return node


## Walk the tree to the leaf cell that contains [param point]. On-plane points
## (within EPS) resolve to the front child deterministically.
func locate_leaf(point: Vector3) -> BSPNode:
	var node := root
	while node != null and not node.is_leaf:
		if node.plane.distance_to(point) >= 0.0:
			node = node.front
		else:
			node = node.back
	return node


## True when [param point] lies in solid space.
func is_solid(point: Vector3) -> bool:
	var leaf := locate_leaf(point)
	return leaf != null and leaf.solid


#region EXTERIOR VOID FLOOD


## Flood fill the empty leaves that connect to the outside void. Builds exact leaf
## adjacency (BSP portals) once, seeds every empty leaf touching the outer bounds,
## then floods through empty neighbours. After this [member BSPNode.exterior] is
## true on every empty leaf reachable from outside without passing through solid.
func mark_exterior() -> void:
	_build_portals()
	for leaf in leaves:
		leaf.exterior = false
	exterior_leaf_count = 0

	var queue: Array[BSPNode] = []
	var mn := _grown.position
	var mx := _grown.position + _grown.size
	for leaf in leaves:
		if leaf.solid or leaf.exterior:
			continue
		if _touches_outer(leaf, mn, mx):
			leaf.exterior = true
			exterior_leaf_count += 1
			queue.append(leaf)

	while not queue.is_empty():
		var leaf: BSPNode = queue.pop_back()
		for nb in leaf.neighbors:
			if not nb.solid and not nb.exterior:
				nb.exterior = true
				exterior_leaf_count += 1
				queue.append(nb)


# A leaf touches the outer void when one of its cell vertices lies on the grown
# root box. The outer void always reaches that box, so these are the flood seeds.
func _touches_outer(leaf: BSPNode, mn: Vector3, mx: Vector3) -> bool:
	for p in _cell_vertices(leaf.cell):
		if (absf(p.x - mn.x) <= EPS or absf(p.x - mx.x) <= EPS
				or absf(p.y - mn.y) <= EPS or absf(p.y - mx.y) <= EPS
				or absf(p.z - mn.z) <= EPS or absf(p.z - mx.z) <= EPS):
			return true
	return false


#region PORTALS (exact leaf adjacency)

# Build adjacency between leaves that share a 2D face. For each internal node we
# take its split plane clipped to the node's cell (the portal), push it down both
# subtrees to the leaves it touches on each side, and link any front/back leaf
# pair whose pieces overlap. This is exact, unlike point sampling.
func _build_portals() -> void:
	for leaf in leaves:
		leaf.neighbors = []
	_portalize(root, _root_cell)


func _portalize(node: BSPNode, cell: Array) -> void:
	if node == null or node.is_leaf:
		return
	var portal := _plane_polygon(node.plane, cell)
	if portal.size() >= 3:
		var fronts: Array = []
		var backs: Array = []
		_gather_pieces(node.front, portal, fronts)
		_gather_pieces(node.back, portal, backs)
		for f in fronts:
			for b in backs:
				if _polys_overlap(f[1], b[1], node.plane):
					_link(f[0], b[0])
	var fc := cell.duplicate()
	fc.append(node.plane)
	var bc := cell.duplicate()
	bc.append(Plane(-node.plane.normal, -node.plane.d))
	_portalize(node.front, fc)
	_portalize(node.back, bc)


# Clip a coplanar polygon down a subtree, collecting [leaf, piece] for every leaf
# the polygon reaches.
func _gather_pieces(node: BSPNode, poly: PackedVector3Array, out: Array) -> void:
	if poly.size() < 3:
		return
	if node.is_leaf:
		out.append([node, poly])
		return
	_gather_pieces(node.front, _clip_front(poly, node.plane), out)
	_gather_pieces(node.back, _clip_front(poly, Plane(-node.plane.normal, -node.plane.d)), out)


func _link(a: BSPNode, b: BSPNode) -> void:
	if not a.neighbors.has(b):
		a.neighbors.append(b)
	if not b.neighbors.has(a):
		b.neighbors.append(a)


# The cross-section polygon of a plane through a convex cell: a big quad on the
# plane clipped by every (inward) cell plane.
func _plane_polygon(plane: Plane, cell: Array) -> PackedVector3Array:
	var n := plane.normal
	var ref := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := n.cross(ref).normalized()
	var v := n.cross(u).normalized()
	var c := plane.get_center()
	var r := _grown.size.length() * 2.0 + 10.0
	var poly := PackedVector3Array([
		c - u * r - v * r,
		c + u * r - v * r,
		c + u * r + v * r,
		c - u * r + v * r,
	])
	for cp: Plane in cell:
		poly = _clip_front(poly, cp)
		if poly.size() < 3:
			break
	return poly


# Keep the part of a convex polygon on the front (>= 0) side of a plane.
func _clip_front(poly: PackedVector3Array, plane: Plane) -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := poly.size()
	if n == 0:
		return out
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var da := plane.distance_to(a)
		var db := plane.distance_to(b)
		if da >= -EPS:
			out.append(a)
		if (da > EPS and db < -EPS) or (da < -EPS and db > EPS):
			var t := da / (da - db)
			out.append(a.lerp(b, t))
	return out


# Do two coplanar polygons overlap with positive area, measured in the plane.
func _polys_overlap(a: PackedVector3Array, b: PackedVector3Array, plane: Plane) -> bool:
	if a.size() < 3 or b.size() < 3:
		return false
	var n := plane.normal
	var ref := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := n.cross(ref).normalized()
	var v := n.cross(u).normalized()
	var c := plane.get_center()
	var a2 := PackedVector2Array()
	for p in a:
		a2.append(Vector2((p - c).dot(u), (p - c).dot(v)))
	var b2 := PackedVector2Array()
	for p in b:
		b2.append(Vector2((p - c).dot(u), (p - c).dot(v)))
	for poly in Geometry2D.intersect_polygons(a2, b2):
		var area := 0.0
		var m := poly.size()
		for i in m:
			var p0 := poly[i]
			var p1 := poly[(i + 1) % m]
			area += p0.x * p1.y - p1.x * p0.y
		if absf(area) * 0.5 > EPS:
			return true
	return false

#endregion


## True when any part of the space directly in front of a face opens onto the
## exterior void. The face polygon is pushed down the tree: at its own boundary
## plane it follows [param normal] to the outward side, transverse planes split
## it, and it ends at the leaves sitting just in front of the face. If any of
## those is an exterior empty leaf the face can see the void. This is exact, so a
## partially covered face is still culled when its exposed part sees out.
func face_front_is_exterior(face_verts: PackedVector3Array, normal: Vector3) -> bool:
	if face_verts.size() < 3:
		return false
	return _sees_exterior(root, face_verts, normal)


func _sees_exterior(node: BSPNode, poly: PackedVector3Array, normal: Vector3) -> bool:
	if node == null or poly.size() < 3:
		return false
	if node.is_leaf:
		return not node.solid and node.exterior

	var nf := 0
	var nb := 0
	for p in poly:
		var d := node.plane.distance_to(p)
		if d > EPS:
			nf += 1
		elif d < -EPS:
			nb += 1

	if nf == 0 and nb == 0:
		# Coplanar with this split: the face lies on it, so follow the outward side.
		if normal.dot(node.plane.normal) >= 0.0:
			return _sees_exterior(node.front, poly, normal)
		return _sees_exterior(node.back, poly, normal)
	if nb == 0:
		return _sees_exterior(node.front, poly, normal)
	if nf == 0:
		return _sees_exterior(node.back, poly, normal)

	if _sees_exterior(node.front, _clip_front(poly, node.plane), normal):
		return true
	return _sees_exterior(node.back, _clip_front(poly, Plane(-node.plane.normal, -node.plane.d)), normal)

#endregion


## Direct point-in-any-brush test, bypassing the tree. Ground truth for tests:
## a point is solid iff it is behind every plane of some brush.
func is_solid_bruteforce(point: Vector3) -> bool:
	for brush in _brushes:
		var inside := true
		for plane in brush.planes:
			if plane.distance_to(point) > 0.0:
				inside = false
				break
		if inside:
			return true
	return false


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
