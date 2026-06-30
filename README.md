# kajmak

`kajmak` removes faces you never see from your `func_godot` maps.

During the map build, `kajmak` creates a BSP of your level and uses it to find hidden faces and removes them. If only part of a face is hidden, `kajmak` cuts away the covered part and keeps the visible part.

This is the same kind of optimization used by old Quake and Half-Life compilers. `func_godot` does not do this, so `kajmak` adds it as a small separate plugin. It does not modify `func_godot`, so you can still update `func_godot` normally.

![Example](https://github.com/milkru/data_resources/blob/main/kajmak.png "Example")

## Install

1. Copy `addons/kajmak` into your project, next to `addons/func_godot`.
2. Open Project Settings, go to Plugins and enable both FuncGodot and `kajmak`.

Built and tested with `func_godot` 2025.12 and Godot 4.5. Other versions may work, but they have not been tested yet.

## Usage

Use a `KajmakMap` node instead of a `FuncGodotMap` node.

It is a drop-in replacement. Use the same map file, the same map settings and the same Build button. The result is the same scene, but with fewer visual surfaces.

## Options

On the `KajmakMap` node, under the `kajmak` category:

* **cull_hidden_faces**
  Default: on
  Removes faces hidden behind other solid brushes. Turn this off to build the map exactly like plain `func_godot`.

* **cull_exterior_faces**
  Default: off
  Also removes the outer shell of a sealed level, where faces point into the empty void outside the map.

  `kajmak` does this by flooding the outside of the BSP and removing anything the outside can reach. To seal an open map, close it with skip-textured brushes. They do not render, but they still count as solid, so they can seal the level for the flood while staying invisible in-game.

* **debug_log_pairs**
  Default: off
  Prints removed and split faces to the Output panel.

Collision is never changed. `kajmak` only removes visual surfaces.

See [docs/GUIDE.md](docs/GUIDE.md) for more details on how it works and how to find leaks.

