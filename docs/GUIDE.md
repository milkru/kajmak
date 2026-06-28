# Kajmak guide

This goes a bit deeper than the README. If you just want to use the thing, the README is enough.

## How it works

Kajmak is a `FuncGodotMap` subclass called `KajmakMap`. When you build, it runs the normal func_godot pipeline (parse, generate brush windings, assemble) but slips one extra pass in between, right after the faces are wound and right before the surfaces are built.

In that pass every face is still sitting in the same shared coordinate space, so Kajmak can compare faces across brushes and entities freely. For each visible face it looks at the solid brushes nearby and works out how much of the face is hidden.

* If the whole face is buried inside another solid, the face is dropped.
* If part of it is covered, Kajmak subtracts the covered patches in 2D, then re triangulates whatever is left with an ear clipping triangulator and rebuilds the face. UVs, normals and tangents come back the same way func_godot makes them, so the split part looks identical to the rest.
* If nothing covers it, the face is left alone.

Because it works off brush volumes and the original face shapes, the order it processes faces in does not matter, and two faces that cover each other both get trimmed correctly.

## Why a separate plugin

func_godot exposes its pipeline classes as public, so Kajmak reuses them and only swaps the geometry step for its own. func_godot files are never modified. Update func_godot whenever you like and Kajmak keeps working, as long as it stays on a version close to what it targets.

## The options again

* **cull_hidden_faces** Master switch for the hidden face pass. Off means you get a plain func_godot build.
* **cull_exterior_faces** Off by default. Turns on the exterior void pass described below.
* **debug_log_pairs** Prints a line per removed or split face to the Output panel. Leave it off unless you are chasing a specific face that is not behaving.

All three live on the `KajmakMap` node in the Kajmak category. You also still have all the normal func_godot settings.

## Exterior void culling

This is the optional pass for sealed levels. The hidden face pass only removes faces touching another solid brush. The exterior pass goes after the other big pile of wasted faces, the outer shell of the level that faces the empty void outside, like the back of every outer wall, the underside of the floor and the top of the roof. The player is sealed inside and never sees any of it.

Here is how it works. Kajmak builds a small BSP out of all your solid brushes, which carves the world into convex cells and tags each one solid or empty. Then it floods the empty cells starting from a point well outside the map. Every empty cell the flood can reach is exterior. Anything it cannot reach, like the inside of a sealed room, stays interior. A face is removed only when the space directly in front of it is entirely exterior. If any part of the front still faces a room or sits against solid, the face is kept whole.

The flood runs first on the untouched faces, then the hidden face pass splits whatever is left, so the two passes stack cleanly.

This pass assumes a sealed map. If there is a gap to the outside, the flood leaks in through it and marks interior cells as exterior, which would cull faces you actually see. Kajmak guards against the worst of this by only removing a face when its whole front is exterior, so a leak tends to nibble a few faces near the hole rather than gut a room. Still, treat a sudden missing wall as a sign of a leak and seal it. Turn on debug_log_pairs to see how many outside cells the flood found, a number far larger than you expect usually means it got out.

## Groups, linked groups, layers

TrenchBroom groups and layers are just for organising. func_godot folds their brushes into worldspawn, so Kajmak treats everything uniformly and groups need no special care. The only thing to know is that func_godot does not apply linked group transforms, so a linked instance shows up where its raw map coordinates put it.

## Limits worth knowing

* A brush sunk fully inside another solid, with no face that lines up flush, will not be trimmed. Keep buried detail out of solids if you want it gone, or skip texture the faces yourself.
* Exterior culling needs a sealed map and only removes a face when its whole front faces the void. A wall that is half against terrain and half open is kept whole rather than split.
* No T junction welding. In grid snapped TrenchBroom geometry this has not shown up as visible cracks, but if you build very off grid you might see hairline seams at a split edge.

## Running the tests

The `dev` folder has a small headless test suite. None of it ships, it is just for development.

Run the edge case corpus with Godot in headless mode against the test project:

```
godot --headless --path external/func_godot_test_project --script res://dev/verify_corpus.gd
```

There are also `verify_skeleton.gd` (proves culling off matches plain func_godot), `verify_cull.gd`, `verify_wedge.gd`, `verify_wedge_split.gd`, `verify_window.gd`, `verify_bsp.gd` (builds the exterior BSP and checks its solid and empty cells against a brute force point in brush test) and `verify_exterior.gd` (a sealed room and a leaky room, checks the void flood stays out of the sealed one and removes the outer shell). Each one builds a tiny map and checks the numbers, so if you change the culling code you can tell straight away whether you broke something.

If you add a new tricky map case, make a small map under `dev/maps`, add an expected result to `verify_corpus.gd`, and it becomes a permanent guard.
