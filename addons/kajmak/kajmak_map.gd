@tool
@icon("res://addons/func_godot/icons/icon_slipgate3d.svg")
class_name KajmakMap extends FuncGodotMap
## A [FuncGodotMap] that builds geometry through [KajmakGeometryGenerator].
##
## [FuncGodotMap.build] hardcodes the generator, so we override [method build] with
## a copy of its driver and swap ours in. In the editor [KajmakPlugin] runs it on a
## worker thread with a progress toolbar; at runtime/headless it runs synchronously.
## Both share the stages [method prepare_build] -> [method setup_generate] ->
## [method run_cull] (any thread) -> [method finish_staged].

const _KAJMAK_SIGNATURE: String = "[KAJMAK]"

## Shared by the build thread and editor UI: a cancel flag and the current step name.
class BuildState extends RefCounted:
	var cancelled: bool = false
	var step: String = ""

## Lets the plugin make a state without naming the inner class (keeps it func_godot-free).
func make_build_state() -> BuildState:
	return BuildState.new()

@export_category("Kajmak")
## Cull faces hidden behind adjacent solid geometry (qbsp/vbsp-style). Off = builds
## identically to stock func_godot.
@export var cull_hidden_faces: bool = true
## Also cull faces opening onto the exterior void (vis-style). Independent of
## [member cull_hidden_faces]; only safe on sealed maps with no leaks to the outside.
@export var cull_exterior_faces: bool = false
## Print each cull/split decision during the build.
@export var debug_log_pairs: bool = false

## Dev-only (BSP harness): build the occluder BSP and print stats instead of culling.
var bsp_debug: bool = false
## Dev-only: the BSP from the last [code]bsp_debug[/code] build.
var bsp_last: Variant = null

## Entry point (and func_godot tool button target). In the editor with the plugin
## loaded, hand off to the threaded build UI; otherwise build synchronously.
func build() -> void:
	if Engine.is_editor_hint() and Engine.has_meta("kajmak_build_ui"):
		Engine.get_meta("kajmak_build_ui").request_build(self)
	else:
		var state := BuildState.new()
		if not prepare_build():
			return
		var ctx := setup_generate(state)   # parse + pre-cull (resources)
		if ctx.is_empty():
			return
		if not run_cull(ctx, state):       # cull (pure math, threadable)
			return
		finish_staged(ctx)                 # surfaces + assemble (resources)

## Main-thread setup: profile banner, clear children, verify, settings. False = abort.
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

## Stage 1 (MAIN thread): parse the map and run the resource-touching pre-cull
## (materials, vertices, winding). Returns {generator, entities, groups}, or {} on failure.
func setup_generate(state: BuildState) -> Dictionary:
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

	if generator.generate_pre_cull(entities) != OK:
		return {}
	return {"generator": generator, "entities": entities, "groups": groups}

## Stage 2 (any thread): the cull. Pure math, no resources, so it runs off the main
## thread in the editor. False on cancel.
func run_cull(ctx: Dictionary, state: BuildState) -> bool:
	var generator: KajmakGeometryGenerator = ctx["generator"]
	if generator.cull_step() != OK or state.cancelled:
		return false
	return true

## Stage 3 (MAIN thread): generate surfaces (mesh resources) and assemble nodes.
func finish_staged(ctx: Dictionary) -> void:
	var generator: KajmakGeometryGenerator = ctx["generator"]
	if generator.generate_post_cull(build_flags) != OK:
		return
	bsp_last = generator.bsp_last

	var assembler := FuncGodotEntityAssembler.new(map_settings)
	if build_flags & BuildFlags.SHOW_PROFILE_INFO:
		print("\nENTITY ASSEMBLER")
		assembler.declare_step.connect(FuncGodotUtil.print_profile_info.bind(assembler._SIGNATURE))
	assembler.build(self, ctx["entities"], ctx["groups"])

	if build_flags & BuildFlags.SHOW_PROFILE_INFO:
		FuncGodotUtil.print_profile_info("Build complete", _KAJMAK_SIGNATURE)

	build_complete.emit()
