@tool
extends EditorPlugin

## Adds the Kimodo dock. Everything the dock does is a call into the
## GDExtension; the plugin itself only owns the panel.

const KimodoDock := preload("res://addons/kimodo/dock.gd")
const Settings := preload("res://addons/kimodo/settings.gd")

var _dock: Control


func _enter_tree() -> void:
	# Declared here rather than from the dock, so the settings are listed in
	# Editor Settings whether or not anyone opens the panel.
	Settings.register()

	_dock = KimodoDock.new()
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	# Selection changes reach the dock on their own. Opening another scene does
	# not, and it can take the target skeleton with it.
	scene_changed.connect(_on_scene_changed)


func _on_scene_changed(_root: Node) -> void:
	if is_instance_valid(_dock):
		_dock.refresh_target()


func _exit_tree() -> void:
	if not is_instance_valid(_dock):
		return
	remove_control_from_docks(_dock)
	_dock.queue_free()
	_dock = null
