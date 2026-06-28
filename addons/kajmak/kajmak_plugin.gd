@tool
class_name KajmakPlugin extends EditorPlugin
## Editor entry point for the Kajmak plugin.
##
## Registers the [KajmakMap] node type and drives the non-blocking build: when a
## KajmakMap is built in the editor, the parse + geometry work runs on a worker
## thread while a small toolbar (icon, status, elapsed time, Cancel) shows in the
## 3D viewport menu. Node assembly runs back on the main thread once the worker
## finishes. Requires the func_godot plugin to also be enabled.

var _toolbar: HBoxContainer
var _label: Label
var _cancel_button: Button

var _thread: Thread = null
var _state: KajmakMap.BuildState = null
var _map: KajmakMap = null
var _result: Dictionary = {}
var _start_ms: int = 0
var _building: bool = false

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
	_build_toolbar()
	# Bridge so KajmakMap.build() (a node) can hand the build to this plugin.
	Engine.set_meta("kajmak_build_ui", self)
	set_process(false)

func _exit_tree() -> void:
	_abort_and_join()
	if Engine.has_meta("kajmak_build_ui"):
		Engine.remove_meta("kajmak_build_ui")
	if _toolbar:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
		_toolbar.queue_free()
		_toolbar = null
	remove_custom_type("KajmakMap")

func _build_toolbar() -> void:
	_toolbar = HBoxContainer.new()
	_toolbar.add_theme_constant_override("separation", 4)

	var icon := TextureRect.new()
	icon.texture = preload("res://addons/func_godot/icons/icon_slipgate3d.svg")
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(16, 16)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_toolbar.add_child(icon)

	_label = Label.new()
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toolbar.add_child(_label)

	_cancel_button = Button.new()
	_cancel_button.text = "Cancel"
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_toolbar.add_child(_cancel_button)

	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.visible = false

## Called by [method KajmakMap.build] in the editor. Runs the main-thread setup,
## then kicks the parse + geometry work onto a worker thread.
func request_build(map: KajmakMap) -> void:
	if _building:
		push_warning("Kajmak: a map build is already running.")
		return
	if not map.prepare_build():
		return

	_map = map
	_state = KajmakMap.BuildState.new()
	_result = {}
	_start_ms = Time.get_ticks_msec()
	_building = true

	_cancel_button.disabled = false
	_label.text = "Building map  0 s"
	if _toolbar:
		_toolbar.visible = true

	_thread = Thread.new()
	_thread.start(_run_generate)
	set_process(true)

# Worker thread body: no scene-tree access, only parse + geometry generation.
func _run_generate() -> void:
	_result = _map.generate_threaded(_state)

func _process(_delta: float) -> void:
	if not _building:
		return

	var elapsed := (Time.get_ticks_msec() - _start_ms) / 1000.0
	var status := _state.step if not _state.step.is_empty() else "Building map"
	if _state.cancelled:
		status = "Cancelling"
	_label.text = "%s  %d s" % [status, int(elapsed)]

	if _thread != null and not _thread.is_alive():
		_finish()

# Join the worker and, unless cancelled or failed, assemble on the main thread.
func _finish() -> void:
	_thread.wait_to_finish()
	_thread = null
	set_process(false)

	var data := _result
	var cancelled := _state.cancelled
	_building = false
	_state = null
	_result = {}
	if _toolbar:
		_toolbar.visible = false

	var map := _map
	_map = null
	if map != null and not cancelled and not data.is_empty():
		map.finish_build(data)

func _on_cancel_pressed() -> void:
	if _state:
		_state.cancelled = true
	_cancel_button.disabled = true

# Force the worker to stop and join it (used when the plugin unloads mid-build).
func _abort_and_join() -> void:
	if _thread != null:
		if _state:
			_state.cancelled = true
		_thread.wait_to_finish()
		_thread = null
	_building = false
	set_process(false)
