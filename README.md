# kajmak

`kajmak` removes faces you never see from your `func_godot` maps.

During the map build, it checks which brush faces are hidden behind other solid brushes. Fully hidden faces are removed. Partly hidden faces are trimmed, and the visible part is kept.

This is the same kind of optimization used by old Quake and Half-Life compilers. `func_godot` does not do this, so `kajmak` adds it as a small separate plugin. It does not modify `func_godot`, so you can still update `func_godot` normally.

![Example](https://github.com/milkru/data_resources/blob/main/kajmak.png "Example")

## Install

1. Copy `addons/kajmak` into your project, next to `addons/func_godot`.
2. Open Project Settings, go to Plugins and enable both `func_godot` and `kajmak`.

Built and tested with `func_godot` 2025.12 and Godot 4.5 and 4.7. Other Godot versions probably work, but they have not been tested yet.

## Usage

Use a `KajmakMap` node instead of a `FuncGodotMap` node.

It is a drop-in replacement. Use the same map file, the same map settings and the same Build button. The result is the same scene, but with fewer visual surfaces.

## Options

On the `KajmakMap` node, under the `kajmak` category:

* **cull_hidden_faces**
  Removes geometry hidden behind other solid brushes. On by default.

* **cull_exterior_faces**
  Removes exterior geometry that point into the empty void outside a sealed level. Off by default.

* **weld_t_junctions**
  After culling, adds each face corner that lies on a neighbouring face's edge to that face, so neighbours share their corners and no hairline cracks open between them. On by default.

* **static_classes**
  Classnames of the brush entities that never move (worldspawn, func_detail, func_group by default). Their brushes hide each other's faces; any other brush entity, such as a door, only hides its own.

* **see_through_classes**
  Classnames of see-through brush entities, such as alpha cutouts (a railing panel, foliage). Their brushes hide no face, so the floor under a railing stays whole; solid brushes still hide their faces. None by default.

* **debug_log_pairs**
  Prints removed and split faces to the Output panel. Off by default.

Convex collision is never changed. Concave collision is built from the faces `kajmak` keeps, so a culled face loses its collision triangles too; it is buried or outside the map, where nothing can touch it.

See [docs/GUIDE.md](docs/GUIDE.md) for details about exterior culling, skip brushes, leaks, limits, and tests.
