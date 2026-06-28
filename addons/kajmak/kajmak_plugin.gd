@tool
class_name KajmakPlugin extends EditorPlugin
## Editor entry point for the Kajmak plugin.
##
## Registers the [code]KajmakMap[/code] node type and drives the non-blocking
## build: parse + geometry work runs on a worker thread while a small toolbar
## (icon, status, elapsed time, Cancel) shows in the 3D viewport menu; node
## assembly runs back on the main thread when the worker finishes.
##
## Kajmak depends on the func_godot plugin (KajmakMap extends FuncGodotMap). This
## script is deliberately written WITHOUT any compile-time reference to func_godot
## or KajmakMap, so that when func_godot is missing it can still load, detect the
## problem and show a clear message instead of failing with cryptic errors.

const _FUNC_GODOT_CFG := "res://addons/func_godot/plugin.cfg"
const _MAP_SCRIPT := "res://addons/kajmak/kajmak_map.gd"
const _ICON := "res://addons/func_godot/icons/icon_slipgate3d.svg"

var _map_script: Script = null

var _toolbar: HBoxContainer
var _label: Label
var _cancel_button: Button

var _thread: Thread = null
var _state: RefCounted = null
var _map: Node = null
var _result: Dictionary = {}
var _start_ms: int = 0
var _building: bool = false

func _get_plugin_name() -> String:
	return "Kajmak"

func _handles(object: Object) -> bool:
	return _map_script != null and is_instance_valid(object) and object.get_script() == _map_script

const _FUNC_GODOT_NAME := "func_godot"

func _enter_tree() -> void:
	# Kajmak needs func_godot both installed and enabled: its classes back KajmakMap
	# and its plugin sets up the project settings and authoring pipeline we rely on.
	if not FileAccess.file_exists(_FUNC_GODOT_CFG):
		_warn("Kajmak requires the func_godot plugin, which is not installed at addons/func_godot.\n\nInstall func_godot and enable it, then re-enable Kajmak.")
		return
	if not EditorInterface.is_plugin_enabled(_FUNC_GODOT_NAME):
		_warn("Kajmak requires the func_godot plugin, which is installed but not enabled.\n\nEnable func_godot in Project Settings > Plugins, then re-enable Kajmak.")
		return

	_map_script = load(_MAP_SCRIPT)
	add_custom_type("KajmakMap", "Node3D", _map_script, load(_ICON))
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
	if _map_script != null:
		remove_custom_type("KajmakMap")

func _warn(msg: String) -> void:
	push_error("[Kajmak] " + msg)
	var dialog := AcceptDialog.new()
	dialog.title = "Kajmak"
	dialog.dialog_text = msg
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered.call_deferred()

func _build_toolbar() -> void:
	_toolbar = HBoxContainer.new()
	_toolbar.add_theme_constant_override("separation", 4)

	var icon := TextureRect.new()
	icon.texture = load(_ICON)
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

## Called by KajmakMap.build() in the editor. Runs the main-thread setup, then
## kicks the parse + geometry work onto a worker thread.
func request_build(map: Object) -> void:
	if _building:
		push_warning("Kajmak: a map build is already running.")
		return
	if not map.prepare_build():
		return

	_map = map
	_state = map.make_build_state()
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
	var status: String = _state.step if not String(_state.step).is_empty() else "Building map"
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
	var cancelled: bool = _state.cancelled
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
