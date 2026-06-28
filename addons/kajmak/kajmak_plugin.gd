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
var _ctx: Dictionary = {}
var _cull_ok: bool = false
var _start_ms: int = 0
var _building: bool = false

func _get_plugin_name() -> String:
	return "kajmak"

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

	# Small spacer so the icon isn't flush against the strip's left edge.
	var lead := Control.new()
	lead.custom_minimum_size = Vector2(6, 0)
	_toolbar.add_child(lead)

	# Size the icon to match the editor's built-in toolbar icons (the same size the
	# bake button uses), reading it from the theme rather than hardcoding.
	var icon_size := Vector2(16, 16) * EditorInterface.get_editor_scale()
	var theme := EditorInterface.get_editor_theme()
	if theme and theme.has_icon("Bake", "EditorIcons"):
		icon_size = theme.get_icon("Bake", "EditorIcons").get_size()

	var icon := TextureRect.new()
	icon.texture = _toolbar_icon()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = icon_size
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_toolbar.add_child(icon)

	_label = Label.new()
	_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_toolbar.add_child(_label)

	_cancel_button = Button.new()
	_cancel_button.text = "Cancel"
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_toolbar.add_child(_cancel_button)

	# Match the toolbar row height so the strip lines up with the menu.
	var row_h := _cancel_button.get_combined_minimum_size().y
	if row_h > 0.0:
		_toolbar.custom_minimum_size = Vector2(0, row_h)

	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.visible = false

# Grayscale icon for the progress toolbar: the func_godot slipgate symbol (same
# family as the KajmakMap node icon, but the monochrome 2D variant rather than the
# tinted 3D node one). Falls back to monochrome editor icons if it is ever missing.
func _toolbar_icon() -> Texture2D:
	const SLIPGATE := "res://addons/func_godot/icons/icon_slipgate.svg"
	if ResourceLoader.exists(SLIPGATE):
		return load(SLIPGATE)
	var theme := EditorInterface.get_editor_theme()
	if theme:
		for name in ["Mesh", "Bake", "Tools"]:
			if theme.has_icon(name, "EditorIcons"):
				return theme.get_icon(name, "EditorIcons")
	return null

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
	_start_ms = Time.get_ticks_msec()

	# Parse + resource-touching pre-cull happen on the main thread (fast).
	_ctx = map.setup_generate(_state)
	if _ctx.is_empty():
		_map = null
		_state = null
		return

	_building = true
	_cull_ok = false
	_cancel_button.disabled = false
	_label.text = "Building map... 0s"
	if _toolbar:
		_toolbar.visible = true

	# Only the cull (pure math) runs on the worker thread.
	_thread = Thread.new()
	_thread.start(_run_cull)
	set_process(true)

# Worker thread body: cull only (no scene tree, no resources).
func _run_cull() -> void:
	_cull_ok = _map.run_cull(_ctx, _state)

func _process(_delta: float) -> void:
	if not _building:
		return

	var elapsed := (Time.get_ticks_msec() - _start_ms) / 1000.0
	var status: String = _state.step if not String(_state.step).is_empty() else "Building map"
	if _state.cancelled:
		status = "Cancelling"
	_label.text = "%s... %ds" % [status, int(elapsed)]

	if _thread != null and not _thread.is_alive():
		_finish()

# Join the worker and, unless cancelled or failed, finish on the main thread.
func _finish() -> void:
	_thread.wait_to_finish()
	_thread = null
	set_process(false)

	var ok: bool = _cull_ok and not _state.cancelled
	var ctx := _ctx
	var map := _map
	_building = false
	_state = null
	_ctx = {}
	_map = null
	if _toolbar:
		_toolbar.visible = false

	if map != null and ok:
		map.finish_staged(ctx)  # surfaces + assemble on the main thread

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
