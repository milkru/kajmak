# Kajmak

Kajmak strips out the faces you never see from your func_godot maps.

When you build a Quake style map with func_godot, every brush is a full solid box. Stack two boxes, push a pillar into a wall, glue a slab onto the floor, and the faces that end up buried inside other geometry still get built and drawn. You cannot see them but the GPU still pays for them. Kajmak finds those hidden faces while the map is building and removes them. When a face is only partly hidden it cuts out the covered part and keeps the rest, so a wall behind a small crate ends up with a neat hole exactly where the crate touches it.

This is the same idea the old Quake and Half Life compilers used when they carved brushes so nothing overlaps. func_godot does not do it, so Kajmak bolts it on as a small separate plugin. It never touches func_godot itself, so you can update func_godot whenever you want.

## What it handles

* Faces fully buried inside another solid brush get removed
* Two faces flush back to back between touching brushes both get removed
* A big face partly covered by smaller brushes gets split so only the visible part stays
* Works across different brushes, different entities and different textures
* Window frames and other shapes that leave a visible island in the middle keep that island
* Skip textured faces still count as solid, so geometry behind them is culled too
* Angled and offset brushes, not just axis aligned boxes

Collision is untouched. Kajmak only removes visual surfaces.

## Install

1. Copy the `addons/kajmak` folder into your project, right next to `addons/func_godot`.
2. Open Project Settings, Plugins, and enable both FuncGodot and Kajmak.
3. That is it.

You need func_godot 2025.12 and Godot 4.5 or newer.

## Use it

Instead of a `FuncGodotMap` node, drop in a `KajmakMap` node. It is a drop in replacement. Same map file, same map settings, same Build Map button. Point its Map Settings at the exact resource you already use, pick your map, and build. You get the same scene, just lighter.

If you already have a scene with a `FuncGodotMap` node, the easiest move is to add a fresh `KajmakMap`, copy over the map file and map settings, and delete the old node.

## Options

On the `KajmakMap` node, under the Kajmak category:

* **cull_hidden_faces** On by default. Turn it off to build exactly like plain func_godot, which is handy if you ever want to compare.
* **cull_exterior_faces** Off by default. Turn it on and Kajmak also removes faces that face the empty void outside a sealed level, like the outer shell of your walls, floors and roof that the player never sees. It builds a little BSP of your solid brushes and floods the empty space from outside in, so anything the outside can reach is fair game. Only switch this on for sealed maps. If there is a hole to the outside the flood leaks in and faces around the leak get kept, so nothing breaks, you just cull less. See the guide for how it works and how to spot leaks.
* **debug_log_pairs** Off by default. Turn it on and rebuild to print what got removed and split to the Output panel. With exterior culling on it also prints how many outside leaves it found and how many faces it dropped. Only useful when something looks off and you want to see what Kajmak noticed.

## What it does not do (yet)

* A brush floating fully inside another solid, with no shared flush face, is not culled. In practice you just avoid burying brushes like that.
* Exterior culling only removes a face when its whole front faces the void. A face that is half outside and half facing a room is kept whole rather than split.

There is more detail in [docs/GUIDE.md](docs/GUIDE.md).
