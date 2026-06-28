@tool
class_name KajmakBSP extends RefCounted
## Solid-leaf BSP tree built from brush volumes, for visible-surface culling.
##
## Splits space by brush planes and stops once a cell is homogeneous: inside a
## brush (SOLID leaf) or outside every brush (EMPTY leaf). Cells are inward-normal
## half-space lists; their convex corners are enumerated from the planes on demand,
## giving exact classification without any grid or ray sampling. Each brush carries
## an interior point so its planes can be oriented outward regardless of winding.

const EPS := 0.001
const _MAX_DEPTH := 256
const _MAX_NODES := 1 << 18

# Where a query plane sits relative to a convex cell.
enum { _FRONT, _BACK, _STRADDLE }

## Internal nodes carry a split [member plane] and two children; leaves carry [member solid].
class BSPNode extends RefCounted:
	var plane: Plane          # splitting plane (internal nodes only)
	var front: BSPNode = null    # cell on the positive side of plane
	var back: BSPNode = null     # cell on the negative side of plane
	var is_leaf: bool = false
	var solid: bool = false   # leaf only
	var exterior: bool = false # leaf only: empty and reachable from the outside void
	var cell: Array = []      # leaf only: inward-normal half-spaces of the cell
	var verts: PackedVector3Array = PackedVector3Array()  # leaf only: cached cell corners
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
## Optional [KajmakMap.BuildState]; set its cancelled flag to abort the build early.
var cancel_state: Variant = null

# Stats, filled by build().
var node_count: int = 0
var leaf_count: int = 0
var solid_leaf_count: int = 0
var empty_leaf_count: int = 0
var internal_count: int = 0
var max_depth: int = 0
var build_msec: float = 0.0
var aborted: bool = false


## Build the tree. [param brushes] holds [Brush] objects or [code]{planes, inside}[/code]
## dicts; the root cell is [param world_aabb] grown slightly.
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
	root = _build_node(cell, _cell_vertices(cell), indices, 0)
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


func _build_node(cell: Array, verts: PackedVector3Array, brush_indices: PackedInt32Array, depth: int) -> BSPNode:
	node_count += 1
	if depth > max_depth:
		max_depth = depth

	if cancel_state != null and cancel_state.cancelled:
		return _make_leaf(false, depth, cell, verts)  # abort: tree is discarded anyway
	if verts.is_empty():
		return _make_leaf(false, depth, cell, verts)  # degenerate sliver: treat as empty

	# One pass per brush, collecting its straddling planes as split candidates:
	# inside any brush -> solid leaf, misses dropped, crossing brushes keep splitting.
	var crossing := PackedInt32Array()
	var candidates: Array[Plane] = []
	for bi in brush_indices:
		var inside_all := true
		var outside := false
		var straddlers: Array[Plane] = []
		for plane in _brushes[bi].planes:
			match _classify(plane, verts):
				_FRONT:
					outside = true
					break
				_STRADDLE:
					inside_all = false
					straddlers.append(plane)
		if outside:
			continue
		if inside_all:
			return _make_leaf(true, depth, cell, verts)
		crossing.append(bi)
		candidates.append_array(straddlers)

	if crossing.is_empty():
		return _make_leaf(false, depth, cell, verts)

	if depth >= _MAX_DEPTH or node_count >= _MAX_NODES:
		aborted = true
		return _make_leaf(false, depth, cell, verts)

	var split := _best_split(candidates, verts)
	if split == null:
		return _make_leaf(false, depth, cell, verts)  # no plane actually cuts the cell

	var back_plane := Plane(-split.normal, -split.d)
	var front_cell := cell.duplicate()
	front_cell.append(split)
	var back_cell := cell.duplicate()
	back_cell.append(back_plane)

	var node := BSPNode.new()
	node.plane = split
	node.depth = depth
	internal_count += 1
	node.front = _build_node(front_cell, _child_vertices(verts, cell, split), crossing, depth + 1)
	node.back = _build_node(back_cell, _child_vertices(verts, cell, back_plane), crossing, depth + 1)
	return node


# Corners of a child cell (parent + new_plane): the parent corners in front of
# new_plane, plus where new_plane meets each pair of parent planes. Same set as a
# full re-enumeration, but O(n^2) instead of O(n^3).
func _child_vertices(parent_verts: PackedVector3Array, parent_cell: Array, new_plane: Plane) -> PackedVector3Array:
	var out := PackedVector3Array()
	for v in parent_verts:
		if new_plane.distance_to(v) >= -EPS:
			out.append(v)
	var child_cell := parent_cell.duplicate()
	child_cell.append(new_plane)
	var n := parent_cell.size()
	for a in range(n):
		var pa: Plane = parent_cell[a]
		for b in range(a + 1, n):
			var p = pa.intersect_3(parent_cell[b], new_plane)
			if p == null:
				continue
			var pt: Vector3 = p
			if _inside_cell(pt, child_cell):
				out.append(pt)
	return out


func _make_leaf(solid: bool, depth: int, cell: Array, verts: PackedVector3Array) -> BSPNode:
	var node := BSPNode.new()
	node.is_leaf = true
	node.solid = solid
	node.cell = cell
	node.verts = verts
	node.depth = depth
	leaf_count += 1
	if solid:
		solid_leaf_count += 1
	else:
		empty_leaf_count += 1
	leaves.append(node)
	return node


## Leaf cell containing [param point]; on-plane points resolve to the front child.
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


## Flood the empty leaves connected to the outside void. Builds portal adjacency,
## seeds empty leaves touching the outer bounds, floods through empty neighbours;
## leaves [member BSPNode.exterior] set on every leaf reachable without crossing solid.
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


# A leaf seeds the flood when one of its corners lies on the grown root box.
func _touches_outer(leaf: BSPNode, mn: Vector3, mx: Vector3) -> bool:
	for p in leaf.verts:
		if (absf(p.x - mn.x) <= EPS or absf(p.x - mx.x) <= EPS
				or absf(p.y - mn.y) <= EPS or absf(p.y - mx.y) <= EPS
				or absf(p.z - mn.z) <= EPS or absf(p.z - mx.z) <= EPS):
			return true
	return false


#region PORTALS (exact leaf adjacency)

# Exact leaf adjacency: for each internal node, clip its split plane to the cell
# (the portal), push it into both subtrees, and link overlapping front/back leaves.
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


# Clip a coplanar polygon down a subtree, collecting [leaf, piece] per leaf reached.
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


# Cross-section of a plane through a cell: a large quad on the plane clipped by every cell plane.
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


## Fragments of the face whose front faces interior space or solid (the parts to
## keep); the rest is void-facing. Lets a partly-outside face be trimmed, not dropped.
func face_visible_fragments(face_verts: PackedVector3Array, normal: Vector3) -> Array:
	var out: Array = []
	if face_verts.size() >= 3:
		_collect_visible(root, face_verts, normal, out)
	return out


func _collect_visible(node: BSPNode, poly: PackedVector3Array, normal: Vector3, out: Array) -> void:
	if node == null or poly.size() < 3:
		return
	if node.is_leaf:
		if node.solid or not node.exterior:
			out.append(poly)
		return

	var nf := 0
	var nb := 0
	for p in poly:
		var d := node.plane.distance_to(p)
		if d > EPS:
			nf += 1
		elif d < -EPS:
			nb += 1

	if nf == 0 and nb == 0:
		if normal.dot(node.plane.normal) >= 0.0:
			_collect_visible(node.front, poly, normal, out)
		else:
			_collect_visible(node.back, poly, normal, out)
	elif nb == 0:
		_collect_visible(node.front, poly, normal, out)
	elif nf == 0:
		_collect_visible(node.back, poly, normal, out)
	else:
		_collect_visible(node.front, _clip_front(poly, node.plane), normal, out)
		_collect_visible(node.back, _clip_front(poly, Plane(-node.plane.normal, -node.plane.d)), normal, out)


#endregion


## Point-in-any-brush test bypassing the tree (test ground truth): solid iff behind
## every plane of some brush.
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


# Of the straddling candidate planes, the one passing closest to the cell centroid
# (tends to halve it). Coplanar duplicates are folded; null if none cut the cell.
func _best_split(candidates: Array[Plane], verts: PackedVector3Array) -> Variant:
	if candidates.is_empty():
		return null
	var centroid := Vector3.ZERO
	for v in verts:
		centroid += v
	centroid /= float(verts.size())

	var best: Variant = null
	var best_dist := INF
	var seen: Dictionary = {}
	for plane in candidates:
		var key := _plane_key(plane)
		if seen.has(key):
			continue
		seen[key] = true
		var d := absf(plane.distance_to(centroid))
		if d < best_dist:
			best_dist = d
			best = plane
	return best


#region GEOMETRY PRIMITIVES

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


# Convex corners of a cell: intersect every plane triple, keep points inside all
# planes. Only used for the root; children derive theirs via _child_vertices.
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
