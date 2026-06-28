@tool
@icon("res://addons/func_godot/icons/icon_slipgate3d.svg")
class_name KajmakMap extends FuncGodotMap
## A [FuncGodotMap] that builds geometry through [KajmakGeometryGenerator].
##
## Identical to [FuncGodotMap] except the geometry-generation step uses our
## [KajmakGeometryGenerator] subclass. [FuncGodotMap.build] hardcodes
## [code]FuncGodotGeometryGenerator.new(...)[/code], so we override [method build]
## with a copy of that driver and swap in our generator. Everything else
## (parser, entity assembler, exports, tool buttons) is inherited unchanged.

const _KAJMAK_SIGNATURE: String = "[KAJMAK]"

@export_category("Kajmak")
## When enabled, faces hidden behind adjacent solid geometry are culled at build
## time (qbsp/vbsp-style). Disable to build identically to stock func_godot.
@export var cull_hidden_faces: bool = true
## Prints every detected coplanar/opposite overlapping face pair during the build.
@export var debug_log_pairs: bool = false

## Dev-only (not exported): when true, the generator builds a [KajmakBSP] from the
## occluder brushes and prints its stats instead of culling. Used by the BSP
## rewrite harness; leaves normal builds untouched.
var bsp_debug: bool = false
## Dev-only: the BSP built during the last [code]bsp_debug[/code] build, for harnesses.
var bsp_last = null

## Copy of [method FuncGodotMap.build] that swaps the geometry generator for
## [KajmakGeometryGenerator]. Kept deliberately close to the original so it stays
## easy to diff against func_godot when the upstream driver changes.
func build() -> void:
	var time_elapsed: float = Time.get_ticks_msec()

	if build_flags & BuildFlags.SHOW_PROFILE_INFO:
		FuncGodotUtil.print_profile_info("Building...", _KAJMAK_SIGNATURE)

	clear_children()

	var verify_err: Error = verify()
	if verify_err != OK:
		fail_build("Verification failed: %s. Aborting map build" % error_string(verify_err), true)
		return

	if not map_settings:
		push_warning("Map assembler does not have a map settings provided and will use default map settings.")
		load(ProjectSettings.get_setting("func_godot/default_map_settings", "res://addons/func_godot/func_godot_default_map_settings.tres"))

	# Parse and collect map data
	var parser := FuncGodotParser.new()
	if build_flags & BuildFlags.SHOW_PROFILE_INFO:
		print("\nPARSER")
		parser.declare_step.connect(FuncGodotUtil.print_profile_info.bind(parser._SIGNATURE))
	var parse_data: FuncGodotData.ParseData = parser.parse_map_data(_map_file_internal, map_settings)

	if parse_data.entities.is_empty():
		return	# Already printed failure message in parser, just return here

	var entities: Array[FuncGodotData.EntityData] = parse_data.entities
	var groups: Array[FuncGodotData.GroupData] = parse_data.groups

	# Free up some memory now that we have the data
	parser = null

	# Retrieve geometry through our culling generator instead of the stock one
	var generator := KajmakGeometryGenerator.new(map_settings, hyperplane_size)
	generator.enable_cull = cull_hidden_faces
	generator.debug_log_pairs = debug_log_pairs
	generator.bsp_debug = bsp_debug
	if build_flags & BuildFlags.SHOW_PROFILE_INFO:
		print("\nGEOMETRY GENERATOR (KAJMAK)")
		generator.declare_step.connect(FuncGodotUtil.print_profile_info.bind(generator._SIGNATURE))

	# Generate surface and shape data
	var generate_error := generator.build(build_flags, entities)
	if generate_error != OK:
		fail_build("Geometry generation failed: %s" % error_string(generate_error))
		return
	bsp_last = generator.bsp_last

	# Assemble entities and groups
	var assembler := FuncGodotEntityAssembler.new(map_settings)
	if build_flags & BuildFlags.SHOW_PROFILE_INFO:
		print("\nENTITY ASSEMBLER")
		assembler.declare_step.connect(FuncGodotUtil.print_profile_info.bind(assembler._SIGNATURE))
	assembler.build(self, entities, groups)

	time_elapsed = Time.get_ticks_msec() - time_elapsed

	if build_flags & BuildFlags.SHOW_PROFILE_INFO:
		print("\nCompleted in %s seconds" % (time_elapsed / 1000.0))
		print("")
		FuncGodotUtil.print_profile_info("Build complete", _KAJMAK_SIGNATURE)

	build_complete.emit()
