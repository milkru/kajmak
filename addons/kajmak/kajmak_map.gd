@tool
@icon("res://addons/func_godot/icons/icon_slipgate3d.svg")
class_name KajmakMap extends FuncGodotMap
## A [FuncGodotMap] that builds geometry through [KajmakGeometryGenerator].
##
## Identical to [FuncGodotMap] except the geometry-generation step uses our
## [KajmakGeometryGenerator] subclass. [FuncGodotMap.build] hardcodes
## [code]FuncGodotGeometryGenerator.new(...)[/code], so we override [method build]
## with a copy of that driver and swap in our generator.
##
## In the editor the build runs on a background thread with a small progress
## toolbar (elapsed time + cancel), driven by [KajmakPlugin]. At runtime or in
## headless tools it runs synchronously. Both paths share the same stages:
## [method prepare_build] (main thread) -> [method generate_threaded] (any thread)
## -> [method finish_build] (main thread).

const _KAJMAK_SIGNATURE: String = "[KAJMAK]"

## Shared between the build thread and the editor UI: a cancel flag and the name
## of the current step for the progress label.
class BuildState extends RefCounted:
	var cancelled: bool = false
	var step: String = ""

@export_category("Kajmak")
## When enabled, faces hidden behind adjacent solid geometry are culled at build
## time (qbsp/vbsp-style). Disable to build identically to stock func_godot.
@export var cull_hidden_faces: bool = true
## When enabled, faces that open onto the exterior void of a sealed map are culled
## at build time, like a vis pass. Off by default and independent of
## [member cull_hidden_faces]. Only safe on maps with no leaks to the outside.
@export var cull_exterior_faces: bool = false
## Prints every detected coplanar/opposite overlapping face pair during the build.
@export var debug_log_pairs: bool = false

## Dev-only (not exported): when true, the generator builds a [KajmakBSP] from the
## occluder brushes and prints its stats instead of culling. Used by the BSP
## rewrite harness; leaves normal builds untouched.
var bsp_debug: bool = false
## Dev-only: the BSP built during the last [code]bsp_debug[/code] build, for harnesses.
var bsp_last: Variant = null

## Entry point (also the func_godot tool button target). In the editor with the
## Kajmak plugin loaded, hand off to the threaded build UI; otherwise build
## synchronously on the calling thread (runtime, headless tools, no plugin).
func build() -> void:
	if Engine.is_editor_hint() and Engine.has_meta("kajmak_build_ui"):
		Engine.get_meta("kajmak_build_ui").request_build(self)
	else:
		var state := BuildState.new()
		if not prepare_build():
			return
		var data := generate_threaded(state)
		if not data.is_empty():
			finish_build(data)

## Main-thread setup: profile banner, clear old children, verify, settings. Returns
## false if the build should not proceed.
func prepare_build() -> bool:
	if build_flags & BuildFlags.SHOW_PROFILE_INFO:
		FuncGodotUtil.print_profile_info("Building...", _KAJMAK_SIGNATURE)

	clear_children()

	var verify_err: Error = verify()
	if verify_err != OK:
		fail_build("Verification failed: %s. Aborting map build" % error_string(verify_err), true)
		return false

	if not map_settings:
		push_warning("Map assembler does not have a map settings provided and will use default map settings.")
		load(ProjectSettings.get_setting("func_godot/default_map_settings", "res://addons/func_godot/func_godot_default_map_settings.tres"))
	return true

## Thread-safe stage: parse the map and generate geometry (no scene-tree access).
## Returns {entities, groups} on success, or an empty dictionary on failure or
## cancellation. [param state] carries the cancel flag and current step name.
func generate_threaded(state: BuildState) -> Dictionary:
	var profile: bool = build_flags & BuildFlags.SHOW_PROFILE_INFO

	var parser := FuncGodotParser.new()
	if profile:
		parser.declare_step.connect(FuncGodotUtil.print_profile_info.bind(parser._SIGNATURE))
	var parse_data: FuncGodotData.ParseData = parser.parse_map_data(_map_file_internal, map_settings)
	if parse_data.entities.is_empty() or state.cancelled:
		return {}

	var entities: Array[FuncGodotData.EntityData] = parse_data.entities
	var groups: Array[FuncGodotData.GroupData] = parse_data.groups
	parser = null

	var generator := KajmakGeometryGenerator.new(map_settings, hyperplane_size)
	generator.enable_cull = cull_hidden_faces
	generator.cull_exterior = cull_exterior_faces
	generator.debug_log_pairs = debug_log_pairs
	generator.bsp_debug = bsp_debug
	generator.cancel_state = state
	generator.declare_step.connect(func(s: String) -> void: state.step = s)
	if profile:
		print("\nGEOMETRY GENERATOR (KAJMAK)")
		generator.declare_step.connect(FuncGodotUtil.print_profile_info.bind(generator._SIGNATURE))

	var generate_error := generator.build(build_flags, entities)
	if generate_error != OK or state.cancelled:
		return {}
	bsp_last = generator.bsp_last

	return {"entities": entities, "groups": groups}

## Main-thread finish: assemble nodes from the generated data and signal done.
func finish_build(data: Dictionary) -> void:
	var assembler := FuncGodotEntityAssembler.new(map_settings)
	if build_flags & BuildFlags.SHOW_PROFILE_INFO:
		print("\nENTITY ASSEMBLER")
		assembler.declare_step.connect(FuncGodotUtil.print_profile_info.bind(assembler._SIGNATURE))
	assembler.build(self, data["entities"], data["groups"])

	if build_flags & BuildFlags.SHOW_PROFILE_INFO:
		FuncGodotUtil.print_profile_info("Build complete", _KAJMAK_SIGNATURE)

	build_complete.emit()
