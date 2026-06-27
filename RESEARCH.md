# RESEARCH.md — Import-time hidden-face culling for func_godot

## Purpose of this document
This file is the full context bootstrap for a new plugin/project (working dir
`C:/Dev/kajmak`, its own git repo). It was written by Claude in a prior session
after exploring a func_godot addon. Read this first in any new session before
writing code. The func_godot addon explored previously lives at
`C:/Dev/puslica/addons/func_godot` — that folder is **just a copy used in an
unrelated game**, not part of this project. Reference it for API only.

---

## Goal (what we're building)
A way to make func_godot replicate what the **Quake/Half-Life BSP compiler**
(qbsp/vbsp) does for visible-surface determination: during map compilation those
tools split brushes along every plane and discard faces that are not visible —
faces buried inside solid, or two faces flush back-to-back between adjacent
brushes. The result is the "perfectly cut" geometry you see when you noclip
through a Quake/HL map: no hidden/overlapping faces are rendered.

func_godot does **not** do this. We want to add it.

### Concrete example the user gave
- One big box brush, one smaller box brush glued face-to-face onto one of the
  big box's faces.
- Desired result:
  1. The small box's face that touches the big box is removed (fully covered).
  2. The big box's face is **split** so the sub-region covered by the small box
     is removed, while the still-visible border of that big face remains.

This is exactly CSG-style face fragmentation: cut each face by adjacent brush
volumes, drop fragments that are covered/interior, keep the rest.

---

## What func_godot already has (and its limits)
File: `addons/func_godot/src/core/geometry_generator.gd`

- It already does the **core qbsp primitive**: builds each face's polygon
  ("winding") by starting from an oversized quad on the face plane and clipping
  it against all *other planes of the same brush*
  (`generate_face_vertices`, ~line 109-137, via `Geometry3D.clip_polygon`).
- It has a partial culling feature: property `_cull_interior_faces`
  (`fgd/cull_interior_faces.tres`, applied to worldspawn/func_detail/func_geo/etc).
  Logic at `generate_entity_surfaces` ~line 391-446.

### Limits of the existing `_cull_interior_faces`
1. **Delete-only, never splits.** It removes a face only if it is *entirely*
   covered by an opposite-facing coplanar face. So the small box's glued face
   gets removed, but the big box's partially-covered face stays 100% intact.
   The "split the big face" half does not exist at all.
2. **Per-entity scope.** `surfaces` is built only from `entity.brushes`, so
   brushes in different entities (e.g. worldspawn vs a func_detail) never cull
   against each other.
3. **Per-texture scope.** Comparison loops over `surfaces[texture_name]`, so two
   glued faces with different textures never cull against each other.

So roughly the "delete fully-covered face" half partially exists; the "split a
larger face and drop the covered chunk" half is entirely missing.

---

## Approaches considered and the decisions made

### Editing the .map file before parsing — REJECTED for the real goal
The user wanted to edit `.map` files directly so changes preview in TrenchBroom.
This does **not** work for true culling because of the format:
- A `.map` brush is not a list of faces — it's a **convex volume** = the
  intersection of N half-space planes. Every brush is always a closed solid.
  You cannot delete or split a single face by editing brush data, and
  TrenchBroom always renders brushes as solid.
- Partial overlaps would require splitting a brush into multiple brushes:
  destructive, changes collision, pollutes the file, brittle. Rejected.
- Only thing that works at `.map` level: retexture fully-covered faces to a
  **skip/nodraw** texture (func_godot already culls `is_skip` faces,
  geometry_generator.gd ~line 342; TrenchBroom shows skip with a marker). That
  handles ONLY the full-overlap case, not splitting. Not our main path.

Key realization: BSP-style cutting is a **render-only, import-time** operation.
It doesn't correspond to any editable brush, so it cannot be previewed in
TrenchBroom anyway. So do it at import time, not in the `.map`.

### Fork func_godot — AVOID if possible
Not necessary.

### Separate plugin reusing func_godot's public classes — CHOSEN
func_godot's pipeline classes are all public `class_name`, instantiable
`RefCounted`:
- `FuncGodotParser` (`src/core/parser.gd`)
- `FuncGodotGeometryGenerator` (`src/core/geometry_generator.gd`)
- `FuncGodotEntityAssembler` (`src/core/entity_assembler.gd`)

`FuncGodotMap.build()` (`src/map/func_godot_map.gd:92-152`) just wires
parser → generator → assembler and emits `build_complete`. But it hardcodes
`FuncGodotGeometryGenerator.new(...)` at line 126, so to inject our own logic we
write our **own ~30-line build driver** (a copy of that method) inside our
plugin that uses:
1. `FuncGodotParser` (unchanged),
2. **our subclass** of `FuncGodotGeometryGenerator` that overrides
   `generate_entity_surfaces` (and adds a global pre-pass),
3. `FuncGodotEntityAssembler` (unchanged).

This keeps func_godot untouched and updatable; we never modify its files.

### Why NOT pure post-process on `build_complete`
Could connect to the `build_complete` signal and process the finished
`MeshInstance3D` nodes. Rejected as primary path: at that point geometry is
**triangle soup** — faces merged per-texture, triangulated, in OpenGL coords,
and the per-brush `Plane`/winding data (`FaceData`/`BrushData`) is already freed.
You'd have to reconstruct coplanar adjacency from raw triangles. The data we most
need is gone. The subclass approach keeps full brush/plane/winding access.

---

## The algorithm to implement (CSG-style face fragmentation)
We do NOT need a full BSP tree: no tree, no portals, no vis. Just face
fragmentation against convex brush volumes.

Relevant data structures (`src/core/data.gd`):
- `BrushData`: `planes: Array[Plane]`, `faces: Array[FaceData]`, `origin: bool`.
- `FaceData`: `vertices: PackedVector3Array` (the winding), `plane: Plane`,
  `indices`, `normals`, `tangents`, `texture`, `uv`, `uv_axes`.
  Helpers: `wind()`, `index_vertices()`, `get_centroid()`.
- Faces get their windings during `generate_brush_vertices`; the cull pre-pass
  must run AFTER windings exist but BEFORE/at surface generation.

High-level steps:
1. **Broadphase.** Compute each brush's AABB. Bucket brushes spatially (grid or
   AABB overlap test) so each face only tests against nearby brushes. Avoids
   O(n^2). (User said perf is not a concern since it's compile-time, but still
   do basic AABB rejection to keep it sane.)
2. **For each face F (of brush B):**
   For each other brush B2 whose AABB overlaps B and where B2 is "solid"
   (a real occluding brush — skip non-solid/illusionary/trigger/origin brushes;
   need a rule for which entity classes count as occluders):
   a. Clip F's polygon against the half-spaces of B2 to get the part of F that
      lies inside B2's volume (the covered fragment) and the parts outside.
   b. The fragment of F that is inside B2 AND lies on B2's surface plane
      (i.e. F is flush against one of B2's faces, opposite normals) is hidden →
      remove it. The remaining fragments stay.
3. **Re-triangulate** the surviving (possibly concave / multi-ring) polygon:
   project to 2D on the face plane, use `Geometry2D.clip_polygons(...,
   DIFFERENCE)` to subtract covered regions, then `Geometry2D.triangulate_polygon`,
   then lift back to 3D.
4. **Rebuild UVs/normals/tangents** for new vertices: func_godot's UVs are planar
   projection — call the existing `FuncGodotUtil.get_face_vertex_uv(v, face,
   tex_size)` on each new vertex. Normals = face plane normal (flat) or via the
   existing smoothing path. UV2 unwrap happens later, unaffected.
5. Feed surviving fragments back into the surface-assembly path that
   `generate_entity_surfaces` already uses.

Special cases / robustness:
- A big face may be covered by **multiple** small brushes — subtract them all
  before triangulating.
- Collision is unaffected: convex collision is built per-brush from `b.planes`
  (geometry_generator.gd ~line 546-558), independent of visual faces. Culling
  visuals will NOT break collision. Good.
- This is purely visual surface reduction.

---

## Known risks (engineering, not unknowns — no research blockers)
1. **Float robustness / T-junctions / cracks** — the classic qbsp pain point and
   where most dev time goes. MITIGATED: TrenchBroom forces grid-snapped modeling,
   which removes most of it upfront. Still need plane/coplanar tolerances.
2. **Performance** — naive is O(n^2); needs AABB/plane broadphase bucketing.
   User: don't care, it's compile-time. Still add basic AABB rejection.
3. **Concave / multi-ring fragments** — handled by Godot's `Geometry2D` polygon
   clipping + triangulation. Considered solved.

Verdict reached with user: bounded scope, standard algorithm, primitives already
present in Godot and func_godot. Roughly "a week of careful edge-case work,"
no blockers, no unknowns.

---

## Suggested task breakdown (ship incrementally)
1. **Plugin skeleton + build driver.** New plugin in `C:/Dev/kajmak` that
   instantiates `FuncGodotParser` → a trivial `FuncGodotGeometryGenerator`
   subclass (no changes yet) → `FuncGodotEntityAssembler`, driven from our own
   node/button. Confirm it builds a map identically to stock func_godot.
2. **Coplanar/adjacent face-pair detection (pure analysis, no geometry change).**
   Global pre-pass: AABB broadphase + bucket faces by plane; find opposite-facing
   coplanar overlapping faces across all brushes/entities. Just log pairs.
3. **Generalized full-overlap cull.** Using step 2's pairs, delete fully-covered
   faces — but now cross-brush, cross-entity, cross-texture (lifting the existing
   feature's 3 limits). Ships the "small glued face disappears" win.
4. **2D difference + split (the core new geometry).** For partial overlaps:
   project to 2D, `Geometry2D.clip_polygons(big, covered, DIFFERENCE)`,
   `triangulate_polygon`, lift to 3D. Do in isolation; riskiest step.
5. **Re-attach split fragments to mesh pipeline.** Recompute UVs
   (`get_face_vertex_uv` per new vertex), normals, tangents; verify visually.
6. **Robustness pass.** Tolerances, T-junctions, faces covered by multiple
   brushes, broadphase tuning, occluder-class rules.

Doing 1→3 first already gives the easy ~60% (full-overlap culling) and is
independently useful. Steps 4–5 are the real "weekend risk." Step 6 is polish.

---

## Open questions to resolve during dev
- Which entity/brush classes count as **occluders** (solid) vs pass-through
  (illusionary, triggers, clip-only, origin brushes)? Need an explicit allowlist.
- How to expose the feature: a global toggle, per-entity property (mirroring
  `_cull_interior_faces`), or both?
- Whether to also drop fully-interior faces of fully-embedded brushes (a brush
  entirely inside another) — likely yes, falls out of the same pass.

---

## Repos / resources (for later, do not pull yet)
- func_godot GitHub org: https://github.com/func-godot — multiple repos: the
  plugin source, example/test maps, TrenchBroom/FGD configs.
  - Likely useful: **example/test maps** (real geometry to validate culling
    against) and the **plugin source** (generator/parser API reference).
  - Probably not needed: TrenchBroom/FGD config repos.
- Plan: add useful ones as **git submodules** during research/dev, strip them
  before shipping so the plugin stays lean. (Requires this `C:/Dev/kajmak`
  folder to be its own git repo — the func_godot copy under `C:/Dev/puslica`
  is not a git repo.)
- Reference copy of func_godot for API reading:
  `C:/Dev/puslica/addons/func_godot` (unrelated game's copy; do not edit).

---

## TL;DR for a cold start
Build a **separate Godot plugin** (no fork) in `C:/Dev/kajmak` that reuses
func_godot's public classes via our own build driver, subclassing
`FuncGodotGeometryGenerator` to add a global, CSG-style hidden-face culling
pre-pass: clip each visual face against adjacent solid brush volumes and drop the
covered fragments (with splitting), reproducing qbsp/vbsp visible-surface
behavior at import time. Known algorithm, no blockers; main effort is float
robustness and wiring split fragments back into the mesh build.
