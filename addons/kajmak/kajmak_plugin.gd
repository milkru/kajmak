@tool
class_name KajmakPlugin extends EditorPlugin
## Editor entry point for the Kajmak plugin.
##
## Registers the [KajmakMap] node type. Requires the func_godot plugin to also be
## enabled, since [KajmakMap] and [KajmakGeometryGenerator] extend func_godot
## classes.

func _get_plugin_name() -> String:
	return "Kajmak"

func _handles(object: Object) -> bool:
	return object is KajmakMap

func _enter_tree() -> void:
	add_custom_type(
		"KajmakMap",
		"Node3D",
		preload("res://addons/kajmak/kajmak_map.gd"),
		preload("res://addons/func_godot/icons/icon_slipgate3d.svg")
	)

func _exit_tree() -> void:
	remove_custom_type("KajmakMap")
