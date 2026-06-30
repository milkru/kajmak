# kajmak

`kajmak` removes faces you never see from your `func_godot` maps.

During the map build, it checks which brush faces are hidden behind other solid brushes. Fully hidden faces are removed. Partly hidden faces are trimmed, and the visible part is kept.

This is the same kind of optimization used by old Quake and Half-Life compilers. `func_godot` does not do this, so `kajmak` adds it as a small separate plugin. It does not modify `func_godot`, so you can still update `func_godot` normally.

![Example](https://github.com/milkru/data_resources/blob/main/kajmak.png "Example")

## Install

1. Copy `addons/kajmak` into your project, next to `addons/func_godot`.
2. Open Project Settings, go to Plugins and enable both `func_godot` and `kajmak`.

Built and tested with `func_godot` 2025.12 and Godot 4.5. Other Godot versions probably work, but they have not been tested yet.

## Usage

Use a `KajmakMap` node instead of a `FuncGodotMap` node.

It is a drop-in replacement. Use the same map file, the same map settings, and the same Build button. The result is the same scene, but with fewer visual surfaces.

## Options

On the `KajmakMap` node, under the `kajmak` category:

* **cull_hidden_faces**
  Removes faces hidden behind other solid brushes. On by default.

* **cull_exterior_faces**
  Removes exterior faces that point into the empty void outside a sealed level. Off by default.

* **debug_log_pairs**
  Prints removed and split faces to the Output panel. Off by default.

Collision is never changed. `kajmak` only removes visual surfaces.

See [docs/GUIDE.md](docs/GUIDE.md) for details about exterior culling, skip brushes, leaks, limits, and tests.
