@tool
class_name KajmakGeometryGenerator extends FuncGodotGeometryGenerator
## func_godot geometry generator with import-time hidden-face culling.
##
## Subclasses [FuncGodotGeometryGenerator] so we can inject a global, CSG-style
## hidden-face culling pre-pass (clip each visual face against adjacent solid
## brush volumes and drop the covered fragments) without modifying func_godot.
##
## Skeleton stage: no overrides yet. Builds identically to stock func_godot.
## Culling logic is added in later steps (see RESEARCH.md task breakdown).
