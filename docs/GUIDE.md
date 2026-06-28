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

* **cull_hidden_faces** Master switch. Off means you get a plain func_godot build.
* **debug_log_pairs** Prints a line per removed or split face to the Output panel. Leave it off unless you are chasing a specific face that is not behaving.

Both live on the `KajmakMap` node in the Kajmak category. You also still have all the normal func_godot settings.

## Groups, linked groups, layers

TrenchBroom groups and layers are just for organising. func_godot folds their brushes into worldspawn, so Kajmak treats everything uniformly and groups need no special care. The only thing to know is that func_godot does not apply linked group transforms, so a linked instance shows up where its raw map coordinates put it.

## Limits worth knowing

* A brush sunk fully inside another solid, with no face that lines up flush, will not be trimmed. Keep buried detail out of solids if you want it gone, or skip texture the faces yourself.
* Kajmak only removes what is hidden by touching solid brushes. It does not flood fill the level to find faces that face the empty outside, so an open back wall of a sealed room is not removed. That is a vis pass, which is a whole other beast.
* No T junction welding. In grid snapped TrenchBroom geometry this has not shown up as visible cracks, but if you build very off grid you might see hairline seams at a split edge.

## Running the tests

The `dev` folder has a small headless test suite. None of it ships, it is just for development.

Run the edge case corpus with Godot in headless mode against the test project:

```
godot --headless --path external/func_godot_test_project --script res://dev/verify_corpus.gd
```

There are also `verify_skeleton.gd` (proves culling off matches plain func_godot), `verify_cull.gd`, `verify_wedge.gd` and `verify_wedge_split.gd`. Each one builds a tiny map and checks the numbers, so if you change the culling code you can tell straight away whether you broke something.

If you add a new tricky map case, make a small map under `dev/maps`, add an expected result to `verify_corpus.gd`, and it becomes a permanent guard.
