# kajmak

Kajmak removes the faces you never see from your func_godot maps.

Build a Quake style map with func_godot and every brush is a solid box. Stack boxes, sink a pillar into a wall, drop a slab on the floor, and the buried faces still get built and drawn. You cannot see them, but the GPU still pays for them. While the map builds, Kajmak makes a BSP of your level and uses it to find those hidden faces and cut them out. When a face is only partly hidden, it trims the covered part and keeps the rest.

It is the same trick the old Quake and Half Life compilers used. func_godot does not do it, so Kajmak adds it as a small separate plugin. It never touches func_godot itself, so you can update func_godot whenever you want.

![Example](https://github.com/milkru/data_resources/blob/main/kajmak.png "Example")

## Install

1. Copy `addons/kajmak` into your project, next to `addons/func_godot`.
2. In Project Settings, Plugins, enable both FuncGodot and Kajmak.

You need func_godot 2025.12 and Godot 4.5 or newer.

## Use it

Drop in a `KajmakMap` node instead of a `FuncGodotMap` node. It is a drop in replacement: same map file, same map settings, same Build button. You get the same scene, just lighter.

## Options

On the `KajmakMap` node, under the Kajmak category:

* **cull_hidden_faces** (on) Removes faces hidden behind other solid brushes. Turn it off to build exactly like plain func_godot.
* **cull_exterior_faces** (off) Also removes the outer shell that faces the empty void outside a sealed level. It floods the outside of the BSP and drops anything the outside can reach. Works best on sealed maps. To close an open map, wall it off with skip textured brushes: they never render but still count as solid, so they seal it for the flood while staying invisible in game.
* **debug_log_pairs** (off) Prints what got removed or split to the Output panel.

Collision is never touched. Kajmak only removes visual surfaces.

See [docs/GUIDE.md](docs/GUIDE.md) for how it works and how to spot leaks.
