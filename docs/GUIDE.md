# `kajmak` guide

This guide explains the parts that are too detailed for the README: where `kajmak` hooks into the build, how the culling works, what exterior culling needs, and what the current limits are.

## Build pipeline

`kajmak` is a `FuncGodotMap` subclass called `KajmakMap`.

When you press Build, it still runs the normal `func_godot` pipeline:

1. parse the map
2. generate brush windings
3. build the final scene

`kajmak` adds one extra geometry pass after the brush faces are generated, but before the final surfaces are built.

At that point, every face is still in the same shared coordinate space. That lets `kajmak` compare faces across brushes and entities before `func_godot` turns them into final render surfaces.

## Hidden face culling

For each visible face, `kajmak` checks nearby solid brushes and works out how much of the face is covered. A face is covered where another brush touches it face to face, and where it runs inside another brush that reaches in front of it (stacked steps, a pillar through a slab), as qbsp's CSG step does.

Brushes of the static entities (`static_classes`: worldspawn, func_detail and func_group by default) cover each other. Any other brush entity, such as a door or a lift, may move: only its own brushes cover its faces, and its brushes cover nothing else, so no hole shows when it moves. qbsp also works per entity.

* If the whole face is buried inside another solid, the face is removed.
* If only part of the face is covered, the hidden part is cut away in 2D.
* If the face is not covered, it is left unchanged.

Where two brushes overlap with faces flush on one plane, facing the same way, both faces would draw and flicker. As in qbsp, the later brush in the map keeps its face and the earlier one loses the overlapping part. A brush flush with a face doesn't bury it: only a brush that reaches in front of a face can.

Covers too small to matter are ignored: anything thinner than a strip 1/1024 of a map unit wide along the face's outline, which is float noise. The cut scales with the outline, not the area, so a small brush on a big floor still cuts its hole.

When a face is split, `kajmak` triangulates the remaining shape with ear clipping and rebuilds the face.

UVs, normals, and tangents are rebuilt the same way `func_godot` builds them, so the trimmed part should look like the original face.

Because this works from brush volumes and original face shapes, the processing order does not matter. Two overlapping faces can both be trimmed correctly.

## Exterior void culling

Exterior culling is optional and is meant for sealed levels.

Hidden face culling only removes faces hidden by other solid brushes. Exterior culling removes faces that point into the empty void outside the level, such as:

* backs of outer walls
* undersides of floors
* tops of roofs
* other outside shell faces the player never sees

`kajmak` builds a small BSP from all solid brushes. The BSP splits the world into convex cells and marks them as solid or empty.

Then it starts from a point outside the map and floods through empty cells:

* empty cells reached by the flood are exterior
* empty cells the flood cannot reach are interior
* solid cells stay solid

After that, each face is clipped against those cells.

* Parts facing the exterior void are removed.
* Parts facing an interior room are kept.
* Parts crossing between both are split and rebuilt.

The hidden face pass runs first. Exterior culling then trims whatever is left. Both passes use a snapshot of the original brush data, so one pass cannot corrupt the other.

## T-junction weld

Culling cuts faces, so a corner of one face often ends in the middle of a neighbour's edge (a T-junction). The two faces then don't share that point, and a hairline crack can open between them. Culled brushes are hollow, so light shines through such a crack from whatever lies behind it.

The weld runs last. Wherever a corner of one face lies on another face's outline, that face gets the corner too, as qbsp's tjunc pass does. Corners that differ only by float noise are merged first. A triangle that gains corners on one side is fanned from the opposite corner, otherwise from a new point at its centre.

After culling and welding, the faces of the static brushes form the closed boundary of their union: every edge is shared by two triangles, and no triangle is flipped (a sliver thinner than the weld tolerance is left unwelded instead).

## Sealing maps with skip

Exterior culling works best when the level is sealed. The outside void needs to be separate from the playable space.

If the map is open to a skybox, or not fully closed yet, seal it with skip-textured brushes.

Skip faces do not render, but `kajmak` still treats them as solid. That means they can block the outside flood without adding visible geometry.

You can:

* put a large skip box around the playable area
* patch only the open parts
* place skip brushes behind a backdrop or skybox area

This is useful for maps that are open on purpose, like a courtyard looking out at a fake background. Seal behind the background with skip, and exterior culling can still remove the unseen shell.

If there is a real leak to the outside, the flood can enter the level and mark interior cells as exterior. That can remove faces you expected to keep.

If a wall suddenly goes missing, treat it as a leak. Seal the map and rebuild.

## Debugging culling

Enable **debug_log_pairs** on the `KajmakMap` node if you need to inspect what happened.

It prints removed and split faces to the Output panel.

For exterior culling, a much larger outside flood than expected usually means the map has a leak.

## Groups, linked groups, and layers

TrenchBroom groups and layers are only for organisation.

`func_godot` folds their brushes into `worldspawn`, so `kajmak` treats them like normal brushes.

Linked groups are different. `func_godot` does not apply linked group transforms, so linked instances appear where their raw map coordinates place them.

## Limits

* Exterior culling needs a sealed map. A wall that is half against terrain and half open can be split correctly, but a real leak can still cause bad culling.
* Split faces can end up with more triangles than they had before.
* Welding adds corners and triangles to the faces it touches.
* Collision is not changed. `kajmak` only removes visual surfaces.

## Running the tests

The `dev` folder contains a small headless test suite. It is only for development and does not ship with the plugin.

Run the edge case corpus with Godot in headless mode against the test project:

```sh
godot --headless --path external/func_godot_test_project --script res://dev/verify_corpus.gd
```

Other test scripts:

* `verify_skeleton.gd` checks that every pass off matches plain `func_godot`.
* `verify_weld.gd` checks that culled and welded maps have no T-junctions and no open edges, and that the check finds T-junctions when the weld is off.
* `verify_cull.gd` checks basic hidden face culling.
* `verify_wedge.gd`, `verify_wedge_split.gd`, and `verify_window.gd` check split face cases.
* `verify_bsp.gd` builds the exterior BSP and checks solid and empty cells against a brute force point-in-brush test.
* `verify_exterior.gd` checks a sealed room and a leaky room.
* `verify_flood.gd` checks that the BSP portal flood matches a brute force voxel flood in both directions.

Each test builds a tiny map and checks the result. If you change the culling code, the tests should show quickly if something broke.

To add a new tricky case, make a small map under `dev/maps`, add the expected result to `verify_corpus.gd`, and it becomes part of the test corpus.
